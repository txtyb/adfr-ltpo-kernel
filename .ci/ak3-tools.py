#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Put native aarch64 busybox/magiskboot into an AnyKernel3 tree.

AnyKernel3's repo ships 32-bit ARM builds of both. They work on kernels with
CONFIG_COMPAT, but they are the only 32-bit dependency in the zip, and when one
of them cannot execute the flasher dies with

    Busybox setup failed. Aborting...

which comes from META-INF/com/google/android/update-binary: setup_bb() fails, or
it could not create the symlinks in bin/ (the abort at that line covers both).

AnyKernel3's own README says other architectures come from the official Magisk
package, so this pulls the latest Magisk APK and swaps in
lib/arm64-v8a/libbusybox.so and lib/arm64-v8a/libmagiskboot.so.

Exit 0 on success. Any failure exits non-zero and the caller keeps the bundled
binaries, so a network problem cannot fail the build.
"""

from __future__ import annotations

import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
MEMBERS = {
    "lib/arm64-v8a/libbusybox.so": "tools/busybox",
    "lib/arm64-v8a/libmagiskboot.so": "tools/magiskboot",
}


def fetch(url: str, timeout: int = 600) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": UA, "Accept": "application/vnd.github+json",
        "Accept-Encoding": "identity"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def elf_machine(data: bytes):
    if data[:4] != b"\x7fELF":
        return None
    return int.from_bytes(data[18:20], "little")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    ak3 = sys.argv[1]

    try:
        rel = json.loads(fetch("https://api.github.com/repos/topjohnwu/Magisk/releases/latest"))
        apk_url = next(a["browser_download_url"] for a in rel["assets"]
                       if a["name"].lower().endswith(".apk"))
        print("  Magisk %s: %s" % (rel.get("tag_name"), os.path.basename(apk_url)))
        apkzip = zipfile.ZipFile(io.BytesIO(fetch(apk_url)))
    except Exception as exc:                                    # noqa: BLE001
        print("  could not get the Magisk release: %s: %s" % (type(exc).__name__, exc),
              file=sys.stderr)
        return 1

    rc = 0
    for member, dest in MEMBERS.items():
        try:
            data = apkzip.read(member)
        except KeyError:
            print("  %s missing from the apk" % member, file=sys.stderr)
            rc = 1
            continue
        machine = elf_machine(data)
        if machine != 0xB7:                      # EM_AARCH64
            print("  %s is not aarch64 (machine=0x%X)" % (member, machine or 0),
                  file=sys.stderr)
            rc = 1
            continue
        target = os.path.join(ak3, dest.replace("/", os.sep))
        with open(target, "wb") as fh:
            fh.write(data)
        os.chmod(target, 0o755)
        print("  %-20s <- %s (%d bytes, AArch64)" % (dest, member, len(data)))
    return rc


if __name__ == "__main__":
    sys.exit(main())
