#!/usr/bin/env bash
# verify-ingest.sh — Remount the CVMFS client and verify files published by
#                    native-smoke.sh are visible through the FUSE mount.
#
# Runs inside the cvmfs-client container (docker compose exec cvmfs-client).
# Called automatically by ./testbed.sh test --method ingest after the ingest
# completes.  Unlike verify-publish.sh (which follows an SSE event stream),
# the native ingest is synchronous: by the time this script is called the new
# manifest is already signed and served by stratum0.  We only need to tell
# the client to drop its cached manifest and re-read it.
#
# Environment:
#   REPO_NAME   — CVMFS repository FQDN (inherited from docker-compose.yml)
#   INGEST_BASE — Sub-path that was ingested (default: test/native/smoke)
#
# Exit codes:
#   0 — all expected files visible after remount
#   1 — one or more expected files not visible within the polling window
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
INGEST_BASE="${INGEST_BASE:-test/native/smoke}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

MOUNT_POINT="/cvmfs/${REPO_NAME}"
POLL_TIMEOUT=60   # seconds to wait for files to appear after remount

# ── Trigger client remount ────────────────────────────────────────────────────
# cvmfs_talk remount sync tells the FUSE daemon to:
#   1. Fetch the latest .cvmfspublished manifest from the server
#   2. Compare revision numbers; if newer, load the new root catalog
# Without this call, the daemon serves its in-memory cached catalog (which
# reflects the pre-ingest state) until the configured TTL expires (default 4 min).
echo ""
echo "Triggering CVMFS client remount (cvmfs_talk remount sync)..."
if /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null; then
    echo -e "  ${GREEN}Remount OK${NC}"
else
    echo -e "  ${YELLOW}cvmfs_talk remount sync returned non-zero — client may have already updated${NC}"
fi

# Print current revision so we can see the catalog advanced.
REVISION=$(attr -qg revision "${MOUNT_POINT}" 2>/dev/null || echo "unknown")
echo "  Catalog revision after remount: ${REVISION}"
echo ""

# ── Check expected paths ──────────────────────────────────────────────────────
# These paths are a representative sample of the payload built by make-test-payload.sh.
# If the ingest succeeded and the catalog advanced, all of these must be visible.
BASE="${MOUNT_POINT}/${INGEST_BASE}"
declare -a CHECK_PATHS=(
    "simple/hello.txt"
    "simple/empty-file"
    "simple/exec-script.sh"
    "links/original.txt"
    "links/rel-symlink-to-hello"
    "large/large-8m.bin"
    "unusual-names"
    "empty-dir"
    "hierarchy/level1/sibling-a"
)

echo "Checking expected paths under ${BASE} ..."
echo ""

FAILED=0
for rel in "${CHECK_PATHS[@]}"; do
    full="${BASE}/${rel}"
    # Poll: after a remount the FUSE daemon may still be loading the new catalog
    # shard for a nested path.  Retry for up to POLL_TIMEOUT seconds.
    _found=false
    _deadline=$(( $(date +%s) + POLL_TIMEOUT ))
    while [[ $(date +%s) -lt $_deadline ]]; do
        if [[ -e "$full" ]]; then
            _found=true
            break
        fi
        # Issue a periodic remount in case the first one raced with the publish.
        if (( $(date +%s) % 5 == 0 )); then
            /usr/local/bin/cvmfs_talk -i "${REPO_NAME}" remount sync 2>/dev/null || true
        fi
        sleep 0.5
    done
    if $_found; then
        echo -e "  ${GREEN}OK${NC}   ${rel}"
    else
        echo -e "  ${RED}MISS${NC} ${rel}"
        FAILED=$(( FAILED + 1 ))
    fi
done

echo ""
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All expected paths visible — ingest verified.${NC}"
    exit 0
else
    echo -e "${RED}${FAILED} path(s) not visible after ${POLL_TIMEOUT}s.${NC}"
    echo ""
    echo "Diagnostics:"
    echo "  Catalog revision : $(attr -qg revision "${MOUNT_POINT}" 2>/dev/null || echo 'unknown')"
    echo "  Mount point ls   : $(ls "${MOUNT_POINT}" 2>&1 | head -5)"
    echo "  INGEST_BASE ls   : $(ls "${MOUNT_POINT}/${INGEST_BASE%%/*}" 2>&1 | head -10)"
    echo "  Debug log        : $(tail -5 /tmp/cvmfs-debug.log 2>/dev/null || echo '(none)')"
    exit 1
fi
