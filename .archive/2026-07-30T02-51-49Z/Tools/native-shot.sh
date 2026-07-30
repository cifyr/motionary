#!/bin/bash
# Builds a runtime-frame design on the simulator from a clip, then reads what the
# widget extension made of it.
#
# The claim this route rests on is that the phone can produce an animating widget
# with nothing compiled. The evidence is a footprint taken inside the extension
# and a burst of screenshots showing the same widget different a fraction of a
# second later - nothing in the process drives the animation, so it cannot be
# stepped, it has to be watched.
#
# Nothing here touches a physical device. Simulator only.
#
#   Tools/native-shot.sh <clip.gif> <fps> <separate|sheet> [out-dir]
#
# MOTIONARY_BURST=1 also photographs the widget page repeatedly.
set -euo pipefail

CLIP="${1:?usage: native-shot.sh <clip.gif> <fps> <separate|sheet> [out-dir]}"
FPS="${2:-16}"
LAYOUT="${3:-separate}"
OUT="${4:-/tmp/native-$FPS-$LAYOUT}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${MOTIONARY_SIM:-FD52D4B0-40BD-423A-8FDB-B1D41C369CA4}"
BUNDLE_ID="com.caden.Motionary"
DERIVED="${MOTIONARY_DERIVED:-build/simN}"
BURST_COUNT="${MOTIONARY_BURST_COUNT:-120}"
BURST_GAP_MS="${MOTIONARY_BURST_GAP_MS:-240}"
BURST_PAGE="${MOTIONARY_BURST_PAGE:-0}"
# How long the import is given. 64 full-resolution frames is a real amount of
# work and a run that walks off before it finishes reports the previous design.
IMPORT_WAIT="${MOTIONARY_IMPORT_WAIT:-75}"
cd "$ROOT"

[ -f "$CLIP" ] || { echo "no clip at $CLIP" >&2; exit 1; }
CLIP_ABS="$(cd "$(dirname "$CLIP")" && pwd)/$(basename "$CLIP")"

echo "==> Building"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" build >/dev/null

# Terminated first, and this is not tidiness. `simctl launch` against an
# already-running app returns that app's pid and exits 0 without restarting it,
# so the import arguments are silently dropped and the run measures whichever
# design was there before. Three configurations of a sweep were lost to it.
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM" "$DERIVED/Build/Products/Debug-iphonesimulator/Motionary.app"

# Pushed into the app's own container rather than read from the host: the
# simulator can reach host paths, but the phone cannot, and the import should be
# exercised the way it will actually run.
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" data)
STAGED="$CONTAINER/Documents/$(basename "$CLIP_ABS")"
mkdir -p "$CONTAINER/Documents"
cp "$CLIP_ABS" "$STAGED"

GROUP=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" groups 2>/dev/null \
    | awk -F'\t' '/group.com.caden.Motionary/ {print $2}' | tail -1)
[ -n "$GROUP" ] || { echo "the app group container is not there" >&2; exit 1; }
# The render log is append-only and kept short; clearing it means every line
# read back belongs to this run rather than to whichever run last succeeded.
rm -f "$GROUP/widget-renders.log" "$GROUP/widget-status.json"

echo "==> Importing on the phone: $FPS fps, $LAYOUT"
# The font lab is switched off explicitly. It is sticky - it lives in the app
# group's defaults - and a simulator left with it on renders the lab instead of
# the design, which reads as this route drawing nothing at all. Cost a run
# before it was spotted.
xcrun simctl launch "$SIM" "$BUNDLE_ID" \
    -MotionaryFontLabOff \
    -MotionaryImportPath "$STAGED" \
    -MotionaryImportFPS "$FPS" \
    -MotionaryImportLayout "$LAYOUT" \
    -MotionaryImportReplace >/dev/null

# Waited on rather than slept through: the import writes a line when it lands.
for _ in $(seq 1 "$IMPORT_WAIT"); do
    grep -q "app  imported\|app  IMPORT FAILED" "$GROUP/widget-renders.log" 2>/dev/null && break
    sleep 1
done
printf 'import wait  %ss\n' "$SECONDS"
if grep -q "app  IMPORT FAILED" "$GROUP/widget-renders.log" 2>/dev/null; then
    echo "==> The import failed:" >&2
    grep "IMPORT FAILED" "$GROUP/widget-renders.log" >&2
    exit 1
fi
grep -q "app  imported" "$GROUP/widget-renders.log" 2>/dev/null \
    || { echo "the import did not finish within ${IMPORT_WAIT}s" >&2; exit 1; }

# The extension needs a moment to be asked for a timeline and to render it, and
# the app has to be out of the way so the render is a placed widget's.
sleep 6
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 8

mkdir -p "$OUT"
cp "$GROUP/widget-renders.log" "$OUT/widget-renders.log" 2>/dev/null || true
cp "$GROUP/widget-status.json" "$OUT/widget-status.json" 2>/dev/null || true

# The bytes on disk, which the manifest also states but which is worth measuring
# rather than trusting.
#
# The newest folder that actually holds frames, not simply the last one `find`
# happened to walk. The store keeps lane-font designs alongside these and one of
# those has no Frames directory at all, which under `pipefail` took the whole run
# down after it had already succeeded.
DESIGN_DIR=""
for candidate in $(ls -td "$GROUP"/Designs/*/ 2>/dev/null); do
    if [ -d "$candidate/Frames" ]; then
        DESIGN_DIR="$candidate"
        break
    fi
done
if [ -n "$DESIGN_DIR" ]; then
    du -sk "$DESIGN_DIR/Frames" 2>/dev/null | awk '{printf "frames on disk  %.1fMB\n", $1/1024}' || true
    cp "$DESIGN_DIR/manifest.json" "$OUT/manifest.json" 2>/dev/null || true
else
    echo "frames on disk  none found"
fi

# The archived timeline: the one cost of this route that is not in the app
# group and not in the extension's footprint.
#
# WidgetKit serialises the rendered view hierarchy and keeps it, so the pictures
# are paid for twice - once decoding them, once in the archive - and there is a
# documented limit on the archive that nothing in the process reports. It turns
# out to be observable: the extension's own PluginKit container holds it under
# SystemData/com.apple.chrono/timelines. The container has to be found by
# identity because `simctl get_app_container` will not name an app extension.
WIDGET_CONTAINER=""
for candidate in ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/PluginKitPlugin/*/; do
    identity=$(plutil -extract MCMMetadataIdentifier raw \
        "$candidate/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)
    if [ "$identity" = "com.caden.Motionary.widget" ]; then
        WIDGET_CONTAINER="$candidate"
        break
    fi
done

echo "==> Archived timeline"
if [ -n "$WIDGET_CONTAINER" ]; then
    ARCHIVES="$WIDGET_CONTAINER/SystemData/com.apple.chrono/timelines"
    find "$ARCHIVES" -name "*.chrono-timeline" -exec ls -l {} + 2>/dev/null \
        | awk '{printf "  %.2fMB  %s\n", $5/1048576, $NF}' \
        | tee "$OUT/archive-sizes.txt"
    [ -s "$OUT/archive-sizes.txt" ] || echo "  no archive written yet"
else
    echo "  could not find the widget extension's container" >&2
fi

echo "==> What the extension reported"
grep -E "img |PLACED|GALLERY|app  " "$OUT/widget-renders.log" 2>/dev/null || echo "  nothing"

if [ "${MOTIONARY_BURST:-0}" = "1" ]; then
    echo "==> Photographing $BURST_COUNT times, ${BURST_GAP_MS}ms apart"
    find ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/Application \
        -name "burst-*.png" -maxdepth 4 -delete 2>/dev/null || true
    # TEST_RUNNER_ prefixed variables are the only ones xcodebuild forwards into
    # the runner, with the prefix stripped. Set plainly, they stay in this shell
    # and the burst quietly photographs the wrong page with default settings.
    TEST_RUNNER_MOTIONARY_BURST_COUNT="$BURST_COUNT" \
    TEST_RUNNER_MOTIONARY_BURST_GAP_MS="$BURST_GAP_MS" \
    TEST_RUNNER_MOTIONARY_BURST_PAGE="$BURST_PAGE" \
    xcodebuild -project Motionary.xcodeproj -scheme Motionary \
        -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" \
        -only-testing:MotionaryUITests/WidgetPageTests/testCaptureABurst test >/dev/null 2>&1 || true

    DOCS=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/Application \
        -name "burst-*.png" -maxdepth 4 2>/dev/null | xargs -r -n1 dirname | sort -u | tail -1)
    [ -n "$DOCS" ] || { echo "the UI test produced no screenshots" >&2; exit 1; }
    cp "$DOCS"/burst-*.png "$OUT/"
    echo "==> $(ls "$OUT"/burst-*.png | wc -l | tr -d ' ') shots in $OUT"
fi

echo "==> $OUT"
