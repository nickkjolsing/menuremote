#!/bin/bash
# Builds "MenuRemote.app" into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuRemote.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MenuRemote"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MenuRemote"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Sources/MenuRemote/Resources/atv_bridge.py Support/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x MenuRemote 2>/dev/null || true
    rm -rf "/Applications/MenuRemote.app"
    cp -R "$APP" /Applications/
    open "/Applications/MenuRemote.app"
    echo "Installed to /Applications and launched"
fi
