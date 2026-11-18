#!/usr/bin/env bash
# Signs an app bundle, with the first of these that is available:
#   1. MACOS_CERT_P12 + MACOS_CERT_PASSWORD: that Developer ID certificate and the hardened runtime (releases).
#   2. SIGN_IDENTITY: the named code-signing identity from your keychains.
#   3. The local identity made by scripts/dev-signing.sh (in ~/.tapeloop-signing).
#   4. Ad hoc ("-"), which needs no certificate.
# Options 1 to 3 keep the app's identity the same from build to build, so macOS keeps its permissions. A plain ad-hoc
# signature identifies the app by the hash of its code, so macOS would ask for the permissions again after each
# rebuild. Local ad-hoc builds (not CI) therefore carry a designated requirement on the bundle identifier alone, which
# every rebuild satisfies. Releases never do this: any app with that identifier would then match the permissions.
set -euo pipefail
APP="$1"
ENT="$(dirname "$0")/../Resources/Tapeloop.entitlements"

# Signs the embedded frameworks first, then the app. Only Developer ID builds use the hardened runtime: with an ad-hoc
# or self-signed identity there is no Team ID, and the hardened runtime's library validation would then refuse to load
# the embedded transcribe.cpp framework.
sign_bundle() {
  local identity="$1"; shift
  for framework in "$APP"/Contents/Frameworks/*.framework; do
    [[ -e "$framework" ]] || continue
    codesign --force "$@" -s "$identity" "$framework"
  done
  codesign --force "$@" "${APP_ONLY[@]}" --entitlements "$ENT" -s "$identity" "$APP"
}
APP_ONLY=()

if [[ -n "${MACOS_CERT_P12:-}" && -n "${MACOS_CERT_PASSWORD:-}" ]]; then
  KEYCHAIN="$RUNNER_TEMP/tapeloop-signing.keychain-db"
  KC_PASS="$(uuidgen)"
  echo "$MACOS_CERT_P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
  security import "$RUNNER_TEMP/cert.p12" -P "$MACOS_CERT_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
  security set-key-partition-list -S apple-tool:,apple: -k "$KC_PASS" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  echo "Signing with Developer ID"
  sign_bundle "$IDENTITY" --options runtime --timestamp
elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "Signing with local identity: $SIGN_IDENTITY"
  sign_bundle "$SIGN_IDENTITY"
elif DEV_DIR="${TAPELOOP_SIGNING_DIR:-$HOME/.tapeloop-signing}" \
  && [[ -f "$DEV_DIR/tapeloop-dev.keychain-db" && -f "$DEV_DIR/password" ]]; then
  security unlock-keychain -p "$(cat "$DEV_DIR/password")" "$DEV_DIR/tapeloop-dev.keychain-db"
  echo "Signing with the local identity from scripts/dev-signing.sh"
  sign_bundle "Tapeloop Local Signing" --keychain "$DEV_DIR/tapeloop-dev.keychain-db"
elif [[ -z "${CI:-}" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  echo "No signing certificate: signing ad hoc for this Mac, identified by $BUNDLE_ID so permissions survive rebuilds"
  APP_ONLY=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
  sign_bundle -
else
  echo "No signing certificate: signing ad hoc"
  sign_bundle -
fi
codesign --verify --deep --strict --verbose=2 "$APP"
