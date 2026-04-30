#!/usr/bin/env bash
# entrypoint.sh — Pre-create required spool paths, then exec cvmfs_gateway.
#
# Required environment variable:
#   REPO_NAME  — CVMFS repository FQDN (e.g. test.cvmfs.io)
#
# cvmfs_receiver requires these paths to exist at run time:
#
#   /var/spool/cvmfs/<repo>/client.local
#     Truncated to zero by commit_processor.cc to invalidate client caches.
#     The call is:  truncate(client_local.c_str(), 0)
#     If the file does not exist, truncate() returns ENOENT → kError reply.
#
#   /var/spool/cvmfs/<repo>/reflog.chksum
#     Read (and possibly updated) by the SigningTool during commit.
#     Missing file → kMissingReflog reply, which counts as a commit failure.
#
#   /srv/cvmfs/<repo>/upstream-scratch/
#     Scratch directory used by LocalUploader for in-flight chunk temp files.
#     MUST be under /srv/cvmfs/<repo>/ (the CAS bind-mount), NOT under
#     /var/spool/cvmfs, so that rename(scratch→data/XY/hash) stays on the
#     same filesystem and does not fail with EXDEV (errno 18).
#
# These files are created by `cvmfs_server mkfs` on the host, but inside the
# gateway container they don't exist unless we create them here (because
# /var/spool/cvmfs is either a fresh overlay-FS layer or a freshly-mounted
# host directory).
#
# NOTE: /var/spool/cvmfs is mounted as a host volume (see docker-compose.yml)
#       so these files persist between restarts and are readable from the host
#       for debugging.
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"

SPOOL_ROOT="/var/spool/cvmfs"
SPOOL_DIR="${SPOOL_ROOT}/${REPO_NAME}"

# CAS root is mounted at /srv/cvmfs/<repo> (docker-compose.yml).
# upstream-scratch lives here (NOT under /var/spool/cvmfs) so that
# LocalUploader::FinalizeStreamedUpload rename(scratch→data/XY/hash) stays
# on the same bind-mount and does not fail with EXDEV (errno 18).
CAS_ROOT="/srv/cvmfs/${REPO_NAME}"
SCRATCH_DIR="${CAS_ROOT}/upstream-scratch"

echo "[gateway-entrypoint] Ensuring spool layout for ${REPO_NAME} ..."

# Create the per-repo spool directory tree (/var/spool/cvmfs/<repo>).
# NOTE: upstream-scratch is no longer here — see SCRATCH_DIR below.
mkdir -p "${SPOOL_DIR}"
chmod 755 "${SPOOL_DIR}"

# Create the upstream-scratch dir under the CAS root so rename() works.
if [[ -d "${CAS_ROOT}" ]]; then
    mkdir -p "${SCRATCH_DIR}"
    chmod 755 "${SCRATCH_DIR}"
    echo "[gateway-entrypoint] Created ${SCRATCH_DIR}"
else
    echo "[gateway-entrypoint] WARNING: CAS root ${CAS_ROOT} not found — scratch dir not created."
    echo "[gateway-entrypoint]   Ensure ${REPO_NAME} is mounted at ${CAS_ROOT} in docker-compose.yml"
fi

# client.local — must exist so truncate() in commit_processor.cc succeeds.
if [[ ! -f "${SPOOL_DIR}/client.local" ]]; then
    touch "${SPOOL_DIR}/client.local"
    echo "[gateway-entrypoint] Created ${SPOOL_DIR}/client.local"
else
    echo "[gateway-entrypoint] ${SPOOL_DIR}/client.local already exists"
fi

# reflog.chksum — must exist for the signing tool at commit time.
# The file should contain the hash written by cvmfs_server mkfs.
# init.sh copies the real file from the host spool into the mounted volume;
# this fallback handles the case where init.sh did not populate it.
if [[ ! -f "${SPOOL_DIR}/reflog.chksum" ]]; then
    touch "${SPOOL_DIR}/reflog.chksum"
    echo "[gateway-entrypoint] Created empty ${SPOOL_DIR}/reflog.chksum (stub — commit may fail)"
    echo "[gateway-entrypoint] To fix: copy /var/spool/cvmfs/${REPO_NAME}/reflog.chksum from the host into"
    echo "[gateway-entrypoint]   \${TESTBED_ROOT}/data/gateway-spool/${REPO_NAME}/reflog.chksum"
else
    echo "[gateway-entrypoint] ${SPOOL_DIR}/reflog.chksum already exists"
fi

echo "[gateway-entrypoint] Spool setup done. Starting: $*"
exec "$@"
