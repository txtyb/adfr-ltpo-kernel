#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Print the `repo` project paths that live under a given prefix.

Used to sync only the kernel platform instead of the whole LineageOS manifest
(which also contains ~1500 device/app/framework projects we do not need).

Usage: list-platform-paths.py <full-manifest.xml> <prefix>
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    manifest, prefix = sys.argv[1], sys.argv[2].strip("/")
    root = ET.parse(manifest).getroot()

    paths = []
    for project in root.iter("project"):
        path = (project.get("path") or "").strip("/")
        if path == prefix or path.startswith(prefix + "/"):
            paths.append(path)

    # Longest first keeps repo's own ordering stable-ish; dedupe defensively.
    for path in sorted(set(paths)):
        print(path)

    print(f"list-platform-paths: {len(set(paths))} projects under {prefix}", file=sys.stderr)
    return 0 if paths else 1


if __name__ == "__main__":
    sys.exit(main())
