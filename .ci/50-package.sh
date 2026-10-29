#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Split the build output into the artifacts a PixelOS 17 install actually needs,
# one directory per purpose so each becomes its own workflow artifact:
#
#   out/release/anykernel3/   the flashable AnyKernel3 zip (written by 60-flashable.sh)
#   out/release/images/       raw partition images you fastboot flash
#   out/release/modules/      the .ko files and their load lists
#   out/release/config/       proof of what was built: the config read back out
#                             of Image, the SoC merged config, the kleaf manifest
#
# What the ROM build consumes from the dist dir (vendor/lineage/build/tasks/
# kernel.mk, platform-target path):
#   Image                     the kernel the ROM packs into boot.img
#   dtb.img / *.dtb           glued into boot.img (BOARD_INCLUDE_DTB_IN_BOOTIMG)
#   dtbo.img                  the dtbo partition (BOARD_KERNEL_SEPARATED_DTBO)
#   *.ko + system_dlkm.modules.load   vendor_dlkm / system_dlkm contents
# and the dist also carries ready-made boot.img / vendor_boot.img built by the
# SoC's own image rules (kleaf-scripts/image_opts.bzl + targets/canoe.bzl), which
# is where the correct cmdline, header version and page size come from.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$DIST"

STAMP="$(date -u +%Y%m%d)"
NAME="op15-infiniti-oss-kernel-${TARGET}-${STAMP}"
rm -rf "$RELEASE"
mkdir -p "$RELEASE/images" "$RELEASE/modules" "$RELEASE/config"

log "Collecting artifacts"
copy_if_present() {
    # copy_if_present <src-glob> <dest-subdir>
    local src dest found=0
    dest="$RELEASE/$2"
    mkdir -p "$dest"
    for src in $1; do
        [ -e "$src" ] || continue
        cp -f "$src" "$dest/" && found=$((found + 1))
    done
    [ "$found" -gt 0 ] || rmdir "$dest" 2>/dev/null || true
    echo "  $2: $found file(s)"
}

# --- raw images -----------------------------------------------------------
copy_if_present "$DIST/Image"                     "images"
copy_if_present "$DIST/dtb.img"                   "images"
copy_if_present "$DIST/dtb/*.dtb"                 "images"
copy_if_present "$DIST/*.dtb"                     "images"
# The DTBs may also sit a level or two down; fetch whatever the globs missed.
if [ -d "$RELEASE/images" ]; then
    find "$DIST" -type f -name '*.dtb' -exec cp -n {} "$RELEASE/images/" \; 2>/dev/null || true
fi
copy_if_present "$DIST/boot.img"                  "images"
copy_if_present "$DIST/*avb*boot*.img"            "images"
copy_if_present "$DIST/vendor_boot.img"           "images"
copy_if_present "$DIST/dtbo.img"                  "images"
copy_if_present "$DIST/vendor_dlkm.img"           "images"
copy_if_present "$DIST/system_dlkm*.img"          "images"
# A dist-provided init_boot.img if there ever is one; .ci/60-flashable.sh
# reports why it cannot be derived otherwise.
copy_if_present "$DIST/init_boot*.img"            "images"
copy_if_present "$DIST/*.dtbo"                    "images"

# --- modules --------------------------------------------------------------
copy_if_present "$DIST/vendor_dlkm.modules.load"  "modules"
copy_if_present "$DIST/system_dlkm.modules.load"  "modules"
copy_if_present "$DIST/*.ko"                      "modules"

# --- config / proof -------------------------------------------------------
copy_if_present "$DIST/kernel.config"             "config"
copy_if_present "$DIST/.config"                   "config"
copy_if_present "$OUT/manifest.xml"               "config"

# A complete listing so nothing is silently lost.
find "$DIST" -maxdepth 1 -type f -printf '%f\n' | sort > "$RELEASE/config/FILES_IN_DIST.txt"

cat > "$RELEASE/images/README-FLASH.txt" <<EOF
OnePlus 15 (infiniti) -- open-source kernel, $TARGET variant
Built $(date -u '+%Y-%m-%d %H:%M UTC') from:
  GKI/ACK   kernel/common            $(git -C "$KERNEL_PATH/common" rev-parse --short HEAD 2>/dev/null || echo '?')
  kleaf     kernel/build             $(git -C "$KERNEL_PATH/build/kernel" rev-parse --short HEAD 2>/dev/null || echo '?')
  CLO/SoC   $KERNEL_SRC_REL  $(git -C "$SOC_REPO" rev-parse --short HEAD 2>/dev/null || echo '?')
  modules   ${KERNEL_SRC_REL}-modules       $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-modules" rev-parse --short HEAD 2>/dev/null || echo '?')
  dtrees    ${KERNEL_SRC_REL}-devicetrees   $(git -C "$KERNEL_PATH/${KERNEL_SRC_REL}-devicetrees" rev-parse --short HEAD 2>/dev/null || echo '?')
Requested config: $(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.ci/extra.config" | tr '\n' ' ')

THE FOUR ARTIFACTS
  op15-anykernel3-*   the flashable zip. Recommended: it swaps only the kernel
                      inside the boot.img already on your device.
  op15-images-*       raw images for fastboot (this directory).
  op15-modules-*      .ko files; not needed for a config-only change like this one.
  op15-config-*       kernel.config read back out of Image, plus the SoC config.

BACK UP FIRST
  Extract boot.img / init_boot.img / vendor_boot.img / dtbo.img / vbmeta.img from
  the PixelOS zip you are running right now (payload-dumper-go payload.bin) and
  keep them. Worst case you can also just re-sideload that same ROM zip.

INSTALL -- use the AnyKernel3 zip (a)

  a) PREFERRED. The AnyKernel3 zip swaps only the kernel inside the boot.img
     already on your device, so the ROM's cmdline, bootconfig, header version
     and DTB all stay as they are. Use a flasher that can run its
     update-binary (Kernel Flasher, or a root shell).

  b) fastboot flash boot images/boot.img -- DO NOT DO THIS FIRST.
     images/boot.img is built by kleaf's kernel_images, NOT by Android build/make
     the way this ROM's boot.img is. build/make fills in the device's
     BOARD_BOOTCONFIG (androidboot.hardware=qcom, hypervisor.version=gunyah,
     memcg=1, usbcontroller=..., vendor.qspa=true), while canoe.bzl's
     boot_image_opts() only adds androidboot.serialconsole=0. Flashing it
     directly therefore drops most of the bootconfig, and the device hangs at the
     boot animation because init never sees the right hardware parameters.
     Verified failure mode: flashing this image directly produced exactly that.

     If you must use fastboot, first compare the two cmdlines:
       adb shell cat /proc/cmdline
       adb shell cat /proc/bootconfig
     If androidboot.hardware / hypervisor.* are missing afterwards, that is why.

  Flash dtbo/vendor_boot only if the device trees changed; for a config-only
  change they did not. Never flash super.img from here.

IF IT HANGS AT THE BOOT ANIMATION
  The kernel booted (animation means init and zygote started), so suspect the
  parameters or the modules, not a panic:
    adb shell uname -r
    adb shell cat /proc/cmdline
    adb shell dmesg | grep -iE 'version magic|disagrees about version|unknown symbol'
  A 'version magic' or 'disagrees about version of symbol' line means the ROM's
  vendor_dlkm modules were built against a different kernel release (this build
  has CONFIG_LOCALVERSION_AUTO=y, so the release string carries a git
  description). Recover with: fastboot flash boot <your-stock-boot.img>

ROLLBACK
  fastboot flash boot     <your-stock-boot.img>
  fastboot flash init_boot <your-stock-init_boot.img>   # only if you touched it
  fastboot flash dtbo     <your-stock-dtbo.img>         # only if you touched it

VERIFY THE KERNEL IS LIVE
  adb shell uname -a
  adb shell zcat /proc/config.gz | grep CONFIG_TMPFS_XATTR     # expect =y

NOTES
  * config/kernel.config is the config read back out of Image -- what the kernel
    actually boots with, not what a fragment asked for.
  * init_boot.img is not in here: this build produces kernel-only boot images
    (the generic ramdisk comes from the ROM's GKI prebuilt), so there is nothing
    to derive it from, and a config-only change does not alter a ramdisk.
  * Our only functional config change is CONFIG_TMPFS_XATTR=y. It does not
    change the module ABI, so vendor_dlkm/system_dlkm need no update; the .ko
    files and both *.modules.load are included anyway.
  * boot.img here is signed with the GKI test key, not PixelOS's. PixelOS builds
    vbmeta with verification and verity disabled
    (BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3) and the bootloader is
    unlocked, which is why that is expected to boot.
EOF

# Report how the base DTB travels. BOARD_INCLUDE_DTB_IN_BOOTIMG is true on this
# device, so the base DTBs should be inside boot.img -- and the dist has no
# dtb.img to point at, which leaves the boot image as the only place they can be.
# unpack_bootimg is the platform's own tool; it writes one file per header field,
# so the presence of 'dtb' answers the question without flashing anything.
if [ -f "$DIST/boot.img" ] && [ -f "$KERNEL_PATH/tools/mkbootimg/unpack_bootimg.py" ]; then
    probe="$OUT/boot_probe"
    rm -rf "$probe"; mkdir -p "$probe"
    log "Probing boot.img: does it carry the base DTB?"
    if python3 "$KERNEL_PATH/tools/mkbootimg/unpack_bootimg.py" \
            --boot_img "$DIST/boot.img" --out "$probe" > "$probe/unpack.log" 2>&1; then
        for f in kernel dtb ramdisk second; do
            if [ -s "$probe/$f" ]; then
                echo "  $f: $(stat -c%s "$probe/$f") bytes"
            else
                echo "  $f: absent"
            fi
        done
        grep -iE '^ *(boot image header version|page size|os version)' "$probe/unpack.log" 2>/dev/null | sed 's/^/  /' || true
    else
        warn "could not unpack boot.img (see $probe/unpack.log)"
    fi
fi

log "Release layout"
du -sh "$RELEASE"/* 2>/dev/null || true
# sed, not head: with pipefail a SIGPIPE on find would fail the step.
find "$RELEASE" -type f -printf '%10s  %P\n' | sort -k2 | sed -n '1,40p'
echo "  ..."
find "$RELEASE" -type f | wc -l | xargs -I{} echo "  {} files total"
