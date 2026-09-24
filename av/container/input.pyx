from libc.stdint cimport int64_t
from libc.stdlib cimport calloc, free, malloc

from av.codec.context cimport CodecContext, wrap_codec_context
from av.container.pyio cimport PyIOFile, pyio_close_custom_gil
from av.container.streams cimport StreamContainer
from av.dictionary cimport _Dictionary
from av.error cimport err_check
from av.packet cimport Packet
from av.stream cimport Stream, wrap_stream
from av.utils cimport avdict_to_dict

from av.dictionary import Dictionary


cdef close_input(InputContainer self):
    cdef Stream stream
    cdef PyIOFile file
    cdef object first_error = None

    if not self.input_was_opened:
        return

    # Reject reentrant close/read calls, including calls from I/O callbacks.
    self.input_was_opened = False
    try:
        if self.streams is not None:
            for stream in self.streams:
                try:
                    if stream.codec_context is not None:
                        stream.codec_context.close(strict=False)
                except BaseException as exc:
                    # A decoder error must not leave the other decoders open.
                    if first_error is None:
                        first_error = exc
    finally:
        try:
            with nogil:
                # Also sets self.ptr to NULL. Keep Python I/O alive until done.
                lib.avformat_close_input(&self.ptr)
            try:
                self.err_check(0)  # Propagate any stashed I/O close exception.
            except BaseException as exc:
                if first_error is None:
                    first_error = exc
            # Some demuxers leave the top-level custom I/O to its owner.
            # Files returned by io_open are ours to close; self.file is not.
            if self.open_files is not None:
                for file in self.open_files.values():
                    try:
                        pyio_close_custom_gil(file.iocontext)
                        self.err_check(0)
                    except BaseException as exc:
                        if first_error is None:
                            first_error = exc
        finally:
            if self.streams is not None:
                # Break the reference cycle without allocating a replacement.
                self.streams.clear()
            if self.open_files is not None:
                self.open_files.clear()
            self.file = None
            self.io_open = None
            stream = None
            file = None

    if first_error is not None:
        raise first_error


cdef class InputContainer(Container):
    def __cinit__(self, *args, **kwargs):
        cdef CodecContext py_codec_context
        cdef unsigned int i
        cdef lib.AVStream *stream
        cdef lib.AVCodec *codec
        cdef lib.AVCodecContext *codec_context = NULL

        # If we have either the global `options`, or a `stream_options`, prepare
        # a mashup of those options for each stream.
        cdef lib.AVDictionary **c_options = NULL
        cdef unsigned int nb_streams = self.ptr.nb_streams
        cdef _Dictionary base_dict, stream_dict
        try:
            try:
                if nb_streams and (self.options or self.stream_options):
                    base_dict = Dictionary(self.options)
                    c_options = <lib.AVDictionary**>calloc(nb_streams, sizeof(lib.AVDictionary*))
                    if c_options == NULL:
                        raise MemoryError("Could not allocate stream options")
                    for i in range(nb_streams):
                        if i < len(self.stream_options):
                            stream_dict = base_dict.copy()
                            stream_dict.update(self.stream_options[i])
                            err_check(lib.av_dict_copy(&c_options[i], stream_dict.ptr, 0))
                        else:
                            err_check(lib.av_dict_copy(&c_options[i], base_dict.ptr, 0))

                self.set_timeout(self.open_timeout)
                self.start_timeout()
                with nogil:
                    ret = lib.avformat_find_stream_info(self.ptr, c_options)
                self.err_check(ret)
            finally:
                self.set_timeout(None)
                if c_options != NULL:
                    # Probing may have added streams; use the allocation count.
                    for i in range(nb_streams):
                        lib.av_dict_free(&c_options[i])
                    free(c_options)

            self.streams = StreamContainer()
            for i in range(self.ptr.nb_streams):
                stream = self.ptr.streams[i]
                codec = lib.avcodec_find_decoder(stream.codecpar.codec_id)
                if codec:
                    codec_context = lib.avcodec_alloc_context3(codec)
                    if codec_context == NULL:
                        raise MemoryError("Could not allocate codec context")
                    try:
                        err_check(lib.avcodec_parameters_to_context(codec_context, stream.codecpar))
                        codec_context.pkt_timebase = stream.time_base
                    except BaseException:
                        lib.avcodec_free_context(&codec_context)
                        raise
                    # wrap_codec_context takes ownership, including on failure.
                    py_codec_context = wrap_codec_context(codec_context, codec)
                    codec_context = NULL
                else:
                    py_codec_context = None
                self.streams.add_stream(wrap_stream(self, stream, py_codec_context))

            self.metadata = avdict_to_dict(self.ptr.metadata, self.metadata_encoding, self.metadata_errors)
        except BaseException:
            # Partially built streams can already form a reference cycle.
            # Release them now, without replacing the original open error.
            try:
                close_input(self)
            except BaseException:
                pass
            raise

    def __dealloc__(self):
        # Python members may already have been cleared by cyclic GC. Their
        # own destructors release the codec contexts and custom I/O buffers.
        if self.input_was_opened:
            self.input_was_opened = False
            with nogil:
                lib.avformat_close_input(&self.ptr)

    @property
    def start_time(self):
        self._assert_open()
        if self.ptr.start_time != lib.AV_NOPTS_VALUE:
            return self.ptr.start_time

    @property
    def duration(self):
        self._assert_open()
        if self.ptr.duration != lib.AV_NOPTS_VALUE:
            return self.ptr.duration

    @property
    def bit_rate(self):
        self._assert_open()
        return self.ptr.bit_rate

    @property
    def size(self):
        self._assert_open()
        return lib.avio_size(self.ptr.pb)

    def close(self):
        """Close the input and its decoders, releasing streams and custom I/O.

        Already returned frames and packet data remain valid. Stream operations
        require an open container. A caller-supplied file object is not closed.
        """
        close_input(self)

    def demux(self, *args, **kwargs):
        """demux(streams=None, video=None, audio=None, subtitles=None, data=None)

        Yields a series of :class:`.Packet` from the given set of :class:`.Stream`::

            for packet in container.demux():
                # Do something with `packet`, often:
                for frame in packet.decode():
                    # Do something with `frame`.

        .. seealso:: :meth:`.StreamContainer.get` for the interpretation of
            the arguments.

        .. note:: The last packets are dummy packets that when decoded will flush the buffers.

        """
        self._assert_open()

        # For whatever reason, Cython does not like us directly passing kwargs
        # from one method to another. Without kwargs, it ends up passing a
        # NULL reference, which segfaults. So we force it to do something with it.
        # This is likely a bug in Cython; see https://github.com/cython/cython/issues/2166
        # (and others).
        id(kwargs)

        streams = self.streams.get(*args, **kwargs)

        cdef bint *include_stream = <bint*>malloc(self.ptr.nb_streams * sizeof(bint))
        if include_stream == NULL:
            raise MemoryError()

        cdef unsigned int i
        cdef Packet packet
        cdef int ret

        self.set_timeout(self.read_timeout)
        try:
            for i in range(self.ptr.nb_streams):
                include_stream[i] = False
            for stream in streams:
                i = stream.index
                if i >= self.ptr.nb_streams:
                    raise ValueError(f"stream index {i} out of range")
                include_stream[i] = True

            while True:
                packet = Packet()
                try:
                    self.start_timeout()
                    with nogil:
                        ret = lib.av_read_frame(self.ptr, packet.ptr)
                    self.err_check(ret)
                except EOFError:
                    break

                if include_stream[packet.ptr.stream_index]:
                    # If AVFMTCTX_NOHEADER is set in ctx_flags, then new streams
                    # may also appear in av_read_frame().
                    # http://ffmpeg.org/doxygen/trunk/structAVFormatContext.html
                    # TODO: find better way to handle this
                    if packet.ptr.stream_index < len(self.streams):
                        packet._stream = self.streams[packet.ptr.stream_index]
                        # Keep track of this so that remuxing is easier.
                        packet._time_base = packet._stream.ptr.time_base
                        yield packet
                        self._assert_open()

            # Flush!
            for i in range(self.ptr.nb_streams):
                if include_stream[i]:
                    packet = Packet()
                    packet._stream = self.streams[i]
                    packet._time_base = packet._stream.ptr.time_base
                    yield packet
                    self._assert_open()

        finally:
            self.set_timeout(None)
            free(include_stream)

    def decode(self, *args, **kwargs):
        """decode(streams=None, video=None, audio=None, subtitles=None, data=None)

        Yields a series of :class:`.Frame` from the given set of streams::

            for frame in container.decode():
                # Do something with `frame`.

        .. seealso:: :meth:`.StreamContainer.get` for the interpretation of
            the arguments.

        """
        self._assert_open()
        id(kwargs)  # Avoid Cython bug; see demux().
        for packet in self.demux(*args, **kwargs):
            for frame in packet.decode():
                self._assert_open()
                yield frame

    def seek(
        self, offset, *, bint backward=True, bint any_frame=False, Stream stream=None,
        bint unsupported_frame_offset=False, bint unsupported_byte_offset=False
    ):
        """seek(offset, *, backward=True, any_frame=False, stream=None)

        Seek to a (key)frame nearsest to the given timestamp.

        :param int offset: Time to seek to, expressed in``stream.time_base`` if ``stream``
            is given, otherwise in :data:`av.time_base`.
        :param bool backward: If there is not a (key)frame at the given offset,
            look backwards for it.
        :param bool any_frame: Seek to any frame, not just a keyframe.
        :param Stream stream: The stream who's ``time_base`` the ``offset`` is in.

        :param bool unsupported_frame_offset: ``offset`` is a frame
            index instead of a time; not supported by any known format.
        :param bool unsupported_byte_offset: ``offset`` is a byte
            location in the file; not supported by any known format.

        After seeking, packets that you demux should correspond (roughly) to
        the position you requested.

        In most cases, the defaults of ``backwards = True`` and ``any_frame = False``
        are the best course of action, followed by you demuxing/decoding to
        the position that you want. This is becase to properly decode video frames
        you need to start from the previous keyframe.

        .. seealso:: :ffmpeg:`avformat_seek_file` for discussion of the flags.

        """
        self._assert_open()

        # We used to take floats here and assume they were in seconds. This
        # was super confusing, so lets go in the complete opposite direction
        # and reject non-ints.
        if not isinstance(offset, int):
            raise TypeError("Container.seek only accepts integer offset.", type(offset))

        cdef int64_t c_offset = offset

        cdef int flags = 0
        cdef int ret

        if backward:
            flags |= lib.AVSEEK_FLAG_BACKWARD
        if any_frame:
            flags |= lib.AVSEEK_FLAG_ANY

        # If someone really wants (and to experiment), expose these.
        if unsupported_frame_offset:
            flags |= lib.AVSEEK_FLAG_FRAME
        if unsupported_byte_offset:
            flags |= lib.AVSEEK_FLAG_BYTE

        cdef int stream_index = stream.index if stream else -1
        with nogil:
            ret = lib.av_seek_frame(self.ptr, stream_index, c_offset, flags)
        err_check(ret)

        self.flush_buffers()

    cdef flush_buffers(self):
        self._assert_open()

        cdef Stream stream
        cdef CodecContext codec_context

        for stream in self.streams:
            codec_context = stream.codec_context
            if codec_context:
                codec_context.flush_buffers()
