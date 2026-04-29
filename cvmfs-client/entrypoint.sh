#!/usr/bin/env bash
# entrypoint.sh — Configure and mount a CVMFS repository, then keep the
# container alive so verify-publish.sh can be exec'd into it on demand.
#
# Required environment variables:
#   REPO_NAME        – CVMFS repository domain, e.g. test.cvmfs.io
#   STRATUM0_URL     – URL of the Stratum 0 Apache endpoint, e.g. http://stratum0
#   PREPUB_URL       – cvmfs-prepub API base URL (used by verify-publish.sh)
#   PREPUB_API_TOKEN – Bearer token for the cvmfs-prepub REST API
#
# The repository's public key is expected at /etc/cvmfs/keys/${REPO_NAME}.crt
# (mounted via TESTBED_ROOT/config/keys volume in docker-compose.yml).
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
: "${STRATUM0_URL:?STRATUM0_URL must be set}"

MOUNT_POINT="/cvmfs/${REPO_NAME}"

# ── Generate /etc/cvmfs/default.local ────────────────────────────────────────
cat > /etc/cvmfs/default.local <<EOF
CVMFS_REPOSITORIES=${REPO_NAME}
CVMFS_HTTP_PROXY=DIRECT
CVMFS_CACHE_BASE=/var/cache/cvmfs
CVMFS_QUOTA_LIMIT=4000
EOF

# ── Generate per-repository configuration ────────────────────────────────────
# config.d may not exist in the base image; create it defensively.
mkdir -p /etc/cvmfs/config.d
cat > "/etc/cvmfs/config.d/${REPO_NAME}.conf" <<EOF
CVMFS_SERVER_URL=${STRATUM0_URL}/cvmfs/${REPO_NAME}
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${REPO_NAME}.crt
EOF

echo "[cvmfs-client] Generated client config for ${REPO_NAME}"

# ── Verify injected binaries ──────────────────────────────────────────────────
for _bin in /usr/local/bin/cvmfs2 /usr/local/bin/cvmfs_talk; do
    if [[ ! -x "$_bin" ]]; then
        echo "[cvmfs-client] ERROR: $_bin is missing or not executable." >&2
        echo "[cvmfs-client] Ensure SOFTWARE_ROOT is set and binaries are copied." >&2
        exit 1
    fi
done

# ── Create mount point ────────────────────────────────────────────────────────
mkdir -p "${MOUNT_POINT}"

# ── Mount the repository ──────────────────────────────────────────────────────
# /usr/local/bin/cvmfs2 is injected from SOFTWARE_ROOT at container start.
# allow_other lets the root-owned FUSE mount be read by exec'd processes.
# Requires 'user_allow_other' in /etc/fuse.conf (set in the Dockerfile).
echo "[cvmfs-client] Mounting ${REPO_NAME} at ${MOUNT_POINT}..."
if ! /usr/local/bin/cvmfs2 \
        -o allow_other,config=/etc/cvmfs/default.local \
        "${REPO_NAME}" \
        "${MOUNT_POINT}"; then
    echo "[cvmfs-client] ERROR: cvmfs2 mount failed." >&2
    echo "[cvmfs-client] Check: SYS_ADMIN capability, /dev/fuse, and AppArmor." >&2
    exit 1
fi

echo "[cvmfs-client] Mounted. Waiting for commands (sleep infinity)."
echo "[cvmfs-client] Run: docker compose exec cvmfs-client verify-publish.sh <job_id> [path]"
exec sleep infinity
