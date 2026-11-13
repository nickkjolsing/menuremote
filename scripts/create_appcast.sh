#!/bin/bash
# Sign the exact packaged ZIP and embed release notes in a signed Sparkle feed.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat version.txt)"
ARCHIVE="MenuRemote-${VERSION}-macOS-arm64.zip"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
KEY_FILE="${MENU_REMOTE_UPDATE_KEY_FILE:-$HOME/Library/Application Support/MenuRemote/Updates/private-key}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    umask 077
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$WORK_DIR/private-key"
    KEY_FILE="$WORK_DIR/private-key"
fi
if [[ ! -f "$KEY_FILE" ]]; then
    echo "Signing key missing. Set SPARKLE_PRIVATE_KEY in GitHub Actions, or run bash scripts/setup_update_signing.sh locally." >&2
    exit 1
fi
mkdir "$WORK_DIR/archives"
cp "dist/$ARCHIVE" "$WORK_DIR/archives/"
cp CHANGELOG.md "$WORK_DIR/archives/${ARCHIVE%.zip}.md"
"$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEY_FILE" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/nickkjolsing/menuremote/releases/download/v$VERSION/" \
    --link "https://github.com/nickkjolsing/menuremote/releases/tag/v$VERSION" \
    "$WORK_DIR/archives"
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY_FILE" "$WORK_DIR/archives/appcast.xml"
cp "$WORK_DIR/archives/appcast.xml" dist/appcast.xml
echo "Created signed dist/appcast.xml"
