"""Exercise Sparkle against signed, disposable apps served only on loopback.

Requires macOS and the resolved Sparkle dependency. Does not touch MenuRemote,
its preferences, its production signing key, or any Apple TV.
"""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT / ".build/artifacts/sparkle/Sparkle"
FRAMEWORKS = SPARKLE / "Sparkle.xcframework/macos-arm64_x86_64"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"Command failed: {args[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        super().do_GET()


def make_app(path, binary, identifier, version, public_key, feed, result, scenario):
    contents = path / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Frameworks").mkdir()
    shutil.copy2(binary, contents / "MacOS/UpdaterFixture")
    run("ditto", FRAMEWORKS / "Sparkle.framework", contents / "Frameworks/Sparkle.framework")
    info = {
        "CFBundleIdentifier": identifier, "CFBundleName": "MenuRemote Update Test",
        "CFBundleExecutable": "UpdaterFixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": version, "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "SUFeedURL": feed, "SUPublicEDKey": public_key,
        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
        "SUAllowsAutomaticUpdates": False, "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        # These exceptions exist only in the disposable loopback test app.
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True, "NSAllowsArbitraryLoads": True},
        "TestResultPath": str(result), "TestScenario": scenario,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", "-", path)
    run("codesign", "--verify", "--deep", "--strict", path)


def exercise(work, binary, private_key, public_key, scenario):
    directory = work / scenario
    directory.mkdir()
    serve = directory / "serve"
    serve.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(serve)))
    server.requests = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    prefix = f"http://127.0.0.1:{server.server_port}/"
    result_path = directory / "result.json"
    identifier = "com.nickkjolsing.menuremote.updater-test." + uuid.uuid4().hex
    current_version = "2.0.0" if scenario == "up-to-date" else "1.0.0"
    app = directory / "installed/UpdaterFixture.app"
    new_app = directory / "release/UpdaterFixture.app"
    make_app(app, binary, identifier, current_version, public_key,
             prefix + "appcast.xml", result_path, scenario)
    make_app(new_app, binary, identifier, "2.0.0", public_key,
             prefix + "appcast.xml", result_path, scenario)
    archive = serve / "update.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", new_app, archive)
    run(SPARKLE / "bin/generate_appcast", "--ed-key-file", private_key,
        "--maximum-deltas", "0", "--download-url-prefix", prefix, serve)
    feed = serve / "appcast.xml"
    if scenario == "bad-archive":
        # The feed remains correctly signed, but its archive signature is invalid.
        with archive.open("ab") as output:
            output.write(b"tampered")
        tree = ET.parse(feed)
        tree.find("./channel/item/enclosure").set("length", str(archive.stat().st_size))
        tree.write(feed, encoding="utf-8", xml_declaration=True)
        run(SPARKLE / "bin/sign_update", "--ed-key-file", private_key, feed)
    elif scenario == "bad-feed":
        feed.write_bytes(feed.read_bytes().replace(b"<channel>", b"<channel> ", 1))
    elif scenario == "feed-unavailable":
        feed.unlink()

    process = None
    try:
        with (directory / "process.log").open("w") as log:
            process = subprocess.Popen([str(app / "Contents/MacOS/UpdaterFixture")],
                                       stdout=log, stderr=log)
            deadline = time.monotonic() + 50
            while time.monotonic() < deadline and not result_path.exists():
                time.sleep(0.1)
            if not result_path.exists():
                raise AssertionError(f"{scenario}: timed out\n{(directory / 'process.log').read_text()}")
        result = json.loads(result_path.read_text())
        installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
        if scenario == "install":
            assert (result["result"], installed) == ("relaunched", "2.0.0"), result
        elif scenario == "manual-idle":
            assert result["result"] == "ready", result
            assert server.requests == [], "Manual-only updater contacted the feed without a click"
        elif scenario == "up-to-date":
            assert result["result"] == "up-to-date" and result["code"] == 1001, result
        elif scenario == "bad-archive":
            assert result["result"] == "error" and {3001, 3002}.intersection(result["codes"]), result
            assert installed == "1.0.0", "Invalid update changed the installed app"
        elif scenario == "bad-feed":
            assert result["result"] == "error" and result["code"] in (1000, 1002), result
            assert installed == "1.0.0", "Failed update changed the installed app"
        else:
            assert result["result"] == "error" and result["code"] == 2001, result
            assert installed == "1.0.0", "Unavailable feed changed the installed app"
        print(f"PASS {scenario}", flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        server.shutdown()
        server.server_close()
        # Remove only this fixture's preferences. Production defaults are separate.
        subprocess.run(["defaults", "delete", identifier], capture_output=True)
        for base in (Path.home() / "Library/Caches", Path.home() / "Library/Application Support"):
            cache = base / identifier
            if cache.is_dir():
                shutil.rmtree(cache)


def main():
    with tempfile.TemporaryDirectory(prefix="menuremote-updater-") as temporary:
        work = Path(temporary)
        binary = work / "UpdaterFixture"
        run("swiftc", "-parse-as-library", "-F", FRAMEWORKS, "-framework", "Sparkle",
            "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ROOT / "Sources/MenuRemote/AppUpdater.swift",
            ROOT / "tests/Swift/UpdaterFixture.swift", "-o", binary)
        private_key, public_key_file = work / "private-key", work / "public-key"
        run("swift", ROOT / "scripts/create_update_key.swift", private_key, public_key_file)
        public_key = public_key_file.read_text().strip()
        for scenario in ("manual-idle", "install", "up-to-date", "bad-archive", "bad-feed", "feed-unavailable"):
            exercise(work, binary, private_key, public_key, scenario)
    print("All 6 Sparkle integration tests passed", flush=True)


if __name__ == "__main__":
    main()
