#!/bin/bash
# Native SwiftUI keyboard checks. Run ./build.sh first to resolve Sparkle.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_APP="$TEST_DIR/TextEntryViewTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Frameworks"
SPARKLE_FRAMEWORKS="$(pwd)/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swiftc -parse-as-library \
    -F "$SPARKLE_FRAMEWORKS" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    Sources/MenuRemote/AppUpdater.swift \
    Sources/MenuRemote/AboutWindow.swift \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    Sources/MenuRemote/ContentView.swift \
    Sources/MenuRemote/PairingViews.swift \
    Sources/MenuRemote/DPadView.swift \
    Sources/MenuRemote/PlayerView.swift \
    tests/Swift/TextEntryViewTests.swift \
    -o "$TEST_APP/Contents/MacOS/TextEntryViewTests"
# AppKit needs a real application identity to activate a key window on CI.
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.nickkjolsing.menuremote.text-entry-tests</string>
<key>CFBundleName</key><string>MenuRemote Text Entry Tests</string>
<key>CFBundleExecutable</key><string>TextEntryViewTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
ditto "$SPARKLE_FRAMEWORKS/Sparkle.framework" "$TEST_APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$TEST_APP"
RESULT="$TEST_DIR/result"
open -n -W --stdout "$TEST_DIR/stdout.log" --stderr "$TEST_DIR/stderr.log" "$TEST_APP" --args --result "$RESULT"
cat "$TEST_DIR/stdout.log" "$TEST_DIR/stderr.log"
test -f "$RESULT"
grep -qx passed "$RESULT"
