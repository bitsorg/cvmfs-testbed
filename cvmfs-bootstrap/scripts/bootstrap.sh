#!/usr/bin/env bash
# bootstrap.sh — Seed the CVMFS repository with the nested-catalog structure
#                required by cvmfs_server ingest -b <path>.
#
# Runs inside the cvmfs-bootstrap container which shares the Docker network with
# the gateway and stratum0 containers, so "gateway" and "stratum0" resolve via
# Docker DNS.
#
# Strategy: use cvmfs_server ingest at the repository root (base path = "")
# to write .cvmfsdirtab + a placeholder file for the nested catalog path.
# cvmfs_swissknife processes .cvmfsdirtab during the catalog sync and creates
# the nested catalog entry.  This avoids FUSE mounts entirely — swissknife
# downloads the current root catalog from stratum0 via HTTP and sends changes
# directly to the gateway receiver.
#
# What this script does:
#   1. Stages CVMFS binaries from SOFTWARE_ROOT to a writable tmpfs location.
#   2. Sets capabilities on cvmfs_publish (needed for signing even in ingest mode).
#   3. Checks idempotency: exits 0 if the nested catalog is already registered.
#   4. Creates a bootstrap tar:
#        .cvmfsdirtab          — registers NESTED_CATALOG_PATH as a nested catalog
#        <path>/.cvmfs_nested_placeholder — ensures the dir exists in the catalog
#   5. Runs: cvmfs_server ingest -t <tar> -b "" <repo>
#      The empty base path means root-level ingest; no FUSE mount required.
#
# Environment (all have defaults; only REPO_NAME is required):
#   REPO_NAME             CVMFS repository FQDN        (e.g. test.cvmfs.io)
#   SOFT_RO               Path to CVMFS binaries inside the container
#                         (default: /opt/cvmfs-software, mounted ro from SOFTWARE_ROOT)
#   NESTED_CATALOG_PATH   Sub-path to register as a nested catalog
#                         (default: test/native/smoke)
#
# Volume expectations (set in docker-compose.yml):
#   /opt/cvmfs-software          ← ${SOFTWARE_ROOT}          (ro)
#   /etc/cvmfs/keys              ← config/keys               (ro)
#   /etc/cvmfs/repositories.d/${REPO_NAME}
#                                ← config/native-publisher   (ro)
#   /srv/cvmfs/${REPO_NAME}      ← repos/${REPO_NAME}        (rw)
#   /var/spool/cvmfs             ← data/bootstrap-spool      (rw)
#
# The script is idempotent: if the nested catalog path already appears in
# .cvmfsdirtab it skips the ingest and exits 0.

set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
SOFT_RO="${SOFT_RO:-/opt/cvmfs-software}"
NESTED_CATALOG_PATH="${NESTED_CATALOG_PATH:-test/native/smoke}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

# ── 1. Stage binaries to a writable tmpfs ─────────────────────────────────────
# SOFTWARE_ROOT is mounted read-only; setcap requires write access.
# Copy just the needed binaries to /run/cvmfs-bin (tmpfs inside the container).
SOFT_BIN=/run/cvmfs-bin
mkdir -p "$SOFT_BIN"

info "Staging CVMFS binaries from $SOFT_RO → $SOFT_BIN ..."
for bin in cvmfs_server cvmfs_publish cvmfs_publish_debug cvmfs_swissknife cvmfs_suid_helper cvmfs2; do
    src="$SOFT_RO/$bin"
    if [[ -f "$src" ]]; then
        cp -a "$src" "$SOFT_BIN/$bin"
        info "  staged $bin"
    else
        warn "  $bin not found in $SOFT_RO — skipping"
    fi
done

# cvmfs_server in CVMFS_TESTBED mode constructs the binary path as
# $CVMFS_TESTBED_SOFTWARE_ROOT/cvmfs_publish_debug.  Release builds don't
# include it; provide a fallback symlink so the script doesn't abort.
if [[ ! -f "$SOFT_BIN/cvmfs_publish_debug" ]]; then
    ln -sf "$SOFT_BIN/cvmfs_publish" "$SOFT_BIN/cvmfs_publish_debug"
    info "  symlinked cvmfs_publish_debug → cvmfs_publish (release build)"
fi

# Shared libraries: copy to a writable location so the dynamic linker finds them.
info "Staging shared libraries ..."
find "$SOFT_RO" -maxdepth 1 \( -name "libcvmfs_*.so*" -o -name "libfuse3.so*" \) \
    -exec cp -a {} "$SOFT_BIN/" \;

export PATH="$SOFT_BIN:$PATH"
export LD_LIBRARY_PATH="$SOFT_BIN:${LD_LIBRARY_PATH:-}"
export CVMFS_TESTBED=true
export CVMFS_TESTBED_SOFTWARE_ROOT="$SOFT_BIN"

# ── 2. Set capabilities on staged binaries ────────────────────────────────────
# cvmfs_publish needs cap_sys_admin for the manifest signing step.
# In gateway-mode ingest the FUSE overlay is not used, but signing still runs.
info "Setting capabilities on staged binaries ..."
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs_publish"      2>/dev/null || warn "setcap cvmfs_publish skipped"
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs_publish_debug" 2>/dev/null || true
setcap cap_sys_admin+ep  "$SOFT_BIN/cvmfs2"              2>/dev/null || warn "setcap cvmfs2 skipped"
chmod u+s                "$SOFT_BIN/cvmfs_suid_helper"   2>/dev/null || warn "chmod u+s cvmfs_suid_helper skipped"

# ── 3. Idempotency check ──────────────────────────────────────────────────────
# Read .cvmfsdirtab directly from the CAS root.
DIRTAB_HINT="/srv/cvmfs/${REPO_NAME}/.cvmfsdirtab"
if [[ -f "$DIRTAB_HINT" ]] && grep -qxF "/${NESTED_CATALOG_PATH}" "$DIRTAB_HINT" 2>/dev/null; then
    success "Nested catalog /${NESTED_CATALOG_PATH} already registered — nothing to do."
    exit 0
fi

info "No existing nested catalog at /${NESTED_CATALOG_PATH} — running bootstrap ingest."

# ── 4. Create bootstrap tar ───────────────────────────────────────────────────
# The tar is ingested at the repository root (base path = "").
# It contains:
#   .cvmfsdirtab      — tells cvmfs_swissknife to create a nested catalog at the path
#   <path>/.cvmfs_nested_placeholder
#                     — creates the directory in the root catalog so that
#                       CreateNestedCatalog() can find it (avoids the
#                       "catalog for directory cannot be found" panic)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info "Building bootstrap tar ..."
echo "/${NESTED_CATALOG_PATH}" > "$WORK_DIR/.cvmfsdirtab"
mkdir -p "$WORK_DIR/${NESTED_CATALOG_PATH}"
echo "bootstrap placeholder — safe to overwrite" \
    > "$WORK_DIR/${NESTED_CATALOG_PATH}/.cvmfs_nested_placeholder"

CATALOG_TAR="$WORK_DIR/catalog_setup.tar"
tar -C "$WORK_DIR" -cf "$CATALOG_TAR" ".cvmfsdirtab" "${NESTED_CATALOG_PATH}"
info "  tar size: $(du -sh "$CATALOG_TAR" | cut -f1)"

# ── 5. Ingest at repository root ──────────────────────────────────────────────
# -b ""  = root-level base path: the gateway grants a lease for the repo root,
#          swissknife updates the root catalog, and processes .cvmfsdirtab to
#          create the nested catalog entry — no FUSE mount required.
info "Running: cvmfs_server ingest -b \"\" -t $CATALOG_TAR $REPO_NAME"
if cvmfs_server ingest \
        -t "$CATALOG_TAR" \
        -b "" \
        "$REPO_NAME"; then
    success "Root-level ingest complete."
    success "Nested catalog /${NESTED_CATALOG_PATH} registered in .cvmfsdirtab."
    success "Bootstrap complete.  Repository ${REPO_NAME} is ready for cvmfs_server ingest."
else
    die "cvmfs_server ingest failed — see output above."
fi
