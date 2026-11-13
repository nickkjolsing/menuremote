#!/bin/bash
# Render the real SwiftUI player with sample data; no TV or pairing required.
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
swift package --disable-keychain --disable-netrc resolve
SPARKLE_FRAMEWORKS="$(pwd)/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
swiftc -parse-as-library \
    -F "$SPARKLE_FRAMEWORKS" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$SPARKLE_FRAMEWORKS" \
    Sources/MenuRemote/AppUpdater.swift \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    Sources/MenuRemote/DPadView.swift \
    Sources/MenuRemote/PlayerView.swift \
    scripts/render_readme.swift \
    -o "$PREVIEW_DIR/render-readme"
"$PREVIEW_DIR/render-readme"
