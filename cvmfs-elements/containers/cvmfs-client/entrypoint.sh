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
# The repository's master public key is expected at /etc/cvmfs/keys/${REPO_NAME}.pub
# (mounted via TESTBED_ROOT/config/keys volume in docker-compose.yml).
# NOTE: CVMFS_PUBLIC_KEY must point to the RSA master public key (.pub), NOT the
# X.509 signing certificate (.crt). The .pub key is used to verify the whitelist
# signature and manifest; using .crt causes error 16 (catalog failure).
set -euo pipefail

: "${REPO_NAME:?REPO_NAME must be set}"
: "${STRATUM0_URL:?STRATUM0_URL must be set}"

MOUNT_POINT="/cvmfs/${REPO_NAME}"

# ── Generate /etc/cvmfs/default.local ────────────────────────────────────────
# Include ALL required settings in default.local (the file explicitly passed
# to cvmfs2 via -o config=).  This avoids relying on cvmfs2 auto-loading the
# config.d/ per-repo file, which behaviour varies across CVMFS versions.
cat > /etc/cvmfs/default.local <<EOF
CVMFS_REPOSITORIES=${REPO_NAME}
CVMFS_HTTP_PROXY=DIRECT
CVMFS_CACHE_BASE=/var/cache/cvmfs
CVMFS_QUOTA_LIMIT=4000
# Per-repo settings (valid in default.local for a single-repo testbed):
CVMFS_SERVER_URL=${STRATUM0_URL}/cvmfs/${REPO_NAME}
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${REPO_NAME}.pub
# Write a debug log so we can diagnose mount failures:
CVMFS_DEBUGLOG=/tmp/cvmfs-debug.log
# Testbed freshness: check for a new root catalog every 10 s instead of the
# repository default 240 s. CVMFS_MAX_TTL_SECS caps the effective TTL
# client-side — min(max_ttl, catalog TTL), no floor (mountpoint.cc,
# GetEffectiveTtlSec) — which is the ONLY reliable knob on this testbed:
# server-side CVMFS_REPOSITORY_TTL is not honored by any publish path here
# (cvmfs_server ingest never passes -T, and the gateway receiver rebuilds the
# root catalog without copying the publisher's TTL property), so the served
# catalogs always carry the 240 s default.
CVMFS_MAX_TTL_SECS=10
# Drain kernel dentry/attr caches on the same scale (default 60 s) — this is
# also the drainout wait for forced remounts on the no-notify-inval fallback
# path (kcache+1 s). Worst-case passive visibility of a publish is roughly
# CVMFS_MAX_TTL_SECS + this value; cvmfs_talk remount sync remains the
# immediate option for scripts.
CVMFS_KCACHE_TIMEOUT=10
EOF

# ── Generate per-repository configuration ────────────────────────────────────
# Also write the per-repo config.d file as a belt-and-suspenders measure.
# config.d may not exist in the base image; create it defensively.
mkdir -p /etc/cvmfs/config.d
cat > "/etc/cvmfs/config.d/${REPO_NAME}.conf" <<EOF
CVMFS_SERVER_URL=${STRATUM0_URL}/cvmfs/${REPO_NAME}
CVMFS_PUBLIC_KEY=/etc/cvmfs/keys/${REPO_NAME}.pub
EOF

echo "[cvmfs-client] Generated client config for ${REPO_NAME}"

# ── Link CVMFS stub libraries into /usr/lib ───────────────────────────────────
# cvmfs2 dlopen()s the FUSE stub using hardcoded absolute paths:
#   ./libcvmfs_fuse3_stub.so  →  /usr/lib/libcvmfs_fuse3_stub.so  →  /usr/lib64/...
# (and the FUSE2 fallback equivalents).
# SOFTWARE_ROOT is mounted read-only at /opt/cvmfs-software.
# Symlink the stubs into /usr/lib/ so cvmfs2 finds them at those exact paths.
#
# The stub itself depends on libfuse3.so.N (N = soname on the build host).
# That library is NOT resolved via dlopen absolute path — it goes through the
# normal dynamic linker.  Rather than running ldconfig at runtime (which would
# require updating the on-disk cache), we pass LD_LIBRARY_PATH=/opt/cvmfs-software
# to the cvmfs2 invocation below so the linker finds it there directly.
if [[ -d /opt/cvmfs-software ]]; then
    for _lib in /opt/cvmfs-software/libcvmfs_fuse*.so*; do
        [[ -f "$_lib" ]] || continue
        _name="$(basename "$_lib")"
        if [[ ! -e "/usr/lib/$_name" ]]; then
            ln -s "$_lib" "/usr/lib/$_name"
            echo "[cvmfs-client] linked stub: $_name → /usr/lib/$_name"
        fi
    done
else
    echo "[cvmfs-client] WARNING: /opt/cvmfs-software not mounted — stub libs missing" >&2
fi

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

# ── Wait for Stratum 0 to be ready ───────────────────────────────────────────
# The stratum0 Apache container starts concurrently.  Poll the manifest URL
# until it responds 200 (or until CVMFS_WAIT_TIMEOUT seconds elapse).
CVMFS_WAIT_TIMEOUT="${CVMFS_WAIT_TIMEOUT:-60}"
_manifest_url="${STRATUM0_URL}/cvmfs/${REPO_NAME}/.cvmfspublished"
echo "[cvmfs-client] Waiting for stratum0 to serve ${_manifest_url} ..."
_deadline=$(( $(date +%s) + CVMFS_WAIT_TIMEOUT ))
while true; do
    _http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 3 "${_manifest_url}" 2>/dev/null || true)
    if [[ "$_http_code" == "200" ]]; then
        echo "[cvmfs-client] Stratum 0 is ready (HTTP 200)."
        break
    fi
    if [[ $(date +%s) -ge $_deadline ]]; then
        echo "[cvmfs-client] ERROR: Stratum 0 not ready after ${CVMFS_WAIT_TIMEOUT}s (last HTTP ${_http_code:-???})." >&2
        echo "[cvmfs-client] URL: ${_manifest_url}" >&2
        exit 1
    fi
    echo "[cvmfs-client] Stratum 0 not ready yet (HTTP ${_http_code:-???}), retrying in 2s..."
    sleep 2
done

# ── Verify public key is present and readable ─────────────────────────────────
_pubkey="/etc/cvmfs/keys/${REPO_NAME}.pub"
if [[ ! -f "$_pubkey" ]]; then
    echo "[cvmfs-client] ERROR: Public key not found at ${_pubkey}." >&2
    echo "[cvmfs-client] Check that ${REPO_NAME}.pub exists in \$TESTBED_ROOT/config/keys/" >&2
    echo "[cvmfs-client] and that the volume mount in docker-compose.yml is correct." >&2
    ls -la /etc/cvmfs/keys/ 2>/dev/null || true
    exit 1
fi
echo "[cvmfs-client] Public key: ${_pubkey} ($(wc -c < "$_pubkey") bytes)"

# ── Mount the repository ──────────────────────────────────────────────────────
# /usr/local/bin/cvmfs2 is injected from SOFTWARE_ROOT at container start.
# allow_other lets the root-owned FUSE mount be read by exec'd processes.
# Requires 'user_allow_other' in /etc/fuse.conf (set in the Dockerfile).
# Retry up to 3 times in case of transient failures (e.g. catalog not yet
# available on the first attempt).
echo "[cvmfs-client] Mounting ${REPO_NAME} at ${MOUNT_POINT}..."
_mount_ok=false
for _attempt in 1 2 3; do
    # LD_LIBRARY_PATH=/opt/cvmfs-software lets the dynamic linker resolve
    # libfuse3.so.N (bundled by install.sh) without needing ldconfig.
    if LD_LIBRARY_PATH=/opt/cvmfs-software${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}} \
            /usr/local/bin/cvmfs2 \
            -o allow_other,config=/etc/cvmfs/default.local \
            "${REPO_NAME}" \
            "${MOUNT_POINT}"; then
        _mount_ok=true
        break
    fi
    if [[ $_attempt -lt 3 ]]; then
        echo "[cvmfs-client] Mount attempt ${_attempt} failed, retrying in 3s..." >&2
        sleep 3
    fi
done
if ! $_mount_ok; then
    echo "[cvmfs-client] ERROR: cvmfs2 mount failed after 3 attempts." >&2
    echo "[cvmfs-client] Check: SYS_ADMIN capability, /dev/fuse, and AppArmor." >&2
    echo "[cvmfs-client] --- generated config ---" >&2
    cat "/etc/cvmfs/config.d/${REPO_NAME}.conf" >&2 || true
    cat /etc/cvmfs/default.local >&2 || true
    echo "[cvmfs-client] --- key files in /etc/cvmfs/keys/ ---" >&2
    ls -la /etc/cvmfs/keys/ >&2 || true
    echo "[cvmfs-client] --- cvmfs2 debug log (/tmp/cvmfs-debug.log) ---" >&2
    cat /tmp/cvmfs-debug.log >&2 || echo "[cvmfs-client] (no debug log found)" >&2
    exit 1
fi

echo "[cvmfs-client] Mounted. Waiting for commands (sleep infinity)."
echo "[cvmfs-client] Run: docker compose exec cvmfs-client verify-publish.sh <job_id> [path]"
exec sleep infinity
