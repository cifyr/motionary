#!/usr/bin/env python3
"""Makes a blink-mask font with a longer period than the shipped one.

The mask that picks which lane is visible is a timer text whose only
substitution table maps the timer's two seconds digits onto one of two glyphs:
a filled square when that second opens a period, nothing otherwise. That is the
whole mechanism, and the period is the whole loop a design built as pictures can
have - the stack repeats when the mask does.

`Custom-Regular` is solid on even seconds, so it repeats every two.

**Why this was rewritten.** The first version patched the ligature output glyph
ids in place, which kept every table offset valid and needed no font compiler.
It also could not express a period that does not divide ten: the six coverage
entries - one per tens digit - all point at the *same* ligature set in that
font, because "solid on even seconds" depends only on the ones digit and the
compiler shared it. Asking for thirty patched those shared bytes six times over
and the last tens digit won, producing a mask solid on nothing at all: a black
widget with every report saying ok.

This builds the table instead, so each tens digit gets its own set and any
period dividing 60 can be written. A thirty-second mask is what lets a design
play several whole clips rather than the opening of each.

    Tools/blink-font.py --period 30 --name Blnk30 --out Resources/Blnk30-Regular.otf
"""
import argparse
import sys

from fontTools.ttLib import TTFont

SOLID_GLYPH = "ligaturefull"
EMPTY_GLYPH = "ligatureempty"
DIGITS = ["zero", "one", "two", "three", "four", "five",
          "six", "seven", "eight", "nine"]
SOURCE_NAME = "Custom"


def ligature_lookup(font):
    """The one ligature lookup, which is the whole mask."""
    table = font["GSUB"].table
    for lookup in table.LookupList.Lookup:
        if lookup.LookupType == 4:
            return lookup
    raise SystemExit("no ligature lookup in the font's GSUB")


def rewrite(font, period):
    """Point every (tens, ones) pair at the solid glyph only when it opens a
    period. Six sets, one per tens digit, so the tens digit can matter."""
    lookup = ligature_lookup(font)
    changed = 0
    for subtable in lookup.SubTable:
        for tens_name, ligatures in subtable.ligatures.items():
            tens = DIGITS.index(tens_name)
            for ligature in ligatures:
                ones = DIGITS.index(ligature.Component[0])
                seconds = tens * 10 + ones
                ligature.LigGlyph = SOLID_GLYPH if seconds % period == 0 else EMPTY_GLYPH
                changed += 1
    return changed


def solid_seconds(font):
    """Which seconds the font is solid on, read back out of what was built.

    The failure this catches produced a font that resolved by name, drew, and
    masked everything out - which looks like the engine being wrong rather than
    like the font being wrong, and cost a day.
    """
    found = []
    for subtable in ligature_lookup(font).SubTable:
        for tens_name, ligatures in subtable.ligatures.items():
            tens = DIGITS.index(tens_name)
            for ligature in ligatures:
                if ligature.LigGlyph == SOLID_GLYPH:
                    found.append(tens * 10 + DIGITS.index(ligature.Component[0]))
    return sorted(set(found))


def rename(font, name):
    for record in font["name"].names:
        value = str(record)
        if SOURCE_NAME in value:
            record.string = value.replace(SOURCE_NAME, name)
    if "CFF " in font:
        cff = font["CFF "].cff
        old = cff.fontNames[0]
        cff.fontNames[0] = old.replace(SOURCE_NAME, name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--period", type=int, required=True, help="seconds between solid seconds")
    parser.add_argument("--name", required=True, help="family name")
    parser.add_argument("--source", default="Resources/Custom-Regular.otf")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.period < 2 or 60 % args.period:
        raise SystemExit(
            "the period has to divide 60: the substitution keys on the seconds "
            "digits, which wrap there"
        )

    font = TTFont(args.source)
    changed = rewrite(font, args.period)
    rename(font, args.name)

    written = solid_seconds(font)
    expected = list(range(0, 60, args.period))
    if written != expected:
        raise SystemExit(f"built solid on {written}, wanted {expected}")

    font.save(args.out)

    # And again from the file, because what matters is what the renderer will
    # read, not what was in memory before it was compiled.
    reread = solid_seconds(TTFont(args.out))
    if reread != expected:
        raise SystemExit(f"{args.out} reads back solid on {reread}, wanted {expected}")

    print(
        f"{args.out}: solid 1 second in {args.period} ({', '.join(map(str, written))}), "
        f"{changed} substitutions, family {args.name}"
    )


if __name__ == "__main__":
    sys.exit(main())
