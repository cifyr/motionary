#!/bin/bash
# Builds the newest design as pictures and delivers it to a connected iPhone
# without installing anything.
#
# This is the whole point of the picture-built body of a design: the phone
# already has the app, and the design is data. Nothing here compiles the widget
# extension, and nothing here touches the toolchain on the phone's side - the
# package is copied into the app's own Documents, and the app takes delivery of
# it the next time it comes to the foreground.
#
#   Tools/deliver.sh [design-uuid]
set -euo pipefail

DESIGN="${1:-}"
DEVICE="${MOTIONARY_DEVICE:-00008150-00042CA60C9A401C}"
BUNDLE_ID="com.caden.Motionary"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="${MOTIONARY_PACKAGE:-/tmp/motionary-delivery.motionary}"
cd "$ROOT"

echo "==> Building the studio"
xcodebuild -project Motionary.xcodeproj -scheme MotionaryStudio \
    -derivedDataPath build/mac build >/dev/null

echo "==> Building the design as pictures"
STUDIO=build/mac/Build/Products/Debug/MotionaryStudio.app/Contents/MacOS/MotionaryStudio
if [ -n "$DESIGN" ]; then
    "$STUDIO" --deliver "$PACKAGE" --design "$DESIGN"
else
    "$STUDIO" --deliver "$PACKAGE"
fi

echo "==> Copying to the phone"
xcrun devicectl device copy to --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --user mobile \
    --source "$PACKAGE" --destination "Documents/$(basename "$PACKAGE")" >/dev/null

# Foregrounding is the delivery: the app unpacks whatever is waiting, selects
# it, and reloads the widget.
xcrun devicectl device process launch --device "$DEVICE" --activate \
    --terminate-existing "$BUNDLE_ID" >/dev/null
sleep 6

echo "==> What the widget did with it"
Tools/pull-reports.sh /tmp/motionary-delivery-reports >/dev/null 2>&1 || true
grep -E "deliv|PLACED|FAIL" /tmp/motionary-delivery-reports/widget-renders.log 2>/dev/null | tail -4 \
    || echo "    (no render yet - the widget is asked for a timeline on its own schedule)"
