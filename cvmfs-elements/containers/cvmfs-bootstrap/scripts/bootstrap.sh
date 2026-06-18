#!/usr/bin/env bash
# bootstrap.sh — Seed the CVMFS repository with the nested-catalog structure
#                required by cvmfs_server ingest -b <path>.
#
# Runs inside the cvmfs-bootstrap container which shares the Docker network with
# the gateway and stratum0 containers, so "gateway" and "stratum0" resolve via
# Docker DNS.
#
# Strategy: take a gateway lease at the TOP-LEVEL ancestor of the nested catalog
# path (e.g. "test" for NESTED_CATALOG_PATH="test/native/smoke"), place a
# .cvmfscatalog marker file at the target sub-path, and run cvmfs_server ingest
# WITHOUT the -c flag.  This is required because of how the gateway receiver's
# CatalogMergeTool filters reportable paths.
#
# Why the lease base must be an ancestor, not the nested catalog path itself:
#   The receiver's CatalogMergeTool only calls AddDirectory / GraftNestedCatalog
#   for paths that are sub-paths of the lease path (IsReportablePath).  If the
#   lease is taken at "test/native/smoke", the intermediate directories "test/"
#   and "test/native/" are traversed but never added to the output catalog.
#   When GraftNestedCatalog("test/native/smoke") subsequently runs it needs
#   FindCatalog("test/native") to succeed — which panics if test/native was
#   never added.  Taking the lease at "test" (the first path component) makes
#   all three directories reportable, so AddDirectory is called for test/ and
#   test/native/ before GraftNestedCatalog is called for test/native/smoke/.
#
# Why a .cvmfscatalog marker instead of the -c flag:
#   -c (create_catalog_on_root_) creates the nested catalog AT the base path
#   passed to -b.  With -b test, that would create a catalog at "test/", not at
#   "test/native/smoke/".  A .cvmfscatalog file placed at the target sub-path
#   inside the tar triggers catalog creation at exactly that sub-path.
#
# Why NOT use .cvmfsdirtab (root-level ingest with -b ""):
#   a) cvmfs_server ingest argument parsing uses "while [ "$2" != "" ]" so an
#      empty -b "" causes the loop to exit early; the repo name ends up as "-b"
#      and the command fails with "transaction on repository -b".
#   b) Even if the root ingest worked, mountless gateway ingest explicitly
#      aborts if .cvmfsdirtab already exists in the published repo:
#      "Mountless gateway ingest does not yet support a published .cvmfsdirtab"
#      — meaning native-smoke.sh would fail on every subsequent run.
#
# What this script does:
#   1. Stages CVMFS binaries from SOFTWARE_ROOT to a writable tmpfs location.
#   2. Sets capabilities on cvmfs_publish (needed for signing even in ingest mode).
#   3. Checks idempotency via a sentinel file in the CAS root.
#   4. Splits NESTED_CATALOG_PATH into:
#        LEASE_BASE      — first path component (e.g. "test")
#        NESTED_RELATIVE — remaining path components (e.g. "native/smoke")
#   5. Builds a tar containing only a .cvmfscatalog file at NESTED_RELATIVE/
#      (no directory entries — CreateDirectories inside swissknife ingest will
#       create the intermediate directories automatically).
#   6. Runs: cvmfs_server ingest -t <tar> -b <LEASE_BASE> <repo>
#      The gateway lease is taken at LEASE_BASE, so the receiver sees all
#      intermediate directories as reportable and adds them before grafting
#      the nested catalog.
#   7. Writes a sentinel file so subsequent runs skip the ingest.
#
# Environment (all have defaults; only REPO_NAME is required):
#   REPO_NAME             CVMFS repository FQDN        (e.g. test.cvmfs.io)
#   SOFT_RO               Path to CVMFS binaries inside the container
#                         (default: /opt/cvmfs-software, mounted ro from SOFTWARE_ROOT)
#   NESTED_CATALOG_PATH   Sub-path to create as a nested catalog
#                         (default: test/native/smoke)
#                         Must have at least two path components (a/b).
#
# Volume expectations (set in docker-compose.yml):
#   /opt/cvmfs-software          ← ${SOFTWARE_ROOT}          (ro)
#   /etc/cvmfs/keys              ← config/keys               (ro)
#   /etc/cvmfs/repositories.d/${REPO_NAME}
#                                ← config/native-publisher   (ro)
#   /srv/cvmfs/${REPO_NAME}      ← repos/${REPO_NAME}        (rw)
#   /var/spool/cvmfs             ← data/bootstrap-spool      (rw)
#
# The script is idempotent: a sentinel file written on success prevents
# re-running the ingest on subsequent container invocations.

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
# A sentinel file written by a successful previous run signals "already done".
# The sentinel lives in the CAS root (mounted rw from repos/<repo>/) so it
# survives snapshots and restores alongside the repository data.
SENTINEL="/srv/cvmfs/${REPO_NAME}/.bootstrap_complete"
if [[ -f "$SENTINEL" ]]; then
    success "Bootstrap sentinel found — nested catalog /${NESTED_CATALOG_PATH} already created."
    exit 0
fi

if [[ -n "${SKIP_BOOTSTRAP_INGEST:-}" ]]; then
    info "SKIP_BOOTSTRAP_INGEST set: skipping native-ingest seeding (not needed for the pull path); no gateway lease taken."
    touch "$SENTINEL"
    success "Bootstrap skipped via SKIP_BOOTSTRAP_INGEST; sentinel written."
    exit 0
fi

info "No bootstrap sentinel found — running bootstrap ingest."

# ── 4. Compute lease base and tar sub-path ────────────────────────────────────
# LEASE_BASE: first path component — the gateway lease is taken here so the
#   receiver reports all intermediate directories as additions, which is required
#   for GraftNestedCatalog to find the parent path in the output catalog.
# NESTED_RELATIVE: remaining path components — this is where the .cvmfscatalog
#   marker is placed inside the tar (relative to LEASE_BASE/).
LEASE_BASE="${NESTED_CATALOG_PATH%%/*}"
NESTED_RELATIVE="${NESTED_CATALOG_PATH#*/}"

if [[ "$LEASE_BASE" == "$NESTED_CATALOG_PATH" ]]; then
    # Single-component path has no parent within the lease scope.
    # A root-level lease (-b "") is needed but is broken in cvmfs_server_ingest.sh.
    die "NESTED_CATALOG_PATH '${NESTED_CATALOG_PATH}' has only one component. " \
        "It must have at least two (e.g. test/smoke) so the lease can be taken " \
        "at the parent level."
fi

info "  LEASE_BASE:      ${LEASE_BASE}"
info "  NESTED_RELATIVE: ${NESTED_RELATIVE}"

# ── 5. Create bootstrap tar ───────────────────────────────────────────────────
# The tar contains ONLY the .cvmfscatalog marker at NESTED_RELATIVE/.
# No directory entries are included: cvmfs_swissknife's CreateDirectories()
# creates all intermediate directories automatically when it sees the marker
# file's parent path.  Omitting explicit directory entries avoids a duplicate
# AddDirectory call for paths that CreateDirectories already processed.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

info "Building bootstrap tar ..."
mkdir -p "$WORK_DIR/${NESTED_RELATIVE}"
# .cvmfscatalog: the standard CVMFS catalog-creation marker.
# cvmfs_swissknife ingest adds the parent path to to_create_catalog_dirs_
# when it encounters this file, which causes CreateNestedCatalog to be called
# at LEASE_BASE/NESTED_RELATIVE after the tar is fully processed.
touch "$WORK_DIR/${NESTED_RELATIVE}/.cvmfscatalog"

CATALOG_TAR="$WORK_DIR/bootstrap.tar"
# --no-recursion: add only the named path, not parent directories.
# The explicit file path ensures no implicit directory entries are added.
tar --no-recursion -C "$WORK_DIR" -cf "$CATALOG_TAR" "${NESTED_RELATIVE}/.cvmfscatalog"
info "  tar contents: $(tar -tf "$CATALOG_TAR")"
info "  tar size:     $(du -sh "$CATALOG_TAR" | cut -f1)"

# ── 6. Ingest to create nested catalog ───────────────────────────────────────
# Gateway lease is taken at LEASE_BASE (not at the full NESTED_CATALOG_PATH).
# This makes the receiver's IsReportablePath return true for all directories
# from LEASE_BASE/ down to the nested catalog root, so AddDirectory is called
# for test/ and test/native/ before GraftNestedCatalog is called for
# test/native/smoke/.  Without this, FindCatalog("test/native") panics because
# the intermediate directories are never added to the receiver's output catalog.
#
# No -c flag: the nested catalog is created at NESTED_RELATIVE/ (not at
# LEASE_BASE/) because the .cvmfscatalog marker file drives catalog creation
# at the exact sub-path.  -c would create a catalog at LEASE_BASE instead.
info "Running: cvmfs_server ingest -b ${LEASE_BASE} -t $CATALOG_TAR $REPO_NAME"
if cvmfs_server ingest \
        -t "$CATALOG_TAR" \
        -b "${LEASE_BASE}" \
        "$REPO_NAME"; then
    success "Ingest complete."
    success "Nested catalog /${NESTED_CATALOG_PATH} created in repository ${REPO_NAME}."
    # Write sentinel so subsequent container runs skip the ingest.
    touch "$SENTINEL"
    success "Bootstrap complete.  Repository ${REPO_NAME} is ready for cvmfs_server ingest."
else
    warn "cvmfs_server ingest failed; aborting transaction to release the gateway lease."
    cvmfs_server abort -f "$REPO_NAME" 2>&1 || warn "cvmfs_server abort returned non-zero (lease may already be free)."
    die "cvmfs_server ingest failed — see output above."
fi
