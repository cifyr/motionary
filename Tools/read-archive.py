#!/usr/bin/env python3
"""Says whether a widget's archived timeline carries font bytes or only font URLs.

WidgetKit serialises the rendered view hierarchy into a `.chrono-timeline` and
`chronod` decodes it later, in its own process. A custom font is written into
that archive one of two ways - as a `file://` URL with a `#postscript-name=`
fragment, or as the font's actual bytes - and which one it is decides whether a
font the phone generated can ever be drawn. Everything else in this project's
font work is downstream of that single question, so it is worth reading off the
bytes rather than inferred from whether the widget looked right.

    Tools/read-archive.py <file.chrono-timeline> [--expect-name NAME]

An sfnt claim is only reported once its table directory checks out: the
TrueType magic is four bytes of 00 01 00 00, which appears all over unrelated
binary data, so the magic alone is not evidence of anything.
"""
import re
import struct
import sys

SFNT_MAGICS = {
    b"\x00\x01\x00\x00": "TrueType",
    b"OTTO": "CFF/OpenType",
    b"true": "TrueType (Apple)",
    b"typ1": "Type 1",
    b"ttcf": "TrueType collection",
}
TAG = re.compile(rb"^[\x20-\x7e]{4}$")
URL = re.compile(rb"file://[!-~]{4,600}")


def read_sfnt(blob, offset):
    """A validated font at `offset`, or None. Returns (kind, tables, end)."""
    magic = blob[offset:offset + 4]
    kind = SFNT_MAGICS.get(magic)
    if kind is None:
        return None
    header = blob[offset + 4:offset + 12]
    if len(header) < 8:
        return None
    num_tables = struct.unpack(">H", header[0:2])[0]
    # A real sfnt has a handful of tables, and the directory has to fit.
    if not 1 <= num_tables <= 64:
        return None
    directory = offset + 12
    if directory + num_tables * 16 > len(blob):
        return None

    tables, end = {}, directory + num_tables * 16
    for index in range(num_tables):
        entry = blob[directory + index * 16:directory + index * 16 + 16]
        tag, _, table_offset, length = struct.unpack(">4sIII", entry)
        if not TAG.match(tag):
            return None
        # Table offsets are from the start of the font, and every table has to
        # land inside the file for this to be a font rather than a coincidence.
        if offset + table_offset + length > len(blob):
            return None
        tables[tag.decode("ascii")] = (table_offset, length)
        end = max(end, offset + table_offset + length)
    if "head" not in tables and "CFF " not in tables and "glyf" not in tables:
        return None
    return kind, tables, end


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    expect = None
    if "--expect-name" in sys.argv:
        expect = sys.argv[sys.argv.index("--expect-name") + 1]

    try:
        with open(path, "rb") as handle:
            blob = handle.read()
    except OSError as error:
        sys.exit(f"could not read {path}: {error}")

    print(f"archive        {len(blob)} bytes ({len(blob) / 1048576:.2f}MB)  {path}")

    fonts, cursor = [], 0
    while cursor < len(blob) - 12:
        found = read_sfnt(blob, cursor)
        if found is None:
            cursor += 1
            continue
        kind, tables, end = found
        fonts.append((cursor, kind, tables, end - cursor))
        # Past this font, so a table's own contents cannot be read as a second one.
        cursor = end
    print(f"embedded fonts {len(fonts)}")
    for offset, kind, tables, length in fonts:
        tags = ",".join(sorted(tables))
        print(f"  at {offset:>9}  {kind:<20} {length:>9} bytes  tables: {tags}")

    urls = sorted(set(URL.findall(blob)))
    font_urls = [u for u in urls if b"postscript-name=" in u or u.endswith((b".ttf", b".otf"))]
    print(f"font URLs      {len(font_urls)}")
    for url in font_urls:
        print(f"  {url.decode('utf-8', 'replace')}")
    other = [u for u in urls if u not in font_urls]
    if other:
        print(f"other URLs     {len(other)}")
        for url in other[:8]:
            print(f"  {url.decode('utf-8', 'replace')}")

    if expect:
        ascii_hits = blob.count(expect.encode("ascii"))
        # A font's `name` table keeps its names in UTF-16BE as well, and that
        # encoding is what tells an embedded name table apart from the same
        # name sitting in a URL fragment.
        utf16_hits = blob.count(expect.encode("utf-16-be"))
        print(f"name {expect!r}  ascii x{ascii_hits}  utf16be x{utf16_hits}")


if __name__ == "__main__":
    main()
