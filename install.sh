#!/usr/bin/env bash
# install.sh — Populate software/ from the CVMFS build tree and rebuild cvmfs_server.
#
# Convention (enforced here and checked by init.sh):
#   <cvmfs-testbed>/cvmfs/          CVMFS source tree (git clone / symlink)
#   <cvmfs-testbed>/software/       destination for built binaries and libraries
#
# Run this once after cloning, and again after every CVMFS code change:
#   cd cvmfs-testbed
#   cmake -S cvmfs -B cvmfs/build
#   make -C cvmfs/build -j$(nproc)
#   ./install.sh
#
# The script:
#   1. Verifies that the CVMFS source tree is present.
#   2. Locates the cmake build directory (tries common names, falls back to find).
#   3. Copies every cvmfs_* executable and libcvmfs_* shared library into software/.
#   4. Resolves .so symlinks so no ldconfig is needed.
#   5. Rebuilds the cvmfs_server shell script from the patched source files in
#      cvmfs/cvmfs/server/ (the patches add CVMFS_TESTBED support) and installs
#      it as software/cvmfs_server.
#
# Nothing is ever written to /usr/bin or any other system directory.
#
# Options:
#   --software-root PATH   Override the default software/ destination.

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*"; }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Preferred location: cvmfs-testbed/cvmfs/ (symlink or clone next to this script).
# Fallback: the cvmfs/ sibling directory one level up (../cvmfs), which is the
# layout used when cvmfs and cvmfs-testbed are siblings inside the same parent.
if [[ -f "$SCRIPT_DIR/cvmfs/cvmfs/make_cvmfs_server.sh" ]]; then
    CVMFS_SRC="$SCRIPT_DIR/cvmfs"
elif [[ -f "$SCRIPT_DIR/../cvmfs/cvmfs/make_cvmfs_server.sh" ]]; then
    CVMFS_SRC="$(cd "$SCRIPT_DIR/../cvmfs" && pwd)"
    warn "Using sibling CVMFS source at $CVMFS_SRC"
    warn "Recommended convention: ln -s ../cvmfs $SCRIPT_DIR/cvmfs"
else
    CVMFS_SRC="$SCRIPT_DIR/cvmfs"   # keep the canonical path for the error message
fi
SOFTWARE_ROOT="${SOFTWARE_ROOT:-$SCRIPT_DIR/software}"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --software-root)
            [[ $# -ge 2 ]] || { error "--software-root requires a value"; exit 1; }
            SOFTWARE_ROOT="$2"; shift 2 ;;
        --software-root=*) SOFTWARE_ROOT="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

info "CVMFS source:   $CVMFS_SRC"
info "Software root:  $SOFTWARE_ROOT"

# ── 1. Verify source tree ─────────────────────────────────────────────────────
if [[ ! -f "$CVMFS_SRC/cvmfs/make_cvmfs_server.sh" ]]; then
    error "CVMFS source tree not found at $CVMFS_SRC"
    error ""
    error "The convention requires the CVMFS source to live at:"
    error "  $SCRIPT_DIR/cvmfs"
    error ""
    error "Either clone it there:"
    error "  git clone https://github.com/cvmfs/cvmfs $SCRIPT_DIR/cvmfs"
    error ""
    error "Or create a symlink from a checkout elsewhere:"
    error "  ln -s /path/to/your/cvmfs $SCRIPT_DIR/cvmfs"
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
    \( -name "cvmfs_*" -o -name "libcvmfs_*" \) \
    -not -path "*/externals/*" \
    -not -path "*CMakeFiles*" \
    2>/dev/null)

if [[ $_copied -eq 0 ]]; then
    error "No cvmfs_* binaries or libcvmfs_* libraries found in $_cvmfs_build."
    error "Did the cmake build complete successfully?"
    exit 1
fi
info "Copied $_copied file(s)."

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

success "install.sh complete.  Binaries are in $SOFTWARE_ROOT"
