#!/bin/bash
# Builds GifCapture.app.
#
# NOTE: this project's `swift build` (SwiftPM) is broken on this machine because the
# installed Command Line Tools (27.0 beta) are missing BuildServerProtocol.framework,
# which the new Swift Build system requires. `swiftc` itself works fine, so we compile
# directly with it and hand-assemble the .app bundle. If a full Xcode install ever
# lands, `swift build -c release` should work too and this script can simplify.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="GifCapture"
BUNDLE_ID="com.robbiecase.gifcapture"
VERSION="0.6.7"
BUILD_NUMBER="607"
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE_DIR=".build/module-cache"

# A stale module cache miscompiles against framework internals (v0.6.0 shipped
# a binary that bus-errored inside SwiftUI-backed controls); always start fresh.
rm -rf "$MODULE_CACHE_DIR"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

echo "Compiling..."
swiftc -O \
  Sources/GifCapture/*.swift \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -o "$BUILD_DIR/$APP_NAME" \
  -framework AppKit -framework AVFoundation -framework AVKit -framework ScreenCaptureKit -framework CoreGraphics -framework Quartz -framework Carbon -framework UserNotifications

echo "Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
if [ -f "Resources/library-icon.png" ]; then
  cp "Resources/library-icon.png" "$APP_DIR/Contents/Resources/library-icon.png"
fi
if [ -f "Resources/library-icon-v2.png" ]; then
  cp "Resources/library-icon-v2.png" "$APP_DIR/Contents/Resources/library-icon-v2.png"
fi
# Bundle the official (universal, self-contained) gifski binary so installs
# on other Macs don't need Homebrew.
if [ -f "Resources/bin/gifski" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/bin"
  cp "Resources/bin/gifski" "$APP_DIR/Contents/Resources/bin/gifski"
  chmod +x "$APP_DIR/Contents/Resources/bin/gifski"
fi

# Prefer the stable local identity so TCC (Screen Recording) grants survive
# rebuilds. Record the build kind in Info.plist; parsing codesign's Authority
# output is unreliable for locally issued certificates.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "GifCapture Local Dev"; then
  SIGN_ID="GifCapture Local Dev"
  BUILD_KIND="development"
  echo "Signing with stable local identity..."
else
  SIGN_ID="-"
  BUILD_KIND="release"
  echo "Ad-hoc signing..."
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Robbie's GifCapture</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>GifCaptureBuildKind</key>
    <string>$BUILD_KIND</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
# The project lives in an iCloud-synced folder whose file provider can reattach
# metadata between xattr cleanup and codesign. Sign a clean staging copy outside
# iCloud, then use that copy for distribution and installation.
SIGN_STAGE_ROOT="$(mktemp -d /tmp/gifcapture-sign.XXXXXX)"
trap 'rm -rf "$SIGN_STAGE_ROOT"' EXIT
SIGN_APP="$SIGN_STAGE_ROOT/$APP_NAME.app"
ditto --noextattr --noacl --norsrc "$APP_DIR" "$SIGN_APP"
xattr -cr "$SIGN_APP" 2>/dev/null || true
for attempt in 1 2 3; do
  if codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$SIGN_APP" 2>/dev/null; then
    break
  fi
  if [ "$attempt" = 3 ]; then
    echo "ERROR: codesign failed after 3 attempts" >&2
    exit 1
  fi
  echo "codesign attempt $attempt failed; clearing metadata and retrying..."
  xattr -cr "$SIGN_APP" 2>/dev/null || true
  sleep 1
done
# Keep the conventional build artifact in place too. The canonical signed copy
# for the remaining build steps is SIGN_APP, which cannot be retagged by iCloud.
rm -rf "$APP_DIR"
ditto --noextattr --noacl --norsrc "$SIGN_APP" "$APP_DIR"

# Distribution copy: ALWAYS ad-hoc signed. Other Macs don't trust the local
# certificate, and macOS won't persist TCC grants for an app whose signature
# chains to an untrusted cert — it would re-prompt for Screen Recording forever.
DIST_DIR=".build/dist"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
# Sign the distribution variant in the same non-iCloud staging directory. The
# workspace file provider can otherwise attach metadata between copy and sign.
mkdir -p "$SIGN_STAGE_ROOT/release"
DIST_SIGN_APP="$SIGN_STAGE_ROOT/release/$APP_NAME.app"
ditto --noextattr --noacl --norsrc "$SIGN_APP" "$DIST_SIGN_APP"
plutil -replace GifCaptureBuildKind -string release "$DIST_SIGN_APP/Contents/Info.plist"
xattr -cr "$DIST_SIGN_APP" 2>/dev/null || true
codesign --force --sign - --identifier "$BUNDLE_ID" "$DIST_SIGN_APP"

# Keep an unpacked distribution artifact for inspection, but create the release
# zip directly from the canonical staging copy.
ditto --noextattr --noacl --norsrc "$DIST_SIGN_APP" "$DIST_DIR/$APP_NAME.app"
# Zip without extended attributes — macOS re-tags signed files with provenance
# xattrs that read as "detritus" and break signature verification on other Macs.
ditto --noextattr --noacl --norsrc -c -k --keepParent "$DIST_SIGN_APP" "$DIST_DIR/$APP_NAME.zip"
echo "Distribution zip (ad-hoc signed, for releases): $DIST_DIR/$APP_NAME.zip"

echo "Built $APP_DIR"

INSTALL_DIR="/Applications/$APP_NAME.app"
if [ "${SKIP_INSTALL:-0}" = "1" ]; then
  echo "Skipped installing to /Applications (SKIP_INSTALL=1)"
elif [ -w /Applications ] || [ -w "$INSTALL_DIR" ]; then
  echo "Installing to $INSTALL_DIR..."
  PREVIOUS_BUILD_KIND=""
  if [ -f "$INSTALL_DIR/Contents/Info.plist" ]; then
    PREVIOUS_BUILD_KIND="$(plutil -extract GifCaptureBuildKind raw "$INSTALL_DIR/Contents/Info.plist" 2>/dev/null || true)"
  fi
  pkill -f "$INSTALL_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  # Copy without Finder/resource metadata, then sign the installed copy. An
  # empty com.apple.FinderInfo xattr is still enough for strict signature
  # validation (and Screen Recording/TCC) to reject an otherwise valid app.
  ditto --noextattr --noacl --norsrc "$SIGN_APP" "$INSTALL_DIR"
  xattr -cr "$INSTALL_DIR" 2>/dev/null || true
  codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$INSTALL_DIR"
  if [ -n "$PREVIOUS_BUILD_KIND" ] && [ "$PREVIOUS_BUILD_KIND" != "$BUILD_KIND" ]; then
    echo "Signing mode changed ($PREVIOUS_BUILD_KIND -> $BUILD_KIND); resetting Screen Recording permission..."
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  echo "Installed. Launch it from Launchpad/Spotlight, or: open -a $APP_NAME"
else
  echo "Skipped installing to /Applications (not writable) — app is at $APP_DIR"
fi
