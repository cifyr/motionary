#!/usr/bin/env python3
"""Makes a blink-mask font with a longer period than the shipped one.

The mask that picks which lane is visible is a timer text in `Custom-Regular`,
whose only substitution table maps the timer's two seconds digits onto one of
two glyphs: a filled square on even seconds, nothing on odd. That is the whole
mechanism, and it is also the whole ceiling - the pattern repeats every two
seconds, so a design built as pictures can only be two seconds long.

A font that is solid one second in every P repeats every P seconds instead, and
`P` groups of lanes gated at one-second offsets step through P seconds of
animation. Nothing else about the mechanism changes.

The patch is deliberately size-preserving: only the ligature output glyph ids
and an equal-length name are rewritten, so every table offset in the file stays
valid and the result needs no font compiler.

    Tools/blink-font.py --period 8 --name Blink08 --out Resources/Blink08-Regular.otf
"""
import argparse
import struct
import sys

SOLID_GLYPH = 14
EMPTY_GLYPH = 13
# The name in the shipped file, and every name record derived from it. A
# replacement of the same byte length keeps the name table's own offsets valid.
SOURCE_NAME = "Custom"


def table_offset(data, tag):
    count = struct.unpack(">H", data[4:6])[0]
    for i in range(count):
        entry = 12 + i * 16
        if data[entry:entry + 4] == tag:
            offset, length = struct.unpack(">II", data[entry + 8:entry + 16])
            return offset, length
    raise SystemExit(f"no {tag.decode()} table in the font")


def rewrite_ligatures(data, period):
    """Point each seconds value at the solid glyph only when it opens a period."""
    gsub, _ = table_offset(data, b"GSUB")
    lookup_list = gsub + struct.unpack(">H", data[gsub + 8:gsub + 10])[0]
    lookup = lookup_list + struct.unpack(">H", data[lookup_list + 2:lookup_list + 4])[0]
    subtable = lookup + struct.unpack(">H", data[lookup + 6:lookup + 8])[0]
    coverage_offset, set_count = struct.unpack(">HH", data[subtable + 2:subtable + 6])

    coverage = subtable + coverage_offset
    coverage_format, entries = struct.unpack(">HH", data[coverage:coverage + 4])
    if coverage_format == 1:
        first_glyphs = [
            struct.unpack(">H", data[coverage + 4 + i * 2:coverage + 6 + i * 2])[0]
            for i in range(entries)
        ]
    elif coverage_format == 2:
        # Ranges, in coverage-index order, which is the order the ligature sets
        # are in - so flattening them gives the same list format 1 would.
        first_glyphs = []
        for i in range(entries):
            start, end, _ = struct.unpack(">HHH", data[coverage + 4 + i * 6:coverage + 10 + i * 6])
            first_glyphs += list(range(start, end + 1))
    else:
        raise SystemExit(f"coverage format {coverage_format} is not understood")
    # Every coverage entry - one per tens digit - points at a ligature set. In
    # this font they all point at the SAME one: the shipped pattern is "solid on
    # even seconds", which depends only on the ones digit, so the compiler
    # emitted one set and referenced it six times.
    #
    # That is the whole constraint on what can be written here. A period that
    # does not divide ten needs the tens digit to matter, and there is nowhere
    # to say so without rebuilding the table. Writing it anyway silently patched
    # the shared bytes six times over, and the last tens digit won: asking for
    # thirty seconds produced a mask solid on nothing at all, which is a widget
    # that draws black with everything else reporting fine.
    sets = [
        subtable + struct.unpack(">H", data[subtable + 6 + i * 2:subtable + 8 + i * 2])[0]
        for i in range(set_count)
    ]
    shared = len(set(sets)) == 1
    if shared and 10 % period:
        raise SystemExit(
            f"period {period} needs the tens digit, and this font shares one ligature set "
            f"across all {set_count} of them - only periods dividing 10 (2, 5, 10) can be "
            f"written without rebuilding the table"
        )

    out = bytearray(data)
    changed = 0
    for i in range(set_count):
        tens = 0 if shared else first_glyphs[i] - 2
        lig_set = sets[i]
        count = struct.unpack(">H", data[lig_set:lig_set + 2])[0]
        for j in range(count):
            lig = lig_set + struct.unpack(">H", data[lig_set + 2 + j * 2:lig_set + 4 + j * 2])[0]
            seconds = tens * 10 + j
            wanted = SOLID_GLYPH if seconds % period == 0 else EMPTY_GLYPH
            struct.pack_into(">H", out, lig, wanted)
            changed += 1
    return bytes(out), changed


def solid_seconds(data):
    """Which seconds the font is solid on, read back out of what was written."""
    gsub, _ = table_offset(data, b"GSUB")
    lookup_list = gsub + struct.unpack(">H", data[gsub + 8:gsub + 10])[0]
    lookup = lookup_list + struct.unpack(">H", data[lookup_list + 2:lookup_list + 4])[0]
    subtable = lookup + struct.unpack(">H", data[lookup + 6:lookup + 8])[0]
    coverage_offset, set_count = struct.unpack(">HH", data[subtable + 2:subtable + 6])
    coverage = subtable + coverage_offset
    fmt, entries = struct.unpack(">HH", data[coverage:coverage + 4])
    firsts = []
    if fmt == 1:
        firsts = [struct.unpack(">H", data[coverage + 4 + i * 2:coverage + 6 + i * 2])[0] for i in range(entries)]
    else:
        for i in range(entries):
            start, end, _ = struct.unpack(">HHH", data[coverage + 4 + i * 6:coverage + 10 + i * 6])
            firsts += list(range(start, end + 1))
    found = []
    for i in range(set_count):
        lig_set = subtable + struct.unpack(">H", data[subtable + 6 + i * 2:subtable + 8 + i * 2])[0]
        count = struct.unpack(">H", data[lig_set:lig_set + 2])[0]
        for j in range(count):
            lig = lig_set + struct.unpack(">H", data[lig_set + 2 + j * 2:lig_set + 4 + j * 2])[0]
            glyph = struct.unpack(">H", data[lig:lig + 2])[0]
            ones = struct.unpack(">H", data[lig + 4:lig + 6])[0] - 2
            if glyph == SOLID_GLYPH:
                found.append((firsts[i] - 2) * 10 + ones)
    return sorted(set(found))


def rename(data, name):
    if len(name) != len(SOURCE_NAME):
        raise SystemExit(
            f"the new name must be {len(SOURCE_NAME)} characters so the name table's "
            f"offsets stay valid; {name!r} is {len(name)}"
        )
    ascii_from, ascii_to = SOURCE_NAME.encode(), name.encode()
    wide_from, wide_to = SOURCE_NAME.encode("utf-16-be"), name.encode("utf-16-be")
    out = data.replace(ascii_from, ascii_to).replace(wide_from, wide_to)
    if len(out) != len(data):
        raise SystemExit("the rename changed the file length, which invalidates every offset")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--period", type=int, required=True, help="seconds between solid seconds")
    parser.add_argument("--name", required=True, help=f"{len(SOURCE_NAME)}-character family name")
    parser.add_argument("--source", default="Resources/Custom-Regular.otf")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.period < 2 or 60 % args.period:
        raise SystemExit(
            "the period has to divide 60: the substitution keys on the seconds "
            "digits, which wrap there"
        )

    data = open(args.source, "rb").read()
    patched, changed = rewrite_ligatures(data, args.period)
    patched = rename(patched, args.name)

    # Read back what was written rather than trusting the write. The failure
    # this catches produced a font that resolved by name, drew, and masked
    # everything out - which looks like the engine being wrong.
    written = solid_seconds(patched)
    expected = list(range(0, 60, args.period))
    if written != expected:
        raise SystemExit(f"wrote solid on {written}, wanted {expected}")

    open(args.out, "wb").write(patched)
    print(
        f"{args.out}: solid 1 second in {args.period}, {changed} substitutions rewritten, "
        f"family {args.name}, {len(patched)} bytes"
    )


if __name__ == "__main__":
    sys.exit(main())
