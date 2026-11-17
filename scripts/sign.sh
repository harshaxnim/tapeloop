#!/usr/bin/env bash
# Signs an app bundle. With MACOS_CERT_P12 + MACOS_CERT_PASSWORD set, signs with that Developer ID
# certificate and the hardened runtime; otherwise signs ad hoc ("-"), which needs no account.
set -euo pipefail
APP="$1"
ENT="$(dirname "$0")/../Resources/Tapeloop.entitlements"

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
  codesign --force --deep --options runtime --timestamp --entitlements "$ENT" -s "$IDENTITY" "$APP"
else
  echo "No signing certificate: signing ad hoc"
  codesign --force --deep --options runtime --entitlements "$ENT" -s - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
