#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Build the kernel. This is the same command LineageOS runs in
# vendor/lineage/build/tasks/kernel.mk for a device with
#   TARGET_KERNEL_PLATFORM_TARGET := canoe_perf
#   TARGET_KERNEL_SOURCE         := vendor/oneplus/sm8850
#   TARGET_KERNEL_BAZEL_FLAGS    += --//vendor/oneplus/sm8850:dtbo_config=...
#
#   cd kernel/platform/kernel-6.12 && ./tools/bazel \
#       --output_user_root=... --output_root=... \
#       run --experimental_convenience_symlinks=ignore --cpu=arm64 \
#       --repo_manifest <platform>:<manifest.xml> --config=stamp \
#       <flags> //vendor/oneplus/sm8850:canoe_perf_dist -- --destdir=...

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_dir "$KERNEL_PATH"
require_file "$KERNEL_PATH/tools/bazel"

mkdir -p "$OUT" "$DIST" "$BAZEL_OUT"

log "Generating $OUT/manifest.xml for kleaf --repo_manifest"
python3 "$REPO_ROOT/.ci/gen-kleaf-manifest.py" "$KERNEL_PLATFORM" "$PLATFORM_REL" > "$OUT/manifest.xml"
echo "  $(wc -l < "$OUT/manifest.xml") lines"

log "Building //$KERNEL_SRC_REL:${TARGET}_dist"
log "  dtbo_config = $DTBO_CONFIG"
echo "  extra flags = ${EXTRA_BAZEL_FLAGS:-(none)}"
echo "  bazel out   = $BAZEL_OUT"
echo "  dist dir    = $DIST"

cd "$KERNEL_PATH"

# The SoC repo ships a device.bazelrc that turns on the DDK unsafe-header
# whitelist, but nothing in the repo references it -- it has to reach bazel
# explicitly, and LineageOS gets it there through board-config plumbing that is
# not visible from kernel.mk. Without it the build dies at
#
#   //vendor/oneplus/sm8850:canoe_perf/drivers/base/regmap/qti-regmap-debugfs
#   fatal error: 'drivers/base/regmap/internal.h' file not found
#
# because BUILD.bazel:212 only exposes the GKI-internal headers to DDK modules
# when allow_ddk_unsafe_headers is set. Two details differ from the file:
#   * its label is //soc-repo:... (Qualcomm's layout); this tree checks the SoC
#     repo out at vendor/oneplus/sm8850, so the label is rewritten.
#   * the socrepo/qtisocrepo flags are left out: the module graph already
#     resolves without them (proved by the failed run reaching the compile step
#     of the right module), so they are not needed to fix this.
# Set SOC_DEVICE_BAZELRC=1 to pass the whole file instead, verbatim.
SOC_FLAGS=()
if [ "$SOC_DEVICE_BAZELRC" = "1" ]; then
    sed "s|//soc-repo:|//$KERNEL_SRC_REL:|g" "$SOC_REPO/device.bazelrc" > "$OUT/device.bazelrc"
    SOC_FLAGS+=("--bazelrc=$OUT/device.bazelrc")
else
    SOC_FLAGS+=(
        "--//build/kernel/kleaf:allow_ddk_unsafe_headers"
        "--//build/kernel/kleaf:user_ddk_unsafe_headers=//$KERNEL_SRC_REL:unsafe_headers_qcom_group"
        "--check_visibility=false"
    )
fi
printf '  ddk flags   = %s\n' "${SOC_FLAGS[*]}"

# Optional bazel disk cache.
#
# Honest accounting, because it is easy to assume a cache always helps:
#   * the workspace is ~36 GB and a full build's output + action cache is
#     another ~23 GB (measured on runs 38757248756 and 39028772560), while the
#     GitHub Actions cache budget is 10 GB per repository -- so neither can be
#     cached whole;
#   * a hermetic bazel build does not use ccache, so that route is closed;
#   * --disk_cache can still hold the hottest objects inside a capped budget,
#     but saving/restoring it costs minutes on a cold run.
# It pays off when re-running the same commit (packaging/flashable iteration)
# and hardly at all while the kernel config is still changing, which is why the
# workflow tars it behind the bazel_disk_cache input and passes it in only then.
CACHE_FLAGS=()
if [ -n "${BAZEL_DISK_CACHE:-}" ]; then
    mkdir -p "$BAZEL_DISK_CACHE"
    CACHE_FLAGS+=("--disk_cache=$BAZEL_DISK_CACHE")
    log "bazel disk cache: $BAZEL_DISK_CACHE ($(du -sh "$BAZEL_DISK_CACHE" 2>/dev/null | cut -f1 || echo empty) restored)"
else
    log "bazel disk cache: off"
fi

set -x
./tools/bazel \
    --output_user_root="$BAZEL_OUT" \
    --output_root="$BAZEL_OUT" \
    run \
    --experimental_convenience_symlinks=ignore \
    --cpu="$KERNEL_ARCH" \
    --repo_manifest "$KERNEL_PLATFORM:$OUT/manifest.xml" \
    --config=stamp \
    "${SOC_FLAGS[@]}" \
    "${CACHE_FLAGS[@]}" \
    "--//$KERNEL_SRC_REL:dtbo_config=$DTBO_CONFIG" \
    $EXTRA_BAZEL_FLAGS \
    "//$KERNEL_SRC_REL:${TARGET}_dist" \
    -- --destdir="$DIST"
set +x

log "Dist contents"
ls -la "$DIST" || die "no dist directory produced"
du -sh "$DIST"

if [ ! -f "$DIST/Image" ]; then
    warn "no Image in $DIST -- listing everything for diagnosis:"
    find "$DIST" -maxdepth 2 -type f -printf '%10s  %p\n' | sort -k2 || true
    die "the build produced no kernel image"
fi

log "Disk space after the build"
df -h "$REPO_ROOT" || true
