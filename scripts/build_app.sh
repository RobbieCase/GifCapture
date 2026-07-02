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
BUILD_DIR=".build/release"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

mkdir -p "$BUILD_DIR"

echo "Compiling..."
swiftc -O \
  Sources/GifCapture/*.swift \
  -o "$BUILD_DIR/$APP_NAME" \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreGraphics

echo "Assembling app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# Bundle the official (universal, self-contained) gifski binary so installs
# on other Macs don't need Homebrew.
if [ -f "Resources/bin/gifski" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/bin"
  cp "Resources/bin/gifski" "$APP_DIR/Contents/Resources/bin/gifski"
  chmod +x "$APP_DIR/Contents/Resources/bin/gifski"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>GifCapture</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Ad-hoc signing..."
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR"

echo "Built $APP_DIR"

INSTALL_DIR="/Applications/$APP_NAME.app"
if [ -w /Applications ] || [ -w "$INSTALL_DIR" ]; then
  echo "Installing to $INSTALL_DIR..."
  pkill -f "$INSTALL_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  cp -R "$APP_DIR" "$INSTALL_DIR"
  echo "Installed. Launch it from Launchpad/Spotlight, or: open -a $APP_NAME"
else
  echo "Skipped installing to /Applications (not writable) — app is at $APP_DIR"
fi
