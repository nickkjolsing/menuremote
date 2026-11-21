#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
swiftc -parse-as-library \
    Sources/MenuRemote/Bridge.swift \
    Sources/MenuRemote/RemoteModel.swift \
    Sources/MenuRemote/DPadView.swift \
    scripts/render_remote.swift \
    -o "$PREVIEW_DIR/render-remote"
"$PREVIEW_DIR/render-remote"
