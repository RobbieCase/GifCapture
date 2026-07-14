#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECTED_VERSION="${1:-0.7.3}"
ZIP_PATH=".build/dist/GifCapture.zip"
EXPECTED_BUNDLE_ID="com.robbiecase.gifcapture"
CHECKSUM_PATH="${ZIP_PATH}.sha256"

if [ ! -f "$ZIP_PATH" ]; then
  echo "ERROR: $ZIP_PATH does not exist; run scripts/build_app.sh first" >&2
  exit 1
fi
if [ ! -f "$CHECKSUM_PATH" ]; then
  echo "ERROR: $CHECKSUM_PATH does not exist" >&2
  exit 1
fi
(cd "$(dirname "$ZIP_PATH")" && shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")

STAGING="$(mktemp -d /tmp/gifcapture-release-verify.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

ditto -x -k "$ZIP_PATH" "$STAGING"
APP="$STAGING/GifCapture.app"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/GifCapture"

test -f "$PLIST"
test -x "$EXECUTABLE"
test -x "$APP/Contents/Resources/bin/gifski"

ARCHS="$(lipo -archs "$EXECUTABLE")"
for REQUIRED_ARCH in arm64 x86_64; do
  if [[ " $ARCHS " != *" $REQUIRED_ARCH "* ]]; then
    echo "ERROR: executable is missing $REQUIRED_ARCH (has: $ARCHS)" >&2
    exit 1
  fi
done
MIN_OS="$(otool -l "$EXECUTABLE" | awk '/minos/ && !found {print $2; found=1}')"
if [ "$MIN_OS" != "13.0" ]; then
  echo "ERROR: executable deployment target is $MIN_OS, expected 13.0" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")"
BUILD_KIND="$(plutil -extract GifCaptureBuildKind raw "$PLIST")"

if [ "$VERSION" != "$EXPECTED_VERSION" ]; then
  echo "ERROR: expected version $EXPECTED_VERSION, found $VERSION" >&2
  exit 1
fi
if [ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]; then
  echo "ERROR: expected bundle ID $EXPECTED_BUNDLE_ID, found $BUNDLE_ID" >&2
  exit 1
fi
if [ "$BUILD_KIND" != "release" ]; then
  echo "ERROR: distribution build kind is $BUILD_KIND, expected release" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Validated GifCapture v$VERSION release ZIP"
