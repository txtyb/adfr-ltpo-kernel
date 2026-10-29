#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Merge a kernel .config fragment into a Qualcomm kleaf defconfig dict.

The Qualcomm CLO kernel tree does not use a plain *_defconfig for its vendor
configuration. Each SoC/variant has a Python dict instead, e.g.
vendor/oneplus/sm8850/configs/canoe_perf.bzl:

    canoe_perf_config = {
        # keep sorted
        "CONFIG_ARCH_CANOE": "y",
        "CONFIG_CFG80211": "m",
        ...
    }

kleaf-scripts/defconfig_fragment.bzl (define_defconfig_fragment) turns every
entry back into a defconfig line and hands the result to Kbuild as a
post_defconfig_fragment, i.e. it is merged *after* gki_defconfig. Editing this
dict is therefore the supported way to add config to the vendor build without
patching GKI.

This script takes a normal .config fragment (CONFIG_FOO=y, CONFIG_FOO=m,
CONFIG_FOO="str", "# CONFIG_FOO is not set") and merges it into such a dict.

It edits as little as possible on purpose. The real files are not a flat sorted
list: canoe_perf.bzl keeps a globally sorted block from ARCH_* to ZSMALLOC with
small conditional groups such as

    # OPLUS_FEATURE_TP_BASIC
        "CONFIG_LEDS_AW210XX": "m",
    # OPLUS_FEATURE_TP_BASIC end

embedded at their sorted position, plus further conditional groups appended at
the very end of the dict. Rebuilding the dict would destroy those markers and
shuffle several dozen unrelated lines, so instead this script only

  * inserts new keys at their sorted position in the file's existing entry
    order, and
  * rewrites the value of a key that is already present.

Every other line (markers, blank lines, hand ordering) is left byte for byte
alone, which keeps `git diff` to the lines that actually changed.

Usage:
    apply-config.py <defconfig.bzl> <extra.config> [--dry-run]

Exit status:
    0  the dict was modified
    1  error
    2  no change was needed (already merged)
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys

# One entry line inside the dict, e.g. '    "CONFIG_FOO": "y",'
ENTRY_RE = re.compile(
    r'^(?P<indent>[ \t]*)"(?P<key>CONFIG_[A-Za-z0-9_]+)"\s*:\s*'
    r'"(?P<value>(?:[^"\\]|\\.)*)"\s*,\s*$'
)
# The line that opens the dict, e.g. 'canoe_perf_config = {'
OPEN_RE = re.compile(r'^(?P<indent>[ \t]*)[A-Za-z_][A-Za-z0-9_]*\s*=\s*\{\s*$')
CLOSE_RE = re.compile(r'^\}\s*$')


def parse_fragment(path: str) -> "dict[str, str]":
    """Parse a .config fragment into {CONFIG_SYMBOL: bzl_value}."""
    entries: "dict[str, str]" = {}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue

            match = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line)
            if match:
                key, raw_value = match.group(1), match.group(2).strip()
                # A quoted value keeps its quotes: the bzl value has to carry
                # them through to Kbuild, escaped the same way config2bzl.sh
                # does it ("CONFIG_X": "\"str\"").
                entries[key] = (
                    raw_value.replace("\\", "\\\\").replace('"', '\\"')
                    if raw_value
                    else '""'
                )
                continue

            match = re.match(r'^#\s*(CONFIG_[A-Za-z0-9_]+) is not set$', line)
            if match:
                entries[match.group(1)] = "n"

    return entries


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("defconfig", help="the *.bzl defconfig dict to edit")
    parser.add_argument("fragment", help="the .config fragment to merge in")
    parser.add_argument("--dry-run", action="store_true", help="show the change without writing")
    args = parser.parse_args()

    extra = parse_fragment(args.fragment)
    if not extra:
        print(f"apply-config: {args.fragment} has no CONFIG_ assignments", file=sys.stderr)
        return 1

    with open(args.defconfig, encoding="utf-8", newline="") as handle:
        original_raw = handle.read()

    # Work in LF internally, then put the file's own convention back on write.
    # Upstream is LF, but a Windows checkout with core.autocrlf=true has CRLF on
    # disk, and writing a bare "\n" into such a file would mix line endings.
    newline_style = "\r\n" if original_raw.count("\r\n") > original_raw.count("\n") - original_raw.count("\r\n") else "\n"
    original = original_raw.replace("\r\n", "\n")
    lines = original.splitlines(keepends=True)

    open_idx = next((i for i, l in enumerate(lines) if OPEN_RE.match(l)), None)
    if open_idx is None:
        print(f"apply-config: no 'name = {{' dict in {args.defconfig}", file=sys.stderr)
        return 1

    close_idx = next((j for j in range(open_idx + 1, len(lines)) if CLOSE_RE.match(lines[j])), None)
    if close_idx is None:
        print(f"apply-config: unterminated dict in {args.defconfig}", file=sys.stderr)
        return 1

    # Entry lines, in file order, with their position inside the dict body.
    body = lines[open_idx + 1:close_idx]
    found: "list[tuple[int, str, str]]" = []          # (body index, key, value)
    indent = None
    for i, line in enumerate(body):
        match = ENTRY_RE.match(line)
        if not match:
            continue
        found.append((i, match.group("key"), match.group("value")))
        if indent is None:
            indent = match.group("indent")
    if indent is None:
        indent = "    "

    existing = {key: value for _, key, value in found}

    updates = {k: v for k, v in extra.items() if k in existing and existing[k] != v}
    additions = {k: v for k, v in extra.items() if k not in existing}

    if not updates and not additions:
        print(f"apply-config: {args.defconfig} already has {', '.join(sorted(extra))}")
        return 2

    new_body = list(body)

    # 1. Rewrite values in place, keeping each line's own indentation.
    for i, key, _value in found:
        if key in updates:
            line_indent = ENTRY_RE.match(new_body[i]).group("indent")
            new_body[i] = f'{line_indent}"{key}": "{updates[key]}",\n'
            print(f"apply-config: {key}: {existing[key]} -> {updates[key]}")

    # 2. Insert new keys at their sorted position in the existing entry order.
    #    "First entry greater than the new key" is correct for the sorted main
    #    block and harmless everywhere else; if nothing is greater they go after
    #    the last entry.
    if additions:
        keys = sorted(additions)
        anchor = None
        for i, key, _value in found:
            if key > keys[0]:
                anchor = i
                break
        if anchor is None:
            anchor = (found[-1][0] + 1) if found else 0

        inserted = [f'{indent}"{key}": "{additions[key]}",\n' for key in keys]
        new_body[anchor:anchor] = inserted
        for key in keys:
            print(f"apply-config: {key} = {additions[key]} (new)")

    updated = "".join(lines[:open_idx + 1] + new_body + lines[close_idx:])

    if args.dry_run:
        sys.stdout.writelines(
            difflib.unified_diff(
                original.splitlines(keepends=True),
                updated.splitlines(keepends=True),
                fromfile=args.defconfig,
                tofile=args.defconfig + " (patched)",
            )
        )
        return 0

    if newline_style != "\n":
        updated = updated.replace("\n", newline_style)

    with open(args.defconfig, "w", encoding="utf-8", newline="") as handle:
        handle.write(updated)
    print(f"apply-config: wrote {args.defconfig} ({newline_style.replace(chr(13), 'CR').replace(chr(10), 'LF')} line endings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
