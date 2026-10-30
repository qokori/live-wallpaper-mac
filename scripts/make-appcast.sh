#!/usr/bin/env bash
# Writes appcast.xml for a release: Sparkle reads it from the release assets (SUFeedURL in Info.plist points at
# .../releases/latest/download/appcast.xml). The release zip is signed with sign_update (EdDSA) and the enclosure points at the
# versioned zip of the same release, so upload appcast.xml together with LiveWallpaper-<version>.zip.
#
# Usage: scripts/make-appcast.sh <version> [--zip FILE] [--notes FILE] [--out FILE]
#   --zip    the release zip (default: LiveWallpaper-<version>.zip in the current folder)
#   --notes  a text file with the short release notes shown in the update window (first 40 lines)
#   --out    where appcast.xml goes (default: next to the zip)
# Environment: SPARKLE_KEY_FILE the private key (default ~/.config/live-wallpaper/sparkle_ed25519.key, made by
# scripts/make-sparkle-key.swift), SIGN_UPDATE the sign_update tool (default: the one SwiftPM fetched into .build/artifacts).
# The key is only read, never printed or copied.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="qokori/live-wallpaper-mac"
VERSION="${1:?usage: make-appcast.sh <version> [--zip FILE] [--notes FILE] [--out FILE]}"
shift
VERSION="${VERSION#v}"
ZIP="LiveWallpaper-$VERSION.zip"; NOTES=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --zip) ZIP="${2:?--zip needs a file}"; shift 2 ;;
        --notes) NOTES="${2:?--notes needs a file}"; shift 2 ;;
        --out) OUT="${2:?--out needs a file}"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$VERSION" in ''|*[!0-9.]*) echo "version must be digits and dots, for example 0.6.2" >&2; exit 2 ;; esac
[ -f "$ZIP" ] || { echo "no release zip: $ZIP" >&2; exit 1; }
[ -n "$OUT" ] || OUT="$(cd "$(dirname "$ZIP")" && pwd)/appcast.xml"

KEY="${SPARKLE_KEY_FILE:-$HOME/.config/live-wallpaper/sparkle_ed25519.key}"
[ -f "$KEY" ] || { echo "no signing key at $KEY (make one with scripts/make-sparkle-key.swift)" >&2; exit 1; }
SIGN="${SIGN_UPDATE:-$(find "$ROOT/.build/artifacts" -type f -name sign_update -path '*/bin/*' 2>/dev/null | head -1)}"
[ -x "$SIGN" ] || { echo "sign_update not found (run swift build once, or set SIGN_UPDATE)" >&2; exit 1; }

# The zip must hold exactly this version, so the feed can never offer a number the app does not carry.
inside="$(unzip -p "$ZIP" LiveWallpaper.app/Contents/Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)" \
    || { echo "$ZIP has no LiveWallpaper.app/Contents/Info.plist" >&2; exit 1; }
[ "$inside" = "$VERSION" ] || { echo "the app in $ZIP is version $inside, not $VERSION" >&2; exit 1; }

attributes="$("$SIGN" --ed-key-file "$KEY" "$ZIP")"
case "$attributes" in *'sparkle:edSignature="'*'length="'*) ;; *) echo "sign_update gave no signature" >&2; exit 1 ;; esac
attributes="$(printf '%s' "$attributes" | tr -d '\n')"

notes_html="Версия $VERSION / Version $VERSION"
if [ -n "$NOTES" ]; then
    notes_html="$(head -n 40 "$NOTES" | python3 -c 'import html,sys; print("<div style=\"white-space: pre-wrap\">" + html.escape(sys.stdin.read().strip()) + "</div>")')"
fi
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
url="https://github.com/$REPO/releases/download/v$VERSION/LiveWallpaper-$VERSION.zip"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Live Wallpaper</title>
        <link>https://github.com/$REPO</link>
        <item>
            <title>Version $VERSION</title>
            <pubDate>$date</pubDate>
            <sparkle:version>$VERSION</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[$notes_html]]></description>
            <enclosure url="$url" type="application/octet-stream" $attributes/>
        </item>
    </channel>
</rss>
XML
xmllint --noout "$OUT" || { echo "appcast.xml is not valid XML" >&2; exit 1; }
echo "Wrote $OUT (version $VERSION, enclosure $url)"
