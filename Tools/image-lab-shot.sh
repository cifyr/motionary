#!/bin/bash
# Builds, installs, switches the image lab on, and photographs the Home Screen
# widget over and over.
#
# The font lab needed one picture per route. This needs a sequence: the claim
# under test is that a stack of ordinary images advances on its own, and the
# only evidence for that is the same widget looking different a fraction of a
# second later. Nothing in this process drives the animation, so it cannot be
# stepped - it has to be watched.
#
#   Tools/image-lab-shot.sh 16 256 separate out-dir
set -euo pipefail

FRAMES="${1:-16}"
SIDE="${2:-256}"
MODE="${3:-separate}"
OUT="${4:-/tmp/image-lab}"
COUNT="${MOTIONARY_BURST_COUNT:-24}"
GAP_MS="${MOTIONARY_BURST_GAP_MS:-250}"
PAGE="${MOTIONARY_BURST_PAGE:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${MOTIONARY_SIM:-FD52D4B0-40BD-423A-8FDB-B1D41C369CA4}"
BUNDLE_ID="com.caden.Motionary"
DERIVED="${MOTIONARY_DERIVED:-build/simA}"
cd "$ROOT"

echo "==> Building"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" build >/dev/null

xcrun simctl install "$SIM" "$DERIVED/Build/Products/Debug-iphonesimulator/Motionary.app"

echo "==> Switching the lab on: $FRAMES frames, ${SIDE}px, $MODE"
xcrun simctl launch "$SIM" "$BUNDLE_ID" \
    -MotionaryImageLabOn \
    -MotionaryImageLabFrames "$FRAMES" \
    -MotionaryImageLabSide "$SIDE" \
    -MotionaryImageLabMode "$MODE" >/dev/null
# The app writes the frames and pushes a reload; the extension then needs a
# moment to be asked for a timeline and to render it.
sleep 12
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 4

echo "==> Photographing $COUNT times, ${GAP_MS}ms apart"
rm -rf "$OUT"
mkdir -p "$OUT"
# The runner keeps its Documents across runs, so last run's burst is still
# sitting there and would be copied out as if it belonged to this one.
find ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/Application \
    -name "burst-*.png" -maxdepth 4 -delete 2>/dev/null || true
# TEST_RUNNER_ prefixed variables are the only ones xcodebuild forwards into
# the runner, with the prefix stripped. Set plainly, they stay in this shell and
# the burst quietly photographs the wrong page with default settings.
TEST_RUNNER_MOTIONARY_BURST_COUNT="$COUNT" \
TEST_RUNNER_MOTIONARY_BURST_GAP_MS="$GAP_MS" \
TEST_RUNNER_MOTIONARY_BURST_PAGE="$PAGE" \
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" \
    -only-testing:MotionaryUITests/WidgetPageTests/testCaptureABurst test >/dev/null 2>&1 || true

DOCS=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/Application \
    -name "burst-*.png" -maxdepth 4 2>/dev/null | xargs -r -n1 dirname | sort -u | tail -1)
[ -n "$DOCS" ] || { echo "the UI test produced no screenshots" >&2; exit 1; }
cp "$DOCS"/burst-*.png "$OUT/"

# The container listing is "<group id><tab><path>"; only the path is wanted.
GROUP=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" groups 2>/dev/null \
    | awk -F'\t' '/group.com.caden.Motionary/ {print $2}' | tail -1)
if [ -n "$GROUP" ]; then
    cp "$GROUP/widget-renders.log" "$OUT/widget-renders.log" 2>/dev/null || true
fi

echo "==> $OUT ($(ls "$OUT"/burst-*.png | wc -l | tr -d ' ') shots)"
