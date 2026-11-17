#!/usr/bin/env bash
# Builds Tapeloop.app (universal arm64 + x86_64) into build/.
# Env: VERSION (default 0.1.0), BUILD_NUMBER (default 1), UNIVERSAL=0 for host arch only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="build/Tapeloop.app"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
[[ "${UNIVERSAL:-1}" == "0" ]] && ARCH_FLAGS=()

# "${ARCH_FLAGS[@]+...}" keeps an empty array safe under `set -u` in macOS's bash 3.2.
swift build -c release --product Tapeloop ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product Tapeloop ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tapeloop" "$APP/Contents/MacOS/Tapeloop"
# Embed the dynamic frameworks the app links (transcribe.cpp's CTranscribe) and let the binary find them there.
mkdir -p "$APP/Contents/Frameworks"
for framework in "$BIN_DIR"/*.framework; do
  [[ -e "$framework" ]] || continue
  ditto "$framework" "$APP/Contents/Frameworks/$(basename "$framework")"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Tapeloop"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon, drawn by script (no binary art in the repo).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Brand/wordmark-on-light.svg Resources/Brand/wordmark-on-dark.svg "$APP/Contents/Resources/"

scripts/sign.sh "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
