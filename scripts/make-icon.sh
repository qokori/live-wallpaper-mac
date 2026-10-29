#!/usr/bin/env bash
# Builds AppIcon.icns from scripts/make-icon.swift. Usage: scripts/make-icon.sh <output.icns>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: make-icon.sh <output.icns>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$WORK/AppIcon.iconset"
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
