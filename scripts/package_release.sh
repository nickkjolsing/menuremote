#!/bin/bash
# Build, verify, and package the Apple silicon app for GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION="$(cat version.txt)"
ARCHIVE="MenuRemote-${VERSION}-macOS-arm64.zip"
mkdir -p dist
rm -f "dist/$ARCHIVE" "dist/$ARCHIVE.sha256" dist/appcast.xml
ditto -c -k --sequesterRsrc --keepParent build/MenuRemote.app "dist/$ARCHIVE"
(
    cd dist
    shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
)

# Verify the downloaded form, including its signature and executable permissions.
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "dist/$ARCHIVE" "$VERIFY_DIR"
plutil -lint "$VERIFY_DIR/MenuRemote.app/Contents/Info.plist"
codesign --verify --deep --strict "$VERIFY_DIR/MenuRemote.app"
test -x "$VERIFY_DIR/MenuRemote.app/Contents/MacOS/MenuRemote"
python3 scripts/verify_release.py "dist/$ARCHIVE" "$VERSION" "$(git rev-parse HEAD)"
KEY_FILE="${MENU_REMOTE_UPDATE_KEY_FILE:-$HOME/Library/Application Support/MenuRemote/Updates/private-key}"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" || -f "$KEY_FILE" ]]; then
    bash scripts/create_appcast.sh
    python3 scripts/verify_release.py "dist/$ARCHIVE" "$VERSION" "$(git rev-parse HEAD)" --require-appcast
else
    echo "No update signing key available; packaged app without a publishable update feed."
fi
echo "Packaged dist/$ARCHIVE"
