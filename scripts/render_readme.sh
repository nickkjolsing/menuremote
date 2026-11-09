#!/bin/bash
# Render the real SwiftUI player with sample data; no TV or pairing required.
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
swiftc -parse-as-library \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    Sources/MenuRemote/DPadView.swift \
    Sources/MenuRemote/PlayerView.swift \
    scripts/render_readme.swift \
    -o "$PREVIEW_DIR/render-readme"
"$PREVIEW_DIR/render-readme"
