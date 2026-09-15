#!/usr/bin/env python3
"""Draw both app icons from the Ember tokens.

The mark is the thing the app actually does: a widget-shaped card with the
frames behind it still fading out, which is what a lane stack looks like caught
mid-cycle. Card proportion is the real one - the iPhone 17 Pro's widget rect is
1074x1632, so 0.658 rather than a guess.

Run after changing EmberPalette; the tokens are duplicated here on purpose
because a build phase that shells out to Python for artwork is worse than a
regenerated PNG someone has looked at.
"""

import json
import pathlib
import subprocess
import sys

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
IOS_SET = ROOT / "Resources/Assets.xcassets/AppIcon.appiconset"
MAC_SET = ROOT / "Mac/Assets.xcassets/AppIcon.appiconset"

DARK = (0x0C, 0x0D, 0x10)
ACCENT = (0xFF, 0x3D, 0x00)

# Drawn 4x and downsampled - PIL has no antialiased primitives, and the corner
# radius is the one part of this that shows every jagged step.
SUPER = 4
SIDE = 1024

CARD_W = 366
CARD_H = 556
CARD_R = 60
STEP = 118
# Front card first, then the trail receding left. Each ghost is also smaller
# than the one in front of it: alpha alone made the stack read as one thick
# slab with a brown edge rather than as something moving.
TRAIL = [1.0, 0.30, 0.12]
FALLOFF = 0.90


def cards(draw, ox, oy, colour, alphas, scale):
    """Lay the stack down back-to-front so the solid card ends up on top."""
    for index in reversed(range(len(alphas))):
        shrink = FALLOFF**index
        width = CARD_W * shrink
        height = CARD_H * shrink
        cx = ox - index * STEP
        left = (cx - width / 2) * scale
        top = (oy - height / 2) * scale
        draw.rounded_rectangle(
            [left, top, left + width * scale, top + height * scale],
            radius=CARD_R * shrink * scale,
            fill=colour + (round(255 * alphas[index]),),
        )


def mark(side, background, colour, alphas, inset=1.0):
    """One square of artwork. `background` of None leaves it transparent."""
    scale = side * SUPER / SIDE
    image = Image.new("RGBA", (side * SUPER, side * SUPER), (0, 0, 0, 0))
    if background is not None:
        ImageDraw.Draw(image).rectangle(
            [0, 0, side * SUPER, side * SUPER], fill=background + (255,)
        )

    # The group is wider than one card by the trail, so its centre is not the
    # card's centre - without this correction the mark sits right of true.
    span = CARD_W + STEP * (len(alphas) - 1)
    ox = SIDE / 2 + (span / 2 - CARD_W / 2)

    plate = Image.new("RGBA", image.size, (0, 0, 0, 0))
    cards(ImageDraw.Draw(plate), ox, SIDE / 2, colour, alphas, scale)
    if inset != 1.0:
        small = plate.resize(
            (round(plate.width * inset), round(plate.height * inset)), Image.LANCZOS
        )
        plate = Image.new("RGBA", image.size, (0, 0, 0, 0))
        plate.paste(
            small,
            ((image.width - small.width) // 2, (image.height - small.height) // 2),
        )
    image.alpha_composite(plate)
    return image.resize((side, side), Image.LANCZOS)


def mac_plate(side):
    """macOS draws no mask of its own, so the rounded plate is part of the art."""
    scale = side * SUPER / SIDE
    image = Image.new("RGBA", (side * SUPER, side * SUPER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    margin = 100 * scale
    draw.rounded_rectangle(
        [margin, margin, side * SUPER - margin, side * SUPER - margin],
        radius=185 * scale,
        fill=DARK + (255,),
    )
    span = CARD_W + STEP * (len(TRAIL) - 1)
    ox = SIDE / 2 + (span / 2 - CARD_W / 2)
    plate = Image.new("RGBA", image.size, (0, 0, 0, 0))
    cards(ImageDraw.Draw(plate), ox, SIDE / 2, ACCENT, TRAIL, scale)
    small = plate.resize((round(plate.width * 0.78), round(plate.height * 0.78)), Image.LANCZOS)
    holder = Image.new("RGBA", image.size, (0, 0, 0, 0))
    holder.paste(
        small, ((image.width - small.width) // 2, (image.height - small.height) // 2)
    )
    image.alpha_composite(holder)
    return image.resize((side, side), Image.LANCZOS)


def write_ios():
    IOS_SET.mkdir(parents=True, exist_ok=True)
    mark(SIDE, DARK, ACCENT, TRAIL).save(IOS_SET / "AppIcon-1024.png")
    # The dark and tinted variants carry no background: iOS composites its own
    # behind them, and a supplied one shows up as a square inside the mask.
    mark(SIDE, None, ACCENT, TRAIL).save(IOS_SET / "AppIcon-1024-dark.png")
    mark(SIDE, None, (0xFF, 0xFF, 0xFF), TRAIL).save(IOS_SET / "AppIcon-1024-tinted.png")

    def entry(name, appearance=None):
        item = {
            "filename": name,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
        if appearance:
            item["appearances"] = [
                {"appearance": "luminosity", "value": appearance}
            ]
        return item

    (IOS_SET / "Contents.json").write_text(
        json.dumps(
            {
                "images": [
                    entry("AppIcon-1024.png"),
                    entry("AppIcon-1024-dark.png", "dark"),
                    entry("AppIcon-1024-tinted.png", "tinted"),
                ],
                "info": {"author": "xcode", "version": 1},
            },
            indent=2,
        )
        + "\n"
    )


MAC_SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def write_mac():
    MAC_SET.mkdir(parents=True, exist_ok=True)
    images = []
    for points, factor in MAC_SIZES:
        pixels = points * factor
        name = f"AppIcon-{points}@{factor}x.png"
        mac_plate(pixels).save(MAC_SET / name)
        images.append(
            {
                "filename": name,
                "idiom": "mac",
                "scale": f"{factor}x",
                "size": f"{points}x{points}",
            }
        )
    (MAC_SET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2)
        + "\n"
    )
    (MAC_SET.parent / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )


if __name__ == "__main__":
    write_ios()
    write_mac()
    print(f"wrote {IOS_SET.relative_to(ROOT)} and {MAC_SET.relative_to(ROOT)}")
