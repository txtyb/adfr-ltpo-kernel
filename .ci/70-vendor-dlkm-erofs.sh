#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build a ROM-compatible EROFS vendor_dlkm image from the kleaf dist.
#
# Why this exists
# ---------------
# LineageOS creates the vendor_dlkm partition with build/make, not with kleaf:
#
#   BOARD_VENDOR_DLKMIMAGE_FILE_SYSTEM_TYPE := erofs   (device BoardConfigCommon.mk)
#   KERNEL_MODULES_OUT := $(TARGET_OUT_VENDOR_DLKM)    (vendor/lineage/build/tasks/kernel.mk)
#
# kleaf's own kernel_images rule keeps its default fs type (ext4, no
# compression) and the standard kernel module layout:
#
#   lib/modules/<release>/extra/vendor/oneplus/sm8850/*.ko
#   lib/modules/<release>/extra/vendor/oneplus/sm8850-modules/*.ko
#   lib/modules/<release>/kernel/...
#
# ... while the ROM flashes a flat EROFS image:
#
#   lib/modules/*.ko
#   lib/modules/modules.load
#
# ... containing 552 modules, not the 640 kleaf builds (the extra ones belong
# to the system_dlkm partition). So neither the filesystem nor the layout nor
# the module set matches; this step rebuilds all three.
#
# Parameters were read back from a real device image
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
MIN_MODULES=500

MANIFEST="$REPO_ROOT/config/vendor_dlkm.modules.txt"
require_file "$MANIFEST"

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
# 1. Mount kleaf's ext4 image and stage only the modules the ROM ships
# ---------------------------------------------------------------------------
rm -rf "$ROOT" "$MOUNT"
mkdir -p "$ROOT/lib/modules" "$MOUNT"

log "loop-mounting dist/vendor_dlkm.img (ext4) read-only"
sudo mount -o loop,ro "$DIST/vendor_dlkm.img" "$MOUNT" \
    || die "cannot loop-mount $DIST/vendor_dlkm.img"

cleanup() {
    sudo umount "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

declare -A want=()
manifest_count=0
while IFS= read -r name; do
    name="${name%%#*}"
    name="$(printf '%s' "$name" | xargs || true)"
    [ -n "$name" ] || continue
    want["$name"]=1
    manifest_count=$((manifest_count + 1))
done < "$MANIFEST"

log "manifest lists $manifest_count modules"

staged=0
while IFS=$'\t' read -r base path; do
    [ -n "$base" ] || continue
    [ "${want[$base]:-0}" = 1 ] || continue
    [ -f "$ROOT/lib/modules/$base" ] && continue        # zram/zsmalloc appear twice
    cp -f "$path" "$ROOT/lib/modules/"
    staged=$((staged + 1))
done < <(find "$MOUNT" -name '*.ko' -printf '%f\t%p\n')

missing=$((manifest_count - staged))
log "staged $staged modules (manifest entries not in the image: $missing)"
[ "$staged" -ge "$MIN_MODULES" ] || die "only $staged modules staged, refusing to build an incomplete image"

# ---------------------------------------------------------------------------
# 2. Metadata files, taken from the image next to the modules
# ---------------------------------------------------------------------------
MODDIR="$(dirname "$(find "$MOUNT" -name 'modules.load' -print -quit)")"
for f in modules.load modules.blocklist system_dlkm.modules.blocklist; do
    if [ -f "$MODDIR/$f" ]; then
        cp -f "$MODDIR/$f" "$ROOT/lib/modules/$f"
    fi
done
[ -f "$ROOT/lib/modules/modules.load" ] || warn "modules.load not found in the image"

# ---------------------------------------------------------------------------
# 3. depmod for the staged set (modules.dep/.alias/.softdep)
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
    warn "kernel release not detected or depmod missing; keeping the metadata from the ext4 image"
fi

# ---------------------------------------------------------------------------
# 4. SELinux labels: everything under vendor_dlkm is vendor_file
#
# The GitHub runner kernel has SELinux compiled in but not enabled, so the
# security.selinux xattr handler is absent and setfattr cannot write the label
# (it silently produces an image with Xattr size 0, which the device then
# cannot label correctly). Build the label into the image instead: mkfs.erofs
# resolves each path against this contexts file and writes the xattr itself.
# ---------------------------------------------------------------------------
CTXFILE="$OUT/vendor_dlkm_file_contexts"
cat > "$CTXFILE" <<'CTX'
/lib(/.*)?    u:object_r:vendor_file:s0
CTX

if mkfs.erofs --help 2>&1 | grep -q 'file-contexts'; then
    log "using mkfs.erofs --file-contexts for SELinux labels"
    CTX_ARG=(--file-contexts="$CTXFILE")
else
    warn "mkfs.erofs has no --file-contexts; trying setfattr"
    CTX_ARG=()
    if command -v setfattr >/dev/null 2>&1; then
        find "$ROOT" -type f -exec setfattr -n security.selinux \
            -v u:object_r:vendor_file:s0 {} + 2>/dev/null \
            || warn "setfattr failed too; the image will have no labels"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Build the image
# ---------------------------------------------------------------------------
rm -f "$OUTIMG"
log "mkfs.erofs -zlz4hc,9 -b $BLOCK -C $CLUSTER -T $TIMESTAMP"
mkfs.erofs -z lz4hc,level=9 \
    -b "$BLOCK" -C "$CLUSTER" \
    -T "$TIMESTAMP" \
    --all-root \
    "${CTX_ARG[@]}" \
    "$OUTIMG" "$ROOT" >/dev/null

SIZE=$(stat -c %s "$OUTIMG")
log "vendor_dlkm.erofs.img: $SIZE bytes (partition $PARTITION_BYTES)"

if [ "$SIZE" -gt "$PARTITION_BYTES" ]; then
    die "image does not fit the partition: $SIZE > $PARTITION_BYTES"
fi
truncate -s "$PARTITION_BYTES" "$OUTIMG"
log "padded to partition size"

dump.erofs -s "$OUTIMG" 2>/dev/null | sed 's/^/    /' || true

# A host without SELinux enabled (the GitHub runner) silently produces an
# image whose files carry no security.selinux xattr, which the device then
# cannot label correctly. Refuse to ship such an image.
if dump.erofs -s "$OUTIMG" 2>/dev/null | grep -q 'xattr_filter'; then
    log "SELinux xattrs present in the image"
else
    die "image has no xattrs: --file-contexts did not take effect, do not flash this"
fi
