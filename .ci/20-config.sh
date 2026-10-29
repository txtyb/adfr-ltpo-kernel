#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Put the requested options where they actually take effect.
#
# There are TWO config surfaces in this workspace and they do different things:
#
#   1. GKI/ACK  kernel/platform/kernel-6.12/common/arch/arm64/configs/gki_defconfig
#      The image that boots is //common:kernel_aarch64, built from this file.
#      device/oneplus/sm8850-common/BoardConfigCommon.mk says
#         BOARD_USES_GENERIC_KERNEL_IMAGE := true
#      and vendor/lineage's kernel.mk hands the ROM
#         TARGET_PREBUILT_INT_KERNEL := $(KERNEL_OUT)/Image
#      i.e. out/dist/Image, which is the GKI image. A kernel option that has to
#      exist in the running kernel must be set HERE.
#
#   2. vendor/oneplus/sm8850/configs/canoe_perf.bzl
#      The Qualcomm kleaf defconfig dict. It drives the vendor DDK modules and
#      the device trees (kleaf-scripts/modules_register.bzl:98 ->
#      canoe_perf_merged_defconfig -> dtbs.bzl post_defconfig_fragments), and it
#      never reaches that kernel binary. On this device all vendor code is built
#      as loadable modules, which is why "audio and display components built
#      from source" shows up as .ko files in vendor_dlkm.
#
# Proof from run 38772010956: after patching only the dict, kleaf's dist/.config
# had CONFIG_TMPFS_XATTR=y and CONFIG_ARCH_CANOE=y, while the config embedded in
# out/dist/Image had no CLO symbol at all. So both surfaces get the fragment:
# the GKI defconfig because that is the kernel, and the dict so the module/DTB
# configuration agrees with it.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FRAGMENT="$CONFIG_FRAGMENT"
GKI_DEFCONFIG="$KERNEL_PATH/common/arch/arm64/configs/gki_defconfig"
SOC_DEFCONFIG="$SOC_REPO/configs/$DEFCONFIG_DICT"

require_dir "$SOC_REPO"
require_file "$FRAGMENT"

# --------------------------------------------------------------------------
# 1. the kernel that actually boots
# --------------------------------------------------------------------------
require_file "$GKI_DEFCONFIG"
log "Patching the GKI defconfig (this is the kernel that boots)"
set +e
python3 "$REPO_ROOT/.ci/patch-defconfig.py" "$GKI_DEFCONFIG" "$FRAGMENT"
rc=$?
set -e
case "$rc" in
    0) log "gki_defconfig updated" ;;
    2) log "gki_defconfig already up to date" ;;
    *) die "patch-defconfig.py failed (exit $rc)" ;;
esac
grep -n 'CONFIG_TMPFS' "$GKI_DEFCONFIG" || warn "no CONFIG_TMPFS* line in gki_defconfig"

# Match the ROM's kernel release string when asked. See lib.sh for why: the
# release is part of every module's vermagic.
if [ -n "$KERNEL_LOCALVERSION" ]; then
    lv_fragment="$OUT/localversion.config"
    printf 'CONFIG_LOCALVERSION="%s"\n' "$KERNEL_LOCALVERSION" > "$lv_fragment"
    log "Forcing CONFIG_LOCALVERSION=\"$KERNEL_LOCALVERSION\" so vermagic matches the ROM"
    set +e
    python3 "$REPO_ROOT/.ci/patch-defconfig.py" "$GKI_DEFCONFIG" "$lv_fragment"
    rc=$?
    set -e
    case "$rc" in
        0) log "localversion set" ;;
        2) log "localversion already set" ;;
        *) die "patch-defconfig.py failed for the localversion (exit $rc)" ;;
    esac
    grep -n '^CONFIG_LOCALVERSION=' "$GKI_DEFCONFIG"
fi

# --------------------------------------------------------------------------
# 2. the vendor DDK / DTB configuration
# --------------------------------------------------------------------------
require_file "$SOC_DEFCONFIG"
log "Merging $(basename "$FRAGMENT") into configs/$DEFCONFIG_DICT (modules + DTBs)"
set +e
python3 "$REPO_ROOT/.ci/apply-config.py" "$SOC_DEFCONFIG" "$FRAGMENT"
rc=$?
set -e
case "$rc" in
    0) log "config dict updated" ;;
    2) log "config dict already up to date" ;;
    *) die "apply-config.py failed (exit $rc)" ;;
esac
grep -n '"CONFIG_TMPFS' "$SOC_DEFCONFIG" || warn "no CONFIG_TMPFS* entry found"

# --------------------------------------------------------------------------
# 3. record exactly what changed
# --------------------------------------------------------------------------
log "Diffs against the checkouts"
git -C "$KERNEL_PATH/common" --no-pager diff --stat -- arch/arm64/configs/gki_defconfig || true
git -C "$SOC_REPO" --no-pager diff --stat -- "configs/$DEFCONFIG_DICT" || true

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    {
        echo "### Kernel config changes"
        echo
        echo "GKI defconfig (the image that boots):"
        echo
        echo '```diff'
        git -C "$KERNEL_PATH/common" --no-pager diff -- arch/arm64/configs/gki_defconfig 2>/dev/null || true
        echo '```'
        echo
        echo "Vendor defconfig dict (modules + DTBs):"
        echo
        echo '```diff'
        git -C "$SOC_REPO" --no-pager diff -- "configs/$DEFCONFIG_DICT" 2>/dev/null || true
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi
