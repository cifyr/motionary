#!/bin/bash
# Builds, installs, switches the mask lab on, places the widget, and takes a
# burst of Home Screen photographs.
#
# One photograph cannot answer this. A mask that was resolved when the view was
# archived shows a card too - it just shows the same one forever - so the
# finding is whether the card CHANGES between shots, which is why this takes
# several and leaves them side by side.
#
#   Tools/mask-shot.sh /tmp/mask 8
set -euo pipefail

OUT="${1:-/tmp/mask}"
SHOTS="${2:-8}"
STACK="${3:-32,4,240}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${MOTIONARY_SIM:-FD52D4B0-40BD-423A-8FDB-B1D41C369CA4}"
BUNDLE_ID="com.caden.Motionary"
cd "$ROOT"

echo "==> Building"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/sim build >/dev/null

xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM" build/sim/Build/Products/Debug-iphonesimulator/Motionary.app
# The app writes the cards the extension reads, so it has to run before the
# widget is asked for a timeline.
xcrun simctl launch "$SIM" "$BUNDLE_ID" -MotionaryMaskLabOn -MotionaryMaskLabStack "$STACK" >/dev/null
sleep 8
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 3

echo "==> Placing the widget"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/sim \
    -only-testing:MotionaryUITests test >/dev/null 2>&1 || true

echo "==> Photographing $SHOTS times"
mkdir -p "$OUT"
rm -f "$OUT"/shot-*.png
for i in $(seq 1 "$SHOTS"); do
    xcrun simctl io "$SIM" screenshot "$OUT/shot-$i.png" >/dev/null 2>&1
    sleep 0.35
done
echo "==> $OUT/shot-1.png .. shot-$SHOTS.png"
