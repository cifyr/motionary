#!/bin/bash
# Runs the runtime-frame route across frame rates and layouts and prints one
# table.
#
# Three numbers per configuration, because three different things can kill this
# and only one of them is visible from outside. The extension's footprint decides
# whether the render survives its memory cap; the archived timeline decides
# whether WidgetKit accepts the render at all; the frames on disk decide whether
# a library of designs fits on the phone.
#
#   Tools/native-sweep.sh <clip.gif> [out-dir] [rates...]
set -euo pipefail

CLIP="${1:?usage: native-sweep.sh <clip.gif> [out-dir] [rates...]}"
OUT="${2:-/tmp/native-sweep}"
shift 2 2>/dev/null || shift 1
RATES=("${@:-8 16 24 32}")
[ $# -eq 0 ] && RATES=(8 16 24 32)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p "$OUT"
RESULTS="$OUT/summary.txt"
: > "$RESULTS"

for rate in "${RATES[@]}"; do
    for layout in separate sheet; do
        run="$OUT/$rate-$layout"
        echo "### $rate fps, $layout"
        if ! bash Tools/native-shot.sh "$CLIP" "$rate" "$layout" "$run" > "$run.log" 2>&1; then
            # A refused sheet is a result, not a broken run: at full resolution a
            # strip runs past the largest picture that can be drawn, and that is
            # the answer to whether a sheet is better in practice.
            reason=$(grep -m1 -o "runtime build: .*" "$run.log" 2>/dev/null \
                || echo "the run failed; see $run.log")
            printf "%3s  %-8s  %-7s  %-9s  %-9s  %-7s  %-7s  %s\n" \
                "$rate" "$layout" "-" "-" "-" "-" "-" "$reason" | tee -a "$RESULTS"
            continue
        fi

        log="$run/widget-renders.log"
        frames=$(grep -oE "img  loaded [0-9]+/[0-9]+" "$log" 2>/dev/null | tail -1 | awk '{print $3}')
        footprint=$(grep "img  loaded" "$log" 2>/dev/null | tail -1 | grep -oE "[0-9]+MB$")
        # Largest archive, because several family descriptors can be cached and
        # only the biggest is the one that has to stay under the limit.
        archive=$(awk '{print $1}' "$run/archive-sizes.txt" 2>/dev/null | sed 's/MB//' | sort -rn | head -1)
        disk=$(grep "app  imported" "$log" 2>/dev/null | tail -1 | grep -oE "[0-9.]+MB$")
        seconds=$(grep -oE "imported .* in [0-9.]+s" "$log" 2>/dev/null | tail -1 | grep -oE "[0-9.]+s")
        verdict=$(grep -c "OK   PLACED.*runtime frames: " "$log" 2>/dev/null || true)
        printf "%3s  %-8s  %-7s  %-9s  %-9s  %-7s  %-7s  %s\n" \
            "$rate" "$layout" "${frames:-?}" "${footprint:-?}" "${archive:-?}MB" \
            "${disk:-?}" "${seconds:-?}" \
            "$([ "${verdict:-0}" -gt 0 ] && echo ok || echo "NOT DRAWN")" | tee -a "$RESULTS"
    done
done

echo
echo "fps  layout    loaded   footprint  archive    disk     import   outcome"
cat "$RESULTS"
