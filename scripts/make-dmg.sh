#!/usr/bin/env bash
# Builds the installer disk image: a window with its own background, an arrow and the app next to Applications.
# Usage: scripts/make-dmg.sh <LiveWallpaper.app> <output.dmg>
#
# The window layout (.DS_Store) is written by dmgbuild, so Finder is never opened and no AppleScript runs. dmgbuild is
# installed into build/dmg-venv on first use (needs network once); nothing is installed system-wide. While the image
# is built, hdiutil mounts it read-write with -nobrowse (no Finder window, no desktop icon) and detaches it again.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: make-dmg.sh <LiveWallpaper.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <LiveWallpaper.app> <output.dmg>}"
DMGBUILD_VERSION="1.6.7"
VENV="$ROOT/build/dmg-venv"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$APP/Contents/Resources/AppIcon.icns" ] || { echo "no AppIcon.icns in $APP (build it with scripts/build-app.sh)" >&2; exit 1; }

if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi

# A program of two files needs its entry point to be called main.swift; Logo.swift is the one drawing of the logo.
cp "$ROOT/scripts/dmg-background.swift" "$WORK/main.swift"
swiftc -O -o "$WORK/dmg-background" "$WORK/main.swift" "$ROOT/Sources/LiveWallpaper/Logo.swift"
"$WORK/dmg-background" background "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null
LAYOUT="$("$WORK/dmg-background" layout)"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" \
    -D app="$APP" -D layout="$LAYOUT" -D background="$WORK/background.tiff" \
    -D volume_icon="$APP/Contents/Resources/AppIcon.icns" \
    "Live Wallpaper" "$OUT"
echo "Built $OUT"
