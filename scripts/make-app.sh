#!/usr/bin/env bash
# Builds Rearview.app (universal arm64 + x86_64) into build/.
# Env: VERSION (default from git describe), BUILD_NUMBER (default 1), UNIVERSAL=0 for host arch only.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="build/Rearview.app"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
[[ "${UNIVERSAL:-1}" == "0" ]] && ARCH_FLAGS=()

swift build -c release --product Rearview "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release --product Rearview "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Rearview" "$APP/Contents/MacOS/Rearview"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon, drawn by script (no binary art in the repo).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

scripts/sign.sh "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
