"""Exercise publishing offline, including a failed upload followed by a retry."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_release import make_appcast, make_package


FAKE_GH = '''#!/usr/bin/env python3
import json, pathlib, shutil, sys
state_path = pathlib.Path("remote/state.json")
state = json.loads(state_path.read_text())
args = sys.argv[1:]
command = args[:2]
if command == ["release", "list"]:
    if state["exists"]:
        print("v1.0.0")
elif args[0] == "api":
    print(state["revision"])
elif command == ["release", "view"]:
    if args[args.index("--json") + 1] == "assets":
        for path in pathlib.Path("remote/assets").iterdir():
            print(path.name)
    else:
        print(str(state["draft"]).lower())
elif command == ["release", "upload"]:
    source = pathlib.Path(args[3])
    if ((state.get("fail_checksum") and source.name.endswith(".sha256"))
            or (state.get("fail_feed") and source.name == "appcast.xml")):
        sys.exit(1)
    destination = pathlib.Path("remote/assets") / source.name
    if destination.exists():
        sys.exit("Attempted to overwrite an existing asset")
    shutil.copyfile(source, destination)
elif command == ["release", "download"]:
    name = args[args.index("--pattern") + 1]
    destination = pathlib.Path(args[args.index("--dir") + 1]) / name
    shutil.copyfile(pathlib.Path("remote/assets") / name, destination)
elif command == ["release", "edit"]:
    if len(list(pathlib.Path("remote/assets").iterdir())) != 3:
        sys.exit("Published before all three assets were attached")
    state["draft"] = False
else:
    sys.exit(f"Unexpected command: {args}")
state_path.write_text(json.dumps(state))
'''


class ReleasePublishingTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for directory in ("scripts", "dist", "bin", "remote/assets"):
            (self.root / directory).mkdir(parents=True)
        source = Path(__file__).resolve().parents[1]
        for name in ("publish_release.sh", "verify_release.py"):
            shutil.copyfile(source / "scripts" / name, self.root / "scripts" / name)
        (self.root / "version.txt").write_text("1.0.0\n")
        self.archive = self.root / "dist/MenuRemote-1.0.0-macOS-arm64.zip"
        self.revision = "a" * 40
        make_package(self.archive, self.revision)
        make_appcast(self.archive)
        for name, script in (("gh", FAKE_GH), ("git", f'#!/bin/sh\nprintf "%s\\n" "{self.revision}"\n')):
            path = self.root / "bin" / name
            path.write_text(script)
            path.chmod(0o755)
        self.state = {"exists": True, "revision": self.revision, "draft": True}
        self.save_state()

    def save_state(self):
        (self.root / "remote/state.json").write_text(json.dumps(self.state))

    def publish(self, **environment):
        return subprocess.run(["bash", "scripts/publish_release.sh"], cwd=self.root,
            env={**os.environ, "PATH": f'{self.root / "bin"}:{os.environ["PATH"]}',
                 "GH_REPO": "test/menuremote", "EXPECTED_RELEASE_SHA": "", **environment},
            capture_output=True, text=True)

    def test_partial_upload_stays_draft_and_retry_finishes_it(self):
        self.state["fail_checksum"] = True
        self.save_state()
        self.assertNotEqual(self.publish().returncode, 0)
        state = json.loads((self.root / "remote/state.json").read_text())
        self.assertTrue(state["draft"])
        self.state["fail_checksum"] = False
        self.save_state()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads((self.root / "remote/state.json").read_text())
        self.assertFalse(state["draft"])
        self.assertEqual(self.publish().returncode, 0)  # Repeating a completed publish is safe.

    def test_changed_existing_asset_is_not_replaced(self):
        remote = self.root / "remote/assets" / self.archive.name
        remote.write_bytes(b"previously published bytes")
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertEqual(remote.read_bytes(), b"previously published bytes")

    def test_unrelated_commit_does_not_upload(self):
        self.state["revision"] = "b" * 40
        self.save_state()
        self.assertEqual(self.publish().returncode, 0)
        self.assertFalse(list((self.root / "remote/assets").iterdir()))

    def test_new_release_for_an_unbuilt_commit_fails(self):
        self.assertNotEqual(self.publish(EXPECTED_RELEASE_SHA="b" * 40).returncode, 0)
        self.assertFalse(list((self.root / "remote/assets").iterdir()))

    def test_no_release_leaves_the_pr_pending(self):
        self.state["exists"] = False
        self.save_state()
        self.assertEqual(self.publish().returncode, 0)
        self.assertFalse(list((self.root / "remote/assets").iterdir()))

    def test_missing_feed_does_not_publish(self):
        (self.root / "dist/appcast.xml").unlink()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SPARKLE_PRIVATE_KEY", result.stderr)
        self.assertFalse(list((self.root / "remote/assets").iterdir()))

    def test_feed_upload_failure_stays_draft_and_can_retry(self):
        self.state["fail_feed"] = True
        self.save_state()
        self.assertNotEqual(self.publish().returncode, 0)
        self.assertTrue(json.loads((self.root / "remote/state.json").read_text())["draft"])
        self.state["fail_feed"] = False
        self.save_state()
        self.assertEqual(self.publish().returncode, 0)
        self.assertFalse(json.loads((self.root / "remote/state.json").read_text())["draft"])
