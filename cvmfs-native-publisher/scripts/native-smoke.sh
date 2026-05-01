#!/usr/bin/env bash
# native-smoke.sh — Comprehensive smoke test via cvmfs_server ingest.
#
# Publishes a rich test payload to test/native/smoke using the native CVMFS
# gateway workflow (cvmfs_server ingest → cvmfs_swissknife → gateway API →
# cvmfs_receiver → signed manifest).
#
# The payload (built by make-test-payload.sh) exercises catalog corner cases:
#   directory hierarchy, symlinks, large file (chunking), unusual file names
#   (spaces, unicode, special chars), permission modes, empty dirs.
#
# Compare against publisher/scripts/smoke-test.sh which uses the cvmfs-bits
# (cvmfs-prepub) REST API path — both use the same payload for a fair comparison.
#
# Environment:
#   REPO_NAME    — CVMFS repository FQDN (e.g. test.cvmfs.io)  [required]
#   INGEST_BASE  — Base path within the repo (default: test/native/smoke)
#
# Lease path note:
#   cvmfs_server ingest requires the gateway lease path to be an existing
#   nested catalog root.  A freshly created repository has only the root
#   catalog, so leasing a sub-path panics on commit with "catalog for
#   directory '/<path>' cannot be found".
#   Fix: repackage the payload so every entry is prefixed with INGEST_BASE/,
#   then ingest at root (no -b flag).  The content still lands at the correct
#   location in the repository.
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

INGEST_BASE="${INGEST_BASE:-test/native/smoke}"

# ── Build comprehensive test payload ───────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "Building comprehensive test payload..."
bash /scripts/make-test-payload.sh "$WORK_DIR"

PAYLOAD_DIR="$WORK_DIR/payload"

# ── Repackage: prefix all entries with INGEST_BASE/ ───────────────────────────
# We ingest at root (no -b flag) so the gateway receiver modifies the root
# catalog — the only catalog that is guaranteed to exist in a fresh repo.
# The desired sub-path is baked into the tar structure instead.
PREFIXED_DIR="$WORK_DIR/prefixed"
mkdir -p "$PREFIXED_DIR/$INGEST_BASE"
cp -a "$PAYLOAD_DIR/." "$PREFIXED_DIR/$INGEST_BASE/"

FINAL_TAR="$WORK_DIR/payload-final.tar"
tar \
    --create \
    --file="$FINAL_TAR" \
    --directory="$PREFIXED_DIR" \
    --hard-dereference \
    --preserve-permissions \
    .

echo ""
echo "Ingesting to ${REPO_NAME}:/ (content at ${INGEST_BASE}/) ..."
echo "  Tar size: $(du -sh "$FINAL_TAR" | cut -f1)"

# ── Run native ingest ──────────────────────────────────────────────────────────
# cvmfs_server ingest is synchronous: acquires a gateway lease, builds the
# catalog via cvmfs_swissknife, commits via the gateway receiver, returns
# when the repository manifest has been updated and signed.
#
# No -b flag → lease and ingest at repository root (root catalog).
if cvmfs_server ingest \
        -t "${FINAL_TAR}" \
        "${REPO_NAME}"; then
    echo ""
    echo -e "${GREEN}Native ingest complete${NC}"
    echo ""
    echo "Expected paths (sample):"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/simple/hello.txt"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/large/large-8m.bin"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/links/rel-symlink-to-hello"
    echo "  /cvmfs/${REPO_NAME}/${INGEST_BASE}/unusual-names/unicode-日本語.txt"
    exit 0
else
    echo ""
    echo -e "${RED}Native ingest failed${NC}"
    exit 1
fi
