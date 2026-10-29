#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the flashable deliverables:
#
#   1. an AnyKernel3 zip that swaps only the kernel inside the ROM's boot.img,
#      and
#   2. an init_boot.img, when one can be derived soundly.
#
# --- Why the AnyKernel3 boot section looks the way it does ---------------------
# This device has a separate init_boot partition (BOARD_INIT_BOOT_HEADER_VERSION
# := 4 in device/oneplus/sm8850-common/BoardConfigCommon.mk), so boot.img holds
# the kernel and init_boot.img holds the generic ramdisk. AnyKernel3's own
# template documents exactly this case:
#
#   dump_boot;  # use split_boot to skip ramdisk unpack, e.g. for devices with
#               # init_boot ramdisk
#   write_boot; # use flash_boot to skip ramdisk repack
#
# so we use split_boot/flash_boot: the kernel is replaced, the ramdisk is not
# touched, and whatever the ROM put in boot.img stays put.
#
# AnyKernel3 ships 32-bit ARM magiskboot/busybox builds. That is fine here: GKI
# has CONFIG_COMPAT=y (verified in arch/arm64/configs/gki_defconfig), so the
# arm64 kernel runs them.
#
# --- About init_boot.img ------------------------------------------------------
# kleaf's kernel_images cannot produce one: its boot_image_outs are only
# boot.img / vendor_boot.img / vendor_kernel_boot.img and there is no
# build_init_boot attribute. The ROM builds init_boot.img from the GKI generic
# ramdisk and it contains no kernel, so a kernel rebuild does not change it.
# We therefore DERIVE one from the GKI boot image in the dist when we can, say
# loudly which file we used, and skip it otherwise. Keeping the ROM's own
# init_boot.img is the safe choice.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$DIST"
require_file "$DIST/Image"

# Pinned so the template we patch is the template we inspected.
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}"
AK3_REF="${AK3_REF:-020dfeccf9d7e962a48400fc94d3e451df92eead}"

AK3_DIR="$OUT/anykernel3"
STAMP="$(date -u +%Y%m%d)"
# One directory per artifact, matching the split in 50-package.sh, so each is
# uploaded separately instead of as one 800 MB bundle.
AK3_ZIP="$RELEASE/anykernel3/op15-infiniti-anykernel3-${TARGET}-${STAMP}.zip"

rm -rf "$AK3_DIR"
mkdir -p "$RELEASE/anykernel3" "$RELEASE/images"

# --------------------------------------------------------------------------
# 1. AnyKernel3 zip
# --------------------------------------------------------------------------
log "Fetching AnyKernel3 @ ${AK3_REF:0:12}"
git clone -q "$AK3_REPO" "$AK3_DIR"
git -C "$AK3_DIR" checkout -q "$AK3_REF"
rm -rf "$AK3_DIR/.git" "$AK3_DIR/.github"

# Native tools. AnyKernel3 ships 32-bit ARM busybox/magiskboot; they are the only
# 32-bit dependency in this zip, and when one cannot execute the flasher dies with
# "Busybox setup failed. Aborting..." (setup_bb() or its symlink install fails).
# AnyKernel3's README points at the Magisk release for other architectures. This
# is best-effort: if the download fails we keep the bundled binaries rather than
# failing a build that otherwise succeeded.
log "Looking for native aarch64 busybox/magiskboot in the Magisk release"
if python3 "$REPO_ROOT/.ci/ak3-tools.py" "$AK3_DIR"; then
    :
else
    warn "keeping AnyKernel3's bundled 32-bit ARM tools"
fi

require_file "$AK3_DIR/anykernel.sh"
require_file "$AK3_DIR/tools/magiskboot"
require_file "$AK3_DIR/tools/ak3-core.sh"

log "Patching anykernel.sh"
# set_prop <key> <value>: replace the whole "key=..." line inside properties().
set_prop() {
    local key="$1" value="$2" file="$AK3_DIR/anykernel.sh"
    if ! grep -q "^${key}=" "$file"; then
        die "anykernel.sh has no '${key}=' line -- AnyKernel3 template changed, refusing to ship a broken zip"
    fi
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    grep -q "^${key}=${value}$" "$file" || die "failed to set ${key}=${value}"
    echo "  ${key}=${value}"
}

set_prop kernel.string "OnePlus 15 OSS kernel (canoe_${SOC_VARIANT}) with CONFIG_TMPFS_XATTR=y"
set_prop do.devicecheck "1"
set_prop do.modules "0"
set_prop do.systemless "1"
set_prop do.cleanup "1"
set_prop do.cleanuponabort "0"
# do_devicecheck() in META-INF/com/google/android/update-binary compares these
# against ro.product.device, ro.build.product, ro.product.vendor.device and
# ro.vendor.product.device -- i.e. against the *codename*, not the model number.
# 'infiniti' is the LineageOS/PixelOS codename; OP60FFL1/OP611FL1 come from this
# device tree's TARGET_OTA_ASSERT_DEVICE, so a ROM that reports the ODM name also
# passes. A failed check only aborts the flash, so extra names are harmless.
set_prop device.name1 "$DEVICE"
set_prop device.name2 "OP60FFL1"
set_prop device.name3 "OP611FL1"
set_prop device.name4 "CPH2745"
set_prop device.name5 "PLK110"

# swap the boot section over to the "kernel only, ramdisk lives in init_boot" flow.
# BLOCK must be set too: the template ships osm0sis' tuna example path
# (/dev/block/platform/omap/...) which does not exist on this device. "boot" makes
# AnyKernel3 resolve the partition by name, which is what modern AK3 expects.
sed -i 's|^BLOCK=.*|BLOCK=boot;|' "$AK3_DIR/anykernel.sh"
sed -i 's|^dump_boot;.*|split_boot; # kernel only: the ramdisk is in init_boot|' "$AK3_DIR/anykernel.sh"
sed -i 's|^write_boot;.*|flash_boot; # do not repack a ramdisk we do not own|' "$AK3_DIR/anykernel.sh"
grep -q '^BLOCK=boot;' "$AK3_DIR/anykernel.sh" || die "failed to set BLOCK=boot"
grep -q '^split_boot;' "$AK3_DIR/anykernel.sh" || die "split_boot swap failed"
grep -q '^flash_boot;' "$AK3_DIR/anykernel.sh" || die "flash_boot swap failed"
sed -i 's|^IS_SLOT_DEVICE=.*|IS_SLOT_DEVICE=1;|' "$AK3_DIR/anykernel.sh"
grep -q '^IS_SLOT_DEVICE=1;' "$AK3_DIR/anykernel.sh" || die "failed to set IS_SLOT_DEVICE=1"
echo "  BLOCK=boot, IS_SLOT_DEVICE=1, split_boot/flash_boot"

log "Installing the kernel image into the zip"
# AnyKernel3 looks for an exact 'Image' at the zip root (tools/ak3-core.sh).
cp -f "$DIST/Image" "$AK3_DIR/Image"
ls -la "$AK3_DIR/Image"

# AnyKernel3 refuses to run if the image it would flash is not there.
if [ ! -s "$AK3_DIR/Image" ]; then
    die "Image is empty"
fi

log "Writing $AK3_ZIP"
( cd "$AK3_DIR" && zip -qr1 "$AK3_ZIP" . -x '.git/*' )

log "Verifying the zip"
for want in anykernel.sh Image tools/magiskboot tools/ak3-core.sh META-INF/com/google/android/update-binary; do
    if ! unzip -l "$AK3_ZIP" | grep -q " ${want}$"; then
        die "zip is missing ${want}"
    fi
    echo "  present: ${want}"
done
echo "  anykernel.sh inside the zip:"
unzip -p "$AK3_ZIP" anykernel.sh | grep -E '^(kernel.string|do.devicecheck|device.name1|BLOCK=|IS_SLOT_DEVICE=|split_boot;|flash_boot;)' | sed 's/^/    /'

# --------------------------------------------------------------------------
# 2. init_boot.img (derived, optional)
# --------------------------------------------------------------------------
MKBOOTIMG_DIR="$KERNEL_PATH/tools/mkbootimg"
INIT_BOOT="$RELEASE/images/init_boot.img"

derive_init_boot() {
    local unpack="$MKBOOTIMG_DIR/unpack_bootimg.py"
    local mkboot="$MKBOOTIMG_DIR/mkbootimg.py"
    [ -f "$unpack" ] && [ -f "$mkboot" ] || { warn "mkbootimg tools not in the platform; skipping"; return 1; }

    # Where the generic ramdisk lives in this dist. The SoC build has no
    # build_init_boot (kleaf's kernel_images has no such attribute), but it does
    # dist the GKI boot artifacts: avb_sign_boot_image() signs
    # //common:kernel_aarch64_gki_artifacts and "distributes the GKI artifacts",
    # which is where boot.img / boot-gz.img / boot-lz4.img / boot-img.tar.gz
    # come from. Those carry the GKI kernel plus the generic ramdisk, so the
    # ramdisk can be lifted out of them.
    #
    # Preference order matters: an explicitly GKI-named file first, then the
    # compressed GKI variants, then plain boot.img. Whatever is picked, it must
    # actually contain a ramdisk or it is skipped, so a wrong guess cannot
    # produce a bogus init_boot.img.
    local candidates=()
    local pattern
    for pattern in '*gki*boot*.img' 'boot-gz.img' 'boot-lz4.img' 'boot.img'; do
        local hit
        while IFS= read -r hit; do
            [ -n "$hit" ] && candidates+=("$hit")
        done < <(find "$DIST" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | sort)
    done
    if [ "${#candidates[@]}" -eq 0 ]; then
        warn "no boot image in the dist to lift a generic ramdisk out of"
        warn "init_boot.img holds only that ramdisk and a kernel rebuild does not"
        warn "change it, so keep the one already on the device."
        return 1
    fi

    local work="$OUT/init_boot_work" src
    for src in "${candidates[@]}"; do
        rm -rf "$work"; mkdir -p "$work"
        local subject="$src"

        # boot-gz.img / boot-lz4.img are the whole boot image compressed, so
        # unpack_bootimg needs them inflated first.
        if [ "$(head -c 2 "$src" | od -An -tx1 | tr -d ' \n')" = "1f8b" ]; then
            if ! gzip -dc "$src" > "$work/inflated.img" 2> "$work/inflate.log"; then
                warn "could not gunzip $(basename "$src")"
                continue
            fi
            subject="$work/inflated.img"
            echo "  gunzipped $(basename "$src") -> $(stat -c%s "$subject") bytes"
        fi

        if ! python3 "$unpack" --boot_img "$subject" --out "$work" > "$work/unpack.log" 2>&1; then
            warn "could not unpack $(basename "$src") (see $work/unpack.log)"
            continue
        fi
        if [ ! -s "$work/ramdisk" ]; then
            warn "$(basename "$src") has no ramdisk; skipping it"
            continue
        fi

        log "Deriving init_boot.img from $(basename "$src")"
        echo "  generic ramdisk: $(stat -c%s "$work/ramdisk") bytes"
        python3 "$mkboot" \
            --header_version 4 \
            --pagesize 4096 \
            --ramdisk "$work/ramdisk" \
            --output "$INIT_BOOT"
        echo "  init_boot.img  : $(stat -c%s "$INIT_BOOT") bytes"
        warn "init_boot.img is DERIVED and normally unnecessary: it holds only the"
        warn "generic ramdisk, which a kernel rebuild does not change. Compare its"
        warn "size against yours before flashing it:"
        warn "  adb shell 'ls -l /dev/block/by-name/init_boot'"
        return 0
    done
    return 1
}

if derive_init_boot; then
    echo "$INIT_BOOT" > "$RELEASE/anykernel3/.has_init_boot"
else
    rm -f "$INIT_BOOT"
    warn "shipping without init_boot.img"
fi

log "Flashable artifacts"
du -sh "$RELEASE"/* 2>/dev/null || true
ls -la "$RELEASE"
