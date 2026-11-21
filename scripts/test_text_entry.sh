#!/bin/bash
# Native SwiftUI keyboard checks. Run ./build.sh first to resolve Sparkle.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
SPARKLE_FRAMEWORKS="$(pwd)/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swiftc -parse-as-library \
    -F "$SPARKLE_FRAMEWORKS" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$SPARKLE_FRAMEWORKS" \
    Sources/MenuRemote/AppUpdater.swift \
    Sources/MenuRemote/AboutWindow.swift \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    Sources/MenuRemote/DPadView.swift \
    Sources/MenuRemote/PlayerView.swift \
    tests/Swift/TextEntryViewTests.swift \
    -o "$TEST_DIR/TextEntryViewTests"
"$TEST_DIR/TextEntryViewTests"
