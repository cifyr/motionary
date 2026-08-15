#!/bin/bash
# Captures App Store Connect screenshots at the one size it insists on.
#
# 6.9" is the required iPhone size (1320x2868); every smaller size is derived
# from it by App Store Connect, so this takes that one and nothing else.
#
# The Home Screen shot is the product, and it is the one that cannot be faked:
# the widget has to be placed by SpringBoard before it can be photographed,
# which is what the UI test target is for.
#
#   Tools/store-shots.sh [output-directory]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/store-shots}"
SIM="${MOTIONARY_SHOT_SIM:-iPhone 17 Pro Max}"
BUNDLE_ID="com.caden.Motionary"
cd "$ROOT"
mkdir -p "$OUT"

echo "==> Booting $SIM"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true

SIZE="$(xcrun simctl io "$SIM" screenshot "$OUT/.probe.png" >/dev/null 2>&1 && \
    sips -g pixelWidth -g pixelHeight "$OUT/.probe.png" | awk '/pixel/{printf "%s", $2"x"}' | sed 's/x$//')"
rm -f "$OUT/.probe.png"
if [ "$SIZE" != "1320x2868" ]; then
    echo "$SIM is $SIZE, not the 1320x2868 App Store Connect wants." >&2
    echo "Set MOTIONARY_SHOT_SIM to a 6.9\" device." >&2
    exit 1
fi

echo "==> Building"
xcodebuild -project Motionary.xcodeproj -scheme Motionary -configuration Debug \
    -destination "platform=iOS Simulator,name=$SIM" build >/dev/null
APP="$(xcodebuild -project Motionary.xcodeproj -scheme Motionary -configuration Debug \
    -destination "platform=iOS Simulator,name=$SIM" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"

# On a simulator that has never run this app, the extension is not in the
# widget gallery yet and the placement test fails looking for it. Launching the
# app once and restarting SpringBoard registers it. Not a product fault - a
# store install registers normally - but it makes this script fail on exactly
# the fresh machine someone would run it on.
echo "==> Registering the extension with the widget gallery"
xcrun simctl install "$SIM" "$APP" >/dev/null
xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
sleep 8
xcrun simctl terminate "$SIM" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl spawn "$SIM" launchctl stop com.apple.SpringBoard 2>/dev/null || true
sleep 10

echo "==> Placing the widget"
# SpringBoard has to put it on the Home Screen before it can be photographed,
# which is what the UI test target is for.
xcodebuild -project Motionary.xcodeproj -scheme Motionary \
    -destination "platform=iOS Simulator,name=$SIM" \
    -only-testing:MotionaryUITests/WidgetPlacementTests test >/dev/null

shoot() {
    local name="$1"
    sleep 2
    xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1
    echo "    $name.png"
}

echo "==> Capturing"
xcrun simctl terminate "$SIM" "$BUNDLE_ID" 2>/dev/null || true
shoot "1-home-screen"

xcrun simctl launch "$SIM" "$BUNDLE_ID" >/dev/null
sleep 4
shoot "2-in-app"

echo
echo "==> $OUT"
echo "These are the frames, not the listing. Anything with a recreated brand"
echo "mark in it is the same question the readiness doc raises about shipping"
echo "them at all - decide that before either goes near App Store Connect."
