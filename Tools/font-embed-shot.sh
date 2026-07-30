#!/bin/bash
# Renders the widget with one runtime-registered lane font and reads the archive
# WidgetKit wrote, with the private embedding flag off or on.
#
# The question is whether `_wantsCustomFontsEmbeddedInArchive` puts the font's
# bytes in the archive or only its URL. That is answerable from the archive
# itself and nowhere else: the extension cannot see what it produced, the widget
# looks the same either way in the simulator, and the failure the flag is meant
# to fix happens in a third process on a device. So the run renders, then reads.
#
# ONE font on purpose. Embedding is suspected to be per use site, and a 32-lane
# design is ~29MB of fonts against a documented ~10MB archive limit - a single
# lane is a clean signal and cannot be confused with hitting the ceiling.
#
# Nothing here touches a physical device. Simulator only.
#
#   Tools/font-embed-shot.sh <off|on> [out-dir]
set -euo pipefail

MODE="${1:?usage: font-embed-shot.sh <off|on> [out-dir]}"
case "$MODE" in
    off) FLAG="-MotionaryFontEmbeddingOff" ;;
    on)  FLAG="-MotionaryFontEmbeddingOn" ;;
    *) echo "mode must be off or on" >&2; exit 1 ;;
esac
OUT="${2:-/tmp/font-embed-$MODE}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${MOTIONARY_SIM:-8A2CFA72-B93E-4DAA-B146-2173636F94B8}"
BUNDLE_ID="com.caden.Motionary"
WIDGET_ID="com.caden.Motionary.widget"
DERIVED="${MOTIONARY_DERIVED:-build/simF}"
# Which lab route supplies the font. `groupProcess` is the production failure:
# an app group file registered with process scope, which encodes as a URL and is
# then denied to chronod on device.
ROUTES="${MOTIONARY_ROUTES:-groupProcess}"
RENDER_WAIT="${MOTIONARY_RENDER_WAIT:-40}"
cd "$ROOT"

# FONT_EMBED_PROBE is what compiles the private-symbol shim into the app and the
# extension. An ordinary build has no reference to the WidgetKit accessors at all,
# so without this the run would measure a widget that never set the flag - and
# report it as WidgetKit ignoring the flag.
echo "==> Building with the probe compiled in"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath "$DERIVED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) FONT_EMBED_PROBE' \
    build >/dev/null

# Terminated before installing: `simctl launch` against a running app returns
# its pid and exits 0 without restarting it, so the launch arguments - which are
# the entire experiment - would be silently dropped.
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$SIM" "$DERIVED/Build/Products/Debug-iphonesimulator/Motionary.app"

GROUP=$(xcrun simctl get_app_container "$SIM" "$BUNDLE_ID" groups 2>/dev/null \
    | awk -F'\t' '/group.com.caden.Motionary/ {print $2}' | tail -1)
[ -n "$GROUP" ] || { echo "the app group container is not there" >&2; exit 1; }

# The widget extension's own PluginKit container, found by identity because
# `simctl get_app_container` will not name an app extension.
WIDGET_CONTAINER=""
for candidate in ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/PluginKitPlugin/*/; do
    identity=$(plutil -extract MCMMetadataIdentifier raw \
        "$candidate/.com.apple.mobile_container_manager.metadata.plist" 2>/dev/null || true)
    if [ "$identity" = "$WIDGET_ID" ]; then
        WIDGET_CONTAINER="$candidate"
        break
    fi
done
[ -n "$WIDGET_CONTAINER" ] || { echo "no container for $WIDGET_ID - is a widget placed?" >&2; exit 1; }
ARCHIVES="$WIDGET_CONTAINER/SystemData/com.apple.chrono/timelines/MotionaryDesignWidget"

LAUNCH=(-MotionaryFontLabOn -MotionaryFontLabRoutes "$ROUTES" "$FLAG")

# Launched twice on purpose. Installing the app is itself enough to make the
# system ask the extension for a timeline, and that first render happens before
# the app has written this run's flag - so it renders under the *previous* run's
# setting. Measured: an "embedding off" run reported the flag observed true,
# because a pre-launch render had set it. The first launch only settles the
# defaults; everything is cleared afterwards and the second launch is the one
# whose render is read.
echo "==> Settling the flags"
xcrun simctl launch "$SIM" "$BUNDLE_ID" "${LAUNCH[@]}" >/dev/null
sleep 8
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 4

# Cleared after the settling launch, so everything read back belongs to the
# measured render. An archive left over from the other mode is the one mistake
# that would make the whole comparison meaningless.
rm -f "$GROUP/widget-renders.log" "$GROUP/widget-status.json" "$GROUP/font-embed-observed.txt"
rm -f "$ARCHIVES"/*.chrono-timeline

echo "==> Rendering: font lab on, route $ROUTES, embedding $MODE"
xcrun simctl launch "$SIM" "$BUNDLE_ID" "${LAUNCH[@]}" >/dev/null

# Out of the way, so the render that lands is a placed widget's rather than the
# app's, and then waited on until an archive appears.
sleep 5
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
for _ in $(seq 1 "$RENDER_WAIT"); do
    compgen -G "$ARCHIVES/*.chrono-timeline" >/dev/null && break
    sleep 1
done
sleep 3

mkdir -p "$OUT"
# The previous run's copy is removed first. `cp` of a file that is legitimately
# absent this time leaves the old one sitting there, and the run then reports an
# observation belonging to a different mode - which is exactly what happened.
rm -f "$OUT/font-embed-observed.txt" "$OUT/font-lab.txt"
cp "$GROUP/widget-renders.log" "$OUT/widget-renders.log" 2>/dev/null || true
cp "$GROUP/widget-status.json" "$OUT/widget-status.json" 2>/dev/null || true
cp "$GROUP/font-lab.txt" "$OUT/font-lab.txt" 2>/dev/null || true
cp "$GROUP/font-embed-observed.txt" "$OUT/font-embed-observed.txt" 2>/dev/null || true

# Whether the flag was actually in the environment the archived render saw. A
# missing line here means the transform closure never ran, which is a different
# answer from the flag having run and done nothing.
echo "==> What the environment read back"
cat "$OUT/font-embed-observed.txt" 2>/dev/null || echo "  the transform closure did not run"

echo "==> What the extension reported"
grep -E "lab |ask |OK  |FAIL|archiv" "$OUT/widget-renders.log" 2>/dev/null || echo "  nothing"

echo "==> Archive"
if compgen -G "$ARCHIVES/*.chrono-timeline" >/dev/null; then
    : >"$OUT/archive-report.txt"
    for archive in "$ARCHIVES"/*.chrono-timeline; do
        cp "$archive" "$OUT/$(basename "$archive")"
        python3 Tools/read-archive.py "$archive" \
            --expect-name "MLabGroupProcess-Regular" | tee -a "$OUT/archive-report.txt"
    done
else
    echo "  no archive was written - the widget was not asked, or the timeline was rejected" >&2
    exit 1
fi

# A negative result is only worth as much as the instrument that produced it, so
# the instrument proves itself on every run: one real lane font appended to this
# run's archive has to be found. If this fails, "no embedded fonts" above means
# nothing.
echo "==> Detector self-check"
CONTROL="$OUT/positive-control.bin"
cat "$OUT"/*.chrono-timeline Resources/MFont9d1a703fL0-Regular.ttf >"$CONTROL" 2>/dev/null
if python3 Tools/read-archive.py "$CONTROL" --expect-name MFont9d1a703fL0-Regular \
    | grep -q "^embedded fonts 1$"; then
    echo "  ok: an appended font is found, so 'embedded fonts 0' is a real zero"
else
    echo "  the detector cannot find a font it was handed - the result above is void" >&2
    exit 1
fi
rm -f "$CONTROL"

echo "==> $OUT"
