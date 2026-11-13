#!/bin/bash
# Builds "MenuRemote.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuRemote.app"
VERSION="$(cat version.txt)"
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "version.txt must contain a stable version such as 1.0.0" >&2
    exit 1
fi
REVISION="$(git rev-parse HEAD)"

swift build --disable-keychain --disable-netrc -c release --arch arm64
BIN="$(swift build --disable-keychain --disable-netrc -c release --arch arm64 --show-bin-path)/MenuRemote"
SPARKLE_ROOT=".build/artifacts/sparkle/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
PUBLIC_KEY="$(cat Support/SparklePublicKey.txt)"
python3 - "$PUBLIC_KEY" <<'PY'
import base64, sys
if len(base64.b64decode(sys.argv[1], validate=True)) != 32:
    raise SystemExit("Invalid Sparkle public key")
PY

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$BIN" "$APP/Contents/MacOS/MenuRemote"
cp Support/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :MenuRemoteRevision string $REVISION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
cp Sources/MenuRemote/Resources/atv_bridge.py Support/AppIcon.icns "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle.LICENSE"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MenuRemote 2>/dev/null || true
    rm -rf "/Applications/MenuRemote.app"
    cp -R "$APP" /Applications/
    open "/Applications/MenuRemote.app"
    echo "Installed to /Applications and launched"
fi
