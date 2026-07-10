#!/bin/bash
# GifCapture one-line installer:
#   curl -fsSL https://raw.githubusercontent.com/RobbieCase/GifCapture/main/install.sh | bash
set -euo pipefail

ZIP_URL="https://github.com/RobbieCase/GifCapture/releases/latest/download/GifCapture.zip"
DEST="/Applications/GifCapture.app"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "Downloading GifCapture..."
curl -fsSL -o "${TMP}/GifCapture.zip" "${ZIP_URL}"
ditto -x -k "${TMP}/GifCapture.zip" "${TMP}"

echo "Installing to ${DEST}..."
pkill -f "${DEST}/Contents/MacOS/GifCapture" 2>/dev/null || true
rm -rf "${DEST}"
ditto "${TMP}/GifCapture.app" "${DEST}"

# The build is ad-hoc signed (not notarized); clear quarantine so Gatekeeper
# doesn't block it.
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

# Each release has a new ad-hoc signature; clear any stale Screen Recording
# entry from a previous version so the fresh grant attaches cleanly.
tccutil reset ScreenCapture com.robbiecase.gifcapture >/dev/null 2>&1 || true

open -a "${DEST}"
echo "Done - GifCapture is running. Look for the GC icon in your menu bar."
echo ""
echo "IMPORTANT: when macOS asks for Screen Recording permission, grant it,"
echo "then QUIT and REOPEN GifCapture once (menu bar icon -> Quit GifCapture)."
echo "The permission only takes effect for a freshly launched app."
