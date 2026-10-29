#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Write the `repo` manifest that kleaf's --repo_manifest expects.

LineageOS does exactly this in vendor/lineage/build/tools/kernel_kleaf_manifest.py:
it reads .repo/project.list and emits a <manifest> whose <project> entries are
the paths (relative to the kernel platform root) of everything that was synced
under kernel/platform/kernel-<ver>/. kleaf uses that list to know which
directories in the workspace are repo projects, so it can set up its bzlmod /
repo mapping without a symlink farm.

Usage: gen-kleaf-manifest.py <repo-workspace-root> <prefix>
       e.g. gen-kleaf-manifest.py .work/kernel_platform kernel/platform/kernel-6.12
"""

from __future__ import annotations

import os
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    root, prefix = sys.argv[1], sys.argv[2].strip("/")
    project_list = os.path.join(root, ".repo", "project.list")
    if not os.path.isfile(project_list):
        print(f"gen-kleaf-manifest: {project_list} not found (did `repo init` run?)", file=sys.stderr)
        return 1

    out = sys.stdout
    out.write("<manifest>\n")
    count = 0
    with open(project_list, encoding="utf-8") as handle:
        for line in handle:
            path = line.strip()
            if path.startswith(prefix + "/"):
                rel = path[len(prefix) + 1:]
                out.write(f'  <project path="{rel}" />\n')
                count += 1
    out.write("</manifest>\n")

    if count == 0:
        print(f"gen-kleaf-manifest: no projects under {prefix} in {project_list}", file=sys.stderr)
        return 1

    print(f"gen-kleaf-manifest: {count} projects", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
