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

# ── Set library path for CVMFS binaries ───────────────────────────────────────
# cvmfs_talk (and cvmfs2) dlopen shared libs from SOFTWARE_ROOT, which is
# mounted at /opt/cvmfs-software.  The entrypoint sets LD_LIBRARY_PATH only
# for the cvmfs2 invocation; docker compose exec starts a fresh shell without
# it.  Export it here so cvmfs_talk can resolve libcvmfs_util.so et al.
export LD_LIBRARY_PATH="/opt/cvmfs-software${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# ── Locate the cvmfs_talk socket ──────────────────────────────────────────────
# cvmfs2 creates the socket at <workspace>/cvmfs_io.<repo>, where workspace is
# derived from CVMFS_CACHE_BASE (or CVMFS_CACHE_DIR) in the CVMFS config.
# The default config at /etc/cvmfs/default.local sets CVMFS_CACHE_BASE.
# cvmfs_talk -i <repo> reads the same config and constructs the same path.
#
# Try the most common path first, then fall back to letting cvmfs_talk discover
# the path itself via -i.
CVMFS_TALK=/usr/local/bin/cvmfs_talk

_cache_base="/var/cache/cvmfs"
_socket="${_cache_base}/${REPO_NAME}/cvmfs_io.${REPO_NAME}"

echo ""
echo "── CVMFS client diagnostics ──────────────────────────────────────────────────"
echo "  Repo:         ${REPO_NAME}"
echo "  Mount point:  ${MOUNT_POINT} (mounted: $(mountpoint -q "${MOUNT_POINT}" && echo yes || echo NO))"
echo "  Cache dir:    ${_cache_base}/${REPO_NAME}"
echo "  Socket path:  ${_socket}"
if [[ -S "$_socket" ]]; then
    echo -e "  Socket:       ${GREEN}exists${NC}"
else
    echo -e "  Socket:       ${RED}NOT FOUND${NC}"
    echo "  Contents of ${_cache_base}/${REPO_NAME}:"
    ls -la "${_cache_base}/${REPO_NAME}" 2>&1 | sed 's/^/    /'
    echo "  Contents of ${_cache_base}:"
    ls -la "${_cache_base}" 2>&1 | sed 's/^/    /'
fi

# Print revision BEFORE remount (reads CVMFS magic xattr from FUSE daemon).
_rev_before=$(getfattr -n user.revision --only-values "${MOUNT_POINT}" 2>/dev/null \
              || attr -qg revision "${MOUNT_POINT}" 2>/dev/null \
              || echo "unknown")
echo "  Revision before remount: ${_rev_before}"
echo ""

# ── Trigger client remount ────────────────────────────────────────────────────
# Try explicit socket path first (-p), then fall back to -i (auto-discovery).
echo "Triggering CVMFS client remount (cvmfs_talk remount sync)..."
_remount_ok=false

if [[ -S "$_socket" ]]; then
    if "$CVMFS_TALK" -p "$_socket" remount sync; then
        _remount_ok=true
        echo -e "  ${GREEN}Remount OK${NC} (via -p ${_socket})"
    else
        echo -e "  ${YELLOW}cvmfs_talk -p failed (exit $?) — trying -i fallback${NC}"
    fi
fi

if ! $_remount_ok; then
    if "$CVMFS_TALK" -i "${REPO_NAME}" remount sync; then
        _remount_ok=true
        echo -e "  ${GREEN}Remount OK${NC} (via -i ${REPO_NAME})"
    else
        echo -e "  ${RED}cvmfs_talk remount sync failed (exit $?)${NC}"
        echo "  Inspect debug log: /tmp/cvmfs-debug.log"
        tail -20 /tmp/cvmfs-debug.log 2>/dev/null | sed 's/^/    /' || true
    fi
fi

# Print revision AFTER remount.
_rev_after=$(getfattr -n user.revision --only-values "${MOUNT_POINT}" 2>/dev/null \
             || attr -qg revision "${MOUNT_POINT}" 2>/dev/null \
             || echo "unknown")
echo "  Revision after remount:  ${_rev_after}"
echo ""

# ── Check helpers ─────────────────────────────────────────────────────────────
BASE="${MOUNT_POINT}/${INGEST_BASE}"
PASS=0; FAIL=0

_ok()   { echo -e "  ${GREEN}OK  ${NC} $*"; PASS=$(( PASS + 1 )); }
_fail() { echo -e "  ${RED}FAIL${NC} $*"; FAIL=$(( FAIL + 1 )); }

# _wait_for <full_path>
# Blocks until the path exists (or a dangling symlink is present) or
# POLL_TIMEOUT expires.  Issues periodic remounts to pick up new catalog.
# Returns 0 on success, 1 on timeout.
_wait_for() {
    local full="$1"
    local _dl=$(( $(date +%s) + POLL_TIMEOUT ))
    local _nr=$(( $(date +%s) + 5 ))
    while [[ $(date +%s) -lt $_dl ]]; do
        # -e follows symlinks; also accept dangling symlinks via -L
        if [[ -e "$full" || -L "$full" ]]; then return 0; fi
        if [[ $(date +%s) -ge $_nr ]]; then
            _nr=$(( $(date +%s) + 5 ))
            if [[ -S "$_socket" ]]; then
                "$CVMFS_TALK" -p "$_socket" remount sync 2>/dev/null || true
            else
                "$CVMFS_TALK" -i "${REPO_NAME}" remount sync 2>/dev/null || true
            fi
        fi
        sleep 0.3
    done
    return 1
}

# _check_content <rel> <expected>
# Verifies exact file content.  Command substitution strips trailing newlines,
# which matches what 'echo "..."' in make-test-payload.sh produces.
_check_content() {
    local rel="$1" expected="$2"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    if [[ ! -f "$full" || -L "$full" ]]; then _fail "${rel}  not a regular file"; return; fi
    local actual rc=0
    actual=$(cat "$full" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then _fail "${rel}  read error (rc=${rc}): ${actual}"; return; fi
    if [[ "$actual" == "$expected" ]]; then
        _ok "${rel}  content"
    else
        _fail "${rel}  content: got $(printf '%q' "${actual:0:80}"), want $(printf '%q' "$expected")"
    fi
}

# _check_prefix <rel> <prefix>
# Verifies the file content starts with <prefix>.
# Used for timestamp-variable content (e.g. hello.txt includes a date).
_check_prefix() {
    local rel="$1" prefix="$2"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    if [[ ! -f "$full" || -L "$full" ]]; then _fail "${rel}  not a regular file"; return; fi
    local actual rc=0
    actual=$(cat "$full" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then _fail "${rel}  read error (rc=${rc}): ${actual}"; return; fi
    if [[ "$actual" == "${prefix}"* ]]; then
        _ok "${rel}  content prefix \"${prefix}\""
    else
        _fail "${rel}  wrong content prefix: got $(printf '%q' "${actual:0:60}")"
    fi
}

# _check_empty <rel>
# Verifies the file exists and has size 0.
_check_empty() {
    local rel="$1"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    local sz
    sz=$(stat -c %s "$full" 2>/dev/null) || { _fail "${rel}  stat failed"; return; }
    if [[ "$sz" -eq 0 ]]; then
        _ok "${rel}  empty (0 bytes)"
    else
        _fail "${rel}  expected 0 bytes, got ${sz}"
    fi
}

# _check_size <rel> <expected_bytes>
# Verifies the file size reported by stat (catalog field) AND by counting bytes
# read (all CAS chunks accessible).
_check_size() {
    local rel="$1" expected="$2"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    # Catalog size (fast path — reads inode from FUSE metadata).
    local sz
    sz=$(stat -c %s "$full" 2>/dev/null) || { _fail "${rel}  stat failed"; return; }
    if [[ "$sz" -ne "$expected" ]]; then
        _fail "${rel}  stat size: got ${sz}, want ${expected}"
        return
    fi
    # Read all bytes to exercise every CAS chunk (catches per-chunk quarantine).
    local read_sz rc=0
    read_sz=$(wc -c < "$full" 2>/dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        _fail "${rel}  read error while counting bytes (rc=${rc})"
        return
    fi
    # wc -c may pad with leading spaces; strip them.
    read_sz="${read_sz// /}"
    if [[ "$read_sz" -eq "$expected" ]]; then
        _ok "${rel}  size ${sz} bytes (all chunks readable)"
    else
        _fail "${rel}  bytes read: got ${read_sz}, want ${expected}"
    fi
}

# _check_mode <rel> <octal>
# Verifies UNIX permission bits, e.g. "755".
_check_mode() {
    local rel="$1" expected="$2"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    local mode
    mode=$(stat -c %a "$full" 2>/dev/null) || { _fail "${rel}  stat failed"; return; }
    if [[ "$mode" == "$expected" ]]; then
        _ok "${rel}  mode ${mode}"
    else
        _fail "${rel}  mode: got ${mode}, want ${expected}"
    fi
}

# _check_symlink <rel> <expected_target>
# Verifies the path is a symlink with the given target string.
_check_symlink() {
    local rel="$1" expected_target="$2"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    if [[ ! -L "$full" ]]; then _fail "${rel}  not a symlink"; return; fi
    local target
    target=$(readlink "$full") || { _fail "${rel}  readlink failed"; return; }
    if [[ "$target" == "$expected_target" ]]; then
        _ok "${rel}  → ${target}"
    else
        _fail "${rel}  symlink target: got $(printf '%q' "$target"), want $(printf '%q' "$expected_target")"
    fi
}

# _check_is_dir <rel>
_check_is_dir() {
    local rel="$1"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    if [[ -d "$full" ]]; then _ok "${rel}  is directory"
    else _fail "${rel}  not a directory"; fi
}

# _check_dir_empty <rel>
_check_dir_empty() {
    local rel="$1"
    local full="${BASE}/${rel}"
    if ! _wait_for "$full"; then _fail "${rel}  not found after ${POLL_TIMEOUT}s"; return; fi
    if [[ ! -d "$full" ]]; then _fail "${rel}  not a directory"; return; fi
    local count
    count=$(find "$full" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    count="${count// /}"
    if [[ "$count" -eq 0 ]]; then _ok "${rel}  empty directory"
    else _fail "${rel}  expected empty, found ${count} entries"; fi
}

# ── 1. simple/ ────────────────────────────────────────────────────────────────
echo "simple/"
_check_prefix  "simple/hello.txt"       "hello from cvmfs comprehensive test "
_check_empty   "simple/empty-file"
_check_content "simple/no-extension"    "no extension"
_check_content "simple/exec-script.sh"  $'#!/bin/sh\necho "I am executable"'
_check_mode    "simple/exec-script.sh"  "755"
echo ""

# ── 2. hierarchy/ ─────────────────────────────────────────────────────────────
echo "hierarchy/"
_d=""
for _depth in 1 2 3 4 5; do
    _d="${_d}${_d:+/}level${_depth}"
    _check_is_dir  "hierarchy/${_d}"
    _check_content "hierarchy/${_d}/file.txt"  "depth=${_depth}"
done
unset _d _depth
_check_is_dir   "hierarchy/level1/sibling-a"
_check_is_dir   "hierarchy/level1/sibling-b"
_check_content  "hierarchy/level1/sibling-a/data.txt"  "sibling-a content"
_check_content  "hierarchy/level1/sibling-b/data.txt"  "sibling-b content"
echo ""

# ── 3. links/ ─────────────────────────────────────────────────────────────────
echo "links/"
_SHARED="shared content — same hash expected in both catalog entries"
_check_content "links/original.txt"   "$_SHARED"
_check_content "links/duplicate.txt"  "$_SHARED"
# CAS deduplication: both files must have identical byte content.
_orig=$(cat "${BASE}/links/original.txt"  2>/dev/null || echo "READ_ERROR_orig")
_dup=$( cat "${BASE}/links/duplicate.txt" 2>/dev/null || echo "READ_ERROR_dup")
if [[ "$_orig" == "$_dup" && "$_orig" != "READ_ERROR_orig" ]]; then
    _ok "links/original.txt == links/duplicate.txt  (content identical — CAS dedup)"
else
    _fail "links/original.txt ≠ links/duplicate.txt  (CAS dedup content mismatch)"
fi
unset _orig _dup _SHARED
_check_symlink "links/rel-symlink-to-hello"  "../simple/hello.txt"
_check_symlink "links/dangling-symlink"       "../nonexistent-target"
echo ""

# ── 4. large/ (8 MiB, 2 CAS chunks) ─────────────────────────────────────────
echo "large/"
_check_size "large/large-8m.bin"  8388608
echo ""

# ── 5. permissions/ ───────────────────────────────────────────────────────────
echo "permissions/"
_check_content "permissions/world-readable.txt"   "world readable"
_check_mode    "permissions/world-readable.txt"   "644"
_check_content "permissions/owner-only.txt"       "owner only"
_check_mode    "permissions/owner-only.txt"       "600"
_check_content "permissions/readonly.txt"         "read only"
_check_mode    "permissions/readonly.txt"         "444"
_check_content "permissions/group-readable.txt"   "group readable"
_check_mode    "permissions/group-readable.txt"   "640"
_check_is_dir  "permissions/private-dir"
_check_mode    "permissions/private-dir"          "700"
_check_is_dir  "permissions/group-dir"
_check_mode    "permissions/group-dir"            "750"
echo ""

# ── 6. unusual-names/ ────────────────────────────────────────────────────────
echo "unusual-names/"
_check_content "unusual-names/file with spaces.txt"          "space"
_check_content "unusual-names/file  with  many  spaces.txt"  "multi-space"
_check_content "unusual-names/file[square-brackets].txt"     "brackets"
_check_content "unusual-names/file(parens-here).txt"         "parens"
_check_content "unusual-names/file#hash!bang.txt"            "hash-bang"
_check_content "unusual-names/file~tilde.txt"                "tilde"
_check_content "unusual-names/file,comma;semicolon.txt"      "punct"
_check_content "unusual-names/.hidden-dotfile"               "hidden"
_check_content "unusual-names/unicode-café.txt"              "cafe"
_check_content "unusual-names/unicode-résumé.txt"            "resume"
_check_content "unusual-names/unicode-日本語.txt"             "japanese"
_check_content "unusual-names/-not-a-flag.txt"               "dash"
_LONG="$(printf 'a%.0s' {1..200}).txt"   # 204-char name
_check_content "unusual-names/${_LONG}"                      "long name"
unset _LONG
echo ""

# ── 7. empty-dir/ ─────────────────────────────────────────────────────────────
echo "empty-dir/"
_check_is_dir   "empty-dir"
_check_dir_empty "empty-dir"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────────────────────────────────────────"
TOTAL=$(( PASS + FAIL ))
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All ${TOTAL} checks passed — ingest verified.${NC}"
    exit 0
else
    _rev_final=$(getfattr -n user.revision --only-values "${MOUNT_POINT}" 2>/dev/null \
                 || attr -qg revision "${MOUNT_POINT}" 2>/dev/null \
                 || echo "unknown")
    echo -e "${RED}${FAIL}/${TOTAL} check(s) failed.${NC}"
    echo ""
    echo "Diagnostics:"
    echo "  Catalog revision : ${_rev_final}"
    echo "  Mount point ls   :"
    ls -la "${MOUNT_POINT}" 2>&1 | sed 's/^/    /' | head -10
    echo "  INGEST_BASE ls   :"
    ls -la "${MOUNT_POINT}/${INGEST_BASE%%/*}" 2>&1 | sed 's/^/    /' | head -10
    echo "  debug log tail   :"
    tail -10 /tmp/cvmfs-debug.log 2>/dev/null | sed 's/^/    /' || echo "    (no debug log)"
    exit 1
fi
