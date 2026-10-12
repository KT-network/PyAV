import gc
import io
import weakref
from unittest import TestCase

import av


class TestInputClose(TestCase):
    def open_input(self, source=None):
        if source is None:
            source = io.BytesIO(bytes(64 * 48 * 3 * 3))
        return av.open(
            source,
            format="rawvideo",
            options={"video_size": "64x48", "pixel_format": "rgb24"},
        )

    def test_close_releases_decoder_with_retained_references(self):
        container = self.open_input()
        stream = container.streams.video[0]
        packets = container.demux(stream)
        packet = next(packets)
        frame = packet.decode()[0]
        self.assertTrue(stream.codec_context.is_open)

        try:
            container.close()
            self.assertFalse(stream.codec_context.is_open)
            self.assertEqual(len(container.streams), 0)
            # Frames already returned to the caller must remain usable.
            self.assertEqual((frame.width, frame.height), (64, 48))
            self.assertEqual(bytes(frame.planes[0]), bytes(64 * 48 * 3))
            self.assertEqual(packet.size, 64 * 48 * 3)
            container.close()
        finally:
            packets.close()
            container.close()

    def test_close_before_decoding(self):
        container = self.open_input()
        context = container.streams.video[0].codec_context
        self.assertFalse(context.is_open)
        container.close()
        container.close()
        self.assertFalse(context.is_open)
        self.assertEqual(len(container.streams), 0)

    def test_context_manager_closes_decoder(self):
        with self.open_input() as container:
            context = container.streams.video[0].codec_context
            frames = container.decode(video=0)
            next(frames)
            self.assertTrue(context.is_open)
        try:
            self.assertFalse(context.is_open)
        finally:
            frames.close()

    def test_context_manager_closes_decoder_on_exception(self):
        with self.assertRaisesRegex(RuntimeError, "stop capture"):
            with self.open_input() as container:
                context = container.streams.video[0].codec_context
                next(container.decode(video=0))
                raise RuntimeError("stop capture")
        self.assertFalse(context.is_open)

    def test_closed_inputs_do_not_require_cyclic_gc(self):
        was_enabled = gc.isenabled()
        gc.disable()
        try:
            for _ in range(10):
                source = io.BytesIO(bytes(64 * 48 * 3 * 3))
                reference = weakref.ref(source)
                container = self.open_input(source)
                next(container.decode(video=0))
                container.close()
                del container, source
                self.assertIsNone(reference())
        finally:
            if was_enabled:
                gc.enable()
            gc.collect()

    def test_resume_demux_after_close(self):
        container = self.open_input()
        packets = container.demux(video=0)
        next(packets)
        container.close()
        with self.assertRaisesRegex(AssertionError, "Container is not open"):
            next(packets)

    def test_resume_decode_after_close(self):
        container = self.open_input()
        context = container.streams.video[0].codec_context
        frames = container.decode(video=0)
        next(frames)
        container.close()
        with self.assertRaisesRegex(AssertionError, "Container is not open"):
            next(frames)
        self.assertFalse(context.is_open)

    def test_resume_demux_after_close_during_flush(self):
        container = self.open_input()
        packets = container.demux(video=0)
        for _ in range(3):
            self.assertGreater(next(packets).size, 0)
        self.assertEqual(next(packets).size, 0)
        container.close()
        with self.assertRaisesRegex(AssertionError, "Container is not open"):
            next(packets)
