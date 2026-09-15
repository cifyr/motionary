#!/usr/bin/env python3
"""Measures what a design actually looks like on every simulator size.

Three questions per device, all of them things that have been wrong at some
point and none of them visible from a screenshot at a glance:

  fills      does the composition reach both edges, or is there a black band
             where a design cut for a narrower canvas stopped
  family     which widget family the system actually placed, since designs are
             cut for the portrait extra-large one and anything below iOS 27
             falls back to systemLarge
  align      does the widget draw the design at the same size and place as the
             app - the number that says whether a tile crossing the widget's
             edge will meet its baked half in the wallpaper

Alignment is measured by taking a patch of the app's render and finding where
it sits in the Home Screen shot. Locating a coloured tile in both was tried
first and is not reliable: it needs the widget's rect to search inside, and
every attempt to detect that rect was defeated by either the wallpaper's
diagonal band or the design's own cool-toned photograph. Correlation needs no
rect, and it fails loudly rather than quietly agreeing with a wrong guess.

Called by geometry-sweep.sh, which does the simulator driving.

  geometry-sweep.py <app.png> <home.png> [render.log]
"""

import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def black_columns(app, row_fraction=0.5):
    """Columns of pure black across one row: the band a too-narrow design leaves."""
    row = app[int(app.shape[0] * row_fraction)]
    return int(np.all(row == 0, axis=1).sum()), app.shape[1]


def pick_template(app, side=220):
    """A patch of the app's render with enough detail to be found again.

    The backdrop animates, so the patch has to come from something static. The
    tiles are the only static thing, and the most saturated colour in the
    composition belongs to one - so the greenest region is a tile, whichever
    design this is.
    """
    h, w, _ = app.shape
    top = app[: int(h * 0.75)]
    r, g, b = top[:, :, 0], top[:, :, 1], top[:, :, 2]
    score = (g - np.maximum(r, b)).clip(min=0)
    if score.max() < 40:
        return None
    ys, xs = np.where(score >= score.max() * 0.6)
    cy, cx = int(np.median(ys)), int(np.median(xs))
    half = side // 2
    cy = int(np.clip(cy, half, top.shape[0] - half - 1))
    cx = int(np.clip(cx, half, w - half - 1))
    return app[cy - half:cy + half, cx - half:cx + half], (cx, cy)


def find(home, template, centre, radius=320, step=4):
    """Where that patch sits in the Home Screen shot, by sum of absolute difference."""
    th, tw, _ = template.shape
    cx, cy = centre
    best = None
    for coarse in (step, 1):
        x_lo = max(0, cx - radius) if coarse == step else best[1] - step
        x_hi = min(home.shape[1] - tw, cx + radius) if coarse == step else best[1] + step
        y_lo = max(0, cy - radius) if coarse == step else best[2] - step
        y_hi = min(home.shape[0] - th, cy + radius) if coarse == step else best[2] + step
        for y in range(y_lo, y_hi + 1, coarse):
            for x in range(x_lo, x_hi + 1, coarse):
                patch = home[y:y + th, x:x + tw]
                if patch.shape != template.shape:
                    continue
                d = np.abs(patch - template).mean()
                if best is None or d < best[0]:
                    best = (d, x, y)
        if best is None:
            return None
    return best


def main():
    app_path, home_path = sys.argv[1], sys.argv[2]
    log = sys.argv[3] if len(sys.argv) > 3 else None

    app = load(app_path)
    home = load(home_path)

    black, width = black_columns(app)
    print(f"    fills   {width - black}/{width} columns drawn"
          f"{'' if black == 0 else f'   BLACK BAND: {black} columns'}")

    if log:
        try:
            asks = [l for l in open(log) if "ask  timeline" in l]
            if asks:
                bits = asks[-1].split()
                fam = next((b for b in bits if b.startswith("family=")), "family=?")
                size = next((b for b in bits if b.startswith("size=")), "size=?")
                print(f"    family  {fam.split('=')[1]}   handed over {size.split('=')[1]}pt")
        except OSError:
            pass

    picked = pick_template(app)
    if picked is None:
        print("    align   no static feature bright enough to track")
        return
    template, centre = picked
    hit = find(home, template, centre)
    if hit is None:
        print("    align   patch not found on the Home Screen")
        return
    diff, x, y = hit
    half = template.shape[0] // 2
    dx = (x + half) - centre[0]
    dy = (y + half) - centre[1]
    # A poor best-match means it matched noise, and an offset read off noise is
    # worse than no offset at all.
    quality = "" if diff < 18 else f"   WEAK MATCH (mean diff {diff:.1f})"
    print(f"    align   dx={dx:+5d}px  dy={dy:+5d}px   match={diff:.1f}{quality}")


if __name__ == "__main__":
    main()
