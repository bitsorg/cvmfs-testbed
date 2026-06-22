#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0

# upload-filelist.sh — Bulk-upload .tar.gz files to CVMFS via the bits REST API.
#
# Reads a filelist (one path per line), extracts each .tar.gz to a temp
# directory, repackages it as a plain (uncompressed) tar — which is the format
# cvmfs-prepub expects — and submits it to the prepub API.  Jobs run with
# bounded concurrency: up to --concurrency uploads are in flight simultaneously.
#
# Runs on the HOST (not inside a Docker container).
#
# Usage:
#   bash upload-filelist.sh [options]
#
# Options:
#   --filelist   <path>  Path to filelist (default: first of
#                        $TESTBED_ROOT/data/filelist.txt or ./filelist.txt)
#   --concurrency <n>    Max parallel in-flight uploads (default: 2)
#   --ingest-path <p>    Repository sub-path prefix (default: upload)
#   --prepub-url  <u>    cvmfs-prepub base URL  (default: $PREPUB_URL or
#                        http://localhost:8080)
#   --repo        <r>    CVMFS repo FQDN (default: $REPO_NAME)
#   --token       <t>    API bearer token (default: $PREPUB_API_TOKEN)
#   --run-log     <f>    NDJSON log file  (default: $RUN_LOG_FILE or
#                        $TESTBED_ROOT/data/runs.ndjson)
#
# The filelist may contain blank lines and lines beginning with '#' (comments).
# Paths are resolved relative to the directory that contains the filelist file.
#
# Exit codes:
#   0 — all files uploaded successfully
#   1 — one or more uploads failed (summary printed at end)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBED_DIR="$(dirname "$SCRIPT_DIR")"   # root of the cvmfs-testbed checkout
DEFAULT_SCAN_DIR="/home/pbuncic/Software/Bits/sw-lhcb/TARS"
SCAN_DIR=""       # set by --dir; takes precedence over --filelist
FILELIST=""       # set by --filelist (fallback when no --dir)
CONCURRENCY=4
INGEST_PATH=""     # resolved below: "pkg" for ingest, "upload" for bits
RECURSIVE=true
PUBLISH_METHOD="bits"   # bits | ingest
PREPUB_URL_ARG=""
REPO_ARG=""
TOKEN_ARG=""
RUN_LOG_ARG=""
JOB_LOG_ARG=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)          SCAN_DIR="$2";       shift 2 ;;
        --dir=*)        SCAN_DIR="${1#*=}";  shift   ;;
        --filelist)     FILELIST="$2";       shift 2 ;;
        --filelist=*)   FILELIST="${1#*=}";  shift   ;;
        --concurrency)  CONCURRENCY="$2";   shift 2 ;;
        --concurrency=*)CONCURRENCY="${1#*=}"; shift ;;
        --ingest-path)  INGEST_PATH="$2";   shift 2 ;;
        --ingest-path=*)INGEST_PATH="${1#*=}"; shift ;;
        --no-recursive) RECURSIVE=false;    shift   ;;
        --method)       PUBLISH_METHOD="$2"; shift 2 ;;
        --method=*)     PUBLISH_METHOD="${1#*=}"; shift ;;
        --prepub-url)   PREPUB_URL_ARG="$2";shift 2 ;;
        --prepub-url=*) PREPUB_URL_ARG="${1#*=}"; shift ;;
        --repo)         REPO_ARG="$2";      shift 2 ;;
        --repo=*)       REPO_ARG="${1#*=}"; shift   ;;
        --token)        TOKEN_ARG="$2";     shift 2 ;;
        --token=*)      TOKEN_ARG="${1#*=}"; shift  ;;
        --run-log)      RUN_LOG_ARG="$2";   shift 2 ;;
        --run-log=*)    RUN_LOG_ARG="${1#*=}"; shift ;;
        --job-log)      JOB_LOG_ARG="$2";   shift 2 ;;
        --job-log=*)    JOB_LOG_ARG="${1#*=}"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ "$PUBLISH_METHOD" == "bits" || "$PUBLISH_METHOD" == "ingest" ]] \
    || { echo "ERROR: --method must be 'bits' or 'ingest'" >&2; exit 1; }

# Method-specific INGEST_PATH defaults (bits → upload, ingest → pkg)
# 'pkg' avoids conflicts with bits-published nested catalogs in 'upload/'
if [[ -z "$INGEST_PATH" ]]; then
    [[ "$PUBLISH_METHOD" == "ingest" ]] && INGEST_PATH="pkg" || INGEST_PATH="upload"
fi

# For ingest method, INGEST_PATH must be a single directory component (no /)
# because it is used as the gateway lease base in the Phase 1 seed step.
if [[ "$PUBLISH_METHOD" == "ingest" && "$INGEST_PATH" == */* ]]; then
    echo -e "${RED}ERROR${NC}: --ingest-path must be a single path component for ingest method (no '/'). Got: '${INGEST_PATH}'" >&2
    exit 1
fi

# ── Source .env for credentials / repo name ───────────────────────────────────
ENV_FILE="${TESTBED_ROOT:-$HOME/cvmfs-testbed}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a; source "$ENV_FILE"; set +a
fi

# CLI args override .env
[[ -n "$PREPUB_URL_ARG" ]] && PREPUB_URL="$PREPUB_URL_ARG"
[[ -n "$REPO_ARG"       ]] && REPO_NAME="$REPO_ARG"
[[ -n "$TOKEN_ARG"      ]] && PREPUB_API_TOKEN="$TOKEN_ARG"
[[ -n "$RUN_LOG_ARG"    ]] && RUN_LOG_FILE="$RUN_LOG_ARG"
[[ -n "$JOB_LOG_ARG"    ]] && JOB_LOG_FILE="$JOB_LOG_ARG"

PREPUB_URL="${PREPUB_URL:-http://localhost:8080}"
RUN_LOG_FILE="${RUN_LOG_FILE:-${TESTBED_ROOT:-$HOME/cvmfs-testbed}/data/runs.ndjson}"
JOB_LOG_FILE="${JOB_LOG_FILE:-${TESTBED_ROOT:-$HOME/cvmfs-testbed}/data/ingest-jobs.ndjson}"
COMPOSE_FILE="${TESTBED_DIR}/docker-compose.yml"

# ── Scratch directory ─────────────────────────────────────────────────────────
# Use a subdirectory of $TESTBED_ROOT so temp files land on the same filesystem
# as the container volumes (not on /tmp which is often a small tmpfs/RAM disk).
# Each run gets its own timestamped sub-directory; it is removed on exit.
SCRATCH_BASE="${TESTBED_ROOT:-$HOME/cvmfs-testbed}/tmp"
mkdir -p "$SCRATCH_BASE"
SCRATCH_DIR="$(mktemp -d "${SCRATCH_BASE}/run-XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

if [[ "$PUBLISH_METHOD" == "bits" ]] && [[ -z "${PREPUB_API_TOKEN:-}" ]]; then
    echo -e "${RED}ERROR${NC}: PREPUB_API_TOKEN not set. Source .env or pass --token." >&2
    exit 1
fi
if [[ -z "${REPO_NAME:-}" ]]; then
    echo -e "${RED}ERROR${NC}: REPO_NAME not set. Source .env or pass --repo." >&2
    exit 1
fi
if [[ "$PUBLISH_METHOD" == "ingest" ]] && [[ ! -f "$COMPOSE_FILE" ]]; then
    echo -e "${RED}ERROR${NC}: docker-compose.yml not found at $COMPOSE_FILE" >&2
    exit 1
fi

# ── Build file list ───────────────────────────────────────────────────────────
FILES=()

if [[ -n "$SCAN_DIR" ]]; then
    # ── Mode 1: scan a directory for *.tar.gz ────────────────────────────────
    if [[ ! -d "$SCAN_DIR" ]]; then
        echo -e "${RED}ERROR${NC}: directory not found: $SCAN_DIR" >&2
        exit 1
    fi
    echo "Scanning ${SCAN_DIR} for *.tar.gz files…"
    if $RECURSIVE; then
        while IFS= read -r -d '' f; do
            FILES+=("$f")
        done < <(find "$SCAN_DIR" -name "*.tar.gz" -type f -print0 | sort -z)
    else
        while IFS= read -r -d '' f; do
            FILES+=("$f")
        done < <(find "$SCAN_DIR" -maxdepth 1 -name "*.tar.gz" -type f -print0 | sort -z)
    fi
    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}WARN${NC}: no *.tar.gz files found in ${SCAN_DIR}" >&2
        exit 0
    fi
    SOURCE_LABEL="dir: $SCAN_DIR"
else
    # ── Mode 2: explicit filelist ─────────────────────────────────────────────
    if [[ -z "$FILELIST" ]]; then
        TESTBED_ROOT_GUESS="${TESTBED_ROOT:-$HOME/cvmfs-testbed}"
        for candidate in \
            "${TESTBED_ROOT_GUESS}/data/filelist.txt" \
            "${TESTBED_DIR}/filelist.txt"; do
            if [[ -f "$candidate" ]]; then
                FILELIST="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$FILELIST" ]] || [[ ! -f "$FILELIST" ]]; then
        echo -e "${RED}ERROR${NC}: no source specified." >&2
        echo "  Use --dir <directory>  to scan a directory for *.tar.gz" >&2
        echo "  Use --filelist <file>  to read an explicit list of paths" >&2
        exit 1
    fi
    FILELIST_DIR="$(cd "$(dirname "$FILELIST")" && pwd)"
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != /* ]] && line="${FILELIST_DIR}/${line}"
        FILES+=("$line")
    done < "$FILELIST"
    if [[ ${#FILES[@]} -eq 0 ]]; then
        echo -e "${YELLOW}WARN${NC}: filelist is empty or contains only comments." >&2
        exit 0
    fi
    SOURCE_LABEL="filelist: $FILELIST"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
    echo "  CVMFS Bulk Upload — native ingest (cvmfs_server ingest)"
else
    echo "  CVMFS Bulk Upload — bits REST API"
fi
echo "  source   : ${SOURCE_LABEL}  (${#FILES[@]} file(s))"
[[ "$PUBLISH_METHOD" == "bits" ]] && echo "  prepub   : $PREPUB_URL"
echo "  repo     : $REPO_NAME"
echo "  path     : ${INGEST_PATH}/<package-name>"
if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
    echo "  note     : Phase 1 seeds ${INGEST_PATH}/<package>/ as nested catalog root"
    echo "             Phase 2 ingests package content. Run 'testbed.sh restore' before re-running."
fi
if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
    echo "  parallel : 1 (ingest is synchronous)"
else
    echo "  parallel : $CONCURRENCY"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Run-log helper ────────────────────────────────────────────────────────────
log_run() {
    local run_id="$1" n_req="$2" n_pub="$3" n_fail="$4"
    local start_ts="$5" end_ts="$6"
    local total_input_bytes="${7:-0}" total_cas_bytes="${8:-0}"
    local avg_s="${9:-0}" min_s="${10:-0}" max_s="${11:-0}" p50_s="${12:-0}" p95_s="${13:-0}"
    local publish_s0_s="${14:-0}" s1_s="${15:-0}"
    [[ -n "${RUN_LOG_FILE:-}" ]] || return 0
    local start_time end_time duration_s throughput
    local total_size_mb cas_size_mb
    start_time="$(date -u -d "@${start_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${start_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    end_time="$(date -u -d "@${end_ts}"   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "${end_ts}"   +%Y-%m-%dT%H:%M:%SZ)"
    duration_s=$(( end_ts - start_ts ))
    throughput="0.00"
    if (( n_pub > 0 && duration_s > 0 )); then
        throughput="$(awk "BEGIN{printf \"%.2f\", ${n_pub} * 60 / ${duration_s}}")"
    fi
    total_size_mb="$(awk "BEGIN{printf \"%.3f\", ${total_input_bytes} / 1048576}")"
    cas_size_mb="$(awk "BEGIN{printf \"%.3f\", ${total_cas_bytes} / 1048576}")"
    printf '{"run_id":"%s","batch_id":"%s","method":"%s","test_type":"batch","n_requested":%d,"n_published":%d,"n_failed":%d,"start_time":"%s","end_time":"%s","duration_s":%d,"avg_s":%d,"min_s":%d,"max_s":%d,"p50_s":%d,"p95_s":%d,"throughput_per_min":%s,"total_size_mb":%s,"cas_size_mb":%s,"publish_s0_s":%s,"s1_s":%s}\n' \
        "$run_id" "${BATCH_ID:-}" "$PUBLISH_METHOD" "$n_req" "$n_pub" "$n_fail" \
        "$start_time" "$end_time" "$duration_s" \
        "$avg_s" "$min_s" "$max_s" "$p50_s" "$p95_s" \
        "$throughput" "$total_size_mb" "$cas_size_mb" \
        "$publish_s0_s" "$s1_s" \
        >> "$RUN_LOG_FILE" 2>/dev/null || true
}

# ── Per-package run log ────────────────────────────────────────────────────────
# Called immediately when a single .tar.gz succeeds or fails so the monitoring
# chart updates in real time rather than only at batch completion.
log_package() {
    local pkg_id="$1" n_pub="$2" n_fail="$3"
    local start_ts="$4" end_ts="$5"
    local input_bytes="${6:-0}" cas_bytes="${7:-0}"
    [[ -n "${RUN_LOG_FILE:-}" ]] || return 0
    local start_time end_time duration_s total_size_mb cas_size_mb
    start_time="$(date -u -d "@${start_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${start_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    end_time="$(date -u -d "@${end_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r "${end_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    duration_s=$(( end_ts - start_ts ))
    total_size_mb="$(awk "BEGIN{printf \"%.3f\", ${input_bytes} / 1048576}")"
    cas_size_mb="$(awk "BEGIN{printf \"%.3f\", ${cas_bytes} / 1048576}")"
    printf '{"run_id":"%s","batch_id":"%s","method":"%s","test_type":"package","n_requested":1,"n_published":%d,"n_failed":%d,"start_time":"%s","end_time":"%s","duration_s":%d,"avg_s":%d,"min_s":%d,"max_s":%d,"p50_s":%d,"p95_s":%d,"throughput_per_min":0,"total_size_mb":%s,"cas_size_mb":%s}\n' \
        "$pkg_id" "${BATCH_ID:-}" "$PUBLISH_METHOD" "$n_pub" "$n_fail" \
        "$start_time" "$end_time" \
        "$duration_s" "$duration_s" "$duration_s" "$duration_s" "$duration_s" "$duration_s" \
        "$total_size_mb" "$cas_size_mb" \
        >> "$RUN_LOG_FILE" 2>/dev/null || true
}

# ── Per-job log entry (ingest-jobs.ndjson) ────────────────────────────────────
# Writes a job record compatible with the /api/ingest-jobs endpoint so that the
# Job State Distribution chart and Jobs table pick up ingest packages.
log_ingest_job() {
    local job_id="$1" state="$2" path="$3"
    local start_ts="$4" end_ts="$5"
    [[ -n "${JOB_LOG_FILE:-}" ]] || return 0
    local created_at updated_at duration_s
    created_at="$(date -u -d "@${start_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${start_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    updated_at="$(date -u -d "@${end_ts}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
               || date -u -r "${end_ts}" +%Y-%m-%dT%H:%M:%SZ)"
    duration_s=$(( end_ts - start_ts ))
    printf '{"job_id":"%s","state":"%s","method":"ingest","repo":"%s","path":"%s","created_at":"%s","updated_at":"%s","published_at":"%s","duration_s":%d}\n' \
        "$job_id" "$state" "${REPO_NAME:-}" "$path" \
        "$created_at" "$updated_at" \
        "$([ "$state" = "published" ] && echo "$updated_at" || echo "")" \
        "$duration_s" \
        >> "$JOB_LOG_FILE" 2>/dev/null || true
}

# ── Streaming tar transformer ─────────────────────────────────────────────────
# Reads <src> (.tar.gz, .tar.bz2, .tar.xz, or plain .tar), converts any
# absolute symlink targets to relative ones, and writes an *uncompressed* .tar
# to <dest>.
#
#   <dest> = regular file  → used by ingest_one (docker cp needs a real file)
#   <dest> = named pipe    → used by upload_one (curl reads directly; no payload
#                            file written to disk at all)
#
# Two sequential passes over the source (both fast sequential reads):
#   Pass 1 — header-only scan  → collect top-level directory names in the archive
#   Pass 2 — full data stream  → restream with absolute symlinks fixed in-flight
#
# Benefits vs the old extract-then-relativize-then-repack approach:
#   • Eliminates the ~500 MB extracted directory on disk entirely.
#   • For bits uploads (named pipe): also eliminates the ~500 MB payload.tar.
#   • Single Python process replaces three steps (tar -x / python / tar -c).
#
# Requires Python ≥ 3.6 (standard library only).
stream_fix_tar() {
    python3 - "$1" "$2" <<'PYEOF'
import tarfile, sys, os, pathlib

src, dst = sys.argv[1], sys.argv[2]

# Pass 1: read all tar member *headers* (no file content) to find top-level dirs.
# tarfile.getmembers() does exactly this for seekable (non-streaming) opens.
roots = set()
with tarfile.open(src, 'r:*') as t:
    for m in t.getmembers():
        p = pathlib.PurePosixPath(m.name).parts
        if p:
            roots.add(p[0].lstrip('./'))

def rel_target(abs_link, member_name):
    """Map an absolute symlink target into a relative path within the archive.
    Returns None if the target cannot be anchored to a known top-level dir."""
    parts = pathlib.PurePosixPath(abs_link).parts
    for i, p in enumerate(parts):
        if p in roots:
            # Virtual in-archive path of the target
            virt = str(pathlib.PurePosixPath(*parts[i:]))
            # Directory that contains the symlink itself
            ldir = str(pathlib.PurePosixPath(member_name).parent)
            return os.path.relpath(virt, ldir)
    return None

fixed = warned = 0

# Pass 2: stream the archive; rewrite absolute symlinks on the fly.
# 'w|' = streaming (no seeking) uncompressed tar — correct for both files and
# named pipes.
with tarfile.open(src, 'r:*') as tin, tarfile.open(dst, 'w|') as tout:
    for m in tin:
        if m.issym() and os.path.isabs(m.linkname):
            rel = rel_target(m.linkname, m.name)
            if rel is not None:
                print(f'  [symfix]  {m.name}: {m.linkname!r} -> {rel!r}', file=sys.stderr)
                m.linkname = rel
                fixed += 1
            else:
                print(f'  [symwarn] cannot relativize: {m.name} -> {m.linkname}', file=sys.stderr)
                warned += 1
        tout.addfile(m, tin.extractfile(m) if m.isfile() else None)

if fixed or warned:
    print(f'  Symlinks: {fixed} converted, {warned} skipped', file=sys.stderr)
PYEOF
}

# ── Upload one file ───────────────────────────────────────────────────────────
# Prints "OK <job_id>" on success, "FAIL <reason>" on failure.
upload_one() {
    local src_file="$1"
    local file_idx="$2"
    local total="$3"

    local base_name
    base_name="$(basename "${src_file%.tar.gz}")"
    # No per-package tag — one batch tag is created after all jobs complete.
    local ingest_sub="${INGEST_PATH}/${base_name}"

    if [[ ! -f "$src_file" ]]; then
        echo "FAIL file not found: $src_file"
        return 1
    fi

    # Temp workspace for this job — lives under SCRATCH_DIR (testbed filesystem,
    # not /tmp) so large tars don't fill the system's tmpfs/RAM disk.
    local tmpdir
    tmpdir="$(mktemp -d "${SCRATCH_DIR}/job-XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    # ── Stream: decompress + fix absolute symlinks → curl via named pipe ────────
    # The named pipe is local to this build node (inside $SCRATCH_DIR).
    # Python writes the fixed tar to it; curl reads from it and POSTs to
    # $PREPUB_URL — which may be on a remote host.  No shared filesystem
    # between the build node and cvmfs-prepub is needed or assumed.
    #
    # Benefits vs extract → relativize_symlinks → repack:
    #   • Eliminates the ~500 MB extracted directory on disk.
    #   • Eliminates the ~500 MB payload.tar file (curl reads the pipe directly).
    #   • Single Python process replaces three separate steps.
    local payload_pipe="${tmpdir}/payload.pipe"
    mkfifo "$payload_pipe"

    echo -e "[${file_idx}/${total}] ${CYAN}Streaming${NC} $(basename "$src_file")…" >&2
    # Start streamer in background.  After pass 1 (fast header scan) it opens
    # the named pipe for writing — this open() blocks until curl opens the read end.
    stream_fix_tar "$src_file" "$payload_pipe" >&2 &
    local stream_pid=$!

    # Submit to prepub API — curl opens the named pipe, unblocking the streamer.
    echo -e "[${file_idx}/${total}] ${CYAN}Submitting${NC} ${base_name} → /${ingest_sub}" >&2
    local response
    response="$(curl -sf --max-time 300 \
        -X POST \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        -F "repo=${REPO_NAME}" \
        -F "path=${ingest_sub}" \
        -F "tar=@${payload_pipe};type=application/octet-stream" \
        "${PREPUB_URL}/api/v1/jobs")" || response=""

    # Reap the background streamer (it exits when it writes the tar EOF block).
    wait "$stream_pid" || true

    local job_id
    job_id="$(echo "$response" | jq -r '.job_id // empty' 2>/dev/null)" || job_id=""
    if [[ -z "$job_id" ]]; then
        echo "FAIL submit failed (response: ${response:0:200})"
        return 1
    fi

    # Wait for completion via SSE
    local final_state=""
    while IFS= read -r line; do
        [[ "$line" == data:* ]] || continue
        local json="${line#data: }"
        local state
        state="$(echo "$json" | jq -r '.state // empty' 2>/dev/null)" || continue
        [[ -n "$state" ]] || continue
        echo -e "[${file_idx}/${total}]  → ${state}" >&2
        case "$state" in
            published)  final_state="published"; break ;;
            failed|aborted) final_state="$state"; break ;;
        esac
    done < <(curl -sN --no-buffer --max-time 1800 \
                 -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
                 "${PREPUB_URL}/api/v1/jobs/${job_id}/events")

    # Fetch the final job record — needed for CAS bytes on success, and for the
    # server-side error message on failure.  Done unconditionally so failures
    # always show the real error rather than just the state name.
    local final_job_json=""
    final_job_json="$(curl -sf --max-time 10 \
        -H "Authorization: Bearer ${PREPUB_API_TOKEN}" \
        "${PREPUB_URL}/api/v1/jobs/${job_id}" 2>/dev/null)" || final_job_json=""

    if [[ -z "$final_state" ]]; then
        # SSE ended without terminal state — read state from the fetched record
        final_state="$(echo "$final_job_json" | jq -r '.state // "unknown"' 2>/dev/null)"
    fi

    if [[ "$final_state" == "published" ]]; then
        echo -e "[${file_idx}/${total}] ${GREEN}✓ published${NC}  $(basename "$src_file")" >&2
        local cas_bytes input_bytes
        cas_bytes="$(echo "$final_job_json" | jq -r '.cas_bytes_written // .cas_size_bytes // 0' 2>/dev/null || echo 0)"
        input_bytes="$(stat -c%s "$src_file" 2>/dev/null || stat -f%z "$src_file" 2>/dev/null || echo 0)"
        # Equivalent-phase timing from the prepub job record: publish-to-Stratum-0
        # = published_at − created_at (pipeline+lease+commit).  S1 distribution is
        # async (distributing_ended_at unset → 0), so it is NOT part of S0.
        local _cre _pub _ds _de _s0ms=0 _s1ms=0
        _cre="$(echo "$final_job_json" | jq -r '.created_at // empty' 2>/dev/null)"
        _pub="$(echo "$final_job_json" | jq -r '(.published_at // .updated_at) // empty' 2>/dev/null)"
        _ds="$(echo "$final_job_json"  | jq -r '.distributing_started_at // empty' 2>/dev/null)"
        _de="$(echo "$final_job_json"  | jq -r '.distributing_ended_at // empty' 2>/dev/null)"
        if [[ -n "$_cre" && -n "$_pub" ]]; then
            _s0ms=$(( $(date -d "$_pub" +%s%3N 2>/dev/null || echo 0) - $(date -d "$_cre" +%s%3N 2>/dev/null || echo 0) ))
            (( _s0ms < 0 )) && _s0ms=0
        fi
        if [[ -n "$_ds" && -n "$_de" && "${_de:0:4}" != "0001" ]]; then
            _s1ms=$(( $(date -d "$_de" +%s%3N 2>/dev/null || echo 0) - $(date -d "$_ds" +%s%3N 2>/dev/null || echo 0) ))
            (( _s1ms < 0 )) && _s1ms=0
        fi
        echo "OK $job_id $input_bytes $cas_bytes $_s0ms $_s1ms"
    else
        echo -e "[${file_idx}/${total}] ${RED}✗ ${final_state:-unknown}${NC}  $(basename "$src_file")" >&2
        # Extract server-side error message so the caller sees the real reason.
        local err_msg=""
        err_msg="$(echo "$final_job_json" | jq -r '.error // empty' 2>/dev/null)" || err_msg=""
        local failed_at_state=""
        failed_at_state="$(echo "$final_job_json" | jq -r '.failed_at_state // empty' 2>/dev/null)" || failed_at_state=""
        if [[ -n "$err_msg" ]]; then
            echo -e "  ${RED}[error]${NC} ${err_msg}" >&2
        fi
        # Build FAIL token: "FAIL <state>[: <server error>]"
        if [[ -n "$err_msg" ]]; then
            echo "FAIL ${final_state:-unknown}: ${err_msg}"
        else
            echo "FAIL ${final_state:-unknown}"
        fi
        return 1
    fi
}

# ── Ingest one file via cvmfs_server ingest (runs inside cvmfs-native-publisher container) ──
# Prints "OK <job_id> <input_bytes> 0" on success, "FAIL <reason>" on failure.
#
# Two-phase approach required by cvmfs_server ingest in mountless gateway mode:
#
#   Phase 1 – SEED: create ${INGEST_PATH}/<package>/ as a nested catalog root.
#     cvmfs_server ingest panics ("catalog for directory X cannot be found") if
#     the target path already has nested sub-catalogs from prior publications
#     (e.g. bits uploads).  By using the fresh single-component INGEST_PATH
#     ("pkg" by default) as the gateway lease base and injecting a .cvmfscatalog
#     marker, we create pkg/<package>/ as a clean nested catalog root with no
#     pre-existing sub-catalog conflicts.
#
#   Phase 2 – CONTENT: ingest the actual package tar into pkg/<package>/.
#     The lease base is now pkg/<package>/ (a proper nested catalog root),
#     and rdonly stubs cover pkg/ and pkg/<package>/ to prevent duplicate
#     AddDirectory errors for paths already in the CVMFS catalog.
#
# Note: re-running ingest on the same packages without a ./testbed.sh restore
# will fail in Phase 1 because the nested catalog root already exists.
# Restore the repository snapshot first: ./testbed.sh restore
ingest_one() {
    local src_file="$1"
    local file_idx="$2"
    local total="$3"

    local base_name
    base_name="$(basename "${src_file%.tar.gz}")"
    # Full CVMFS path for this package: e.g. pkg/Clang-v20.1.7-local1...
    local ingest_base="${INGEST_PATH}/${base_name}"

    if [[ ! -f "$src_file" ]]; then
        echo "FAIL file not found: $src_file"
        return 1
    fi

    # Temp workspace for this job — lives under SCRATCH_DIR (testbed filesystem,
    # not /tmp) so large tars don't fill the system's tmpfs/RAM disk.
    local tmpdir
    tmpdir="$(mktemp -d "${SCRATCH_DIR}/job-XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '${tmpdir}'" RETURN

    echo -e "[${file_idx}/${total}] ${CYAN}Ingesting${NC} ${base_name} → /${ingest_base}" >&2

    # ── Phase 1: seed pkg/<package>/ as a nested catalog root ─────────────────
    # Build a minimal tar containing only the .cvmfscatalog marker at
    # <package>/.cvmfscatalog.  No directory entries — swissknife's
    # CreateDirectories() adds intermediate dirs automatically.
    local seed_dir="${tmpdir}/seed/${base_name}"
    mkdir -p "$seed_dir"
    touch "${seed_dir}/.cvmfscatalog"
    local seed_tar="${tmpdir}/seed.tar"
    tar --no-recursion -C "${tmpdir}/seed" -cf "$seed_tar" \
        "${base_name}/.cvmfscatalog" 2>/dev/null \
        || tar -C "${tmpdir}/seed" -cf "$seed_tar" "${base_name}/.cvmfscatalog"

    local container_seed="/tmp/seed-${base_name}-$$.tar"
    if ! docker cp "$seed_tar" "cvmfs-native-publisher:${container_seed}" 2>&1 >&2; then
        echo "FAIL docker cp (seed) failed for $src_file"
        return 1
    fi

    echo -e "  [${CYAN}Phase 1${NC}] Seeding nested catalog root: ${ingest_base}/" >&2
    local seed_out seed_rc
    seed_out="$(docker compose -f "$COMPOSE_FILE" exec -T cvmfs-native-publisher \
        bash -c "
            _SPOOL=\"/var/spool/cvmfs/${REPO_NAME}\"
            _rdonly=\"\${_SPOOL}/rdonly\"
            rm -f \"\${_SPOOL}/session_token\" \"\${_SPOOL}/stats.db\"
            # Stub INGEST_PATH/ only if it was already created by a prior Phase 1.
            # On the very first package, INGEST_PATH/ is new so no stub is needed
            # (swissknife will AddDirectory it for the first time).
            # After any successful Phase 1 we persist the stub so subsequent
            # packages skip the duplicate AddDirectory for INGEST_PATH/.
            # (The rdonly volume is mounted from data/native-ingest and persists.)
            cvmfs_server ingest \
                -t '${container_seed}' \
                -b '${INGEST_PATH}' \
                '${REPO_NAME}'
            _rc=\$?
            if [[ \$_rc -eq 0 ]]; then
                # Persist rdonly stub so next package's Phase 1 skips AddDirectory
                mkdir -p \"\${_rdonly}/${INGEST_PATH}\"
            fi
            rm -f '${container_seed}'
            exit \$_rc
        " 2>&1)"
    seed_rc=$?
    echo "$seed_out" >&2

    if [[ $seed_rc -ne 0 ]]; then
        echo -e "  ${RED}[Phase 1 FAILED]${NC} Could not seed nested catalog for ${base_name}" >&2
        echo -e "  Hint: if this package was already ingested, run ./testbed.sh restore first." >&2
        echo "FAIL phase1 seed failed"
        return 1
    fi

    # ── Phase 2: ingest actual package content ─────────────────────────────────
    # Stream: decompress + fix absolute symlinks → uncompressed payload.tar.
    # (docker cp requires a real file; named-pipe streaming not possible here.)
    local payload_tar="${tmpdir}/payload.tar"
    echo -e "  [${CYAN}Phase 2${NC}] Preparing payload for ${base_name}…" >&2
    stream_fix_tar "$src_file" "$payload_tar" >&2 || {
        echo "FAIL tar stream/fix failed for $src_file"; return 1; }

    local container_tar="/tmp/content-${base_name}-$$.tar"
    if ! docker cp "$payload_tar" "cvmfs-native-publisher:${container_tar}" 2>&1 >&2; then
        echo "FAIL docker cp (content) failed for $src_file"
        return 1
    fi

    echo -e "  [${CYAN}Phase 2${NC}] Publishing content to ${ingest_base}/" >&2
    local ingest_out ingest_rc
    ingest_out="$(docker compose -f "$COMPOSE_FILE" exec -T cvmfs-native-publisher \
        bash -c "
            _SPOOL=\"/var/spool/cvmfs/${REPO_NAME}\"
            _rdonly=\"\${_SPOOL}/rdonly\"
            rm -f \"\${_SPOOL}/session_token\" \"\${_SPOOL}/stats.db\"
            # Stub all components of ingest_base to prevent duplicate
            # AddDirectory errors for directories already in the CVMFS catalog.
            _path=''
            IFS='/' read -ra _comps <<< '${ingest_base}'
            for _c in \"\${_comps[@]}\"; do
                _path=\"\${_path:+\${_path}/}\${_c}\"
                mkdir -p \"\${_rdonly}/\${_path}\"
            done
            cvmfs_server ingest \
                -t '${container_tar}' \
                -b '${ingest_base}' \
                '${REPO_NAME}'
            _rc=\$?
            rm -f '${container_tar}'
            exit \$_rc
        " 2>&1)"
    ingest_rc=$?
    echo "$ingest_out" >&2

    if [[ $ingest_rc -eq 0 ]]; then
        echo -e "[${file_idx}/${total}] ${GREEN}✓ published${NC}  $(basename "$src_file")" >&2
        local job_id="ingest-${base_name}-$(date +%Y%m%d-%H%M%S)"
        local input_bytes
        input_bytes="$(stat -c%s "$src_file" 2>/dev/null || stat -f%z "$src_file" 2>/dev/null || echo 0)"
        echo "OK $job_id $input_bytes 0"
    else
        echo -e "[${file_idx}/${total}] ${RED}✗ ingest failed${NC}  $(basename "$src_file")" >&2
        docker compose -f "$COMPOSE_FILE" exec -T cvmfs-native-publisher \
            rm -f "${container_tar}" 2>/dev/null || true
        echo "FAIL ingest failed"
        return 1
    fi
}

# ── Concurrency manager ───────────────────────────────────────────────────────
PUBLISHED=0
FAILED=0
TOTAL_INPUT_BYTES=0
TOTAL_CAS_BYTES=0
declare -a PKG_DURATIONS=()   # per-package duration_s values for stats at end
SUM_S0_MS=0   # Σ per-package publish-to-Stratum-0 (ms) — equivalent-phase metric
SUM_S1_MS=0   # Σ per-package S1 distribution (ms); 0 when async/non-blocking
N_S0=0
START_TS=$(date +%s)
TOTAL=${#FILES[@]}
BATCH_ID="${PUBLISH_METHOD}-$(date -u -d "@${START_TS}" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -r "${START_TS}" +%Y%m%dT%H%M%SZ)"

# Active background jobs: each entry = "pid file_idx src_file result_file log_file start_ts"
declare -a ACTIVE=()

# For ingest: force concurrency=1 (cvmfs_server ingest is synchronous)
[[ "$PUBLISH_METHOD" == "ingest" ]] && CONCURRENCY=1

submit_bg() {
    local file_idx="$1"
    local src_file="$2"
    local result_file log_file
    result_file="$(mktemp "${SCRATCH_DIR}/result-XXXXXX")"
    log_file="$(mktemp    "${SCRATCH_DIR}/log-XXXXXX")"
    local pkg_start
    pkg_start="$(date +%s)"
    (
        local _fn="upload_one"
        [[ "$PUBLISH_METHOD" == "ingest" ]] && _fn="ingest_one"
        # stdout → result token file ("OK <id> <in> <cas>" or "FAIL <reason>[: <detail>]")
        # stderr → log file (progress messages, then replayed to main stderr on completion)
        # Do NOT append a fallback here: upload_one/ingest_one always writes the
        # real FAIL reason before returning non-zero; a second line would mask it.
        "$_fn" "$src_file" "$file_idx" "$TOTAL" \
            >"$result_file" 2>"$log_file" || true
    ) &
    local pid=$!
    ACTIVE+=("${pid} ${file_idx} ${src_file} ${result_file} ${log_file} ${pkg_start}")
}

reap_completed() {
    # Checks each active job; removes finished ones, updates counters,
    # and immediately logs each completed package to runs.ndjson so the
    # monitoring chart updates in real time.
    local new_active=()
    for entry in "${ACTIVE[@]}"; do
        local pid file_idx src_file result_file log_file pkg_start
        read -r pid file_idx src_file result_file log_file pkg_start <<< "$entry"
        if ! kill -0 "$pid" 2>/dev/null; then
            # Job finished — replay log then read result
            wait "$pid" 2>/dev/null || true
            [[ -f "$log_file" ]] && cat "$log_file" >&2
            rm -f "$log_file"
            local result=""
            # head -1: the upload function always writes the real reason first;
            # any subsequent lines (e.g. debug output) are ignored.
            [[ -f "$result_file" ]] && result="$(grep -E '^(OK|FAIL)' "$result_file" | head -1)"
            [[ -z "$result" ]] && result="FAIL no result written (check log above)"
            rm -f "$result_file"
            local pkg_end
            pkg_end="$(date +%s)"
            local _base_name
            _base_name="$(basename "${src_file%.tar.gz}")"
            local _pkg_dur=$(( pkg_end - ${pkg_start:-$START_TS} ))
            if [[ "$result" == OK* ]]; then
                PUBLISHED=$(( PUBLISHED + 1 ))
                PKG_DURATIONS+=("$_pkg_dur")
                # Accumulate size counters from "OK <job_id> <input_bytes> <cas_bytes>"
                local _job_id _in _cas
                _job_id="$(echo "$result" | awk '{print $2}')"
                _in="$(echo "$result"  | awk '{print $3+0}')"
                _cas="$(echo "$result" | awk '{print $4+0}')"
                TOTAL_INPUT_BYTES=$(( TOTAL_INPUT_BYTES + _in ))
                TOTAL_CAS_BYTES=$(( TOTAL_CAS_BYTES + _cas ))
                # Equivalent-phase: OK fields 5/6 = publish-to-S0 / S1 (ms).  Bits
                # emits them; ingest (and any legacy OK line without them) falls
                # back to the whole-package wall time as the S0 measure, S1=0.
                local _s0ms _s1ms
                _s0ms="$(echo "$result" | awk '{print ($5==""?-1:$5)+0}')"
                _s1ms="$(echo "$result" | awk '{print ($6==""?0:$6)+0}')"
                (( _s0ms < 0 )) && _s0ms=$(( _pkg_dur * 1000 ))
                SUM_S0_MS=$(( SUM_S0_MS + _s0ms ))
                SUM_S1_MS=$(( SUM_S1_MS + _s1ms ))
                N_S0=$(( N_S0 + 1 ))
                local _effective_id="${_job_id:-pkg-${_base_name}-${pkg_end}}"
                # Immediately write a per-package entry so the chart updates live
                log_package "${_effective_id}" \
                    1 0 "${pkg_start:-$START_TS}" "$pkg_end" "$_in" "$_cas"
                # Only write to ingest-jobs.ndjson for ingest method (bits jobs
                # are already tracked by the prepub API and would appear as "ingest"
                # in the dashboard if also written here)
                if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
                    log_ingest_job "${_effective_id}" "published" \
                        "${INGEST_PATH}/${_base_name}" "${pkg_start:-$START_TS}" "$pkg_end"
                fi
            else
                FAILED=$(( FAILED + 1 ))
                PKG_DURATIONS+=("$_pkg_dur")
                echo -e "  ${RED}[FAIL]${NC} ${_base_name}: ${result:-unknown error}" >&2
                local _fail_id="fail-${_base_name}-${pkg_end}"
                # Log failed packages too so failures are visible in the chart
                log_package "${_fail_id}" \
                    0 1 "${pkg_start:-$START_TS}" "$pkg_end" 0 0
                if [[ "$PUBLISH_METHOD" == "ingest" ]]; then
                    log_ingest_job "${_fail_id}" "failed" \
                        "${INGEST_PATH}/${_base_name}" "${pkg_start:-$START_TS}" "$pkg_end"
                fi
            fi
        else
            new_active+=("$entry")
        fi
    done
    ACTIVE=("${new_active[@]+"${new_active[@]}"}")
}

FILE_IDX=0
for src_file in "${FILES[@]}"; do
    FILE_IDX=$(( FILE_IDX + 1 ))

    # Wait until a slot opens
    while [[ ${#ACTIVE[@]} -ge $CONCURRENCY ]]; do
        reap_completed
        [[ ${#ACTIVE[@]} -ge $CONCURRENCY ]] && sleep 1
    done

    submit_bg "$FILE_IDX" "$src_file"
done

# Wait for all remaining jobs
while [[ ${#ACTIVE[@]} -gt 0 ]]; do
    reap_completed
    [[ ${#ACTIVE[@]} -gt 0 ]] && sleep 1
done

END_TS=$(date +%s)
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${PUBLISH_METHOD}-upload-${RUN_TS}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Upload complete: ${PUBLISHED} published, ${FAILED} failed / ${TOTAL} total"
echo "  Duration: $(( END_TS - START_TS ))s   Run ID: ${RUN_ID}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Compute per-package timing stats from accumulated durations
AVG_S=0; MIN_S=0; MAX_S=0; P50_S=0; P95_S=0
if [[ ${#PKG_DURATIONS[@]} -gt 0 ]]; then
    local_sorted="$(printf '%s\n' "${PKG_DURATIONS[@]}" | sort -n)"
    local_n=${#PKG_DURATIONS[@]}
    local_sum=0
    for _d in "${PKG_DURATIONS[@]}"; do local_sum=$(( local_sum + _d )); done
    AVG_S=$(( local_sum / local_n ))
    MIN_S="$(echo "$local_sorted" | head -1)"
    MAX_S="$(echo "$local_sorted" | tail -1)"
    P50_S="$(echo "$local_sorted" | sed -n "$(( (local_n * 50 / 100) + 1 ))p")"
    P95_S="$(echo "$local_sorted" | sed -n "$(( (local_n * 95 / 100) + 1 ))p")"
    # fallback for edge cases
    [[ -z "$P50_S" ]] && P50_S=$AVG_S
    [[ -z "$P95_S" ]] && P95_S=$MAX_S
fi

PUBLISH_S0_S="0"; S1_S="0"
if (( N_S0 > 0 )); then
    PUBLISH_S0_S="$(awk "BEGIN{printf \"%.3f\", ${SUM_S0_MS}/${N_S0}/1000}")"
    S1_S="$(awk "BEGIN{printf \"%.3f\", ${SUM_S1_MS}/${N_S0}/1000}")"
fi

log_run "$RUN_ID" "$TOTAL" "$PUBLISHED" "$FAILED" "$START_TS" "$END_TS" \
    "$TOTAL_INPUT_BYTES" "$TOTAL_CAS_BYTES" \
    "$AVG_S" "$MIN_S" "$MAX_S" "$P50_S" "$P95_S" \
    "$PUBLISH_S0_S" "$S1_S"

[[ $FAILED -eq 0 ]]
