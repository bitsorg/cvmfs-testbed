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

# ── S3 capability for direct-to-S3 ingest (S3_ENABLED=1) ─────────────────────
# This writes the S3 CONFIG. It does not decide anything.
#
# cvmfs_server enables direct-to-S3 only on --direct-s3 (or
# CVMFS_INGEST_DIRECT_S3=true) and then reads its settings from
# /etc/cvmfs/<repo>.s3.conf. The file's presence is NOT a switch -- that was an
# early prototype, and building the testbed around it meant publishes ran
# through the gateway while looking like they used S3.
#
# Because prepub now takes --direct-s3 PER JOB, the config has to be present all
# the time: any build may ask for it, and requiring a restart to make it usable
# would defeat choosing per build. So this is a capability, not a mode.
#
# S3_ENABLED stays the outermost test, so withdrawing the capability still
# withdraws it.  Checking the provisioned file first would make the cleanup
# branch unreachable whenever init.sh had written one — and it writes it
# whenever credentials exist, independently of S3_ENABLED — so `make s3-off`
# would stop MinIO but leave a usable-looking config behind, turning an
# immediate "S3 config does not exist" into a connection failure deep inside a
# publish.
if [[ "${S3_ENABLED:-0}" == "1" ]]; then
  # A canonical config provisioned by init.sh (mounted read-only at the path in
  # CVMFS_INGEST_DIRECT_S3_CONFIG) wins over anything written here: the gateway
  # receiver reads that same file when the repository's upstream is S3, and a
  # second copy generated per container is how prepub, the receiver and the
  # native publisher would come to disagree about which bucket the repository
  # lives in.  Writing our own is the fallback for deployments without one.
  if [[ -n "${CVMFS_INGEST_DIRECT_S3_CONFIG:-}" && -e "${CVMFS_INGEST_DIRECT_S3_CONFIG}" ]]; then
    # -e then -r, not -r alone: an existing but unreadable file must fail loudly
    # rather than silently fall through to a per-container copy, which is
    # exactly the divergence this is meant to prevent.
    if [[ ! -r "${CVMFS_INGEST_DIRECT_S3_CONFIG}" ]]; then
        echo "[prepub-entrypoint] ERROR: provisioned S3 config" \
             "${CVMFS_INGEST_DIRECT_S3_CONFIG} exists but is not readable by" \
             "$(id -un) (uid $(id -u)). Fix its permissions on the host —" \
             "falling back to a private copy would let this container publish" \
             "to a different bucket than the gateway receiver commits to." >&2
        exit 1
    fi
    echo "[prepub-entrypoint] Using provisioned S3 config:" \
         "${CVMFS_INGEST_DIRECT_S3_CONFIG} (not writing a per-container copy)."
  else
    if [[ -z "${REPO_NAME:-}" ]]; then
        echo "[prepub-entrypoint] ERROR: S3_ENABLED=1 but REPO_NAME is unset —" \
             "the config path is /etc/cvmfs/<repo>.s3.conf, so there is nothing" \
             "to write and any build asking for --direct-s3 would fail." >&2
        exit 1
    fi
    if [[ -z "${MINIO_ROOT_USER:-}" || -z "${MINIO_ROOT_PASSWORD:-}" ]]; then
        echo "[prepub-entrypoint] ERROR: S3_ENABLED=1 but MinIO credentials are unset" >&2
        exit 1
    fi

    # CVMFS parses this file by SOURCING it — BashOptionsManager::ParsePath
    # opens a real shell and feeds it every line — so an unquoted value with $,
    # backticks or # is expanded, truncated, or executed as the publishing user.
    # Single-quote everything, escaping embedded quotes the POSIX way.
    sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

    s3_conf="/etc/cvmfs/${REPO_NAME}.s3.conf"
    mkdir -p /etc/cvmfs 2>/dev/null || true
    # Braces so the redirection failure is silenced too: `! : > f 2>/dev/null`
    # applies redirections left to right, so the shell's own "Permission denied"
    # reaches the terminal before stderr is closed off.
    if ! { : > "$s3_conf"; } 2>/dev/null; then
        echo "[prepub-entrypoint] ERROR: cannot write ${s3_conf} —" \
             "this container runs as an unprivileged user and /etc/cvmfs is" \
             "root-owned. The image must grant it write access." >&2
        exit 1
    fi
    # 077 while the file is written: the credentials must never exist on disk
    # world-readable, not even for the moment between create and chmod.
    ( umask 077
      # DNS_BUCKETS=false: MinIO serves path-style (host/bucket), not
      # bucket.host virtual-host style.
      cat > "$s3_conf" <<EOF
CVMFS_S3_HOST=$(sq "${S3_HOST:-minio}")
CVMFS_S3_PORT=$(sq "${S3_PORT:-9000}")
CVMFS_S3_BUCKET=$(sq "${S3_BUCKET:-cvmfs}")
CVMFS_S3_ACCESS_KEY=$(sq "${MINIO_ROOT_USER}")
CVMFS_S3_SECRET_KEY=$(sq "${MINIO_ROOT_PASSWORD}")
CVMFS_S3_DNS_BUCKETS=false
CVMFS_S3_USE_HTTPS=false
CVMFS_S3_REGION=$(sq "${S3_REGION:-us-east-1}")
CVMFS_S3_MAX_NUMBER_OF_PARALLEL_CONNECTIONS=$(sq "${S3_PARALLEL:-16}")
EOF
    )
    chmod 600 "$s3_conf"
    # Point cvmfs_server at the copy we just wrote.  Compose sets
    # CVMFS_INGEST_DIRECT_S3_CONFIG unconditionally, and cvmfs_server_ingest.sh
    # honours it over the conventional /etc/cvmfs/<repo>.s3.conf and aborts the
    # publish if it does not exist — so without this, reaching the fallback
    # branch means every direct_s3 job dies with "S3 config does not exist"
    # while a perfectly good config sits at the conventional path.
    export CVMFS_INGEST_DIRECT_S3_CONFIG="$s3_conf"
    echo "[prepub-entrypoint] S3 capability ready: ${s3_conf}." \
         "Builds submitted with direct_s3=true will bypass the gateway for data;" \
         "others are unaffected."
  fi
else
    # Withdrawing the capability must actually withdraw it, so clear the pointer
    # as well as the file: a build asking for direct_s3 should fail immediately
    # with "S3 config does not exist" rather than later, inside a publish,
    # against a MinIO that is no longer running.
    unset CVMFS_INGEST_DIRECT_S3_CONFIG
    # Remove a config left by a previous S3_ENABLED=1 run, so withdrawing the
    # capability actually withdraws it: a stale file would let a build request
    # --direct-s3 and point cvmfs_server at credentials for a MinIO that is no
    # longer running.
    #
    # Best-effort on purpose: this container runs unprivileged and /etc/cvmfs is
    # root-owned, so removing a file that IS present fails with EACCES, and
    # under `set -e` that would take the service down.
    #
    # (An earlier commit message blamed this line for a startup failure. It was
    # wrong: the failure was the heredoc in the capability branch above, and
    # `rm -f` on a MISSING file in an unwritable directory returns 0. Hardening
    # both branches was still right.)
    rm -f "/etc/cvmfs/${REPO_NAME:-__none__}.s3.conf" 2>/dev/null || true
fi

exec "$@"
