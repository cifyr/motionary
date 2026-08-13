#!/bin/bash
# Measures what a stack of runtime frames costs the widget extension, on the
# phone, one point at a time.
#
# The engine's frames are glyphs in fonts the renderer loads a glyph at a time.
# Frames delivered as pictures are decoded by the extension instead, and the
# extension is killed a little above 45MB - so how many frames a design can
# have is a measurement, not a preference. Each point sets the stack, waits for
# a render, and reads the extension's own report back off the phone.
#
#   Tools/mask-sweep.sh "32,32,360 32,32,540 64,64,540"
set -euo pipefail

POINTS="${1:-32,4,240 32,32,360 32,32,540 32,32,720 64,64,540}"
DEVICE="${MOTIONARY_DEVICE:-00008150-00042CA60C9A401C}"
BUNDLE_ID="com.caden.Motionary"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${MOTIONARY_SWEEP_OUT:-/tmp/motionary-sweep}"
cd "$ROOT"
mkdir -p "$OUT"

echo "==> Building and installing"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS,id=$DEVICE" -derivedDataPath build/device \
    -allowProvisioningUpdates build >/dev/null
xcrun devicectl device install app --device "$DEVICE" \
    build/device/Build/Products/Debug-iphoneos/Motionary.app >/dev/null

printf '\n%-16s %-8s %s\n' "STACK" "FOOTPRINT" "WHAT THE EXTENSION SAID"
for point in $POINTS; do
    xcrun devicectl device process launch --device "$DEVICE" --activate \
        --terminate-existing "$BUNDLE_ID" -- \
        -MotionaryMaskLabOn -MotionaryMaskLabStack "$point" >/dev/null
    # The app writes the cards and pushes a reload; the extension is asked for a
    # timeline and archives it after that, and neither is instant.
    sleep 18
    Tools/pull-reports.sh "$OUT/$point" >/dev/null 2>&1 || true

    line=$(grep "  mask " "$OUT/$point/widget-renders.log" 2>/dev/null | tail -1 || true)
    footprint=$(echo "$line" | grep -o '[0-9]*MB' | tail -1 || true)
    trouble=$(grep -icE "imageTooLarge|badTimelineData|archiveTooLarge" \
        "$OUT/$point/widget-renders.log" 2>/dev/null || echo 0)
    printf '%-16s %-8s %s\n' "$point" "${footprint:-none}" \
        "$(echo "$line" | sed 's/.*mask //')${trouble:+  archiver complaints: $trouble}"
done
echo
echo "==> Reports under $OUT"
