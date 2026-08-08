#!/bin/bash
# Turns a built design's preview video into a README-sized GIF.
#
# The pipeline already writes a full-screen preview of every design it builds
# (Resources/prebuilt-<id>-preview.mp4), and that video *is* the animation the
# widget plays - so it is the honest source for documentation images, and it does
# not need a phone or a simulator to capture.
#
#   Tools/make-gif.sh Resources/prebuilt-<id>-preview.mp4 docs/images/out.gif [seconds] [width]
set -euo pipefail

SRC=${1:?usage: make-gif.sh <preview.mp4> <out.gif> [seconds] [width]}
OUT=${2:?usage: make-gif.sh <preview.mp4> <out.gif> [seconds] [width]}
SECONDS_=${3:-8}
WIDTH=${4:-300}

command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
[ -f "$SRC" ] || { echo "no such preview: $SRC" >&2; exit 1; }

DURATION=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$SRC")
echo "source: $SRC (${DURATION}s), taking ${SECONDS_}s at ${WIDTH}px wide"

PALETTE=$(mktemp -t motionary-palette).png
trap 'rm -f "$PALETTE"' EXIT

# Two passes: a palette built from the frames that will actually be used, then
# the encode. One pass with a generic palette bands the gradients badly.
ffmpeg -v error -y -ss 0 -t "$SECONDS_" -i "$SRC" \
  -vf "fps=12,scale=${WIDTH}:-1:flags=lanczos,palettegen=stats_mode=diff" "$PALETTE"

ffmpeg -v error -y -ss 0 -t "$SECONDS_" -i "$SRC" -i "$PALETTE" \
  -lavfi "fps=12,scale=${WIDTH}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3" \
  "$OUT"

echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
