#!/bin/bash
# Reads the widget's own reports off a connected iPhone.
#
# The extension writes into the app group, which devicectl will not read out
# of - it answers "file paths cannot contain '..'" for anything beside
# Library. The app mirrors them into its own Documents on every foreground,
# which is readable, so this brings the app forward first and then copies.
#
#   Tools/pull-reports.sh [out-dir]
set -euo pipefail

OUT="${1:-/tmp/motionary-reports}"
DEVICE="${MOTIONARY_DEVICE:-00008150-00042CA60C9A401C}"
BUNDLE_ID="com.caden.Motionary"
REPORTS="widget-renders.log widget-status.json mask-lab.txt font-lab.txt"

mkdir -p "$OUT"

echo "==> Foregrounding the app so it mirrors what the widget last wrote"
xcrun devicectl device process launch --device "$DEVICE" --activate \
    --terminate-existing "$BUNDLE_ID" >/dev/null
sleep 4

for name in $REPORTS; do
    if xcrun devicectl device copy from --device "$DEVICE" \
        --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
        --user mobile \
        --source "Documents/reports/$name" --destination "$OUT/$name" >/dev/null 2>&1
    then
        echo "==> $OUT/$name"
    else
        echo "    (no $name on the phone)"
    fi
done
