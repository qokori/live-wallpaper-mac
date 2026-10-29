#!/usr/bin/env bash
# Builds AppIcon.icns from scripts/make-icon.swift and Sources/LiveWallpaper/Logo.swift. Usage: scripts/make-icon.sh <output.icns>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: make-icon.sh <output.icns>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A program of two files needs its entry point to be called main.swift.
cp "$ROOT/scripts/make-icon.swift" "$WORK/main.swift"
swiftc -O -o "$WORK/make-icon" "$WORK/main.swift" "$ROOT/Sources/LiveWallpaper/Logo.swift"
"$WORK/make-icon" "$WORK/AppIcon.iconset"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
