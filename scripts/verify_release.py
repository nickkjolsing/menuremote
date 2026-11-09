"""Verify release identity and integrity on both macOS builders and Linux publishers."""

import hashlib
from pathlib import Path
import plistlib
import struct
import sys
from zipfile import ZipFile


def verify(archive, version, revision):
    archive = Path(archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    expected_checksum = f"{digest}  {archive.name}\n"
    if archive.with_suffix(".zip.sha256").read_text() != expected_checksum:
        raise ValueError("Release checksum does not match the archive")

    with ZipFile(archive) as bundle:
        root = "MenuRemote.app/Contents/"
        info = plistlib.loads(bundle.read(root + "Info.plist"))
        if (info["CFBundleShortVersionString"], info["CFBundleVersion"],
                info["MenuRemoteRevision"], info["CFBundleIdentifier"]) != (
                version, version, revision, "com.nickkjolsing.menuremote"):
            raise ValueError("Release version or source commit does not match the build")
        executable = bundle.getinfo(root + "MacOS/MenuRemote")
        if not (executable.external_attr >> 16) & 0o111:
            raise ValueError("App executable lost its executable permissions")
        # A thin 64-bit Mach-O header followed by CPU_TYPE_ARM64.
        if bundle.read(executable)[:8] != struct.pack("<II", 0xFEEDFACF, 0x0100000C):
            raise ValueError("App executable is not an Apple silicon Mach-O binary")
        for resource in ("atv_bridge.py", "AppIcon.icns", "LICENSE"):
            if not bundle.read(root + "Resources/" + resource):
                raise ValueError(f"Empty app resource: {resource}")


if __name__ == "__main__":
    verify(*sys.argv[1:])
    print("Release checksum, bundle, version, and source commit verified")
