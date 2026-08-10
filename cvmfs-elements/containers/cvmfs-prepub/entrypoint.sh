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

exec "$@"
