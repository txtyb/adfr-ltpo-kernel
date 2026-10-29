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
# wrong filesystem. This step re-packs the same module set as EROFS.
#
# Where the module set comes from
# -------------------------------
# NOT from dist/vendor_dlkm.modules.load: that file only lists the modules init
# loads at boot (~200 of them), while the partition ships the whole vendor set
# (~550). Staging from it produces a broken image (measured: 205 files).
#
# dist/vendor_dlkm.img (kleaf's ext4 image) already contains exactly the set
# that belongs on the partition, so it is loop-mounted and re-packed.
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
require_file "$DIST/vendor_dlkm.img"

BLOCK=4096
CLUSTER=4096
TIMESTAMP=1230768000          # 2009-01-01, what build/make stamps
PARTITION_BYTES=59920384      # OnePlus 15 vendor_dlkm_a
MIN_MODULES=400               # the device ships 552; anything near 200 is the boot subset

ROOT="$OUT/vendor_dlkm_root"
MOUNT="$OUT/vendor_dlkm_mnt"
OUTIMG="$RELEASE/images/vendor_dlkm.erofs.img"
mkdir -p "$RELEASE/images"

for pkg in erofs-utils attr e2fsprogs; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        log "installing $pkg"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "$pkg"
    fi
done

command -v mkfs.erofs >/dev/null 2>&1 || die "mkfs.erofs not available"

# ---------------------------------------------------------------------------
# 1. Stage the module set kleaf puts in vendor_dlkm (from its ext4 image)
# ---------------------------------------------------------------------------
rm -rf "$ROOT" "$MOUNT"
mkdir -p "$ROOT" "$MOUNT"

log "loop-mounting dist/vendor_dlkm.img (ext4) read-only"
sudo mount -o loop,ro "$DIST/vendor_dlkm.img" "$MOUNT" \
    || die "cannot loop-mount $DIST/vendor_dlkm.img"
sudo cp -a "$MOUNT/." "$ROOT/"
sudo chown -R "$(id -u):$(id -g)" "$ROOT"
sudo umount "$MOUNT" || warn "umount failed"

KO=$(find "$ROOT" -name '*.ko' | wc -l)
log "staged $KO modules from the ext4 image"
[ "$KO" -ge "$MIN_MODULES" ] || die "only $KO modules staged, refusing to build an incomplete image"

# ---------------------------------------------------------------------------
# 2. depmod so modules.dep/.alias/.softdep are consistent with the set
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
        [ -f "$STAGE/lib/modules/$RELEASE/$f" ] && \
            cp -f "$STAGE/lib/modules/$RELEASE/$f" "$ROOT/lib/modules/$f"
    done
    rm -rf "$STAGE"
else
    warn "kernel release not detected or depmod missing; keeping the modules.dep from the ext4 image"
fi
[ -f "$ROOT/lib/modules/modules.load" ] || warn "no modules.load in the staged tree"

# ---------------------------------------------------------------------------
# 3. SELinux labels: everything under vendor_dlkm is vendor_file
# ---------------------------------------------------------------------------
if command -v setfattr >/dev/null 2>&1; then
    if find "$ROOT" -type f -exec setfattr -n security.selinux \
            -v u:object_r:vendor_file:s0 {} + 2>/dev/null; then
        log "applied vendor_file label to $(find "$ROOT" -type f | wc -l) files"
    else
        warn "could not set security.selinux on this runner; labels fall back to file_contexts at mount time"
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
log "vendor_dlkm.erofs.img: $SIZE bytes (partition $PARTITION_BYTES)"

if [ "$SIZE" -gt "$PARTITION_BYTES" ]; then
    die "image does not fit the partition: $SIZE > $PARTITION_BYTES"
fi
truncate -s "$PARTITION_BYTES" "$OUTIMG"
log "padded to partition size"

dump.erofs -s "$OUTIMG" 2>/dev/null | sed 's/^/    /' || true
