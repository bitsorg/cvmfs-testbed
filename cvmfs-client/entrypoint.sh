#!/usr/bin/env bash
# entrypoint.sh — Configure and mount a CVMFS repository, then keep the
# container alive so verify-publish.sh can be exec'd into it on demand.
#
# Required environment variables:
#   REPO_NAME      – CVMFS repository domain, e.g. test.cvmfs.io
#   STRATUM0_URL   – URL of the Stratum 0 Apache endpoint, e.g. http://stratum0
#   PREPUB_URL     – cvmfs-prepub API base URL, e.g. http://cvmfs-prepub:8080
#   PREPUB_API_TOKEN – Bearer token for the cvmfs-prepub REST API
#
# The repository's public key is expected at /etc/cvmfs/keys/${REPO_NAME}.crt
# (mounted via TESTBED_ROOT/config/keys volume in docker-compose.yml).
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
: "${STRATUM0_URL:?STRATUM0_URL must be set}"

MOUNT_POINT="/cvmfs/${REPO_NAME}"

# ── Generate /etc/cvmfs/default.local ────────────────────────────────────────
# These settings mirror a minimal client config. CVMFS_SERVER_URL is the
# Stratum 0 endpoint; in a real deployment this would point to a Stratum 1
# proxy, but for testbed purposes direct S0 access is fine.
cat > /etc/cvmfs/default.local <<EOF
CVMFS_REPOSITORIES=${REPO_NAME}
CVMFS_HTTP_PROXY=DIRECT
CVMFS_CACHE_BASE=/var/cache/cvmfs
CVMFS_QUOTA_LIMIT=4000
EOF

# ── Generate per-repository configuration ────────────────────────────────────
cat > "/etc/cvmfs/config.d/${REPO_NAME}.conf" <<EOF
CVMFS_SERVER_URL=${STRATUM0_URL}/cvmfs/${REPO_NAME}
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${REPO_NAME}.crt
EOF

echo "[cvmfs-client] Generated client config for ${REPO_NAME}"

# ── Create mount point ────────────────────────────────────────────────────────
mkdir -p "${MOUNT_POINT}"

# ── Mount the repository ──────────────────────────────────────────────────────
# /usr/local/bin/cvmfs2 is injected from SOFTWARE_ROOT at container start.
# The -o allow_other flag lets the root-owned mount be accessible by exec.
echo "[cvmfs-client] Mounting ${REPO_NAME} at ${MOUNT_POINT}..."
/usr/local/bin/cvmfs2 \
    -o allow_other,config=/etc/cvmfs/default.local \
    "${REPO_NAME}" \
    "${MOUNT_POINT}"

echo "[cvmfs-client] Mounted. Waiting for commands (sleep infinity)."
echo "[cvmfs-client] Run: docker compose exec cvmfs-client verify-publish.sh <job_id> [path]"
exec sleep infinity
