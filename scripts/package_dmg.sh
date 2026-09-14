#!/bin/bash
# Wrap an already-built release ZIP in a drag-and-drop disk image.
# This preserves the app signature and does not notarize or install the app.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP_PATH="${1:-.build/dist/GifCapture.zip}"
CHECKSUM_PATH="${ZIP_PATH}.sha256"
test -f "$ZIP_PATH"
test -f "$CHECKSUM_PATH"
(cd "$(dirname "$ZIP_PATH")" && shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")

STAGING="$(mktemp -d /tmp/gifcapture-dmg.XXXXXX)"
MOUNT_POINT="$STAGING/mounted"
MOUNTED=0
cleanup() {
  if [ "$MOUNTED" = "1" ]; then
    if ! hdiutil detach "$MOUNT_POINT" -quiet; then
      echo "Warning: could not unmount $MOUNT_POINT; leaving staging files in $STAGING" >&2
      return
    fi
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT

# Extract the canonical ZIP outside synced folders. Finder metadata attached
# to unpacked workspace copies can make their existing signatures fail.
ditto -x -k "$ZIP_PATH" "$STAGING/extracted"
SOURCE_APP="$STAGING/extracted/GifCapture.app"
PLIST="$SOURCE_APP/Contents/Info.plist"
test "$(plutil -extract CFBundleIdentifier raw "$PLIST")" = "com.robbiecase.gifcapture"
test "$(plutil -extract GifCaptureBuildKind raw "$PLIST")" = "release"
codesign --verify --deep --strict "$SOURCE_APP"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: unexpected app version: $VERSION" >&2
  exit 1
fi

CONTENTS="$STAGING/contents"
mkdir -p "$CONTENTS" "$MOUNT_POINT"
ditto --noextattr --noacl --norsrc "$SOURCE_APP" "$CONTENTS/GifCapture.app"
ln -s /Applications "$CONTENTS/Applications"
cat > "$CONTENTS/Read Me First.txt" <<'README'
INSTALL RGC (ROBBIE'S GIFCAPTURE)

1. Quit GifCapture if it is already running.
2. Drag GifCapture.app onto the Applications folder in this window.
3. Open GifCapture from Applications, then eject this disk image.

FIRST LAUNCH

This community build is not notarized by Apple. If macOS blocks it,
open System Settings > Privacy & Security and look for Open Anyway
after attempting to open the app. Confirm only if you trust this copy.
On a managed work Mac, your IT team may control this setting.

SCREEN RECORDING

Choose Record New GIF from the menu-bar icon. When prompted, enable
GifCapture in System Settings > Privacy & Security > Screen & System
Audio Recording. Quit and reopen GifCapture if macOS asks.

If updating an older copy leaves permission enabled but recording
blocked, remove GifCapture from that permission list, add the copy
in Applications again, and quit and reopen GifCapture.

UPDATES

Use Check for Updates in GifCapture, or download a newer disk image
from https://github.com/RobbieCase/GifCapture/releases/latest .
README

DMG_NAME="GifCapture-${VERSION}.dmg"
hdiutil create -volname "RGC ${VERSION}" -srcfolder "$CONTENTS" \
  -fs HFS+ -format UDZO "$STAGING/$DMG_NAME"
hdiutil verify "$STAGING/$DMG_NAME"
hdiutil attach "$STAGING/$DMG_NAME" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
MOUNTED=1
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications"
test -s "$MOUNT_POINT/Read Me First.txt"
test "$(plutil -extract CFBundleShortVersionString raw "$MOUNT_POINT/GifCapture.app/Contents/Info.plist")" = "$VERSION"
codesign --verify --deep --strict "$MOUNT_POINT/GifCapture.app"
cmp "$SOURCE_APP/Contents/MacOS/GifCapture" "$MOUNT_POINT/GifCapture.app/Contents/MacOS/GifCapture"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNTED=0

OUTPUT_DIR="$(dirname "$ZIP_PATH")"
cp "$STAGING/$DMG_NAME" "$OUTPUT_DIR/$DMG_NAME"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
echo "Created and verified: $OUTPUT_DIR/$DMG_NAME"
