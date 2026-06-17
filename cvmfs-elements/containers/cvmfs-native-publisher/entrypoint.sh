#!/usr/bin/env bash
# entrypoint.sh — Pre-create spool directory for cvmfs_server ingest, then exec CMD.
#
# Required environment variable:
#   REPO_NAME  — CVMFS repository FQDN (e.g. test.cvmfs.io)
#
# cvmfs_server ingest (gateway mode) uses the per-repo spool directory at
# /var/spool/cvmfs/<repo>/ for transaction lock files and temporary staging.
# The directory must exist and be writable before the first ingest.
#
# /var/spool/cvmfs is bind-mounted from ${TESTBED_ROOT}/data/native-ingest
# (see docker-compose.yml), so the sub-directory is created here at startup
# rather than in init.sh so restarts with a fresh volume still work.
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

SPOOL_DIR="/var/spool/cvmfs/${REPO_NAME}"
mkdir -p "${SPOOL_DIR}"
chmod 755 "${SPOOL_DIR}"

# tmp/ sub-directory used as staging scratch for gateway-mode uploads.
mkdir -p "${SPOOL_DIR}/tmp"
chmod 755 "${SPOOL_DIR}/tmp"

# Remove any stale session_token and stats.db left by a previously crashed
# cvmfs_server ingest.  A leftover token causes the gateway to reject the next
# payload submission ("broken pipe" / "invalid token"), so always start clean.
rm -f "${SPOOL_DIR}/session_token" "${SPOOL_DIR}/stats.db"

echo "[native-publisher] Spool directory ready: ${SPOOL_DIR}"
echo "[native-publisher] Starting: $*"
exec "$@"
