#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Prove that the requested config actually reached the built kernel.
#
# There are two different ways this can go wrong, and they need different fixes,
# so this step reports which one happened rather than just "symbol missing":
#
#   A. the SoC kernel config has the option but out/dist/Image does not
#      -> Image is not the kernel the SoC config describes (in this workspace
#         kleaf also builds //common:kernel_aarch64 and dists GKI artifacts), so
#         the artifact the ROM would pack is the wrong kernel.
#   B. neither config has it
#      -> the fragment never reached Kbuild, i.e. the injection path is wrong.
#
# The authoritative config for the kernel that produces Image is kleaf's own
# dist/.config output (canoe_perf_dtb_build declares .config as one of its outs).
# Image's embedded copy (CONFIG_IKCONFIG=y) is what actually got compiled, so
# both are checked.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

IMAGE="$DIST/Image"
require_file "$IMAGE"

EMBEDDED="$DIST/kernel.config"          # extracted from Image
DISTCFG="$DIST/.config"                 # kleaf's merged config for the SoC build
EXTRACT="$KERNEL_PATH/common/scripts/extract-ikconfig"
XATTR='CONFIG_TMPFS_XATTR=y'

identify() {
    # identify <file> <label>: say what kernel a config belongs to
    local f="$1" label="$2" n
    if [ ! -s "$f" ]; then
        echo "  ${label}: (absent)"
        return 0
    fi
    n=$(wc -l < "$f")
    echo "  ${label}: $f  (${n} lines, $(stat -c%s "$f") bytes)"
    printf '    %-34s %s\n' "CONFIG_TMPFS_XATTR" "$(grep -E '^CONFIG_TMPFS_XATTR=|^# CONFIG_TMPFS_XATTR' "$f" || echo '(absent)')"
    # Markers that only exist once the Qualcomm/CLO fragment is applied.
    local sym
    for sym in CONFIG_ARCH_CANOE CONFIG_OPLUS_CHARGER CONFIG_ARM_QCOM_CPUFREQ_HW CONFIG_CFG80211; do
        printf '    %-34s %s\n' "$sym" "$(grep -E "^${sym}=" "$f" || echo '-')"
    done
}

log "Reading the config embedded in Image"
if [ -f "$EXTRACT" ]; then
    if bash "$EXTRACT" "$IMAGE" > "$EMBEDDED" 2> "$DIST/extract-ikconfig.log"; then
        log "extracted $(wc -l < "$EMBEDDED") config lines with scripts/extract-ikconfig"
    else
        warn "extract-ikconfig failed (see $DIST/extract-ikconfig.log)"
        rm -f "$EMBEDDED"
    fi
else
    warn "$EXTRACT not found"
fi

# extract-ikconfig compiles scripts/binoffset.c against the host compiler and
# needs a working gzip, so keep a dependency-free inflate as a fallback.
if [ ! -s "$EMBEDDED" ]; then
    warn "falling back to .ci/extract-config.py"
    if python3 "$REPO_ROOT/.ci/extract-config.py" "$IMAGE" "$EMBEDDED"; then
        log "extracted $(wc -l < "$EMBEDDED") config lines with .ci/extract-config.py"
    else
        warn "extract-config.py could not find an embedded config either"
        rm -f "$EMBEDDED"
    fi
fi

log "Identifying the configs"
identify "$EMBEDDED" "embedded in Image"
identify "$DISTCFG" "kleaf dist/.config"

log "Kernel artifacts in the dist"
ls -la "$DIST/Image" "$DIST/.config" "$DIST/vmlinux" 2>/dev/null || true
find "$DIST" -maxdepth 1 -type f \( -name 'Image*' -o -name '*vmlinux*' -o -name 'System.map' \) -printf '  %10s  %f\n' 2>/dev/null | sort -k2 || true

in_embedded=no
in_dist=no
grep -qx "$XATTR" "$EMBEDDED" 2>/dev/null && in_embedded=yes
grep -qx "$XATTR" "$DISTCFG" 2>/dev/null && in_dist=yes

verdict=""
if [ "$in_embedded" = yes ] && [ "$in_dist" = yes ]; then
    log "OK: $XATTR is present in both the built Image and the SoC config"
elif [ "$in_dist" = yes ] && [ "$in_embedded" = no ]; then
    verdict="case A: kleaf's dist/.config HAS $XATTR but the Image we would flash does not, so out/dist/Image is a different kernel than the SoC config describes"
elif [ "$in_dist" = no ] && [ "$in_embedded" = no ]; then
    verdict="case B: neither config has $XATTR, so the fragment never reached Kbuild"
else
    verdict="odd: the embedded Image config has $XATTR but dist/.config does not"
fi

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    {
        echo "### Kernel config check"
        echo
        echo '```'
        echo "embedded in Image : $(grep -E '^CONFIG_TMPFS_XATTR=|^# CONFIG_TMPFS_XATTR' "$EMBEDDED" 2>/dev/null || echo absent)"
        echo "dist/.config      : $(grep -E '^CONFIG_TMPFS_XATTR=|^# CONFIG_TMPFS_XATTR' "$DISTCFG" 2>/dev/null || echo absent)"
        grep -E '^CONFIG_ARCH_CANOE=|^CONFIG_OPLUS_CHARGER=' "$DISTCFG" 2>/dev/null || echo "dist/.config has no CLO fragment markers"
        echo '```'
        echo
        [ -n "$verdict" ] && echo "**$verdict**"
    } >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "$verdict" ]; then
    die "$verdict (see the identification block above)"
fi
