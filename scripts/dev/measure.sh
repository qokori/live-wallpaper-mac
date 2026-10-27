#!/usr/bin/env bash
# Measures what the wallpaper costs: an idle baseline, then the app showing <source>, each over <seconds>.
# Reports CPU% and energy impact (top) of the app and of the helper processes it starts (VTDecoderXPCService for
# hardware video decoding, com.apple.WebKit.* for web pages), WindowServer CPU%, GPU utilization and average system
# power from the battery gauge. No root needed (powermetrics would need sudo). Quit LiveWallpaper before running.
# The app remembers <source> as its wallpaper and sets the video's first frame as the desktop picture (if that
# option is on), like a normal choice from the menu.
# Usage: scripts/dev/measure.sh <video | web folder | .html | https://…> [seconds=60]
#        LW_FPS=60 scripts/dev/measure.sh examples/aurora-shader      # web frame rate, 30 by default
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
SOURCE="$1"
SPAN="${2:-60}"
case "$SOURCE" in
    http://*|https://*|*.html|*.htm) FLAG=--web ;;
    *) if [ -d "$SOURCE" ]; then FLAG=--web; else FLAG=--video; fi ;;
esac
HELPERS='VTDecoderXPCService|com.apple.WebKit'


if pgrep -x LiveWallpaper >/dev/null; then echo "LiveWallpaper is already running; quit it first" >&2; exit 1; fi

telemetry() { ioreg -rn AppleSmartBattery | grep -o "\"$1\"=[0-9]*" | head -1 | cut -d= -f2; }
gpu() { ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*' | head -1 | cut -d= -f2; }

# Average system power (W) and GPU utilization (%) over SPAN seconds, while `top` measures the given pids.
sample() {
    local load0 count0 load1 count1 gpu_sum=0 gpu_n=0 top_out
    load0=$(telemetry AccumulatedSystemLoad); count0=$(telemetry SystemLoadAccumulatorCount)
    top_out=$(mktemp)
    top -l 2 -s "$SPAN" -stats pid,command,cpu,power "$@" > "$top_out" &
    local top_pid=$!
    for _ in $(seq 1 $((SPAN / 2))); do
        gpu_sum=$((gpu_sum + $(gpu))); gpu_n=$((gpu_n + 1)); sleep 2
    done
    wait "$top_pid"
    load1=$(telemetry AccumulatedSystemLoad); count1=$(telemetry SystemLoadAccumulatorCount)
    # Second `top` sample = averages over the interval.
    awk '/^PID/{block++} block==2 && $1 ~ /^[0-9]+$/ {printf "    %-22s CPU %5s%%  energy impact %s\n", $2" ("$1")", $3, $4}' "$top_out"
    rm -f "$top_out"
    awk -v l="$((load1 - load0))" -v c="$((count1 - count0))" -v g="$gpu_sum" -v n="$gpu_n" \
        'BEGIN { printf "    system power %.2f W (battery gauge average), GPU %.0f%%\n", (c > 0 ? l / c / 1000 : 0), g / n }'
}

WINDOW_SERVER=$(pgrep -x WindowServer)
echo "== baseline, app not running, ${SPAN}s"
sample -pid "$WINDOW_SERVER"

before=$(pgrep -f "$HELPERS" | sort || true)
"$APP" "$FLAG" "$SOURCE" --fps "${LW_FPS:-30}" 2>/dev/null &
APP_PID=$!
sleep 10
helpers=$(comm -13 <(echo "$before") <(pgrep -f "$HELPERS" | sort) | sed 's/^/-pid /' | tr '\n' ' ')
echo "== playing $(basename "$SOURCE") ($FLAG, web ${LW_FPS:-30} fps), ${SPAN}s"
# shellcheck disable=SC2086
sample -pid "$APP_PID" $helpers -pid "$WINDOW_SERVER"
# No EXIT trap: bash 3.2 also runs it inside $(...) subshells, which would kill the app mid-measurement.
kill "$APP_PID"
