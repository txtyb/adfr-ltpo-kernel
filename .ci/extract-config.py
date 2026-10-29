#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Read the .config that a kernel image was built with.

`Image` is an ELF, not a container, but CONFIG_IKCONFIG=y makes the build embed
the whole .config as a gzip stream inside it. The kernel's own
scripts/extract-ikconfig does the same job, except it needs to compile
scripts/binoffset.c first and silently fails if the host compiler or the
compression tool is missing.

This is a dependency-free fallback: find the IKCFG_ST marker, then try to
gunzip from there (and, failing that, from every gzip magic in the file) until
something that looks like a kernel config falls out.

Usage: extract-config.py <Image> [out.config]
Exits 0 and writes the config, or exits 1 if none could be found.
"""

from __future__ import annotations

import sys
import zlib

IKCFG_ST = b"IKCFG_ST"
IKCFG_ED = b"IKCFG_ED"
GZIP_MAGIC = b"\x1f\x8b\x08"
# A config that mentions no CONFIG_ line is not a config.
NEEDLE = b"CONFIG_"
# Refuse to inflate anything that is obviously not a config.
MAX_OUTPUT = 8 << 20


def _try_inflate(data: bytes, offset: int) -> bytes | None:
    if data[offset:offset + 3] != GZIP_MAGIC:
        return None
    decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = decompressor.decompress(data[offset:], MAX_OUTPUT)
        out += decompressor.flush()
    except zlib.error:
        return None
    if NEEDLE in out:
        return out
    return None


def extract(path: str) -> bytes | None:
    with open(path, "rb") as handle:
        data = handle.read()

    # Preferred: the marker the kernel writes right before the payload.
    offset = 0
    while True:
        marker = data.find(IKCFG_ST, offset)
        if marker == -1:
            break
        # 'IKCFG_ST' + 4 byte payload length, then the compressed stream.
        for candidate in (marker + len(IKCFG_ST) + 4, marker + len(IKCFG_ST)):
            result = _try_inflate(data, candidate)
            if result is not None:
                return result
        offset = marker + 1

    # Fallback: any gzip stream in the image that inflates to a config.
    offset = 0
    while True:
        offset = data.find(GZIP_MAGIC, offset)
        if offset == -1:
            break
        result = _try_inflate(data, offset)
        if result is not None:
            return result
        offset += 1

    return None


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    image = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None

    config = extract(image)
    if config is None:
        print(f"extract-config: no embedded kernel config found in {image}", file=sys.stderr)
        return 1

    text = config.split(IKCFG_ED)[0].decode("utf-8", errors="replace")
    if out_path:
        with open(out_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        print(f"extract-config: wrote {out_path} ({len(text.splitlines())} lines)", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
