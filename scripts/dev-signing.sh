#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local builds, once, so macOS keeps Tapeloop's permissions
# (microphone, system audio, calendars, speech) across rebuilds.
#
# Why: an ad-hoc signature identifies the app by the hash of its exact code, so every rebuild looks like a new app to
# macOS and the permissions are asked for again. A signature from a fixed certificate identifies the app by its bundle
# ID and that certificate instead, which stays the same from build to build.
#
# Everything lives in ~/.tapeloop-signing (outside the repository): a separate keychain, its random password, and
# nothing else. Your login keychain is not touched. scripts/sign.sh uses this identity whenever it exists.
#
#   scripts/dev-signing.sh            create it (does nothing if it exists)
#   scripts/dev-signing.sh --remove   delete it (builds go back to ad-hoc signing)
set -euo pipefail

DIR="${TAPELOOP_SIGNING_DIR:-$HOME/.tapeloop-signing}"
KEYCHAIN="$DIR/tapeloop-dev.keychain-db"
NAME="Tapeloop Local Signing"

if [[ "${1:-}" == "--remove" ]]; then
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$DIR"
  echo "Removed $DIR; builds are signed ad hoc again."
  exit 0
fi

if [[ -f "$KEYCHAIN" && -f "$DIR/password" ]]; then
  echo "Signing identity already set up: \"$NAME\" in $KEYCHAIN"
  exit 0
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS="$(uuidgen)"
printf '%s' "$PASS" > "$DIR/password"
chmod 600 "$DIR/password"

# A certificate that may only sign code, valid for 20 years.
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# The Keychain only reads PKCS#12 files with the older algorithms.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -passout "pass:$PASS" -out "$WORK/identity.p12" 2>/dev/null \
  || openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$WORK/key.pem" \
    -in "$WORK/cert.pem" -name "$NAME" -passout "pass:$PASS" -out "$WORK/identity.p12"

security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # no automatic locking
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null

echo "Created \"$NAME\" in $KEYCHAIN."
echo "Build with 'make app': the next launch asks for the permissions once more; later builds keep them."
