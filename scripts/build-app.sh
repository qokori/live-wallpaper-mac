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
# Sparkle checks every update against this public EdDSA key (the private half is outside the repo, see README).
SPARKLE_PUBLIC_KEY="6bgPBB94kaM7YqHUfm018bHSx/KEvqsm6VHmAFMpesY="
FEED_URL="https://github.com/qokori/live-wallpaper-mac/releases/latest/download/appcast.xml"

cd "$ROOT"
# Universal binary (Apple Silicon + Intel).
BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
# Sparkle.framework (from the SwiftPM artifact) lives in Contents/Frameworks; the binary finds it through this rpath.
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*macos-arm64_x86_64*' | head -1)"
[ -d "$SPARKLE_FRAMEWORK" ] || { echo "Sparkle.framework not found in .build/artifacts (run swift build first)" >&2; exit 1; }
ditto --norsrc --noextattr "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME"
# Drop the debug map (OSO/SO entries name the build directory) and local symbols; the signature is made after this.
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"
# The app icon is drawn by code (Sources/LiveWallpaper/Logo.swift, built by scripts/make-icon.sh), so it is rebuilt with the app.
"$ROOT/scripts/make-icon.sh" "$APP_DIR/Contents/Resources/AppIcon.icns"
# The same drawing as an Icon Composer icon, compiled by actool: macOS recolours it for Tinted/Clear/Dark (CFBundleIconName).
# The .icns stays for older systems, the volume icon of the .dmg and its preview.
"$ROOT/scripts/make-assets.sh" "$APP_DIR/Contents/Resources/Assets.car"

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
    <key>CFBundleIconName</key>
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
    <key>SUFeedURL</key>
    <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>
    <string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAllowsAutomaticUpdates</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
# Ad-hoc signature (no developer account required). Inside out and without --deep: Sparkle's helpers first, then the framework,
# then the app, so every nested code is signed by itself.
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in "$FRAMEWORK"/XPCServices/*.xpc "$FRAMEWORK/Updater.app" "$FRAMEWORK/Autoupdate"; do
    codesign --force -s - "$helper"
done
codesign --force -s - "$APP_DIR/Contents/Frameworks/Sparkle.framework"
codesign --force -s - "$APP_DIR"

echo "Built $APP_DIR (version $VERSION)"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    cp -R "$APP_DIR" "$INSTALL_DIR/$APP_NAME.app"
    echo "Installed $INSTALL_DIR/$APP_NAME.app"
fi
