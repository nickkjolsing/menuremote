#!/bin/bash
# Render info-window concepts and the actual About view, entirely offline.
set -euo pipefail
cd "$(dirname "$0")/.."

PREVIEW_DIR="$(mktemp -d)"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
swiftc -parse-as-library \
    Sources/MenuRemote/AboutWindow.swift \
    scripts/render_info.swift \
    -o "$PREVIEW_DIR/render-info"
"$PREVIEW_DIR/render-info" "$@"
