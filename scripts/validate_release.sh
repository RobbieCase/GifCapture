#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

EXPECTED_VERSION="${1:-0.7.0}"
ZIP_PATH=".build/dist/GifCapture.zip"
EXPECTED_BUNDLE_ID="com.robbiecase.gifcapture"

if [ ! -f "$ZIP_PATH" ]; then
  echo "ERROR: $ZIP_PATH does not exist; run scripts/build_app.sh first" >&2
  exit 1
fi

STAGING="$(mktemp -d /tmp/gifcapture-release-verify.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

ditto -x -k "$ZIP_PATH" "$STAGING"
APP="$STAGING/GifCapture.app"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/GifCapture"

test -f "$PLIST"
test -x "$EXECUTABLE"
test -x "$APP/Contents/Resources/bin/gifski"

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
