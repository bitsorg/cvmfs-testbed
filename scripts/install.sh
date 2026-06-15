#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN (European Organization for Nuclear Research)
# SPDX-License-Identifier: Apache-2.0

# install.sh — Populate software/ from the CVMFS build tree, rebuild cvmfs_server,
#              and copy cvmfs-prepub binaries from the cvmfs-bits build.
#
# Convention (enforced here and checked by init.sh):
#   <cvmfs-testbed>/cvmfs/          CVMFS source tree (git clone / symlink)
#   <cvmfs-testbed>/cvmfs-bits/     cvmfs-bits source tree (git clone / symlink)
#   <cvmfs-testbed>/act_runner      Gitea CI runner binary (optional, bits overlay)
#   <cvmfs-testbed>/software/       destination for built binaries and libraries
#
# Run this once after cloning, and again after every code change:
#   cd cvmfs-testbed
#   cmake -S cvmfs -B cvmfs/build
#   make -C cvmfs/build -j$(nproc)
#   make -C cvmfs-bits build
#   ./testbed install          # or:  bash scripts/install.sh
#
# The script:
#   1. Verifies that the CVMFS source tree is present.
#   2. Locates the cmake build directory (tries common names, falls back to find).
#   3. Copies every cvmfs_* executable and libcvmfs_* shared library into software/.
#   4. Resolves .so symlinks so no ldconfig is needed.
#   5. Rebuilds the cvmfs_server shell script from the patched source files in
#      cvmfs/cvmfs/server/ (the patches add CVMFS_TESTBED support) and installs
#      it as software/cvmfs_server.
#   6. Copies cvmfs-prepub and prepubctl from the cvmfs-bits build into software/.
#
# Nothing is ever written to /usr/bin or any other system directory.
#
# Options:
#   --software-root PATH   Override the default software/ destination.
#   --bits-dir PATH        Path to the cvmfs-bits source tree.
#                          Default: <cvmfs-testbed>/cvmfs-bits
#                          The binaries are expected at <bits-dir>/bin/.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"   # root of the cvmfs-testbed checkout

# Canonical location: cvmfs-testbed/cvmfs/ (clone or symlink at the testbed root).
# Fallback: cvmfs/ as a sibling of the testbed root (../cvmfs), the layout when
# cvmfs and cvmfs-testbed are checked out side-by-side in the same parent directory.
if [[ -f "$TESTBED_DIR/cvmfs/cvmfs/make_cvmfs_server.sh" ]]; then
    CVMFS_SRC="$TESTBED_DIR/cvmfs"
elif [[ -f "$TESTBED_DIR/../cvmfs/cvmfs/make_cvmfs_server.sh" ]]; then
    CVMFS_SRC="$(cd "$TESTBED_DIR/../cvmfs" && pwd)"
    warn "Using sibling CVMFS source at $CVMFS_SRC"
    warn "Recommended convention: ln -s ../cvmfs $TESTBED_DIR/cvmfs"
else
    CVMFS_SRC="$TESTBED_DIR/cvmfs"   # keep the canonical path for the error message
fi
SOFTWARE_ROOT="${SOFTWARE_ROOT:-$TESTBED_DIR/software}"
BITS_DIR="${BITS_DIR:-$TESTBED_DIR/cvmfs-bits}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --software-root)
            [[ $# -ge 2 ]] || { error "--software-root requires a value"; exit 1; }
            SOFTWARE_ROOT="$2"; shift 2 ;;
        --software-root=*) SOFTWARE_ROOT="${1#*=}"; shift ;;
        --bits-dir)
            [[ $# -ge 2 ]] || { error "--bits-dir requires a value"; exit 1; }
            BITS_DIR="$2"; shift 2 ;;
        --bits-dir=*) BITS_DIR="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

info "CVMFS source:   $CVMFS_SRC"
info "Software root:  $SOFTWARE_ROOT"
info "Bits dir:       $BITS_DIR"

# ── 1. Verify source tree ─────────────────────────────────────────────────────
if [[ ! -f "$CVMFS_SRC/cvmfs/make_cvmfs_server.sh" ]]; then
    error "CVMFS source tree not found at $CVMFS_SRC"
    error ""
    error "The convention requires the CVMFS source to live at:"
    error "  $TESTBED_DIR/cvmfs"
    error ""
    error "Either clone it there:"
    error "  git clone https://github.com/cvmfs/cvmfs $TESTBED_DIR/cvmfs"
    error ""
    error "Or create a symlink from a checkout elsewhere:"
    error "  ln -s /path/to/your/cvmfs $TESTBED_DIR/cvmfs"
    exit 1
fi

mkdir -p "$SOFTWARE_ROOT"

# ── 2. Locate cmake build directory ──────────────────────────────────────────
_cvmfs_build=""
for _try in \
    "$CVMFS_SRC/build" \
    "$CVMFS_SRC/build-release" \
    "$CVMFS_SRC/build-debug" \
    "$CVMFS_SRC/_build"; do
    if [[ -d "$_try" ]]; then
        _cvmfs_build="$_try"
        break
    fi
done

# Fallback: find the directory that contains cvmfs_publish anywhere under src.
if [[ -z "$_cvmfs_build" ]]; then
    _cvmfs_build=$(find "$CVMFS_SRC" -maxdepth 5 -name "cvmfs_publish" \
        -not -path "*/externals/*" 2>/dev/null \
        | head -1 | xargs -r dirname) || true
fi

if [[ -z "$_cvmfs_build" ]]; then
    error "No cmake build directory found under $CVMFS_SRC."
    error ""
    error "Build CVMFS first:"
    error "  cmake -S $CVMFS_SRC -B $CVMFS_SRC/build"
    error "  make -C $CVMFS_SRC/build -j\$(nproc)"
    exit 1
fi
info "Build tree:     $_cvmfs_build"

# ── 3. Copy executables and shared libraries ──────────────────────────────────
info "Copying binaries and libraries → $SOFTWARE_ROOT ..."
_copied=0
while IFS= read -r _f; do
    if [[ -f "$_f" && ( -x "$_f" || "$_f" == *.so* ) ]]; then
        cp -a "$_f" "$SOFTWARE_ROOT/"
        info "  $(basename "$_f")"
        (( _copied++ )) || true
    fi
done < <(find "$_cvmfs_build" -maxdepth 5 \
    \( -name "cvmfs_*" -o -name "libcvmfs_*" -o -name "cvmfs2" -o -name "cvmfs2_*" \) \
    -not -path "*/externals/*" \
    -not -path "*CMakeFiles*" \
    2>/dev/null)

if [[ $_copied -eq 0 ]]; then
    error "No cvmfs binaries or libraries found in $_cvmfs_build."
    error "Did the cmake build complete successfully?"
    exit 1
fi
info "Copied $_copied file(s)."

# ── 3a. Ensure cvmfs_publish_debug exists ─────────────────────────────────────
# cvmfs_server in CVMFS_TESTBED mode constructs binary paths as
# $CVMFS_TESTBED_SOFTWARE_ROOT/cvmfs_publish_debug.  Release builds don't
# produce the debug variant; create a fallback symlink so cvmfs_server
# transaction/mkfs/publish all work without a debug build.
if [[ ! -f "$SOFTWARE_ROOT/cvmfs_publish_debug" ]]; then
    ln -sf "$SOFTWARE_ROOT/cvmfs_publish" "$SOFTWARE_ROOT/cvmfs_publish_debug" \
        && info "  symlinked cvmfs_publish_debug → cvmfs_publish (no debug build)" \
        || warn "  could not create cvmfs_publish_debug symlink"
fi

# ── 3b. Bundle host FUSE3 runtime ────────────────────────────────────────────
# libcvmfs_fuse3_stub.so is linked against the host's libfuse3.so (soname may
# be .3 or .4 depending on the FUSE version installed).  The Ubuntu 24.04 repo
# ships only FUSE 3.14 (libfuse3.so.3), but the host may have a newer version
# (libfuse3.so.4 from FUSE 3.16+).  Copy whatever soname the host provides into
# SOFTWARE_ROOT so the cvmfs-client container gets the exact same version.
info "Bundling host FUSE3 runtime libraries → $SOFTWARE_ROOT ..."
_fuse_copied=0
for _fuse3 in \
        /usr/lib/x86_64-linux-gnu/libfuse3.so.* \
        /usr/lib/aarch64-linux-gnu/libfuse3.so.* \
        /usr/lib/libfuse3.so.*; do
    [[ -f "$_fuse3" ]] || continue
    cp -a "$_fuse3" "$SOFTWARE_ROOT/"
    info "  $(basename "$_fuse3")"
    (( _fuse_copied++ )) || true
done
if [[ $_fuse_copied -eq 0 ]]; then
    warn "libfuse3 runtime not found on host — cvmfs-client container may fail to mount"
fi

# ── 4. Resolve .so symlinks ───────────────────────────────────────────────────
# setcap refuses to operate on symlinks; copy the real files so no ldconfig is needed.
while IFS= read -r _link; do
    _target=$(readlink -f "$_link" 2>/dev/null) || continue
    if [[ -f "$_target" && "$_target" != "$SOFTWARE_ROOT/"* ]]; then
        cp -a "$_target" "$SOFTWARE_ROOT/" 2>/dev/null \
            && info "  resolved symlink: $(basename "$_link") → $(basename "$_target")" \
            || warn "  could not copy resolved target: $_target"
    fi
done < <(find "$SOFTWARE_ROOT" -maxdepth 1 -name "libcvmfs_*.so*" -type l 2>/dev/null)

# ── 5. Rebuild cvmfs_server from patched source ───────────────────────────────
info "Rebuilding cvmfs_server from patched source ..."
if ( cd "$CVMFS_SRC/cvmfs" && ./make_cvmfs_server.sh "$SOFTWARE_ROOT/cvmfs_server" ); then
    chmod +x "$SOFTWARE_ROOT/cvmfs_server"
    success "cvmfs_server rebuilt → $SOFTWARE_ROOT/cvmfs_server"
else
    error "cvmfs_server rebuild failed — check output above."
    exit 1
fi

# ── 5b. Patch hardcoded /usr/bin/ paths in generated cvmfs_server ─────────────
# make_cvmfs_server.sh bakes the install prefix into the script as literal
# /usr/bin/cvmfs_publish (and similar).  On this testbed the binaries live in
# SOFTWARE_ROOT, not /usr/bin, so those hardcoded paths break operations like
# "cvmfs_server publish" on the host.
#
# Replace each hardcoded absolute path with a bare command name so the shell
# resolves it via PATH at runtime.  This works for both the host (PATH includes
# SOFTWARE_ROOT) and containers (/usr/local/bin is always in PATH).
_patched=0
for _bin in cvmfs_publish cvmfs_swissknife cvmfs_suid_helper; do
    if grep -q "/usr/bin/${_bin}" "$SOFTWARE_ROOT/cvmfs_server" 2>/dev/null; then
        sed -i "s|/usr/bin/${_bin}|${_bin}|g" "$SOFTWARE_ROOT/cvmfs_server"
        info "  patched /usr/bin/${_bin} → ${_bin} (PATH lookup)"
        (( _patched++ )) || true
    fi
done
[[ $_patched -gt 0 ]] && success "Patched $_patched hardcoded path(s) in cvmfs_server."

# ── 6. Copy cvmfs-bits binaries ───────────────────────────────────────────────
# cvmfs-prepub and prepubctl are built by  make -C cvmfs-bits build  and land in
# cvmfs-bits/bin/.  They are NOT produced by the cmake build, so the cvmfs_* glob
# above never picks them up.  docker-compose bind-mounts them from SOFTWARE_ROOT,
# so they must exist there before containers start.
info "Copying cvmfs-bits binaries → $SOFTWARE_ROOT ..."
_bits_bin="$BITS_DIR/bin"
if [[ ! -d "$_bits_bin" ]]; then
    warn "cvmfs-bits bin/ not found at $_bits_bin"
    warn "Build cvmfs-bits first:  make -C \"$BITS_DIR\" build"
    warn "(or in the testbed Makefile:  make build)"
else
    _bits_copied=0
    for _bin in cvmfs-prepub prepubctl; do
        _src="$_bits_bin/$_bin"
        if [[ -f "$_src" && -x "$_src" ]]; then
            cp "$_src" "$SOFTWARE_ROOT/$_bin"
            chmod +x "$SOFTWARE_ROOT/$_bin"
            info "  $_bin"
            (( _bits_copied++ )) || true
        else
            warn "  $_bin not found or not executable in $_bits_bin"
            warn "  Run: make -C \"$BITS_DIR\" build"
        fi
    done
    if [[ $_bits_copied -gt 0 ]]; then
        success "Copied $_bits_copied cvmfs-bits binary/binaries."
    fi
fi

# ── 7. Copy act_runner ───────────────────────────────────────────────────────
# act_runner is the Gitea CI runner required by the bits-console overlay.
# It is expected at <cvmfs-testbed>/act_runner (download from
# https://gitea.com/gitea/act_runner/releases and place there).
# Copying it to SOFTWARE_ROOT puts it on PATH so init.sh can find it.
_act_runner_src="$TESTBED_DIR/act_runner"
if [[ -f "$_act_runner_src" ]]; then
    cp "$_act_runner_src" "$SOFTWARE_ROOT/act_runner"
    chmod +x "$SOFTWARE_ROOT/act_runner"
    success "act_runner installed → $SOFTWARE_ROOT/act_runner"
fi
# If act_runner is not present, init.sh will warn when bits-console/ is present.

# ── 8. Install gateway stub scripts ──────────────────────────────────────────
# Some cvmfs-gateway actions invoke scripts that are part of the full
# cvmfs-server Debian package (e.g. upload_stats_plots.sh).  That package is
# not installed in the lightweight gateway container, so the gateway logs an
# error on every transaction.  Install harmless stubs so those paths exist.
_stub_src="$TESTBED_DIR/cvmfs-elements/containers/gateway/upload_stats_plots.sh"
_stub_dst="$SOFTWARE_ROOT/upload_stats_plots.sh"
if [[ -f "$_stub_src" ]]; then
    cp "$_stub_src" "$_stub_dst"
    chmod +x "$_stub_dst"
    info "  upload_stats_plots.sh (stub)"
    success "Gateway stubs installed."
else
    warn "Gateway stub not found: $_stub_src — skipping."
fi

success "install.sh complete.  Binaries are in $SOFTWARE_ROOT"
