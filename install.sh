#!/bin/bash
# GifCapture one-command installer and updater:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/RobbieCase/GifCapture/main/install.sh)"
set -euo pipefail

ZIP_URL="${GIFCAPTURE_ZIP_URL:-https://github.com/RobbieCase/GifCapture/releases/latest/download/GifCapture.zip}"
CHECKSUM_URL="${GIFCAPTURE_CHECKSUM_URL:-${ZIP_URL}.sha256}"
DEST="${GIFCAPTURE_INSTALL_DEST:-/Applications/GifCapture.app}"
BUNDLE_ID="com.robbiecase.gifcapture"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

download() {
  local source="$1"
  local destination="$2"
  if ! curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 1 --retry-all-errors \
      --output "$destination" "$source"; then
    echo "ERROR: The latest release is missing required installer files." >&2
    echo "Please check https://github.com/RobbieCase/GifCapture/releases/latest" >&2
    exit 1
  fi
}

echo "Downloading the latest GifCapture release..."
download "$ZIP_URL" "${TMP}/GifCapture.zip"
download "$CHECKSUM_URL" "${TMP}/GifCapture.zip.sha256"

echo "Verifying download..."
(cd "$TMP" && shasum -a 256 -c GifCapture.zip.sha256)
ditto -x -k "${TMP}/GifCapture.zip" "$TMP"

SOURCE_APP="${TMP}/GifCapture.app"
PLIST="${SOURCE_APP}/Contents/Info.plist"
EXECUTABLE="${SOURCE_APP}/Contents/MacOS/GifCapture"
if [ ! -f "$PLIST" ] || [ ! -x "$EXECUTABLE" ]; then
  echo "ERROR: The release archive does not contain a valid GifCapture app." >&2
  exit 1
fi
if [ "$(plutil -extract CFBundleIdentifier raw "$PLIST")" != "$BUNDLE_ID" ]; then
  echo "ERROR: The downloaded app has an unexpected bundle identifier." >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"

USE_SUDO=0
INSTALL_PARENT="$(dirname "$DEST")"
if [ ! -w "$INSTALL_PARENT" ]; then
  echo "Administrator permission is required to update ${INSTALL_PARENT}."
  USE_SUDO=1
fi

run_install() {
  if [ "$USE_SUDO" = "1" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

echo "Installing GifCapture..."
if [ "${GIFCAPTURE_SKIP_QUIT:-0}" != "1" ]; then
  # Match the executable name only. Matching the full installer command line can
  # accidentally terminate the shell that is performing the update.
  pkill -x GifCapture 2>/dev/null || true
fi

BACKUP="${DEST}.previous"
run_install rm -rf "$BACKUP"
if [ -e "$DEST" ]; then
  run_install mv "$DEST" "$BACKUP"
fi

if ! run_install ditto --noextattr --noacl --norsrc "$SOURCE_APP" "$DEST"; then
  echo "ERROR: Installation failed; restoring the previous version." >&2
  run_install rm -rf "$DEST"
  if [ -e "$BACKUP" ]; then run_install mv "$BACKUP" "$DEST"; fi
  exit 1
fi

# Free GitHub builds are ad-hoc signed rather than Developer ID notarized. The
# command-line installer removes only the downloaded quarantine marker after
# checksum, bundle identity, and code-signature validation succeed.
run_install xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
if ! codesign --verify --deep --strict "$DEST"; then
  echo "ERROR: Installed app validation failed; restoring the previous version." >&2
  run_install rm -rf "$DEST"
  if [ -e "$BACKUP" ]; then run_install mv "$BACKUP" "$DEST"; fi
  exit 1
fi
run_install rm -rf "$BACKUP"

if [ "${GIFCAPTURE_SKIP_LAUNCH:-0}" != "1" ]; then
  open "$DEST"
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
echo "Done — GifCapture v${VERSION} is installed and running."
echo "If macOS requests Screen Recording access, grant it once in Privacy & Security."
