import hashlib
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from zipfile import ZipFile, ZipInfo

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from verify_release import verify


def make_package(archive, revision, version="1.0.0", executable=True, cpu=0x0100000C):
    root = "MenuRemote.app/Contents/"
    with ZipFile(archive, "w") as bundle:
        bundle.writestr(root + "Info.plist", plistlib.dumps({
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "MenuRemoteRevision": revision,
            "CFBundleIdentifier": "com.nickkjolsing.menuremote",
        }))
        binary = ZipInfo(root + "MacOS/MenuRemote")
        binary.external_attr = (0o100755 if executable else 0o100644) << 16
        bundle.writestr(binary, struct.pack("<II", 0xFEEDFACF, cpu))
        for resource in ("atv_bridge.py", "AppIcon.icns", "LICENSE"):
            bundle.writestr(root + "Resources/" + resource, b"sample")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{digest}  {archive.name}\n")


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


if __name__ == "__main__":
    unittest.main()
