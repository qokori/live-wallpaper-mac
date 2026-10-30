#!/usr/bin/env bash
# Builds Assets.car (the Icon Composer icon AppIcon.icon, which macOS tints for Tinted/Clear/Dark) from the same drawing as
# AppIcon.icns: scripts/make-icon.swift writes icon.json and the waves layer, `actool` compiles them.
# Usage: scripts/make-assets.sh <output Assets.car>   (CFBundleIconName in Info.plist is AppIcon)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: make-assets.sh <output Assets.car>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/scripts/make-icon.swift" "$WORK/main.swift"
swiftc -O -o "$WORK/make-icon" "$WORK/main.swift" "$ROOT/Sources/LiveWallpaper/Logo.swift"
"$WORK/make-icon" --icon "$WORK/AppIcon.icon"
mkdir -p "$WORK/out"
xcrun actool "$WORK/AppIcon.icon" --compile "$WORK/out" --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$WORK/out/partial.plist" --app-icon AppIcon --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en --target-device mac --minimum-deployment-target 14.0 --platform macosx
[ -f "$WORK/out/Assets.car" ] || { echo "actool made no Assets.car" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$WORK/out/Assets.car" "$OUT"
