#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Install the host tooling the kleaf build needs, plus the `repo` launcher.
# Written for Debian/Ubuntu (what GitHub's ubuntu-* runners are).

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
fi

log "Installing apt packages"
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
# kleaf wants a normal kernel build environment; the prebuilts (clang, rust,
# jdk, build-tools) all come from the LineageOS manifest, not from apt.
PKGS="
    bc bison build-essential ca-certificates cpio curl flex git gnupg gperf
    kmod libelf-dev libssl-dev libxml2-utils lz4 python3 python3-venv rsync
    unzip xxd xsltproc zip zlib1g-dev zstd libdw-dev libncurses-dev
    libyaml-dev device-tree-compiler
"
# "xxd" and "device-tree-compiler" are the ones most likely to be renamed or
# absent on a given runner, so do not let one of them kill the whole job.
if ! $SUDO apt-get install -y -qq --no-install-recommends $PKGS; then
    warn "bulk install failed; retrying package by package"
    for pkg in $PKGS; do
        $SUDO apt-get install -y -qq --no-install-recommends "$pkg" \
            || warn "package unavailable, continuing: $pkg"
    done
fi

log "Installing the repo launcher"
mkdir -p "$HOME/bin"
if [ ! -x "$HOME/bin/repo" ]; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/bin/repo"
    chmod +x "$HOME/bin/repo"
fi
export PATH="$HOME/bin:$PATH"
repo --version

if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$HOME/bin" >> "$GITHUB_PATH"
fi

log "Toolchain"
python3 --version
git --version
make --version | head -1

log "Disk space"
df -h "$REPO_ROOT" || true
