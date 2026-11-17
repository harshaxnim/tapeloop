#!/usr/bin/env bash
# Mounts the DMG and checks the app inside: bundle keys, LSUIElement, usage strings, signature, entitlements.
set -euo pipefail
DMG="$1"
MNT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
trap 'hdiutil detach "$MNT" >/dev/null || true' EXIT
APP="$MNT/Tapeloop.app"
PL="$APP/Contents/Info.plist"
fail() { echo "FAIL: $*"; exit 1; }

[[ -d "$APP" ]] || fail "Tapeloop.app missing"
[[ -L "$MNT/Applications" ]] || fail "Applications link missing"
get() { /usr/libexec/PlistBuddy -c "Print $1" "$PL"; }
[[ "$(get CFBundleIdentifier)" == "io.github.harshaxnim.tapeloop" ]] || fail "bundle id"
[[ "$(get LSUIElement)" == "true" ]] || fail "LSUIElement"
[[ "$(get LSMinimumSystemVersion)" == "14.0" ]] || fail "minimum system version"
for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription NSCalendarsFullAccessUsageDescription NSSpeechRecognitionUsageDescription; do
  [[ -n "$(get $key)" ]] || fail "$key"
done
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || fail "icon"
lipo -archs "$APP/Contents/MacOS/Tapeloop" | tee /dev/stderr | grep -q arm64 || fail "arm64 slice"
lipo -archs "$APP/Contents/MacOS/Tapeloop" | grep -q x86_64 || fail "x86_64 slice"
FW="$APP/Contents/Frameworks/CTranscribe.framework/Versions/A/CTranscribe"
[[ -f "$FW" ]] || fail "transcription engine framework missing"
lipo -archs "$FW" | grep -q arm64 && lipo -archs "$FW" | grep -q x86_64 || fail "framework slices"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "signature"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q com.apple.security.device.audio-input || fail "entitlements"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|flags" 
"$APP/Contents/MacOS/Tapeloop" --version | grep -q "Tapeloop" || fail "--version"
echo "DMG OK: $DMG ($(get CFBundleShortVersionString))"
