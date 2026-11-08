#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
PRODUCT_NAME="Standup"
APP_NAME="Standup"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
BUILD_DIR="${TMPDIR:-/private/tmp}/startup-manager-swift-build"

cd "$ROOT"
swift "$ROOT/Scripts/render_logo.swift"
swift build -c release --scratch-path "$BUILD_DIR"
if [[ -e "$APP_BUNDLE" ]]; then rm -rf "$APP_BUNDLE"; fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
BIN_PATH="$BUILD_DIR/out/Products/Release/$PRODUCT_NAME"
if [[ ! -x "$BIN_PATH" ]]; then BIN_PATH="$BUILD_DIR/$PRODUCT_NAME"; fi
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT/Assets/StartupManagerLogo.png" "$APP_BUNDLE/Contents/Resources/StartupManagerLogo.png"
iconutil -c icns "$ROOT/Assets/StartupManager.iconset" -o "$APP_BUNDLE/Contents/Resources/StartupManagerLogo.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Standup</string>
<key>CFBundleIdentifier</key><string>local.startup-manager</string>
<key>CFBundleIconFile</key><string>StartupManagerLogo</string>
<key>CFBundleName</key><string>Standup</string>
<key>CFBundleDisplayName</key><string>Standup</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP_BUNDLE"
echo "Created: $APP_BUNDLE"
