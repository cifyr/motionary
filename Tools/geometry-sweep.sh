#!/bin/bash
# Runs the app and the widget on every iPhone simulator size and measures them.
#
# The build is cut for one measured phone and derived for the rest, so the
# question this answers is not "does it run" but "does it come out the right
# size and in the right place" - which is invisible unless something measures
# it. See Tools/geometry-sweep.py for what each number means.
#
#   Tools/geometry-sweep.sh [device-name ...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${MOTIONARY_SWEEP_OUT:-$ROOT/build/geometry-sweep}"
BUNDLE_ID="com.caden.Motionary"
cd "$ROOT"
mkdir -p "$OUT"

if [ "$#" -gt 0 ]; then
    DEVICES=("$@")
else
    DEVICES=("iPhone 17e" "iPhone 17" "iPhone Air" "iPhone 17 Pro" "iPhone 17 Pro Max")
fi

echo "==> Building once for the simulator"
xcodebuild -project Motionary.xcodeproj -scheme Motionary -configuration Debug \
    -destination "platform=iOS Simulator,name=${DEVICES[0]}" build >/dev/null
APP="$(xcodebuild -project Motionary.xcodeproj -scheme Motionary -configuration Debug \
    -destination "platform=iOS Simulator,name=${DEVICES[0]}" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"

for SIM in "${DEVICES[@]}"; do
    TAG="$(echo "$SIM" | tr ' ' '-')"
    echo
    echo "=== $SIM ==="
    xcrun simctl boot "$SIM" 2>/dev/null || true
    xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true

    xcrun simctl install "$SIM" "$APP"
    # A simulator that has never run this app has no widget in its gallery yet,
    # so the placement below would fail looking for one.
    xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    sleep 6
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl spawn "$SIM" launchctl stop com.apple.SpringBoard 2>/dev/null || true
    sleep 8

    if ! xcodebuild -project Motionary.xcodeproj -scheme Motionary \
        -destination "platform=iOS Simulator,name=$SIM" \
        -only-testing:MotionaryUITests/WidgetPlacementTests test >/dev/null 2>&1; then
        echo "    could not place the widget; skipping"
        continue
    fi

    sleep 3
    xcrun simctl io "$SIM" screenshot "$OUT/$TAG-home.png" >/dev/null 2>&1
    xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
    sleep 5
    xcrun simctl io "$SIM" screenshot "$OUT/$TAG-app.png" >/dev/null 2>&1
    xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true

    ID="$(xcrun simctl list devices | grep -F "$SIM (" | head -1 | sed 's/.*(\([A-F0-9-]*\)).*/\1/')"
    LOG="$(find "$HOME/Library/Developer/CoreSimulator/Devices/$ID/data/Containers/Shared/AppGroup" \
        -name widget-renders.log 2>/dev/null | head -1)"

    SIZE="$(sips -g pixelWidth -g pixelHeight "$OUT/$TAG-app.png" | awk '/pixel/{printf "%s ", $2}')"
    echo "    screen  $(echo "$SIZE" | tr ' ' 'x' | sed 's/x$//')px"
    python3 Tools/geometry-sweep.py "$OUT/$TAG-app.png" "$OUT/$TAG-home.png" "$LOG"
done

echo
echo "==> screenshots in $OUT"
