import base64
import hashlib
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from zipfile import ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from verify_release import FEED_URL, SPARKLE_NS, verify


def make_package(archive, revision, version="1.0.0", executable=True, cpu=0x0100000C,
                 automatic_updates=False, include_updater=True):
    root = "MenuRemote.app/Contents/"
    with ZipFile(archive, "w") as bundle:
        bundle.writestr(root + "Info.plist", plistlib.dumps({
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "MenuRemoteRevision": revision,
            "CFBundleIdentifier": "com.nickkjolsing.menuremote",
            "SUFeedURL": FEED_URL,
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
            "SUEnableAutomaticChecks": automatic_updates,
            "SUAutomaticallyUpdate": False,
            "SUAllowsAutomaticUpdates": False,
            "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True,
        }))
        binary = ZipInfo(root + "MacOS/MenuRemote")
        binary.external_attr = (0o100755 if executable else 0o100644) << 16
        bundle.writestr(binary, struct.pack("<II", 0xFEEDFACF, cpu))
        for resource in ("atv_bridge.py", "AppIcon.icns", "LICENSE"):
            bundle.writestr(root + "Resources/" + resource, b"sample")
        if include_updater:
            for name in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater"):
                component = ZipInfo(root + "Frameworks/Sparkle.framework/Versions/B/" + name)
                component.external_attr = 0o100755 << 16
                bundle.writestr(component, b"sample")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")


def make_appcast(archive, version="1.0.0", download_url=None):
    """Structural fixture only; real signatures are exercised by test_updater.py."""
    signature = base64.b64encode(bytes(64)).decode()
    download_url = download_url or f"https://github.com/nickkjolsing/menuremote/releases/download/v{version}/{archive.name}"
    content = (f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0"><channel><item>'
               f'<sparkle:version>{version}</sparkle:version>'
               f'<enclosure url="{download_url}" length="{archive.stat().st_size}" '
               f'sparkle:edSignature="{signature}" /></item></channel></rss>').encode()
    (archive.parent / "appcast.xml").write_bytes(
        content + f'<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n'.encode())


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.archive = Path(self.temp.name) / "MenuRemote-1.0.0-macOS-arm64.zip"
        self.revision = "a" * 40

    def package(self, version="1.0.0", executable=True, cpu=0x0100000C):
        make_package(self.archive, self.revision, version, executable, cpu)

    def test_valid_package(self):
        self.package()
        verify(self.archive, "1.0.0", self.revision)

    def test_modified_download_is_rejected(self):
        self.package()
        with self.archive.open("ab") as archive:
            archive.write(b"unexpected bytes")
        with self.assertRaisesRegex(ValueError, "checksum"):
            verify(self.archive, "1.0.0", self.revision)

    def test_wrong_version_or_commit_is_rejected(self):
        self.package()
        for version, revision in (("2.0.0", self.revision), ("1.0.0", "b" * 40)):
            with self.subTest(version=version, revision=revision):
                with self.assertRaisesRegex(ValueError, "source commit"):
                    verify(self.archive, version, revision)

    def test_missing_executable_permission_is_rejected(self):
        self.package(executable=False)
        with self.assertRaisesRegex(ValueError, "permissions"):
            verify(self.archive, "1.0.0", self.revision)

    def test_intel_binary_is_rejected(self):
        self.package(cpu=0x01000007)
        with self.assertRaisesRegex(ValueError, "Apple silicon"):
            verify(self.archive, "1.0.0", self.revision)

    def test_publish_requires_a_signed_feed(self):
        self.package()
        with self.assertRaisesRegex(ValueError, "SPARKLE_PRIVATE_KEY"):
            verify(self.archive, "1.0.0", self.revision, require_appcast=True)
        make_appcast(self.archive)
        verify(self.archive, "1.0.0", self.revision, require_appcast=True)

    def test_feed_cannot_point_to_a_different_version_or_download(self):
        self.package()
        for kwargs in ({"version": "2.0.0"}, {"download_url": "https://example.com/other.zip"}):
            make_appcast(self.archive, **kwargs)
            with self.assertRaisesRegex(ValueError, "does not match"):
                verify(self.archive, "1.0.0", self.revision, require_appcast=True)

    def test_automatic_checks_cannot_be_enabled_in_release(self):
        make_package(self.archive, self.revision, automatic_updates=True)
        with self.assertRaisesRegex(ValueError, "user initiated"):
            verify(self.archive, "1.0.0", self.revision)

    def test_missing_updater_framework_is_rejected(self):
        make_package(self.archive, self.revision, include_updater=False)
        with self.assertRaises(KeyError):
            verify(self.archive, "1.0.0", self.revision)


if __name__ == "__main__":
    unittest.main()
