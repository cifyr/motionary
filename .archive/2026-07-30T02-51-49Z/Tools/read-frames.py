#!/usr/bin/env python3
"""Names the frame in each screenshot of an image-lab burst.

The widget's frames are flat, evenly spaced hues, so the mean colour of a patch
of the widget says which frame was on screen. That turns a pile of screenshots
into a list of frame indices with times against them, which is what the claim
has to be judged on: how many distinct frames appeared, whether they landed in
the slot the maths says they should, and how fast they changed.

    Tools/read-image-lab.py <dir> <frame-count> [--crop x0,y0,x1,y1]
"""
import argparse
import colorsys
import glob
import os
import re
import sys

from PIL import Image

# Middle of the widget on the second Home Screen page, as fractions of the
# screen. Avoids the widget's caption strip along its bottom edge, which is
# black in every frame and would drag every mean towards each other.
DEFAULT_CROP = (0.30, 0.14, 0.70, 0.40)

STAMP = re.compile(r"burst-(\d+)-(\d+)\.png$")


def expected_colours(count):
    return [
        tuple(round(c * 255) for c in colorsys.hsv_to_rgb(i / count, 1.0, 1.0))
        for i in range(count)
    ]


def mean_colour(path, crop):
    with Image.open(path) as im:
        im = im.convert("RGB")
        box = (
            int(crop[0] * im.width),
            int(crop[1] * im.height),
            int(crop[2] * im.width),
            int(crop[3] * im.height),
        )
        patch = im.crop(box)
        pixels = list(patch.getdata())
    n = len(pixels)
    return tuple(sum(p[c] for p in pixels) / n for c in range(3))


def nearest(colour, count):
    """Names the frame by hue, in degrees away from the frame's own hue.

    Matched on hue rather than on RGB because the Home Screen does not hand the
    widget's pixels back untouched - everything comes out about 15% darker than
    it was drawn, which at 64 frames is a larger error than the gap between two
    neighbouring frames. Hue survives that; brightness does not.
    """
    hue, saturation, _ = colorsys.rgb_to_hsv(*[c / 255 for c in colour])
    if saturation < 0.25:
        return None, 180.0
    best, best_distance = None, None
    for index in range(count):
        target = index / count
        delta = abs(hue - target)
        distance = min(delta, 1 - delta) * 360
        if best_distance is None or distance < best_distance:
            best, best_distance = index, distance
    return best, best_distance


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("count", type=int)
    parser.add_argument("--crop", default=None, help="x0,y0,x1,y1 as fractions")
    parser.add_argument(
        "--tolerance",
        type=float,
        default=None,
        help="how many degrees of hue a shot may sit from a frame before it is called unreadable; "
        "defaults to a third of the gap between neighbouring frames",
    )
    args = parser.parse_args()

    crop = DEFAULT_CROP
    if args.crop:
        crop = tuple(float(v) for v in args.crop.split(","))

    tolerance = args.tolerance
    if tolerance is None:
        tolerance = min(30.0, 360.0 / args.count / 3)

    shots = sorted(glob.glob(os.path.join(args.directory, "burst-*.png")))
    if not shots:
        print("no shots in %s" % args.directory, file=sys.stderr)
        return 1

    rows = []
    for path in shots:
        match = STAMP.search(path)
        stamp = int(match.group(2)) if match else 0
        colour = mean_colour(path, crop)
        index, distance = nearest(colour, args.count)
        rows.append((stamp, colour, index, distance))

    first = rows[0][0]
    seen = {}
    unreadable = 0
    print("  t(ms)  mean RGB              frame  hue  slot")
    for stamp, colour, index, distance in rows:
        readable = index is not None and distance <= tolerance
        if readable:
            seen.setdefault(index, 0)
            seen[index] += 1
        else:
            unreadable += 1
        # Which slot the wall clock says should have been showing. The stamp is
        # taken just before the capture, so a shot near a slot edge can land one
        # slot either side; this is a sanity check, not a verdict.
        slot = int((stamp / 1000.0) % 2.0 / (2.0 / args.count))
        print(
            "%7d  (%5.1f,%5.1f,%5.1f)  %5s  %4.0f  %4d"
            % (
                stamp - first,
                colour[0],
                colour[1],
                colour[2],
                index if readable else "-",
                distance,
                slot,
            )
        )

    print()
    print("shots         %d" % len(rows))
    print("unreadable    %d" % unreadable)
    print("distinct      %d of %d frames" % (len(seen), args.count))
    print("seen          %s" % sorted(seen))
    print("tolerance     %.1f degrees of hue" % tolerance)
    changes = 0
    previous = None
    for _, _, index, distance in rows:
        if index is None or distance > tolerance:
            previous = None
            continue
        if previous is not None and index != previous:
            changes += 1
        previous = index
    print("changes       %d over %d consecutive pairs" % (changes, max(0, len(rows) - 1)))

    # A burst that photographed the wrong Home Screen page is 200 pictures of
    # wallpaper, and every summary line above still prints happily. That reads as
    # "the widget did not animate" when it means "the widget was never in frame",
    # so it has to be an error rather than a zero.
    if unreadable == len(rows):
        print(
            "\nnot one shot showed a probe frame. The burst most likely photographed a page the "
            "widget is not on (MOTIONARY_BURST_PAGE), or the widget is not placed, or it rendered "
            "blank. Mean colour of the first shot was (%.1f,%.1f,%.1f) over crop %s."
            % (rows[0][1][0], rows[0][1][1], rows[0][1][2], crop),
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
