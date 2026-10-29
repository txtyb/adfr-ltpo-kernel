#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build a ROM-compatible EROFS vendor_dlkm image from the kleaf dist.
#
# Why this exists
# ---------------
# LineageOS creates the vendor_dlkm partition with build/make, not with kleaf:
#
#   BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs      (device BoardConfigCommon.mk)
#   KERNEL_MODULES_OUT := $(TARGET_OUT_VENDOR_DLKM)       (vendor/lineage/build/tasks/kernel.mk)
#
# kleaf's own kernel_images rule keeps its default fs type (ext4, no
# compression), so dist/vendor_dlkm.img is ~3x the partition size and uses the
# wrong filesystem. This step reproduces what the ROM actually flashes, from the
# same .ko set the dist ships.
#
# Parameters below were read back from a real device image
# (dump.erofs -s vendor_dlkm_stock.img):
#
#   block 4096, cluster 4096, lz4hc, build time 2009-01-01, 566 inodes,
#   14335 blocks / 58,716,160 bytes out of a 59,920,384 byte partition
#
# A dry run of these parameters against the extracted stock tree reproduced the
# original image byte for byte (14335 blocks, 566 inodes).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$DIST"
require_file "$DIST/vendor_dlkm.modules.load"

BLOCK=4096
CLUSTER=4096
TIMESTAMP=1230768000          # 2009-01-01, what build/make stamps
PARTITION_BYTES=59920384      # OnePlus 15 vendor_dlkm_a

ROOT="$OUT/vendor_dlkm_root"
OUTIMG="$RELEASE/images/vendor_dlkm.erofs.img"
mkdir -p "$RELEASE/images"

for pkg in erofs-utils attr; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        log "installing $pkg"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "$pkg"
    fi
done

command -v mkfs.erofs >/dev/null 2>&1 || die "mkfs.erofs not available"

# ---------------------------------------------------------------------------
# 1. Stage exactly the modules the ROM puts in vendor_dlkm
# ---------------------------------------------------------------------------
rm -rf "$ROOT"
mkdir -p "$ROOT/lib/modules"

staged=0
missing=0
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | xargs || true)"
    [ -n "$line" ] || continue
    base="$(basename "$line")"
    if [ -f "$DIST/$base" ]; then
        cp -f "$DIST/$base" "$ROOT/lib/modules/"
        staged=$((staged + 1))
    else
        warn "not in dist: $base"
        missing=$((missing + 1))
    fi
done < "$DIST/vendor_dlkm.modules.load"

log "staged $staged modules (missing $missing) for vendor_dlkm"
[ "$staged" -gt 400 ] || die "only $staged modules staged, refusing to build an incomplete image"

cp -f "$DIST/vendor_dlkm.modules.load" "$ROOT/lib/modules/modules.load"
for f in vendor_dlkm.modules.blocklist; do
    [ -f "$DIST/$f" ] && cp -f "$DIST/$f" "$ROOT/lib/modules/modules.blocklist"
done

# ---------------------------------------------------------------------------
# 2. depmod so modules.dep/.alias/.softdep exist like the ROM's image
# ---------------------------------------------------------------------------
RELEASE="$(strings "$DIST/Image" 2>/dev/null | grep -m1 -oE '6\.12\.[0-9]+-android16[^ ]*' || true)"
if [ -n "$RELEASE" ] && command -v depmod >/dev/null 2>&1; then
    log "depmod for $RELEASE"
    STAGE="$OUT/depmod_stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/lib/modules/$RELEASE"
    cp -f "$ROOT/lib/modules"/*.ko "$STAGE/lib/modules/$RELEASE/"
    depmod -b "$STAGE" -a "$RELEASE" || warn "depmod failed"
    for f in modules.dep modules.alias modules.softdep; do
        [ -f "$STAGE/lib/modules/$RELEASE/$f" ] && cp -f "$STAGE/lib/modules/$RELEASE/$f" "$ROOT/lib/modules/$f"
    done
    rm -rf "$STAGE"
else
    warn "kernel release not detected or depmod missing; skipping modules.dep generation"
fi

# ---------------------------------------------------------------------------
# 3. SELinux labels: everything under vendor_dlkm is vendor_file
# ---------------------------------------------------------------------------
if command -v setfattr >/dev/null 2>&1; then
    if find "$ROOT" -type f -exec setfattr -n security.selinux \
            -v u:object_r:vendor_file:s0 {} + 2>/dev/null; then
        log "applied vendor_file label to $(find "$ROOT" -type f | wc -l) files"
    else
        warn "could not set security.selinux (runner is not SELinux capable); labels will be defaulted at runtime"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Build the image
# ---------------------------------------------------------------------------
rm -f "$OUTIMG"
log "mkfs.erofs -zlz4hc,9 -b $BLOCK -C $CLUSTER -T $TIMESTAMP"
mkfs.erofs -z lz4hc,level=9 \
    -b "$BLOCK" -C "$CLUSTER" \
    -T "$TIMESTAMP" \
    --all-root \
    "$OUTIMG" "$ROOT" >/dev/null

SIZE=$(stat -c %s "$OUTIMG")
log "vendor_dlkm.erofs.img: $SIZE bytes"

if [ "$SIZE" -gt "$PARTITION_BYTES" ]; then
    warn "image exceeds the $PARTITION_BYTES byte partition; padding to exactly that size is impossible"
else
    truncate -s "$PARTITION_BYTES" "$OUTIMG"
    log "padded to partition size $PARTITION_BYTES"
fi

dump.erofs -s "$OUTIMG" 2>/dev/null | sed 's/^/    /' || true

if [ -f "$DIST/vendor_dlkm.img" ]; then
    KLEAF_SIZE=$(stat -c %s "$DIST/vendor_dlkm.img")
    log "for reference, kleaf's own vendor_dlkm.img is $KLEAF_SIZE bytes (ext4, not what the ROM flashes)"
fi
