"""Test the relocated helper with no network, Homebrew, or external Python access."""

import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def check_binaries(helper):
    """Reject build-machine library paths or a silently raised macOS requirement."""
    binaries = [helper / "Contents/MacOS/MenuRemoteHelper"]
    binaries.extend(p for p in helper.rglob("*") if p.suffix in (".so", ".dylib"))
    for binary in binaries:
        if binary.read_bytes()[:8] != struct.pack("<II", 0xFEEDFACF, 0x0100000C):
            raise AssertionError(f"Expected arm64 Mach-O: {binary}")
        dependencies = subprocess.check_output(["otool", "-L", binary], text=True)
        for line in dependencies.splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            if not dependency.startswith(("@", "/usr/lib/", "/System/Library/")):
                raise AssertionError(f"External library in {binary}: {dependency}")
        commands = subprocess.check_output(["otool", "-l", binary], text=True)
        command = None
        for line in commands.splitlines():
            words = line.split()
            if len(words) == 2 and words[0] == "cmd":
                command = words[1]
            if len(words) == 2 and ((command == "LC_BUILD_VERSION" and words[0] == "minos") or
                                    (command == "LC_VERSION_MIN_MACOSX" and words[0] == "version")):
                version = tuple(int(part) for part in words[1].split("."))
                if version[:2] > (14, 0):
                    raise AssertionError(f"{binary} requires macOS {words[1]}")


def exercise(app):
    helper = app / "Contents/Helpers/MenuRemoteHelper.app"
    check_binaries(helper)
    with tempfile.TemporaryDirectory(prefix="menuremote-helper-") as temporary:
        work = Path(temporary)
        # Spaces and an unrelated directory catch absolute paths left by a build.
        relocated = work / "Moved App.app"
        subprocess.run(["ditto", str(app), str(relocated)], check=True)
        executable = relocated / "Contents/Helpers/MenuRemoteHelper.app/Contents/MacOS/MenuRemoteHelper"
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(relocated)], check=True)
        profile = work / "offline.sb"
        blocked = [ROOT, Path.home() / ".local/share/uv", Path("/opt/homebrew"), Path("/usr/local")]
        profile.write_text('(version 1)\n(allow default)\n(deny network*)\n' +
                           "\n".join(f"(deny file-read* (subpath {json.dumps(str(path))}))" for path in blocked))
        sandbox = shutil.which("sandbox-exec")
        if not sandbox:
            raise RuntimeError("sandbox-exec is required for the offline release check")
        command = [sandbox, "-f", str(profile), str(executable)]
        environment = {"HOME": str(work), "PATH": "/usr/bin:/bin", "TMPDIR": str(work),
                       "PYTHONHOME": "/missing-python", "PYTHONPATH": "/missing-modules"}
        result = subprocess.run(command + ["--self-test"], env=environment, cwd=work,
                                capture_output=True, text=True, timeout=30, check=True)
        event = json.loads(result.stdout)
        expected_python = (ROOT / "Support/helper-python-version.txt").read_text().strip()
        if (event["event"], event["version"], event["python"], event["protocols"]) != (
                "self_test", "0.18.0", expected_python, ["AirPlay", "Companion", "DMAP", "MRP", "RAOP"]):
            raise AssertionError(event)
        if event.get("pairing") != ["HAP", "Legacy"]:
            raise AssertionError("Helper did not exercise pairing initialization")
        # Existing credentials stay byte-for-byte intact; the legacy venv is absent.
        storage = work / "pyatv.conf"
        original = json.dumps({"version": 1, "devices": [{"protocols": {
            "companion": {"identifier": "fixture-device", "credentials": "fixture-credentials"}
        }}]}) + "\n"
        storage.write_text(original)
        process = subprocess.Popen(command + [str(storage)], env=environment, cwd=work,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            # Send a command that never touches a device. communicate bounds startup
            # time too, unlike readline, which could hang before the first event.
            stdout, stderr = process.communicate('{"cmd":"bundle_check"}\n', timeout=30)
            if process.returncode:
                raise AssertionError(f"Helper exited {process.returncode}: {stderr}")
            events = [json.loads(line) for line in stdout.splitlines()]
            if not any(e.get("event") == "ready" and e.get("version") == "0.18.0" for e in events):
                raise AssertionError(f"Helper did not become ready: {stdout}\n{stderr}")
            if not any(e.get("event") == "error" and e.get("command") == "bundle_check" for e in events):
                raise AssertionError(f"Helper did not process stdin: {stdout}\n{stderr}")
            if storage.read_text() != original:
                raise AssertionError("Startup modified existing credentials")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        print("PASS relocated helper: offline startup, crypto, pairing, protocols, stdio, and existing credentials")


if __name__ == "__main__":
    exercise(Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "build/MenuRemote.app").resolve())
