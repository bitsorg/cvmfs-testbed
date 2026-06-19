#!/usr/bin/env bash
# make-test-payload.sh — Create a comprehensive, DETERMINISTIC CVMFS test payload.
#
# Determinism is mandatory: the bits and native-ingest paths must ingest
# BYTE-IDENTICAL input so their catalogs/chunks can be compared (ADR-0001).
# All "random" data is a fixed AES-CTR keystream (same key+iv => same bytes);
# no $(date), no /dev/urandom. The tar is built reproducibly (--sort, fixed
# --mtime, numeric 0 owner).
#
# Coverage:
#   simple/        — regular, empty, no-extension, executable
#   hierarchy/     — 5-level deep tree + siblings
#   links/         — CAS-dedup pair, relative symlink, dangling symlink
#   large/         — 8 MiB deterministic file (legacy case)
#   permissions/   — 0644/0600/0444/0640 files; 0750/0700 dirs
#   unusual-names/ — spaces, brackets, unicode, long name, dash-prefix, ...
#   empty-dir/     — empty directory
#   chunk/         — (A) chunk-boundary + intra-file-dedup cases
#   compress/      — (B) zeros / incompressible / pre-compressed
#   nested/, manyfiles/ — (C) nested-catalog marker + many-entry dir
#   meta/          — (D) setuid/setgid/sticky, symlink chain, all-bytes binary
#
# Optional (default OFF) — bits-incompatible cases kept behind a flag so the
# normal suite stays green; enable to drive bits fixes:
#   PAYLOAD_INCLUDE_INCOMPATIBLE=1  adds a true hardlink group and an absolute
#   symlink (both currently rejected by cvmfs-prepub staging/unpack).
#
# Usage:   bash make-test-payload.sh <work-dir>
# Outputs: <work-dir>/payload/  and  <work-dir>/payload.tar
#
# Dependencies: bash, coreutils, tar, gzip, openssl. (Runs where these exist —
# the native-publisher or the host; NOT the bits container, which lacks
# openssl. The bits path consumes the pre-built tar instead of regenerating.)

set -euo pipefail

WORK_DIR="${1:?Usage: $0 <work-dir>}"
PAYLOAD_DIR="$WORK_DIR/payload"
PAYLOAD_TAR="$WORK_DIR/payload.tar"
INCOMPAT="${PAYLOAD_INCLUDE_INCOMPATIBLE:-0}"

# Live CVMFS chunk thresholds (config/repo-config/server.conf).
MIN=4194304      # 4 MiB
AVG=8388608      # 8 MiB
MAX=16777216     # 16 MiB

rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"

# ── deterministic byte source ─────────────────────────────────────────────────
# gen_rand <nbytes> <iv-index> <outfile>: AES-256-CTR keystream over zeros.
# Fixed key; iv derived from a per-file index so distinct files differ but every
# regeneration is identical.
_KEY=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
gen_rand() {
    local n="$1" idx="$2" out="$3"
    local iv
    iv="$(printf '%032x' "$idx")"
    head -c "$n" /dev/zero \
      | openssl enc -aes-256-ctr -nosalt -K "$_KEY" -iv "$iv" 2>/dev/null \
      > "$out"
}

# ── 1. simple/ ────────────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/simple"
# Fixed suffix (was $(date)) so content is deterministic; verify-ingest checks
# only the prefix "hello from cvmfs comprehensive test ".
echo "hello from cvmfs comprehensive test fixed-payload-v1" \
    > "$PAYLOAD_DIR/simple/hello.txt"
touch   "$PAYLOAD_DIR/simple/empty-file"
echo "no extension"   > "$PAYLOAD_DIR/simple/no-extension"
printf '#!/bin/sh\necho "I am executable"\n' > "$PAYLOAD_DIR/simple/exec-script.sh"
chmod 0755 "$PAYLOAD_DIR/simple/exec-script.sh"

# ── 2. hierarchy/ ─────────────────────────────────────────────────────────────
for depth in 1 2 3 4 5; do
    path="$PAYLOAD_DIR/hierarchy"
    for lvl in $(seq 1 $depth); do path="$path/level${lvl}"; done
    mkdir -p "$path"; echo "depth=${depth}" > "$path/file.txt"
done
mkdir -p "$PAYLOAD_DIR/hierarchy/level1/sibling-a" "$PAYLOAD_DIR/hierarchy/level1/sibling-b"
echo "sibling-a content" > "$PAYLOAD_DIR/hierarchy/level1/sibling-a/data.txt"
echo "sibling-b content" > "$PAYLOAD_DIR/hierarchy/level1/sibling-b/data.txt"

# ── 3. links/ ─────────────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/links"
SHARED_CONTENT="shared content — same hash expected in both catalog entries"
echo "$SHARED_CONTENT" > "$PAYLOAD_DIR/links/original.txt"
echo "$SHARED_CONTENT" > "$PAYLOAD_DIR/links/duplicate.txt"
ln -s "../simple/hello.txt"  "$PAYLOAD_DIR/links/rel-symlink-to-hello"
ln -s "../nonexistent-target" "$PAYLOAD_DIR/links/dangling-symlink"

# ── 4. large/ (legacy 8 MiB case, now deterministic) ──────────────────────────
mkdir -p "$PAYLOAD_DIR/large"
gen_rand "$AVG" 1 "$PAYLOAD_DIR/large/large-8m.bin"

# ── 5. permissions/ ──────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/permissions/private-dir" "$PAYLOAD_DIR/permissions/group-dir"
echo "world readable"  > "$PAYLOAD_DIR/permissions/world-readable.txt"
echo "owner only"      > "$PAYLOAD_DIR/permissions/owner-only.txt"
echo "read only"       > "$PAYLOAD_DIR/permissions/readonly.txt"
echo "group readable"  > "$PAYLOAD_DIR/permissions/group-readable.txt"
chmod 0644 "$PAYLOAD_DIR/permissions/world-readable.txt"
chmod 0600 "$PAYLOAD_DIR/permissions/owner-only.txt"
chmod 0444 "$PAYLOAD_DIR/permissions/readonly.txt"
chmod 0640 "$PAYLOAD_DIR/permissions/group-readable.txt"
chmod 0700 "$PAYLOAD_DIR/permissions/private-dir"
chmod 0750 "$PAYLOAD_DIR/permissions/group-dir"

# ── 6. unusual-names/ ────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/unusual-names"
echo "space" > "$PAYLOAD_DIR/unusual-names/file with spaces.txt"
echo "multi-space" > "$PAYLOAD_DIR/unusual-names/file  with  many  spaces.txt"
echo "brackets" > "$PAYLOAD_DIR/unusual-names/file[square-brackets].txt"
echo "parens" > "$PAYLOAD_DIR/unusual-names/file(parens-here).txt"
echo "hash-bang" > "$PAYLOAD_DIR/unusual-names/file#hash!bang.txt"
echo "tilde" > "$PAYLOAD_DIR/unusual-names/file~tilde.txt"
echo "punct" > "$PAYLOAD_DIR/unusual-names/file,comma;semicolon.txt"
echo "hidden" > "$PAYLOAD_DIR/unusual-names/.hidden-dotfile"
echo "cafe" > "$PAYLOAD_DIR/unusual-names/unicode-café.txt"
echo "resume" > "$PAYLOAD_DIR/unusual-names/unicode-résumé.txt"
echo "japanese" > "$PAYLOAD_DIR/unusual-names/unicode-日本語.txt"
LONG_NAME="$(printf 'a%.0s' {1..200}).txt"
echo "long name" > "$PAYLOAD_DIR/unusual-names/${LONG_NAME}"
echo "dash" > "$PAYLOAD_DIR/unusual-names/-not-a-flag.txt"

# ── 7. empty-dir/ ─────────────────────────────────────────────────────────────
mkdir -p "$PAYLOAD_DIR/empty-dir"

# ── 8. chunk/ — (A) chunk boundaries + intra-file dedup ───────────────────────
# Sizes sit exactly on the live min/avg/max thresholds so the test catches any
# divergence between bits' chunker and CVMFS content-defined chunking.
mkdir -p "$PAYLOAD_DIR/chunk"
gen_rand $((MIN - 1048576))     10 "$PAYLOAD_DIR/chunk/whole-small.bin"   # 3 MiB, below min -> single object
gen_rand "$MIN"                 11 "$PAYLOAD_DIR/chunk/at-min.bin"        # exactly min
gen_rand "$AVG"                 12 "$PAYLOAD_DIR/chunk/at-avg.bin"        # exactly avg
gen_rand "$MAX"                 13 "$PAYLOAD_DIR/chunk/at-max.bin"        # exactly max
gen_rand $((MAX + 65536))       14 "$PAYLOAD_DIR/chunk/over-max.bin"     # max+64K -> >=2 chunks
gen_rand $((AVG * 5))           15 "$PAYLOAD_DIR/chunk/multi-large.bin"  # 40 MiB -> several chunks
# Intra-file dedup: one deterministic AVG-sized block repeated 4x. The same
# chunk hash must recur; CVMFS/bits should both dedup it.
gen_rand "$AVG" 16 "$PAYLOAD_DIR/chunk/.block"
cat "$PAYLOAD_DIR/chunk/.block" "$PAYLOAD_DIR/chunk/.block" \
    "$PAYLOAD_DIR/chunk/.block" "$PAYLOAD_DIR/chunk/.block" \
    > "$PAYLOAD_DIR/chunk/repeated-blocks.bin"
rm -f "$PAYLOAD_DIR/chunk/.block"

# ── 9. compress/ — (B) compressibility extremes ───────────────────────────────
mkdir -p "$PAYLOAD_DIR/compress"
head -c $((AVG + AVG/2)) /dev/zero > "$PAYLOAD_DIR/compress/zeros.bin"     # 12 MiB zeros (maximally compressible)
gen_rand $((AVG + AVG/2)) 20 "$PAYLOAD_DIR/compress/random.bin"           # 12 MiB incompressible
gen_rand "$MIN" 21 "$WORK_DIR/.precompress.src"
gzip -n -c "$WORK_DIR/.precompress.src" > "$PAYLOAD_DIR/compress/precompressed.gz"  # -n => deterministic header
rm -f "$WORK_DIR/.precompress.src"

# ── 10. nested/ + manyfiles/ — (C) nested catalog + scale ─────────────────────
mkdir -p "$PAYLOAD_DIR/nested/sub"
touch "$PAYLOAD_DIR/nested/.cvmfscatalog"      # forces a nested-catalog boundary
echo "nested root file" > "$PAYLOAD_DIR/nested/file-a.txt"
echo "nested sub file"  > "$PAYLOAD_DIR/nested/sub/file-b.txt"
mkdir -p "$PAYLOAD_DIR/manyfiles"
for i in $(seq -w 1 2000); do echo "f$i" > "$PAYLOAD_DIR/manyfiles/f${i}.txt"; done

# ── 11. meta/ — (D) metadata fidelity (bits-compatible subset) ────────────────
mkdir -p "$PAYLOAD_DIR/meta/sticky-dir"
echo "setuid" > "$PAYLOAD_DIR/meta/setuid";  chmod 4755 "$PAYLOAD_DIR/meta/setuid"
echo "setgid" > "$PAYLOAD_DIR/meta/setgid";  chmod 2755 "$PAYLOAD_DIR/meta/setgid"
chmod 1777 "$PAYLOAD_DIR/meta/sticky-dir"
# Relative symlink chain: chain-1 -> chain-2 -> chain-target.txt
echo "chain target" > "$PAYLOAD_DIR/meta/chain-target.txt"
ln -s "chain-target.txt" "$PAYLOAD_DIR/meta/chain-2"
ln -s "chain-2"          "$PAYLOAD_DIR/meta/chain-1"
# All 256 byte values, no trailing newline.
for b in $(seq 0 255); do printf "\\$(printf '%03o' "$b")"; done > "$PAYLOAD_DIR/meta/all-bytes.bin"

# ── 12. optional bits-incompatible cases (default OFF) ────────────────────────
TAR_LINK_FLAG="--hard-dereference"
if [[ "$INCOMPAT" == "1" ]]; then
    # True hardlink group (POSIX type-1) — currently crashes cvmfs-prepub staging.
    echo "hardlinked content" > "$PAYLOAD_DIR/meta/hardlink-a"
    ln "$PAYLOAD_DIR/meta/hardlink-a" "$PAYLOAD_DIR/meta/hardlink-b"
    # Absolute symlink — currently rejected by cvmfs-prepub unpack.
    ln -s "/etc/hostname" "$PAYLOAD_DIR/meta/abs-symlink"
    TAR_LINK_FLAG=""   # keep real hardlinks in the tar
    echo "PAYLOAD_INCLUDE_INCOMPATIBLE=1: added hardlink group + absolute symlink"
fi

# ── 13. Build the tar (reproducible) ──────────────────────────────────────────
tar \
    --create \
    --file="$PAYLOAD_TAR" \
    --directory="$PAYLOAD_DIR" \
    $TAR_LINK_FLAG \
    --preserve-permissions \
    --sort=name \
    --mtime=@1577836800 \
    --owner=0 --group=0 --numeric-owner \
    .

echo "Payload directory: $PAYLOAD_DIR"
echo "Payload tar:       $PAYLOAD_TAR  ($(du -sh "$PAYLOAD_TAR" | cut -f1))"
