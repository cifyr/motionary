#!/usr/bin/env python3
"""Gives every design a name that tells it apart from the rest.

    Tools/number-design-names.py            # show what would change
    Tools/number-design-names.py --write    # change it

A design is named after the file it was made from, and the same clip gets
dropped over and over while a layout is worked out. Until DesignStore's
uniqueName there was nothing stopping that, so a library can hold rows that are
identical in name, count and date - this one held nineteen designs all called
after one downloaded GIF, which is unnavigable.

The fix in the app only covers designs made from now on. This is the one-shot
for what is already there.

Rules:

  * Duplicates are numbered in createdAt order. The oldest keeps the bare name,
    the rest become "name 2", "name 3", and so on - matching what the app now
    does for a new drop.
  * Numbers skip anything already taken anywhere in the library, so this cannot
    create a fresh collision.
  * updatedAt is never touched. The library sorts on it, and the whole point of
    the migration fix was to stop a batch job rewriting the real order of work.
  * Every file it rewrites is backed up alongside as design.json.bak first.

Names that are already unique are left alone.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
import json
import logging
from pathlib import Path
import shutil
import sys

# Where the studio keeps designs; see StudioPipeline.storeContainer().
DEFAULT_STORE = Path.home() / "Library/Application Support/Motionary/Designs"

logger = logging.getLogger("number-design-names")


class DesignFile:
    __slots__ = ("path", "name", "created", "identifier")

    def __init__(self, path: Path, name: str, created: float, identifier: str) -> None:
        self.path = path
        self.name = name
        self.created = created
        self.identifier = identifier


def read_designs(store: Path) -> list[DesignFile]:
    """Every readable design.json under the store, newest field errors reported."""
    if not store.is_dir():
        raise SystemExit(f"no design store at {store}")

    designs: list[DesignFile] = []
    for path in sorted(store.glob("*/design.json")):
        try:
            document = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as err:
            # Skipped rather than fatal, matching the store: one unreadable
            # design should not stop the rest being fixed.
            logger.error("skipping %s: %s", path, err)
            continue

        name = document.get("name")
        if not isinstance(name, str):
            logger.error("skipping %s: no name field", path)
            continue

        designs.append(DesignFile(
            path=path,
            name=name,
            created=float(document.get("createdAt", 0)),
            identifier=str(document.get("id", path.parent.name)),
        ))
    return designs


def plan(designs: list[DesignFile]) -> list[tuple[DesignFile, str]]:
    """Returns the (design, new name) pairs that need writing."""
    by_name: dict[str, list[DesignFile]] = defaultdict(list)
    for design in designs:
        by_name[design.name].append(design)

    taken = {design.name for design in designs}
    changes: list[tuple[DesignFile, str]] = []

    for name, group in sorted(by_name.items()):
        if len(group) < 2:
            continue
        # Oldest first, so the original keeps the bare name and the numbering
        # follows the order the designs were actually made in.
        group.sort(key=lambda design: design.created)

        for index, design in enumerate(group):
            if index == 0:
                continue
            attempt = index + 1
            while f"{name} {attempt}" in taken:
                attempt += 1
            new_name = f"{name} {attempt}"
            taken.add(new_name)
            changes.append((design, new_name))

    return changes


def apply(changes: list[tuple[DesignFile, str]]) -> int:
    written = 0
    for design, new_name in changes:
        backup = design.path.with_suffix(".json.bak")
        try:
            shutil.copy2(design.path, backup)
        except OSError as err:
            logger.error("not rewriting %s: could not back it up: %s", design.path, err)
            continue

        try:
            document = json.loads(design.path.read_text())
            document["name"] = new_name
            # Matches the store's own encoder settings, so the app's next save
            # does not reformat the whole file.
            design.path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
        except (OSError, json.JSONDecodeError) as err:
            logger.exception("failed to rewrite %s: %s", design.path, err)
            continue

        logger.info("%s -> %s", design.identifier[:8], new_name)
        written += 1
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--store", type=Path, default=DEFAULT_STORE,
                        help=f"design store (default {DEFAULT_STORE})")
    parser.add_argument("--write", action="store_true", help="actually rename")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    designs = read_designs(args.store)
    logger.info("read %d designs from %s", len(designs), args.store)

    changes = plan(designs)
    if not changes:
        print("Every design already has a distinct name. Nothing to do.")
        return 0

    width = max(len(design.name) for design, _ in changes)
    print(f"\n{len(changes)} of {len(designs)} designs would be renamed:\n")
    for design, new_name in changes:
        print(f"  {design.identifier[:8]}  {design.name[:width]:{width}}  ->  {new_name}")

    if not args.write:
        print("\nDry run. Pass --write to apply.")
        return 0

    written = apply(changes)
    print(f"\nRenamed {written} of {len(changes)}. Originals kept as design.json.bak.")
    return 0 if written == len(changes) else 1


if __name__ == "__main__":
    sys.exit(main())
