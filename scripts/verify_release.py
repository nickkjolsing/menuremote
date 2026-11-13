"""Verify release identity and integrity on both macOS builders and Linux publishers."""

import base64
import hashlib
from pathlib import Path
import plistlib
import re
import struct
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile


FEED_URL = "https://github.com/nickkjolsing/menuremote/releases/latest/download/appcast.xml"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def verify(archive, version, revision, require_appcast=False):
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
        if info.get("SUFeedURL") != FEED_URL:
            raise ValueError("App update feed does not point to the production release feed")
        if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
            raise ValueError("App is missing its Sparkle public signing key")
        if any(info.get(key) is not False for key in (
            "SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"
        )):
            raise ValueError("Updates must remain user initiated")
        if not all(info.get(key) is True for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed")):
            raise ValueError("Update archives and feeds must require signatures")
        framework = root + "Frameworks/Sparkle.framework/Versions/B/"
        for binary in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"):
            item = bundle.getinfo(framework + binary)
            if not bundle.read(item) or not (item.external_attr >> 16) & 0o111:
                raise ValueError(f"Missing executable Sparkle component: {binary}")

    appcast = archive.parent / "appcast.xml"
    if require_appcast or appcast.exists():
        verify_appcast(appcast, archive, version)


def verify_appcast(appcast, archive, version):
    """Check release identity; Sparkle verifies Ed25519 signatures at runtime."""
    appcast = Path(appcast)
    if not appcast.exists():
        raise ValueError("Signed appcast.xml is missing; configure SPARKLE_PRIVATE_KEY before publishing")
    data = appcast.read_bytes()
    feed_signature = re.search(rb"<!-- sparkle-signatures:\s+edSignature: ([A-Za-z0-9+/=]+)\s+length: (\d+)\s+-->\s*$", data)
    if (feed_signature is None
            or len(base64.b64decode(feed_signature[1], validate=True)) != 64
            or int(feed_signature[2]) != feed_signature.start()):
        raise ValueError("Update feed must have an embedded Sparkle signature")
    items = ET.fromstring(data).findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Release update feed must describe exactly this release")
    item = items[0]
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Update feed is missing the archive enclosure")
    expected_url = f"https://github.com/nickkjolsing/menuremote/releases/download/v{version}/{archive.name}"
    if (item.findtext(f"{{{SPARKLE_NS}}}version"),
        enclosure.get("url"), enclosure.get("length")) != (
            version, expected_url, str(Path(archive).stat().st_size)):
        raise ValueError("Update feed version, download URL, or length does not match the archive")
    signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Update archive signature is missing or invalid")


if __name__ == "__main__":
    args = sys.argv[1:]
    require_appcast = "--require-appcast" in args
    if require_appcast:
        args.remove("--require-appcast")
    verify(*args, require_appcast=require_appcast)
    print("Release checksum, bundle, version, and source commit verified")
