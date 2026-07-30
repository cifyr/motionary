#!/usr/bin/env python3
"""Closes the edge-calibration loop: measure a Home Screen shot, write the profile.

    Tools/edge-calibrate.py shot.png --design <uuid-or-prefix>          # measure
    Tools/edge-calibrate.py shot.png --design <uuid-or-prefix> --write  # and write

What it measures is the light the system is *still* adding after whatever
correction the shot was taken with - the residual - and what it writes is the old
profile plus that residual. So the loop is: build, screenshot, run this, rebuild.
Doing that by hand three times is what it replaces.

Method, per docs/home-screen-compositing.md:

  * The design's own wallpaper is the reference. The widget's content and the
    wallpaper behind it are the same picture, so the wallpaper file says what
    every pixel should be. It is written at screen resolution and displayed 1:1 -
    verified here, not assumed: the tool refuses to measure if the shot and the
    wallpaper are not registered.

  * A local baseline, from rows just inside the band, is subtracted. The widget's
    display path does not match the wallpaper's exactly even after WidgetTint,
    and what is left of that varies down the height of the widget. Without the
    baseline that colour error gets folded into the edge profile, where it does
    not belong and where it would be subtracted from one row instead of all of
    them.

  * Bin across the width, and only trust the bins with headroom. The correction
    can only remove light from content that has some, so a bin whose content was
    already darker than the correction clamped at zero, and its residual says
    more about clamping than about the system. Those bins are excluded from the
    fit and counted in the report - that count is the number that says whether a
    design's own darkness, rather than the profile, is what is showing.

Screenshots must be FULL RESOLUTION. A screenshot pasted into a chat client gets
resampled to 0.76, which spreads a two-pixel line and halves its peak; the first
profile fitted that way was wrong by 2x and put one edge a row out. The tool
checks the pixel dimensions and refuses anything else.
"""
import argparse
import datetime
import json
import pathlib
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROFILE_PATH = ROOT / "Resources" / "edge-profile.json"
RESOURCES = ROOT / "Resources"

# Shared/Model/DeviceGeometry.swift. The rendered frame, not the cut frame: the
# rim lands on the rows the system draws, and the widget begins 2px left of where
# a design is cut.
DEVICES = {
    "iphone17pro": {
        "screen": (1206, 2622),
        "rendered": (64, 270, 1078, 1645),
        "corner_radius": 78,
    },
}
# Shared/Pipeline/WidgetTint.swift. Needed only to reconstruct what the pipeline
# had to subtract from, for the headroom test.
TINT_GAIN = (0.984, 1.035, 1.096)
# Rows inside the band whose residual is the local colour baseline. Far enough in
# that the rim has faded (the profile is 9 rows), close enough that the drift down
# the widget has not moved.
BASELINE_RANGE = (14, 44)
BINS = 9
# Below this many usable bins an edge is not written. One design's tiles can cover
# most of an edge, and the two bins left over disagreed by 20 units where six
# agreed within three - writing that over a nine-bin fit is a downgrade, not a
# refinement. Calibrate that edge from a design that does not sit on it.
MIN_BINS_TO_WRITE = 5
# A bin needs this much more content than the correction subtracted before its
# residual is trusted, so a bin that only just cleared zero is not fitted.
HEADROOM_MARGIN = 6.0
CHANNELS = ("r", "g", "b")


def die(message):
    sys.exit(f"edge-calibrate: {message}")


def load_profile(path=PROFILE_PATH):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        die(f"no profile at {path}; the shipped one is committed, so this is a bad checkout")
    except json.JSONDecodeError as error:
        die(f"{path} is not valid JSON: {error}")


def find_wallpaper(design):
    """The wallpaper of one bundled design, by id or by any unique prefix of it."""
    needle = design.lower().replace("-", "")
    matches = [
        path for path in sorted(RESOURCES.glob("prebuilt-*-wallpaper.png"))
        if path.name[len("prebuilt-"):].lower().replace("-", "").startswith(needle)
    ]
    if not matches:
        available = sorted(
            p.name[len("prebuilt-"):-len("-wallpaper.png")]
            for p in RESOURCES.glob("prebuilt-*-wallpaper.png")
        )
        die("no bundled design matches "
            f"{design!r}; Resources has:\n  " + "\n  ".join(available or ["nothing"]))
    if len(matches) > 1:
        die(f"{design!r} matches {len(matches)} designs: "
            + ", ".join(p.name for p in matches))
    return matches[0]


def read_rgb(path, expected):
    try:
        image = Image.open(path)
    except OSError as error:
        die(f"cannot read {path}: {error}")
    if image.size != expected:
        die(f"{path} is {image.size[0]}x{image.size[1]}, wanted "
            f"{expected[0]}x{expected[1]}. Full-resolution screenshots only - a "
            "shot that has been through a chat client is resampled and will fit "
            "a profile that is wrong by about 2x.")
    return np.asarray(image.convert("RGB")).astype(float)


def check_registration(shot, wall, device):
    """Refuses to measure a shot the wallpaper does not line up with.

    Every number below is a per-pixel difference against the wallpaper, so a shot
    of a different design - or of the same design after the wallpaper was
    rebuilt - would produce a confident, meaningless profile.
    """
    x, y, w, h = device["rendered"]
    # Below the widget: wallpaper in both, and away from the dock.
    y0, y1 = y + h + 16, min(y + h + 86, device["screen"][1] - 620)
    a = shot[y0:y1, x:x + w].mean(axis=2)
    b = wall[y0:y1, x:x + w].mean(axis=2)
    a_c, b_c = a - a.mean(), b - b.mean()
    denominator = np.sqrt((a_c ** 2).sum() * (b_c ** 2).sum())
    if denominator < 1e-6:
        die("the strip below the widget is flat in one of the two images; "
            "cannot check that they are the same picture")
    score = float((a_c * b_c).sum() / denominator)
    best = None
    for dy in (-2, -1, 0, 1, 2):
        for dx in (-2, -1, 0, 1, 2):
            shifted = shot[y0 + dy:y1 + dy, x + dx:x + w + dx].mean(axis=2)
            shifted = shifted - shifted.mean()
            value = float((shifted * b_c).sum()
                          / np.sqrt((shifted ** 2).sum() * (b_c ** 2).sum()))
            if best is None or value > best[0]:
                best = (value, dx, dy)
    if score < 0.99 or best[1:] != (0, 0):
        die(f"the shot and {'the wallpaper'} do not register (correlation "
            f"{score:.3f} at 0,0; best {best[0]:.3f} at dx={best[1]} dy={best[2]}). "
            "Wrong design, or the wallpaper was rebuilt after the shot was taken.")
    return score


def check_design_was_corrected(backdrop_path, wall, entry, device, manifest):
    """Refuses to calibrate against a design that was built without the correction.

    This is the failure that cost a night. What this tool measures is the light
    left over *after* a correction, so a shot of a design that never had one
    measures the whole line - and folding that in doubles the profile instead of
    refining it. The two look identical in the output.

    The design's own backdrop settles it: it is the picture the widget draws, so
    the correction either is in it or is not. Reported as the share of the
    expected subtraction that is actually present.
    """
    if not backdrop_path.exists():
        return None, "no backdrop file next to the wallpaper; cannot tell"
    backdrop = np.asarray(Image.open(backdrop_path).convert("RGB")).astype(float)
    rect = manifest.get("backdropRect")
    if rect is None:
        return None, "the manifest has no backdropRect; cannot place the backdrop"
    (bx, by), (bw, bh) = rect
    if (backdrop.shape[1], backdrop.shape[0]) != (bw, bh):
        return None, (f"the backdrop is {backdrop.shape[1]}x{backdrop.shape[0]} but the "
                      f"manifest says {bw}x{bh}")

    x, y, w, h = device["rendered"]
    gain = np.array(TINT_GAIN)
    expected, found = 0.0, 0.0
    for edge, rows in (("top", entry["top"]), ("bottom", entry["bottom"])):
        for distance, correction in enumerate(rows):
            row = y + distance if edge == "top" else y + h - 1 - distance
            if not (by <= row < by + bh):
                continue
            columns = tile_free_columns(manifest, row, device)
            if not columns:
                continue
            take = np.array(columns) - bx
            back_row = backdrop[row - by][take].mean(axis=0)
            wall_row = wall[row][np.array(columns)].mean(axis=0) * gain
            expected += float(np.sum(correction))
            found += float(np.sum(np.clip(wall_row - back_row, 0, None)))
    if expected <= 0:
        return None, "no edge row of the backdrop was usable"
    return found / expected, f"{100 * found / expected:.0f}% of the profile is baked in"


def tile_free_columns(manifest, row, device):
    """Columns of one row with no tile on them.

    The wallpaper has the tiles baked in and the backdrop does not - the widget
    draws its own, live - so a column under a tile compares two different
    pictures. Inset past the corner radius as well, where the widget does not
    cover the row at all.
    """
    x, y, w, h = device["rendered"]
    radius = device["corner_radius"]
    columns = set(range(x + radius, x + w - radius))
    for tile in manifest.get("tiles", []):
        cx, cy = tile["center"]
        side = tile["size"]
        pad = 12
        if cy - side / 2 - pad <= row <= cy + side / 2 + pad:
            columns -= set(range(int(cx - side / 2 - pad), int(cx + side / 2 + pad) + 1))
    return sorted(columns)


def bin_edges(device):
    """Column bins across the widget, inset past the rounded corners.

    Inside the corner radius the widget does not cover the edge rows at all - the
    wallpaper shows through - so those columns would measure the reference against
    itself and dilute the fit towards "nothing left to correct".
    """
    x, _, w, _ = device["rendered"]
    radius = device["corner_radius"]
    lo, hi = x + radius, x + w - radius
    return [(lo + (hi - lo) * i // BINS, lo + (hi - lo) * (i + 1) // BINS) for i in range(BINS)]


def usable_bins(device, manifest, edge_row):
    """The column bins, with tile-covered columns dropped.

    A bin that loses more than a third of its columns to a tile is dropped
    outright rather than measured on what is left: the point of binning across the
    width is that each bin is a wide sample, and a sliver is not.
    """
    bins = []
    allowed = set(tile_free_columns(manifest, edge_row, device))
    for lo, hi in bin_edges(device):
        columns = sorted(c for c in range(lo, hi) if c in allowed)
        if len(columns) >= (hi - lo) * 2 // 3:
            bins.append((lo, hi, np.array(columns)))
    return bins


def measure_edge(shot, wall, device, profile_rows, edge, manifest):
    """Residual per distance-from-edge per channel, and which bins were trusted.

    The residual is what the system is still adding after the correction that is
    already baked into `profile_rows`.
    """
    x, y, w, h = device["rendered"]
    depth = len(profile_rows)
    sign = 1 if edge == "top" else -1
    edge_row = y if edge == "top" else y + h - 1

    def row_of(distance):
        return edge_row + sign * distance

    bins = usable_bins(device, manifest, edge_row)
    residual = np.zeros((depth, 3))
    trusted_counts = np.zeros((depth, 3), dtype=int)
    clamped = np.zeros((depth, 3), dtype=int)
    per_bin = []

    for lo, hi, columns in bins:
        shot_bin = shot[:, columns, :].mean(axis=1)
        wall_bin = wall[:, columns, :].mean(axis=1)
        delta = shot_bin - wall_bin

        baseline_rows = [row_of(d) for d in range(*BASELINE_RANGE)]
        baseline = delta[baseline_rows].mean(axis=0)

        bin_note = {"columns": (lo, hi - 1), "baseline": baseline.tolist(), "rows": []}
        for distance in range(depth):
            row = row_of(distance)
            correction = np.array(profile_rows[distance], dtype=float)
            # What the pipeline had to subtract from: the wallpaper as the widget
            # draws it, which is after the tint.
            available = wall_bin[row] * np.array(TINT_GAIN)
            has_room = available >= correction + HEADROOM_MARGIN
            value = delta[row] - baseline
            for channel in range(3):
                if has_room[channel]:
                    residual[distance][channel] += value[channel]
                    trusted_counts[distance][channel] += 1
                else:
                    clamped[distance][channel] += 1
            bin_note["rows"].append({
                "distance": distance,
                "screen_row": row,
                "delta": value.tolist(),
                "had_room": has_room.tolist(),
            })
        per_bin.append(bin_note)

    with np.errstate(invalid="ignore", divide="ignore"):
        mean_residual = np.where(trusted_counts > 0, residual / np.maximum(trusted_counts, 1), np.nan)
    return mean_residual, trusted_counts, clamped, per_bin, len(bins)


def report(edge, mean_residual, trusted_counts, clamped, profile_rows, bin_count):
    depth = len(profile_rows)
    print(f"\n== {edge} ==  {bin_count} of {BINS} bins usable "
          f"(the rest lost too many columns to a tile)")
    print("  d   current (r,g,b)      residual (r,g,b)        bins trusted   ->  new")
    for distance in range(depth):
        current = profile_rows[distance]
        res = mean_residual[distance]
        trusted = trusted_counts[distance]
        new = updated_row(current, res)
        res_text = " ".join("   n/a" if np.isnan(v) else f"{v:+6.1f}" for v in res)
        print(f"  {distance}  "
              f"{current[0]:5.1f} {current[1]:5.1f} {current[2]:5.1f}   "
              f"{res_text}    {trusted[0]}/{bin_count} {trusted[1]}/{bin_count} "
              f"{trusted[2]}/{bin_count}"
              f"   ->  {new[0]:5.1f} {new[1]:5.1f} {new[2]:5.1f}")
    total = clamped.sum() + trusted_counts.sum()
    share = 100.0 * clamped.sum() / total if total else 0.0
    print(f"  clamped: {clamped.sum()}/{total} bin-rows-channels had no room to be "
          f"darkened ({share:.1f}%)")
    if share > 25:
        print("  more than a quarter of this edge is too dark to correct. No profile "
              "fixes that:\n  move the clip or the background so the widget's "
              "outermost rows are not the darkest\n  part of the picture.")
    return share


def updated_row(current, residual):
    """Old profile plus the residual, per channel, never below zero.

    A channel whose bins were all clamped keeps its current value: there was no
    measurement, and defaulting to zero would throw away a correction that is
    working everywhere the content allows it.
    """
    return [
        max(0.0, round(float(current[channel]) + (0.0 if np.isnan(residual[channel])
                                                  else float(residual[channel])), 1))
        for channel in range(3)
    ]


def main():
    parser = argparse.ArgumentParser(
        description="Measure the widget's edge residual and write the profile back.")
    parser.add_argument("shot", help="full-resolution Home Screen screenshot")
    parser.add_argument("--design", required=True,
                        help="the design in the shot: bundled id or a unique prefix")
    parser.add_argument("--device", default="iphone17pro")
    parser.add_argument("--wallpaper", default=None,
                        help="override the reference (defaults to the design's own)")
    parser.add_argument("--write", action="store_true",
                        help="write the updated profile to Resources/edge-profile.json")
    parser.add_argument("--json", default=None,
                        help="also dump the per-bin measurement to this path")
    parser.add_argument("--force", action="store_true",
                        help="write even though the design was not built with the correction "
                             "(this doubles the profile; only for a first fit from zero)")
    args = parser.parse_args()

    device = DEVICES.get(args.device)
    if device is None:
        die(f"no geometry for {args.device!r}; known: {', '.join(sorted(DEVICES))}")

    profile = load_profile()
    entry = profile.get("devices", {}).get(args.device)
    if entry is None:
        die(f"{PROFILE_PATH} has no entry for {args.device!r}")

    wallpaper_path = pathlib.Path(args.wallpaper) if args.wallpaper else find_wallpaper(args.design)
    shot = read_rgb(args.shot, device["screen"])
    wall = read_rgb(wallpaper_path, device["screen"])
    score = check_registration(shot, wall, device)

    manifest_path = pathlib.Path(str(wallpaper_path).replace("-wallpaper.png", "-manifest.json"))
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    backdrop_path = pathlib.Path(str(wallpaper_path).replace("-wallpaper.png", "-backdrop.jpg"))
    baked, baked_note = check_design_was_corrected(backdrop_path, wall, entry, device, manifest)

    print(f"shot       {args.shot}")
    print(f"reference  {wallpaper_path.name}")
    print(f"registered correlation {score:.4f} at dx=0 dy=0")
    x, y, w, h = device["rendered"]
    print(f"widget     ({x}, {y}) {w}x{h}, rows {y} and {y + h - 1}, "
          f"{BINS} bins inset {device['corner_radius']}px past the corners")
    print(f"baseline   rows {BASELINE_RANGE[0]}..{BASELINE_RANGE[1] - 1} inward, per bin per channel")
    print(f"baked in   {baked_note}")
    if baked is not None and baked < 0.5:
        print("\n!! The design in this shot was built WITHOUT the edge correction, so what")
        print("!! follows is the whole line, not the residual. Adding it to the profile")
        print("!! would roughly double it. Rebuild the design with a studio built from")
        print("!! this source, take a fresh shot, and run this again:")
        print("!!   xcodebuild -scheme MotionaryStudio -destination platform=macOS build")
        print("!!   MotionaryStudio --rebuild-starred")

    updated = {}
    dumps = {}
    writable = []
    for edge in ("top", "bottom"):
        rows = entry[edge]
        mean_residual, trusted, clamped, per_bin, bin_count = measure_edge(
            shot, wall, device, rows, edge, manifest)
        report(edge, mean_residual, trusted, clamped, rows, bin_count)
        if bin_count >= MIN_BINS_TO_WRITE:
            writable.append(edge)
            updated[edge] = [updated_row(rows[d], mean_residual[d]) for d in range(len(rows))]
        else:
            updated[edge] = [list(map(float, row)) for row in rows]
            print(f"  only {bin_count} bins usable, under the {MIN_BINS_TO_WRITE} needed to "
                  f"write: keeping the current {edge} profile. Calibrate this edge from a "
                  "design whose tiles do not sit on it.")
        dumps[edge] = {
            "residual": np.where(np.isnan(mean_residual), None, mean_residual).tolist(),
            "trusted": trusted.tolist(),
            "clamped": clamped.tolist(),
            "bins": per_bin,
        }

    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(dumps, indent=2, default=float))
        print(f"\nper-bin measurement written to {args.json}")

    biggest = max(
        abs(updated[edge][d][c] - entry[edge][d][c])
        for edge in ("top", "bottom") for d in range(len(entry[edge])) for c in range(3)
    )
    print(f"\nlargest change to any entry: {biggest:.1f} units")

    if not args.write:
        print("\nnothing written. Pass --write to update "
              f"{PROFILE_PATH.relative_to(ROOT)}, then rebuild the designs:")
        print("  MotionaryStudio --rebuild-starred")
        return

    if baked is not None and baked < 0.5 and not args.force:
        die("refusing to write: the design in this shot carries "
            f"{100 * baked:.0f}% of the profile, so this measurement is the whole line "
            "rather than what is left of it. Rebuild the design first, or pass --force "
            "if you really are fitting from zero.")
    if not writable:
        die(f"refusing to write: neither edge had {MIN_BINS_TO_WRITE} usable bins in this "
            "design. Its tiles cover the edges; calibrate from one whose tiles do not.")

    entry["top"] = updated["top"]
    entry["bottom"] = updated["bottom"]
    entry["measuredAt"] = datetime.date.today().isoformat()
    entry["measuredFrom"] = (
        f"{pathlib.Path(args.shot).name} against {wallpaper_path.name}, "
        f"{BINS} column bins, clamped bins excluded; "
        f"rewritten: {', '.join(writable)}"
    )
    PROFILE_PATH.write_text(json.dumps(profile, indent=2) + "\n")
    print(f"\nwrote {PROFILE_PATH.relative_to(ROOT)}")
    print("The correction is applied when a design is built, so designs already")
    print("built still carry the old one:")
    print("  MotionaryStudio --rebuild-starred")
    print("Then take another shot and run this again; the residual should shrink.")


if __name__ == "__main__":
    main()
