#!/usr/bin/env bash
# Packs the app into the release zip and writes <output.zip>.sha256 next to it.
# Usage: scripts/make-zip.sh <LiveWallpaper.app> <output.zip>
#
# The app is copied first and cleaned of extended attributes, and ditto runs without resource forks, so the archive
# has no AppleDouble (._*) files: those break the signature after a plain unzip.
set -euo pipefail

APP="${1:?usage: make-zip.sh <LiveWallpaper.app> <output.zip>}"
OUT="${2:?usage: make-zip.sh <LiveWallpaper.app> <output.zip>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$APP/Contents" ] || { echo "$APP is not an app bundle" >&2; exit 1; }

ditto --norsrc --noextattr "$APP" "$WORK/$(basename "$APP")"
xattr -cr "$WORK/$(basename "$APP")"
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT"
ditto -c -k --norsrc --noextattr --keepParent "$WORK/$(basename "$APP")" "$OUT"
if unzip -l "$OUT" | grep -q '/\._\|__MACOSX'; then echo "the archive contains AppleDouble files" >&2; exit 1; fi
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "Built $OUT"
