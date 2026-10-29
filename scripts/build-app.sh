#!/usr/bin/env bash
# Builds LiveWallpaper (universal), assembles an ad-hoc signed .app bundle and installs it to ~/Applications.
# SKIP_INSTALL=1 builds into build/ only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="LiveWallpaper"
BUNDLE_ID="io.github.qokori.LiveWallpaper"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP_DIR="$ROOT/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

cd "$ROOT"
# Universal binary (Apple Silicon + Intel).
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
# The app icon is drawn by code (Sources/LiveWallpaper/Logo.swift, built by scripts/make-icon.sh), so it is rebuilt with the app.
"$ROOT/scripts/make-icon.sh" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Live Wallpaper</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (no developer account required).
codesign --force --deep -s - "$APP_DIR"

echo "Built $APP_DIR (version $VERSION)"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
    echo "Installed $INSTALL_DIR/$APP_NAME.app"
fi
