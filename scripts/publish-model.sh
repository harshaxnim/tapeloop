#!/usr/bin/env bash
# Publishes the Parakeet model file as an asset of the `models-v1` release of Tapeloop's GitHub repository, where the
# app downloads it from (see TranscriptionModel.parakeetUnifiedEnglish). The file must match the catalog's size and
# SHA-256; it is checked before upload. Maintainers run this once per model.
# Usage: scripts/publish-model.sh <path-to-parakeet-unified-en-0.6b-Q8_0.gguf>
set -euo pipefail

REPO="harshaxnim/tapeloop"
TAG="models-v1"
FILE="parakeet-unified-en-0.6b-Q8_0.gguf"
SHA256="4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"

LOCAL="${1:?Usage: scripts/publish-model.sh <path-to-$FILE>}"
[[ "$(basename "$LOCAL")" == "$FILE" ]] || { echo "The file must be named $FILE"; exit 1; }
echo "$SHA256  $LOCAL" | shasum -a 256 -c -

if ! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    gh release create "$TAG" -R "$REPO" --title "Speech models" --prerelease --latest=false --notes \
"Speech models that Tapeloop downloads on request (Settings › Transcripts, or the welcome guide). Not needed to run Tapeloop.

- \`$FILE\`: NVIDIA Parakeet Unified English 0.6B, 8-bit (Q8_0) GGUF for transcribe.cpp. Licence: CC-BY-4.0 (NVIDIA); see THIRD_PARTY_NOTICES.md. SHA-256 \`$SHA256\`."
fi
gh release upload "$TAG" -R "$REPO" "$LOCAL" --clobber
echo "Published https://github.com/$REPO/releases/download/$TAG/$FILE"
