#!/usr/bin/env bash
# Makes build/Tapeloop-<version>.dmg with Tapeloop.app and an Applications link (drag to install).
# Notarizes it when APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD are set and the app is Developer ID signed.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Tapeloop.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Tapeloop-$VERSION.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tapeloop $VERSION" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${MACOS_CERT_P12:-}" ]]; then
  echo "Notarizing $DMG"
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
else
  echo "No notarization secrets: the DMG is not notarized"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "$DMG" > build/dmg-path.txt
