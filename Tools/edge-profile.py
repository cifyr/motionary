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
  rings        what the pure primaries came back as. This is the sharpest of the
               four: a channel drawn at 0 that returns above 0 measures added
               light directly, with no reference image and nothing to subtract.
  path         the three flat band levels away from every edge, which separate a
               gain from an offset.

    Tools/edge-profile.py shot.png [--frame x,y,w,h]

Screenshots are tagged Display P3 and the pipeline's pictures are written
untagged, i.e. sRGB. Everything here is converted to sRGB first: sRGB red
(255, 0, 0) is (234, 51, 35) read as P3, which is large enough to look like a
finding on its own.
"""
import argparse
import io
import sys

import numpy as np
from PIL import Image, ImageCms

# The *rendered* frame from Shared/Model/DeviceGeometry.swift, not the frame a
# design is cut to. EdgeLabView draws its rings, bands and grid to the widget's own
# bounds, so every offset here is measured from those - and the cut frame is 2px
# right of them and 13 rows short, which put the bounds samples on the wrong
# columns and the rim samples on the wrong rows.
# Passed in when a shot comes from a device whose frame is not this one.
DEFAULT_FRAME = (64, 270, 1079, 1645)
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


def read_srgb(path):
    """Pixels in sRGB, converting from whatever the file is tagged as."""
    image = Image.open(path)
    icc = image.info.get("icc_profile")
    image = image.convert("RGB")
    if icc:
        image = ImageCms.profileToProfile(
            image,
            ImageCms.ImageCmsProfile(io.BytesIO(icc)),
            ImageCms.createProfile("sRGB"),
            outputMode="RGB",
        )
    return np.asarray(image).astype(float)


def report_rings(image, frame, corner_radius=78):
    """Added light per edge, read off the channels the rings drew at zero.

    The sharpest instrument on the target. A pure primary has two channels at
    zero, so whatever comes back in them was put there by the system - no
    reference picture, no high-pass, nothing to cancel. Sampled inside the corner
    radius, where the widget actually covers the edge rows.
    """
    x, y, w, h = frame
    print("\n== rings ==")
    print("what the system added, from the channels drawn at 0 (sRGB)")
    for edge in ("top", "bottom", "left", "right"):
        print(f"  {edge}:")
        for inset, name, drawn in [(i, n, c) for i, (n, c) in enumerate(RINGS)]:
            if edge in ("top", "bottom"):
                row = y + inset if edge == "top" else y + h - 1 - inset
                if not 0 <= row < image.shape[0]:
                    continue
                strip = image[row, x + corner_radius: x + w - corner_radius]
            else:
                column = x + inset if edge == "left" else x + w - 1 - inset
                if not 0 <= column < image.shape[1]:
                    continue
                strip = image[y + corner_radius: y + h - corner_radius, column]
            got = strip.mean(axis=0)
            zeros = [got[c] for c in range(3) if drawn[c] == 0]
            added = f"{np.mean(zeros):+6.1f}" if zeros else "     -"
            print(f"    d={inset} {name:7s} got "
                  f"({got[0]:6.1f},{got[1]:6.1f},{got[2]:6.1f})   added {added}")


def report_path(image, frame, corner_radius=78):
    """The display path, from the three flat levels far from every edge.

    Three levels are what separate a gain from an offset, which is the whole
    reason the target has three. If the fit needs an offset, a per-channel
    multiply cannot express it and the colour match will drift with brightness.
    """
    x, y, w, h = frame
    print("\n== path ==")
    rows_by_level = {level: [] for level in BAND_LEVELS}
    for row in range(y + 200, y + h - 200):
        offset = row - y
        if offset % GRID_SPACING == 0:
            continue
        rows_by_level[BAND_LEVELS[(offset // BAND_HEIGHT) % len(BAND_LEVELS)]].append(row)
    columns = [c for c in range(x + 300, x + w - 300) if (c - x) % GRID_SPACING != 0]
    points = []
    for level, rows in sorted(rows_by_level.items()):
        if not rows or not columns:
            continue
        got = image[np.ix_(rows, columns)].reshape(-1, 3).mean(axis=0)
        drawn = level * 255
        points.append((drawn, float(got.mean())))
        print(f"  drawn {drawn:6.1f}  got ({got[0]:6.1f},{got[1]:6.1f},{got[2]:6.1f})"
              f"  delta {got.mean() - drawn:+6.1f}")
    if len(points) >= 2:
        (low_in, low_out), (high_in, high_out) = points[0], points[-1]
        slope = (high_out - low_out) / (high_in - low_in)
        offset = low_out - slope * low_in
        print(f"  affine fit: captured = {slope:.4f} * drawn {offset:+.2f}")
        if abs(offset) > 2:
            print("  that offset is why a per-channel gain alone cannot match the "
                  "wallpaper at every brightness")
    return points


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

    image = read_srgb(args.shot)
    print(f"{args.shot}: {image.shape[1]}x{image.shape[0]}, read as sRGB")
    report_bounds(image, frame)
    report_rings(image, frame)
    report_path(image, frame)
    report_rim(image, frame)
    report_warp(image, frame)


if __name__ == "__main__":
    main()
