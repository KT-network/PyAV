"""Screen bundled PE files for known Windows 8+ requirements.

This static check does not replace a runtime test on Windows 7 SP1.
"""

import sys
import zipfile
from pathlib import Path

import pefile

# These imports are unavailable on Windows 7, even with the UCRT updates.
UNSUPPORTED_IMPORTS = {
    "CreateFile2",
    "DiscardVirtualMemory",
    "GetCurrentPackageId",
    "GetCurrentThreadStackLimits",
    "GetOverlappedResultEx",
    "GetProcessMitigationPolicy",
    "GetSystemCpuSetInformation",
    "GetSystemTimePreciseAsFileTime",
    "GetTempPath2A",
    "GetTempPath2W",
    "GetThreadDescription",
    "GetThreadInformation",
    "MFCreateDXGIDeviceManager",
    "MFCreateDXGISurfaceBuffer",
    "MFTEnum2",
    "OfferVirtualMemory",
    "ReclaimVirtualMemory",
    "SetProcessMitigationPolicy",
    "SetThreadDescription",
    "SetThreadInformation",
    "WaitOnAddress",
    "WakeByAddressAll",
    "WakeByAddressSingle",
}
UNSUPPORTED_DLLS = {
    "api-ms-win-core-path-l1-1-0.dll",
    "api-ms-win-core-synch-l1-2-0.dll",
    "api-ms-win-core-winrt-l1-1-0.dll",
    "api-ms-win-core-winrt-string-l1-1-0.dll",
}


def check_pe(name, data):
    pe = pefile.PE(data=data, fast_load=True)
    errors = []
    if pe.FILE_HEADER.Machine != pefile.MACHINE_TYPE["IMAGE_FILE_MACHINE_AMD64"]:
        errors.append(f"{name}: expected x64")
    header = pe.OPTIONAL_HEADER
    for label, version in (
        (
            "OS",
            (header.MajorOperatingSystemVersion, header.MinorOperatingSystemVersion),
        ),
        ("subsystem", (header.MajorSubsystemVersion, header.MinorSubsystemVersion)),
    ):
        if version > (6, 1):
            errors.append(f"{name}: {label} requires Windows {version}")
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]]
    )
    # Delay-loaded and dynamically resolved APIs may have runtime fallbacks.
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
        dll = entry.dll.decode("ascii").lower()
        if dll in UNSUPPORTED_DLLS:
            errors.append(f"{name}: imports {dll}")
        for symbol in entry.imports:
            if symbol.name:
                api = symbol.name.decode("ascii")
                if api in UNSUPPORTED_IMPORTS:
                    errors.append(f"{name}: imports {dll}!{api}")
    pe.close()
    return errors


def main():
    wheels = sorted(Path(sys.argv[1]).glob("*-cp38-cp38-win_amd64.whl"))
    if not wheels:
        raise RuntimeError("No CPython 3.8 x64 Windows wheel found")
    errors = []
    count = 0
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as archive:
            binaries = [
                name for name in archive.namelist() if name.endswith((".pyd", ".dll"))
            ]
            if not any(name.endswith(".pyd") for name in binaries):
                errors.append(f"{wheel.name}: no extension modules")
            if not any(name.endswith(".dll") for name in binaries):
                errors.append(f"{wheel.name}: no bundled FFmpeg DLLs")
            for name in binaries:
                errors.extend(check_pe(name, archive.read(name)))
                count += 1
    if errors:
        raise RuntimeError(
            "Windows 7 compatibility check failed:\n" + "\n".join(errors)
        )
    print(f"Checked {count} PE files: no known Windows 8+ requirements found")


if __name__ == "__main__":
    main()
