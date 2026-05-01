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

echo "[native-publisher] Spool directory ready: ${SPOOL_DIR}"
echo "[native-publisher] Starting: $*"
exec "$@"
