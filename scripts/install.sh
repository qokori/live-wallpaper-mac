#!/usr/bin/env bash
# Installs Live Wallpaper from a GitHub release without the Gatekeeper "Apple could not verify" warning.
#
#   curl -fsSL https://raw.githubusercontent.com/qokori/live-wallpaper-mac/main/scripts/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --version 0.4.0
#
# It downloads the release zip with curl (a file fetched by curl gets no quarantine mark, so Gatekeeper has nothing to
# ask about), checks its SHA-256 against the .sha256 file of the same release, unpacks it with ditto and puts
# LiveWallpaper.app into /Applications, or into ~/Applications when /Applications is not writable. No sudo.
# If the app is running it asks you to quit it and does nothing. It never touches the quarantine attribute.
#
# For testing: LW_INSTALL_DIR replaces the install folder, LW_BASE_URL the release download address (file:// works),
# LW_APP_PROCESS the process name that counts as "the app is running".
set -euo pipefail

REPO="qokori/live-wallpaper-mac"
APP="LiveWallpaper.app"
PROCESS="${LW_APP_PROCESS:-LiveWallpaper}"
VERSION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a number, for example 0.4.0}"; shift 2 ;;
        --version=*) VERSION="${1#--version=}"; shift ;;
        -h|--help) sed -n '2,12p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }

if pgrep -x "$PROCESS" >/dev/null 2>&1; then
    echo "Live Wallpaper is running. Quit it (menu bar icon → «Выйти») and run this again. Nothing was changed." >&2
    exit 1
fi

if [ -z "$VERSION" ]; then
    # /releases/latest redirects to /releases/tag/vX.Y.Z; no API token or JSON tools needed.
    final="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" || fail "cannot reach GitHub"
    VERSION="${final##*/v}"
    case "$VERSION" in [0-9]*) ;; *) fail "cannot find the latest release (got: $final)" ;; esac
fi
VERSION="${VERSION#v}"
BASE="${LW_BASE_URL:-https://github.com/$REPO/releases/download/v$VERSION}"
ZIP="LiveWallpaper-$VERSION.zip"

if [ -n "${LW_INSTALL_DIR:-}" ]; then
    DEST="$LW_INSTALL_DIR"
elif [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading Live Wallpaper ${VERSION}…"
curl -fsSL -o "$WORK/$ZIP" "$BASE/$ZIP" || fail "cannot download $BASE/$ZIP (is there a release v$VERSION?)"
curl -fsSL -o "$WORK/$ZIP.sha256" "$BASE/$ZIP.sha256" || fail "cannot download $BASE/$ZIP.sha256"

expected="$(awk '{print $1; exit}' "$WORK/$ZIP.sha256")"
actual="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "SHA-256 does not match (expected $expected, got $actual); nothing was installed"
echo "SHA-256 ok."

mkdir "$WORK/unpacked"
ditto -x -k "$WORK/$ZIP" "$WORK/unpacked"
[ -d "$WORK/unpacked/$APP" ] || fail "$ZIP does not contain $APP"

# Copy next to the target first, then swap, so a failed copy never leaves the old app half-removed.
rm -rf "${DEST:?}/.$APP.new"
ditto "$WORK/unpacked/$APP" "$DEST/.$APP.new"
rm -rf "${DEST:?}/$APP"
mv "$DEST/.$APP.new" "$DEST/$APP"

echo "Installed $DEST/$APP (version $VERSION)."
echo "Open it from Applications or Launchpad."
