#!/usr/bin/env python3
"""Writes a looping GIF whose frames can be told apart from a screenshot.

The runtime-frame route is judged by looking at a rendered widget, and a
screenshot of a photograph says nothing about which frame was on screen. So the
clip is a hue sweep: every frame is one flat, fully saturated colour, evenly
spaced around the circle, with its index drawn on it. The mean colour of a patch
of the widget then names the frame outright, which is what `read-image-lab.py`
reads.

Sized to the widget frame by default, so a design built from it is at full
resolution with nothing scaled.

    Tools/make-loop-clip.py out.gif --seconds 0.75 --frames 24
"""
import argparse
import colorsys
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover - a missing Pillow is the whole message
    print("this needs Pillow: pip3 install Pillow", file=sys.stderr)
    raise


def frame_image(index, count, size):
    red, green, blue = colorsys.hsv_to_rgb(index / count, 1.0, 1.0)
    image = Image.new("RGB", size, (round(red * 255), round(green * 255), round(blue * 255)))

    # Readable by eye as well as by mean colour. A screenshot that names its own
    # frame is worth a great deal when the alternative is deciding whether two
    # shades of orange are the same shade.
    draw = ImageDraw.Draw(image)
    label = str(index)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size[0] // 3)
    except OSError:
        font = ImageFont.load_default()
    box = draw.textbbox((0, 0), label, font=font)
    draw.text(
        ((size[0] - (box[2] - box[0])) / 2, (size[1] - (box[3] - box[1])) / 2),
        label,
        fill=(0, 0, 0),
        font=font,
    )
    return image


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output")
    parser.add_argument("--seconds", type=float, default=0.75, help="the clip's own loop length")
    parser.add_argument("--frames", type=int, default=24)
    parser.add_argument("--width", type=int, default=1074, help="defaults to the widget frame's width")
    parser.add_argument("--height", type=int, default=1632)
    args = parser.parse_args()

    size = (args.width, args.height)
    frames = [frame_image(index, args.frames, size) for index in range(args.frames)]
    # GIF delays are stored in centiseconds, so a duration that is not a whole
    # number of them comes back rounded and the clip is not the length it says.
    delay_ms = round(args.seconds * 1000 / args.frames / 10) * 10
    frames[0].save(
        args.output,
        save_all=True,
        append_images=frames[1:],
        duration=delay_ms,
        loop=0,
        optimize=False,
    )
    print(
        "%s: %d frames of %dx%d at %dms = %.2fs"
        % (args.output, args.frames, size[0], size[1], delay_ms, delay_ms * args.frames / 1000)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
