#!/bin/bash
# Puts the edge calibration target in the widget and photographs the Home
# Screen, so what the system does to the widget's border can be measured.
#
# The composite is the only place the effect exists: the extension draws known
# pixels and something else decides what reaches the screen. Read the shot with
# Tools/edge-profile.py.
#
#   Tools/edge-shot.sh on /tmp/edge.png
set -euo pipefail

MODE="${1:-on}"
OUT="${2:-/tmp/edge.png}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${MOTIONARY_SIM:-FD52D4B0-40BD-423A-8FDB-B1D41C369CA4}"
BUNDLE_ID="com.caden.Motionary"
cd "$ROOT"

case "$MODE" in
    on) FLAG=-MotionaryEdgeLabOn ;;
    off) FLAG=-MotionaryEdgeLabOff ;;
    *) echo "usage: edge-shot.sh <on|off> [out.png]" >&2; exit 1 ;;
esac

echo "==> Building"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/sim build >/dev/null

xcrun simctl install "$SIM" build/sim/Build/Products/Debug-iphonesimulator/Motionary.app
xcrun simctl launch "$SIM" "$BUNDLE_ID" "$FLAG" >/dev/null
# The app sets the flag and pushes a reload; the extension needs a moment to be
# asked for a timeline and to render it.
sleep 10
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
sleep 4

echo "==> Photographing the Home Screen"
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,id=$SIM" -derivedDataPath build/sim \
    -only-testing:MotionaryUITests test >/dev/null 2>&1 || true

SHOT=$(find ~/Library/Developer/CoreSimulator/Devices/"$SIM"/data/Containers/Data/Application \
    -name "page-0.png" -maxdepth 4 2>/dev/null | xargs -r ls -t | head -1)
[ -n "$SHOT" ] || { echo "the UI test produced no screenshot" >&2; exit 1; }
cp "$SHOT" "$OUT"
echo "==> $OUT"
