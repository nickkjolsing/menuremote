#!/bin/bash
# Ad-hoc by default. Set MENU_REMOTE_CODESIGN_IDENTITY to enable Developer ID.
set -euo pipefail
APP="${1:?Pass the app bundle to sign}"
IDENTITY="${MENU_REMOTE_CODESIGN_IDENTITY:--}"
OPTIONS=()
if [[ "$IDENTITY" != - ]]; then
    OPTIONS+=(--options runtime --timestamp)
    # Re-sign the vendor's nested code with our identity, from the inside out.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for COMPONENT in \
        "$SPARKLE/XPCServices/Downloader.xpc" \
        "$SPARKLE/XPCServices/Installer.xpc" \
        "$SPARKLE/Autoupdate" \
        "$SPARKLE/Updater.app" \
        "$APP/Contents/Frameworks/Sparkle.framework"; do
        codesign --force --sign "$IDENTITY" "${OPTIONS[@]}" --preserve-metadata=identifier,entitlements "$COMPONENT"
    done
fi
# PyInstaller has already signed the helper and its libraries with this identity.
codesign --force --sign "$IDENTITY" ${OPTIONS[@]+"${OPTIONS[@]}"} "$APP"
