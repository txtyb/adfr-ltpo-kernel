#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Shared paths and constants for the OnePlus 15 (infiniti) OSS kernel build.
# Sourced by every other script in this directory.
#
# Layout produced under $WORK_ROOT:
#
#   .work/kernel_platform/                 <- `repo` workspace root
#   .work/kernel_platform/kernel/platform/kernel-6.12/
#       build/kernel/                      <- kleaf (kernel/build)
#       common/                            <- GKI/ACK (kernel/common)
#       prebuilts/... tools/mkbootimg external/...
#       tools/bazel -> build/kernel/kleaf/bazel.sh     (repo linkfile)
#       MODULE.bazel, WORKSPACE.bzlmod                 (repo linkfiles)
#       vendor/oneplus/sm8850/             <- CLO/SoC kernel  (this repo's target)
#       vendor/oneplus/sm8850-modules/     <- techpack modules
#       vendor/oneplus/sm8850-devicetrees/ <- techpack devicetrees
#
# This mirrors LineageOS: device/oneplus/sm8850-common/lineage.dependencies
# places the three vendor/oneplus repos at exactly these paths, and
# vendor/lineage/build/tasks/kernel.mk builds them with
#
#   ./tools/bazel ... run ... //vendor/oneplus/sm8850:canoe_perf_dist -- --destdir=...
#
# which is what .ci/30-build.sh reproduces.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# --------------------------------------------------------------------------
# What to build
# --------------------------------------------------------------------------
# LineageOS branch used for the three vendor/oneplus repos.
export KERNEL_BRANCH="${KERNEL_BRANCH:-lineage-24.0}"

# LineageOS manifest repo. Its snippets/kernel-<ver>.xml pins the GKI/ACK
# revision (android16-6.12-2026-06, the tag the PixelOS 17 thread links to) and
# the whole kleaf platform (kernel/build, prebuilts, external/*).
export MANIFEST_URL="${MANIFEST_URL:-https://github.com/LineageOS/android}"
export KERNEL_SNIPPET="${KERNEL_SNIPPET:-kernel-6.12.xml}"

export KERNEL_VERSION="${KERNEL_VERSION:-6.12}"
export KERNEL_ARCH="${KERNEL_ARCH:-arm64}"

# Device / SoC. OnePlus 15 == infiniti, Qualcomm SM8850 == "canoe".
export DEVICE="${DEVICE:-infiniti}"
export SOC_VARIANT="${SOC_VARIANT:-perf}"          # perf | consolidate
export TARGET="${TARGET:-canoe_${SOC_VARIANT}}"

# Which defconfig dict .ci/apply-config.py edits. Always the perf one:
# android_build.bzl passes canoe_perf_config as `implicit_config_fragment` for
# the consolidate variant too, so editing perf covers both.
export DEFCONFIG_DICT="${DEFCONFIG_DICT:-canoe_perf.bzl}"

# The extra .config fragment merged into that dict (normal .config syntax).
# Override it to build with a different set of options.
export CONFIG_FRAGMENT="${CONFIG_FRAGMENT:-$REPO_ROOT/.ci/extra.config}"

# --------------------------------------------------------------------------
# Where the CLO/SoC kernel comes from
# --------------------------------------------------------------------------
# Default: LineageOS upstream, i.e. exactly what the PixelOS 17 build uses.
# Point these at a fork (and a branch of it) to build your own kernel commits:
#   CLO_REPO=yourname/android_kernel_oneplus_sm8850
#   CLO_REVISION=my-branch
# CLO_REMOTE_FETCH is the git host that CLO_REPO is served from.
export CLO_REPO="${CLO_REPO:-LineageOS/android_kernel_oneplus_sm8850}"
export CLO_REVISION="${CLO_REVISION:-$KERNEL_BRANCH}"
export CLO_REMOTE_FETCH="${CLO_REMOTE_FETCH:-https://github.com}"

# Optional GKI pin override. "auto" (default) keeps whatever revision the
# LineageOS snippet pins; anything else is applied as an explicit override.
export GKI_REVISION="${GKI_REVISION:-auto}"

# Device dtbo overlay config, as passed by
# device/oneplus/infiniti/BoardConfig.mk (TARGET_KERNEL_BAZEL_FLAGS).
export DTBO_CONFIG="${DTBO_CONFIG:-//vendor/oneplus/sm8850-devicetrees:${DEVICE}_dtbo_config}"

# Any extra bazel flags, appended verbatim.
export EXTRA_BAZEL_FLAGS="${EXTRA_BAZEL_FLAGS:-}"

# Set to 1 to hand the SoC repo's device.bazelrc to bazel verbatim (with its
# //soc-repo label rewritten for this tree) instead of the individual flags
# .ci/30-build.sh names.
export SOC_DEVICE_BAZELRC="${SOC_DEVICE_BAZELRC:-0}"

# Optional bazel --disk_cache directory. Empty means no cache. .ci/30-build.sh
# documents what it does and does not buy; the workflow only sets it when the
# bazel_disk_cache input is enabled.
export BAZEL_DISK_CACHE="${BAZEL_DISK_CACHE:-}"

# Optional CONFIG_LOCALVERSION override for the GKI defconfig.
#
# The kernel release string ends up in every module's vermagic, and with
# CONFIG_MODVERSIONS=y the kernel refuses modules built against a different
# release. A ROM built elsewhere gets a "-g<sha>" suffix from setlocalversion
# that this build does not reproduce (the sandbox has no git), so the releases
# differ and none of the ROM's vendor modules load -- which looks exactly like a
# hang at the boot animation.
#
# Set this to the suffix your ROM's "uname -r" shows between "-android16-6" and
# "-4k" to make the release identical. Empty leaves upstream's "-4k" alone.
export KERNEL_LOCALVERSION="${KERNEL_LOCALVERSION:-}"

# --------------------------------------------------------------------------
# Where things live
# --------------------------------------------------------------------------
export WORK_ROOT="${WORK_ROOT:-$REPO_ROOT/.work}"
export PLATFORM_REL="kernel/platform/kernel-${KERNEL_VERSION}"

# `repo` workspace root == kleaf workspace root ("kernel_platform").
export KERNEL_PLATFORM="$WORK_ROOT/kernel_platform"
# Where the SoC repo (and friends) live inside it.
export KERNEL_PATH="$KERNEL_PLATFORM/$PLATFORM_REL"
export KERNEL_SRC_REL="vendor/oneplus/sm8850"
export SOC_REPO="$KERNEL_PATH/$KERNEL_SRC_REL"

export OUT="${OUT:-$REPO_ROOT/out}"
export DIST="$OUT/dist"
export BAZEL_OUT="$OUT/bazel"
export RELEASE="$OUT/release"

export JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

require_file() { [ -f "$1" ] || die "missing file: $1"; }
require_dir()  { [ -d "$1" ] || die "missing directory: $1"; }
