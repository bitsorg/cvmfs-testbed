#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0

# dump-catalogs.sh — Decompress and SQL-dump all CVMFS catalogs reachable from
# the current published manifest of a CVMFS repository.
#
# CVMFS catalogs are zlib-compressed SQLite databases stored in the CAS at
#   data/<XY>/<rest>C
# where <XY><rest> is the SHA-1 hash and 'C' is the catalog content-type suffix.
#
# This script:
#   1. Reads .cvmfspublished to find the root catalog hash.
#   2. Decompresses each catalog with Python's zlib (no external deps).
#   3. Reads the catalog's "root_prefix" property (mount path within the repo).
#   4. Walks the nested_catalogs table to find child catalogs, recursively.
#   5. Dumps each catalog with "sqlite3 <db> .dump" and saves to OUTPUT_DIR.
#
# Output filenames use the catalog's root_prefix with slashes replaced by '_':
#   __root__.dump              root catalog  (root_prefix = "")
#   _test_smoke.dump           catalog at /test/smoke
#
# Usage:
#   dump-catalogs.sh <cas-root> <output-dir>
#
# Arguments:
#   cas-root    Host path to the repo CAS root (contains data/ and .cvmfspublished).
#               Example: $TESTBED_ROOT/repos/$REPO_NAME
#   output-dir  Where to write .dump files (created if absent).
#
# Dependencies: python3 (stdlib only), sqlite3

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERR ]${NC}  $*"; }

CAS_ROOT="${1:-}"
OUTPUT_DIR="${2:-}"

if [[ -z "$CAS_ROOT" || -z "$OUTPUT_DIR" ]]; then
    echo "Usage: $0 <cas-root> <output-dir>"
    echo "  cas-root   — path to repo CAS root (contains data/ and .cvmfspublished)"
    echo "  output-dir — where to write .dump files"
    exit 1
fi

if [[ ! -f "$CAS_ROOT/.cvmfspublished" ]]; then
    err "No .cvmfspublished found at $CAS_ROOT — has the repository been initialised?"
    exit 1
fi

command -v python3 >/dev/null 2>&1 || { err "python3 not found in PATH"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found in PATH"; exit 1; }

mkdir -p "$OUTPUT_DIR"

# ── Parse .cvmfspublished ──────────────────────────────────────────────────────
# The manifest is a series of single-character-prefixed lines.
# 'C' = root catalog SHA-1 hash (40 hex chars, no suffix).
ROOT_HASH=""
while IFS= read -r line; do
    if [[ "${line:0:1}" == "C" ]]; then
        ROOT_HASH="${line:1}"
        break
    fi
done < "$CAS_ROOT/.cvmfspublished"

if [[ -z "$ROOT_HASH" ]]; then
    err "Could not extract root catalog hash from .cvmfspublished"
    exit 1
fi
info "Root catalog hash: $ROOT_HASH"

# ── Python helper: decompress a CAS object and return sqlite3-dumpable path ──
# Embedded as a heredoc so the script is self-contained.
DECOMPRESS_PY=$(cat <<'PYEOF'
import sys, zlib, sqlite3, os, tempfile

def cas_path(cas_root, hex_hash):
    """Convert a 40-char hex hash to its CAS filesystem path (catalog suffix C)."""
    return os.path.join(cas_root, "data", hex_hash[:2], hex_hash[2:] + "C")

def decompress_catalog(cas_root, hex_hash):
    """Decompress a catalog CAS object, verify it is SQLite, return temp file path."""
    path = cas_path(cas_root, hex_hash)
    if not os.path.exists(path):
        print(f"MISS {path}", file=sys.stderr)
        return None
    with open(path, "rb") as f:
        data = f.read()
    try:
        raw = zlib.decompress(data)
    except zlib.error as e:
        print(f"ZLIB_ERR {path}: {e}", file=sys.stderr)
        return None
    if raw[:16] != b"SQLite format 3\x00":
        print(f"NOT_SQLITE {path}", file=sys.stderr)
        return None
    fd, tmp = tempfile.mkstemp(suffix=".sqlite", prefix="cvmfscatalog_")
    with os.fdopen(fd, "wb") as f:
        f.write(raw)
    return tmp

def get_property(db_path, key):
    try:
        conn = sqlite3.connect(db_path)
        row = conn.execute("SELECT value FROM properties WHERE key=?", (key,)).fetchone()
        conn.close()
        return row[0] if row else None
    except Exception:
        return None

def get_nested_hashes(db_path):
    """Return list of (path, sha1) for all nested catalogs."""
    try:
        conn = sqlite3.connect(db_path)
        rows = conn.execute("SELECT path, sha1 FROM nested_catalogs").fetchall()
        conn.close()
        return rows
    except Exception:
        return []

cas_root = sys.argv[1]
root_hash = sys.argv[2]
output_dir = sys.argv[3]

# BFS walk of the catalog tree
queue = [(root_hash, None)]   # (hash, parent_path_hint)
visited = set()
results = []

while queue:
    hex_hash, _ = queue.pop(0)
    if hex_hash in visited:
        continue
    visited.add(hex_hash)

    tmp = decompress_catalog(cas_root, hex_hash)
    if tmp is None:
        print(f"SKIP {hex_hash}")
        continue

    root_prefix = get_property(tmp, "root_prefix") or ""
    schema = get_property(tmp, "schema") or "?"
    schema_rev = get_property(tmp, "schema_revision") or "?"
    revision = get_property(tmp, "revision") or "?"

    # Derive a human-readable output filename from the root_prefix.
    # root_prefix is e.g. "" (root), "/test/smoke", "/usr"
    if root_prefix == "" or root_prefix == "/":
        label = "__root__"
    else:
        label = root_prefix.replace("/", "_").lstrip("_")

    dump_path = os.path.join(output_dir, f"{label}.dump")
    print(f"DUMP hash={hex_hash[:12]}... prefix={root_prefix!r:30s} schema={schema}/{schema_rev} rev={revision} → {os.path.basename(dump_path)}")
    results.append((hex_hash, root_prefix, dump_path, tmp))

    # Find nested catalogs and enqueue them.
    for nested_path, nested_hash in get_nested_hashes(tmp):
        if nested_hash and nested_hash not in visited:
            queue.append((nested_hash, nested_path))

# Emit the list of (tmp_path, dump_path) pairs for the bash loop to process.
for hex_hash, prefix, dump_path, tmp in results:
    print(f"FILE {tmp} {dump_path}")
PYEOF
)

# ── Run the Python walker ──────────────────────────────────────────────────────
info "Walking catalog tree from root $ROOT_HASH ..."

TMPFILES=()
DUMP_PAIRS=()

while IFS=' ' read -r tag a b; do
    case "$tag" in
        DUMP)
            info "  $a $b" ;;
        SKIP)
            warn "  Skipped catalog: $a" ;;
        FILE)
            # a = temp sqlite path, b = desired dump path
            TMPFILES+=("$a")
            DUMP_PAIRS+=("$a:$b")
            ;;
    esac
done < <(python3 -c "$DECOMPRESS_PY" "$CAS_ROOT" "$ROOT_HASH" "$OUTPUT_DIR")

# ── Dump each catalog with sqlite3 ────────────────────────────────────────────
DUMPED=0
for pair in "${DUMP_PAIRS[@]}"; do
    tmp="${pair%%:*}"
    dump_path="${pair#*:}"
    if sqlite3 "$tmp" .dump > "$dump_path"; then
        ok "  $(basename "$dump_path")  ($(wc -l < "$dump_path") lines)"
        DUMPED=$(( DUMPED + 1 ))
    else
        warn "  sqlite3 .dump failed for $tmp"
    fi
done

# ── Clean up temp files ────────────────────────────────────────────────────────
for f in "${TMPFILES[@]}"; do
    rm -f "$f"
done

echo ""
ok "Dumped ${DUMPED} catalog(s) to $OUTPUT_DIR"
[[ $DUMPED -gt 0 ]]
