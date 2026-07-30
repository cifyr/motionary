#!/usr/bin/env python3
"""Reads the edge calibration target out of a Home Screen screenshot.

The widget drew known pixels; this says what arrived. Three answers come out,
in the order they matter:

  bounds       which coloured ring lands on which screen row, i.e. where the
               widget's boundary really is. A pixel of drift here is itself a
               visible line, and no inverse can fix a misplaced frame.
  rim          how the flat grey bands deviate as they approach the boundary.
               Two levels moving by the same amount is an added rim; moving in
               proportion is a gain. Both invert; neither is a warp.
  warp         where the 1px grid lines actually landed. Lines that shift as
               they near the edge mean the content is displaced, which no
               per-pixel curve can undo - that needs a pre-warp.

    Tools/edge-profile.py shot.png [--frame x,y,w,h]
"""
import argparse
import sys

import numpy as np
from PIL import Image

# The measured frame, from Shared/DeviceGeometry.swift. Passed in when a shot
# comes from a device whose frame is not this one.
DEFAULT_FRAME = (66, 270, 1074, 1632)
RINGS = [("red", (255, 0, 0)), ("green", (0, 255, 0)),
         ("blue", (0, 0, 255)), ("yellow", (255, 255, 0))]
BAND_LEVELS = [0.25, 0.5, 0.75]
BAND_HEIGHT = 96
GRID_SPACING = 24
FIELD_INSET = 4


def nearest_ring(pixel):
    """Which ring colour a pixel is closest to, and how far off it is."""
    best, best_distance = None, None
    for name, rgb in RINGS:
        distance = float(np.linalg.norm(pixel - np.array(rgb)))
        if best_distance is None or distance < best_distance:
            best, best_distance = name, distance
    return best, best_distance


def report_bounds(image, frame):
    x, y, w, h = frame
    print("== bounds ==")
    print(f"expected frame x={x} y={y} w={w} h={h} (right {x + w - 1}, bottom {y + h - 1})")
    for label, samples in (
        ("top", [(y + d, x + w // 2) for d in range(-3, 7)]),
        ("bottom", [(y + h - 1 + d, x + w // 2) for d in range(-6, 4)]),
        ("left", [(y + h // 2, x + d) for d in range(-3, 7)]),
        ("right", [(y + h // 2, x + w - 1 + d) for d in range(-6, 4)]),
    ):
        print(f"  {label}:")
        for row, column in samples:
            if not (0 <= row < image.shape[0] and 0 <= column < image.shape[1]):
                continue
            pixel = image[row, column]
            name, distance = nearest_ring(pixel)
            note = f"~{name} (off by {distance:.0f})" if distance < 90 else "not a ring"
            print(f"    ({column:5d},{row:5d}) {tuple(int(v) for v in pixel)}  {note}")


def report_rim(image, frame, depth=24):
    """Deviation of the flat field from what was drawn, by distance from the edge."""
    x, y, w, h = frame
    print("\n== rim ==")
    print("distance from edge -> mean captured level vs drawn level, per band level")
    for label, sample in (
        ("left", lambda d, row: image[row, x + d]),
        ("right", lambda d, row: image[row, x + w - 1 - d]),
    ):
        print(f"  {label}:")
        for level in BAND_LEVELS:
            drawn = level * 255
            rows = [
                row for row in range(y + FIELD_INSET, y + h - FIELD_INSET)
                if BAND_LEVELS[((row - y) // BAND_HEIGHT) % len(BAND_LEVELS)] == level
                and (row - y) % GRID_SPACING != 0
            ]
            if not rows:
                continue
            deltas = []
            for d in range(FIELD_INSET, FIELD_INSET + depth):
                column = [sample(d, row) for row in rows]
                grey = np.mean([np.mean(p) for p in column])
                deltas.append(grey - drawn)
            shown = " ".join(f"{v:+5.1f}" for v in deltas[:16])
            print(f"    drawn {drawn:5.0f}  d={FIELD_INSET}..{FIELD_INSET + 15}: {shown}")


def report_warp(image, frame, depth=96):
    """Where the vertical grid lines landed, near the left edge and far from it."""
    x, y, w, h = frame
    print("\n== warp ==")
    row_far = y + h // 2
    strip = image[row_far, x:x + depth]
    brightness = np.array([np.mean(p) for p in strip])
    # A grid line is a local maximum well above its neighbours.
    peaks = [
        i for i in range(1, len(brightness) - 1)
        if brightness[i] > brightness[i - 1] and brightness[i] >= brightness[i + 1]
        and brightness[i] - min(brightness[max(0, i - 6):i + 7]) > 25
    ]
    print(f"  vertical grid lines within {depth}px of the left edge, at y={row_far}:")
    print(f"    found at x-offsets {peaks}")
    print(f"    drawn at {[o for o in range(GRID_SPACING, depth, GRID_SPACING)]}")
    if peaks:
        drift = [p - round(p / GRID_SPACING) * GRID_SPACING for p in peaks]
        print(f"    drift from the grid: {drift}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("shot")
    parser.add_argument("--frame", default=None,
                        help="x,y,w,h of the widget in screen pixels")
    args = parser.parse_args()

    frame = DEFAULT_FRAME
    if args.frame:
        parts = [int(v) for v in args.frame.split(",")]
        if len(parts) != 4:
            sys.exit("--frame wants x,y,w,h")
        frame = tuple(parts)

    image = np.asarray(Image.open(args.shot).convert("RGB")).astype(int)
    print(f"{args.shot}: {image.shape[1]}x{image.shape[0]}")
    report_bounds(image, frame)
    report_rim(image, frame)
    report_warp(image, frame)


if __name__ == "__main__":
    main()
