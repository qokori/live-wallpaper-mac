#!/usr/bin/env bash
# Checks the update chain without a network and without running the app:
#  1. the built .app: Info.plist keys, Sparkle.framework embedded and signed inside out, rpath, `codesign --verify --deep --strict`;
#  2. make-appcast.sh with a throwaway key in a temp folder: the signature verifies, a tampered zip does not, the feed is valid.
# Usage: scripts/test-updates.sh [LiveWallpaper.app]   (default build/LiveWallpaper.app, made by scripts/build-app.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/LiveWallpaper.app}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if "${@:2}" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
plist() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist" 2>/dev/null; }
expect() { [ "$(plist "$1")" = "$2" ]; }

# 1. the app
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
check "Sparkle.framework is embedded" test -d "$FRAMEWORK/Versions/B"
check "SUFeedURL points at the latest release's appcast.xml" expect SUFeedURL "https://github.com/qokori/live-wallpaper-mac/releases/latest/download/appcast.xml"
check "SUPublicEDKey is a 32-byte base64 key" bash -c "[ \"\$(plutil -extract SUPublicEDKey raw -o - '$APP/Contents/Info.plist' | base64 -D | wc -c | tr -d ' ')\" = 32 ]"
check "SUEnableAutomaticChecks is true" expect SUEnableAutomaticChecks true
check "SUScheduledCheckInterval is 86400" expect SUScheduledCheckInterval 86400
check "SUAutomaticallyUpdate is true (automatic install by default)" expect SUAutomaticallyUpdate true
check "SUAllowsAutomaticUpdates is true" expect SUAllowsAutomaticUpdates true
check "no private key material in Info.plist" bash -c "! grep -qi 'private' '$APP/Contents/Info.plist'"
check "rpath @executable_path/../Frameworks" bash -c "otool -l '$APP/Contents/MacOS/LiveWallpaper' | grep -q '@executable_path/../Frameworks'"
check "the binary links Sparkle through @rpath" bash -c "otool -L '$APP/Contents/MacOS/LiveWallpaper' | grep -q '@rpath/Sparkle.framework'"
for part in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK" "$APP"; do
    check "signed: ${part#"$APP"}" codesign --verify --strict "$part"
done
check "codesign --verify --deep --strict" codesign --verify --deep --strict "$APP"

# 2. appcast
SIGN="${SIGN_UPDATE:-$(find "$ROOT/.build/artifacts" -type f -name sign_update -path '*/bin/*' | head -1)}"
VERSION="$(plist CFBundleShortVersionString)"
mkdir -p "$WORK/release"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$WORK/release/LiveWallpaper-$VERSION.zip"
swiftc -O -o "$WORK/make-key" "$ROOT/scripts/make-sparkle-key.swift"
"$WORK/make-key" "$WORK/key/throwaway.key" > "$WORK/public.key"
echo "Release notes: a line.
<tag> & more" > "$WORK/notes.txt"
SPARKLE_KEY_FILE="$WORK/key/throwaway.key" check "make-appcast.sh writes the feed" \
    "$ROOT/scripts/make-appcast.sh" "$VERSION" --zip "$WORK/release/LiveWallpaper-$VERSION.zip" --notes "$WORK/notes.txt"
FEED="$WORK/release/appcast.xml"
signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$FEED")"
check "the feed has a signature" test -n "$signature"
check "the enclosure points at the versioned release zip" grep -q "releases/download/v$VERSION/LiveWallpaper-$VERSION.zip\"" "$FEED"
check "the notes are escaped" grep -q "&lt;tag&gt; &amp; more" "$FEED"
check "the feed is valid XML" xmllint --noout "$FEED"
check "sign_update --verify passes for the zip" "$SIGN" --ed-key-file "$WORK/key/throwaway.key" --verify "$WORK/release/LiveWallpaper-$VERSION.zip" "$signature"
cp "$WORK/release/LiveWallpaper-$VERSION.zip" "$WORK/tampered.zip"
printf 'x' >> "$WORK/tampered.zip"
check "sign_update --verify FAILS for a tampered zip" bash -c "! '$SIGN' --ed-key-file '$WORK/key/throwaway.key' --verify '$WORK/tampered.zip' '$signature'"
check "make-appcast.sh refuses a zip of another version" bash -c "! SPARKLE_KEY_FILE='$WORK/key/throwaway.key' '$ROOT/scripts/make-appcast.sh' 9.9.9 --zip '$WORK/release/LiveWallpaper-$VERSION.zip' --out '$WORK/x.xml'"

[ "$failures" -eq 0 ] && echo "all update checks passed" || { echo "$failures check(s) failed" >&2; exit 1; }
