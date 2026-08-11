#!/usr/bin/env bash
# entrypoint.sh — prepare cvmfs_server's spool, then exec cvmfs-prepub.
#
# cvmfs-prepub needs no setup itself. This exists only for the `ingest` publish
# path (--ingest-publish), where prepub shells out to `cvmfs_server ingest`.
# That command needs a per-repository spool directory at
# /var/spool/cvmfs/<repo>/ for its transaction lock files and staging scratch,
# and it does NOT create it. cvmfs-native-publisher's entrypoint does the same
# thing for the same reason; this mirrors it deliberately.
#
# REPO_NAME is OPTIONAL here, unlike in the native publisher. prepub serves
# whatever repositories jobs ask for and is perfectly usable with only the
# `prepub` publish path, so a missing REPO_NAME must not stop the service —
# it just means there is no spool to pre-create.
set -euo pipefail

if [[ -n "${REPO_NAME:-}" ]]; then
    SPOOL_DIR="/var/spool/cvmfs/${REPO_NAME}"
    if mkdir -p "${SPOOL_DIR}/tmp" 2>/dev/null; then
        chmod 755 "${SPOOL_DIR}" "${SPOOL_DIR}/tmp" 2>/dev/null || true

        # Drop state left by a crashed `cvmfs_server ingest`. A stale
        # session_token makes the gateway reject the next payload submission
        # ("invalid token" / "broken pipe"), and the failure looks like a
        # gateway problem rather than leftover local state.
        rm -f "${SPOOL_DIR}/session_token" "${SPOOL_DIR}/stats.db"
        echo "[prepub-entrypoint] spool ready: ${SPOOL_DIR}"
    else
        # Not fatal: the prepub publish path does not need this at all, and
        # failing here would take out a working service over an unused feature.
        echo "[prepub-entrypoint] WARN: cannot create ${SPOOL_DIR} —" \
             "the 'ingest' publish path will not work (prepub path unaffected)" >&2
    fi
else
    echo "[prepub-entrypoint] REPO_NAME unset — skipping spool setup" \
         "(only needed for the 'ingest' publish path)"
fi

# ── Optional: direct-to-S3 ingest (S3_DIRECT=1) ──────────────────────────────
# cvmfs_server_ingest.sh switches to direct upload purely on the EXISTENCE of
# /etc/cvmfs/<repo>.s3.conf:
#
#   if [ $mountless_gateway_ingest -eq 1 ] && [ -f "$s3_direct_config" ]; then
#       ingest_command="$ingest_command -3 $s3_direct_config"
#
# so the file must not be bind-mounted unconditionally — that would silently
# reroute every ingest publish to S3, and the objects would no longer be under
# repos/<repo> where stratum0's Apache serves them. Writing it here keeps the
# switch explicit and off by default.
if [[ "${S3_DIRECT:-0}" == "1" && -n "${REPO_NAME:-}" ]]; then
    if [[ -z "${MINIO_ROOT_USER:-}" || -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
        echo "[prepub-entrypoint] ERROR: S3_DIRECT=1 but MinIO credentials are unset" >&2
        exit 1
    fi
    s3_conf="/etc/cvmfs/${REPO_NAME}.s3.conf"
    mkdir -p /etc/cvmfs
    # DNS_BUCKETS=false: MinIO serves path-style (host/bucket), not
    # bucket.host virtual-host style.
    cat > "$s3_conf" <<EOF
CVMFS_S3_HOST=${S3_HOST:-minio}
CVMFS_S3_PORT=${S3_PORT:-9000}
CVMFS_S3_BUCKET=${S3_BUCKET:-cvmfs}
CVMFS_S3_ACCESS_KEY=${MINIO_ROOT_USER}
CVMFS_S3_SECRET_KEY=${MINIO_ROOT_PASSWORD}
CVMFS_S3_DNS_BUCKETS=false
CVMFS_S3_USE_HTTPS=false
CVMFS_S3_REGION=${S3_REGION:-us-east-1}
CVMFS_S3_MAX_NUMBER_OF_PARALLEL_CONNECTIONS=${S3_PARALLEL:-16}
EOF
    chmod 600 "$s3_conf"
    echo "[prepub-entrypoint] S3_DIRECT=1 — wrote ${s3_conf};" \
         "'cvmfs_server ingest' will add -3 and bypass the gateway for data"
else
    # Remove a file left by a previous S3_DIRECT=1 run, so turning the switch
    # off actually turns it off.
    rm -f "/etc/cvmfs/${REPO_NAME:-__none__}.s3.conf"
fi

exec "$@"
