#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Append/refresh .config fragment lines in a defconfig file, idempotently.

Why this exists: on this device the image that actually boots is the GKI kernel
from //common:kernel_aarch64, which is built from arch/arm64/configs/gki_defconfig.
The Qualcomm/CLO defconfig dict (configs/canoe_perf.bzl) only drives the vendor
DDK modules and the device trees -- it never reaches that kernel binary. So a
kernel option like CONFIG_TMPFS_XATTR has to be set in gki_defconfig itself.

Placement matters. kleaf's config action runs `savedefconfig` on the built config
and compares the result with the source defconfig, line by line, failing with

    ERROR: savedefconfig does not match common/arch/arm64/configs/gki_defconfig

so a line appended at the end of the file is rejected even though Kbuild would
have honoured it. savedefconfig emits options in Kconfig traversal order, not
alphabetically, and that order cannot be derived here. The fragment therefore
says where a new line belongs:

    # @after CONFIG_TMPFS
    CONFIG_TMPFS_XATTR=y

Without such a hint a new option is appended at the end and a warning says the
savedefconfig comparison may reject it.

Usage: patch-defconfig.py <defconfig> <fragment.config> [--dry-run]
Exit:  0 changed, 2 nothing to do, 1 error.
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys

ASSIGN_RE = re.compile(r'^(?P<key>CONFIG_[A-Za-z0-9_]+)=')
UNSET_RE = re.compile(r'^#\s*(?P<key>CONFIG_[A-Za-z0-9_]+) is not set\s*$')
AFTER_RE = re.compile(r'^#\s*@after\s+(?P<key>CONFIG_[A-Za-z0-9_]+)\s*$')


def parse_fragment(path: str) -> "dict[str, tuple[str, str | None]]":
    """Return {symbol: (rendered line, anchor symbol or None)}."""
    out: "dict[str, tuple[str, str | None]]" = {}
    anchor = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            hint = AFTER_RE.match(line)
            if hint:
                anchor = hint.group("key")
                continue
            if ASSIGN_RE.match(line):
                out[line.split("=", 1)[0]] = (line, anchor)
                anchor = None
                continue
            m = UNSET_RE.match(line)
            if m:
                out[m.group("key")] = ("# %s is not set" % m.group("key"), anchor)
                anchor = None
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("defconfig")
    ap.add_argument("fragment")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    wanted = parse_fragment(args.fragment)
    if not wanted:
        print("patch-defconfig: %s has no CONFIG_ lines" % args.fragment, file=sys.stderr)
        return 1

    raw = open(args.defconfig, encoding="utf-8", newline="").read()
    crlf = raw.count("\r\n") > raw.count("\n") - raw.count("\r\n")
    lines = raw.replace("\r\n", "\n").split("\n")

    changes: "list[str]" = []
    warnings: "list[str]" = []

    def find(key: str):
        for i, line in enumerate(lines):
            m = ASSIGN_RE.match(line) or UNSET_RE.match(line)
            if m and m.group("key") == key:
                return i
        return None

    # Refresh values first; new lines are inserted afterwards so earlier indices
    # stay valid.
    pending: "list[tuple[str, str, str | None]]" = []
    for key, (rendered, anchor) in wanted.items():
        idx = find(key)
        if idx is None:
            pending.append((key, rendered, anchor))
        elif lines[idx].strip() != rendered:
            changes.append("%s: %r -> %r" % (key, lines[idx].strip(), rendered))
            lines[idx] = rendered

    for key, rendered, anchor in pending:
        pos = None
        if anchor:
            idx = find(anchor)
            if idx is not None:
                pos = idx + 1
            else:
                warnings.append("%s: anchor %s not in %s, appending at end"
                                % (key, anchor, args.defconfig))
        if pos is None:
            pos = len(lines) - 1 if lines and lines[-1] == "" else len(lines)
            if not anchor:
                warnings.append("%s: no '# @after' hint; appended at end, which kleaf's "
                                "savedefconfig comparison may reject" % key)
        lines.insert(pos, rendered)
        changes.append("%s: (new)" % key)

    if not changes:
        print("patch-defconfig: %s already has %s"
              % (args.defconfig, ", ".join(sorted(wanted))))
        for w in warnings:
            print("patch-defconfig: warning: " + w, file=sys.stderr)
        return 2

    updated = "\n".join(lines)
    if args.dry_run:
        sys.stdout.writelines(difflib.unified_diff(
            raw.replace("\r\n", "\n").splitlines(keepends=True),
            updated.splitlines(keepends=True),
            fromfile=args.defconfig, tofile=args.defconfig + " (patched)"))
        for c in changes:
            print(c, file=sys.stderr)
        return 0

    if crlf:
        updated = updated.replace("\n", "\r\n")
    with open(args.defconfig, "w", encoding="utf-8", newline="") as fh:
        fh.write(updated)

    for c in changes:
        print("patch-defconfig: " + c)
    for w in warnings:
        print("patch-defconfig: warning: " + w, file=sys.stderr)
    print("patch-defconfig: wrote %s" % args.defconfig)
    return 0


if __name__ == "__main__":
    sys.exit(main())
