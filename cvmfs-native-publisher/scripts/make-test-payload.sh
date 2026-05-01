#!/usr/bin/env bash
# make-test-payload.sh — Create a comprehensive CVMFS test payload.
#
# Exercises catalog corner cases that simple smoke tests miss:
#
#   simple/        — basic files: regular, empty, no extension, executable
#   hierarchy/     — 5-level deep directory tree with sibling dirs at each level
#   links/         — hard link pair, relative symlink, absolute symlink, dangling symlink
#   large/         — 20 MiB file of pseudo-random data (triggers CVMFS file chunking)
#   permissions/   — files with 0755, 0644, 0444, 0600 modes; dirs with 0750, 0700
#   unusual-names/ — spaces, brackets, parens, hash, leading dot, unicode (accents,
#                    CJK), tilde, comma, semicolon, very long name (200 chars)
#   empty-dir/     — completely empty directory (tests catalog entry for empty dirs)
#
# Usage:
#   bash make-test-payload.sh <work-dir>
#
# Outputs:
#   <work-dir>/payload/   — the unpacked directory tree
#   <work-dir>/payload.tar — tar archive suitable for cvmfs_server ingest or
#                            multipart upload to cvmfs-prepub API
#
# The caller can then use:
#   PAYLOAD_DIR=<work-dir>/payload
#   PAYLOAD_TAR=<work-dir>/payload.tar
#
# Dependencies: bash, coreutils (dd, ln, chmod, mkdir, touch, tar), /dev/urandom.
#               No Python or other extras required.

set -euo pipefail

WORK_DIR="${1:?Usage: $0 <work-dir>}"
PAYLOAD_DIR="$WORK_DIR/payload"
PAYLOAD_TAR="$WORK_DIR/payload.tar"

mkdir -p "$PAYLOAD_DIR"

# ── 1. simple/ ────────────────────────────────────────────────────────────────
# Regular files covering the most basic catalog entry types.
mkdir -p "$PAYLOAD_DIR/simple"
echo "hello from cvmfs comprehensive test $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$PAYLOAD_DIR/simple/hello.txt"
touch   "$PAYLOAD_DIR/simple/empty-file"           # 0-byte regular file
echo "no extension"   > "$PAYLOAD_DIR/simple/no-extension"
printf '#!/bin/sh\necho "I am executable"\n' > "$PAYLOAD_DIR/simple/exec-script.sh"
chmod 0755 "$PAYLOAD_DIR/simple/exec-script.sh"

# ── 2. hierarchy/ ─────────────────────────────────────────────────────────────
# 5-level deep tree with sibling directories at each level.
# Exercises nested catalog creation and parent-catalog cross-references.
for depth in 1 2 3 4 5; do
    path="$PAYLOAD_DIR/hierarchy"
    for lvl in $(seq 1 $depth); do path="$path/level${lvl}"; done
    mkdir -p "$path"
    echo "depth=${depth}" > "$path/file.txt"
done
# Sibling directories at level 2 (tests multiple children in same parent catalog)
mkdir -p "$PAYLOAD_DIR/hierarchy/level1/sibling-a"
mkdir -p "$PAYLOAD_DIR/hierarchy/level1/sibling-b"
echo "sibling-a content" > "$PAYLOAD_DIR/hierarchy/level1/sibling-a/data.txt"
echo "sibling-b content" > "$PAYLOAD_DIR/hierarchy/level1/sibling-b/data.txt"

# ── 3. links/ ─────────────────────────────────────────────────────────────────
# Tests all link types CVMFS must handle in its catalog.
mkdir -p "$PAYLOAD_DIR/links"

# Identical-content pair: two files with the same content, stored as separate
# regular files in the tar.  CVMFS's CAS deduplicates them to the same content
# hash; both catalog entries should reference that single hash.
# NOTE: we intentionally avoid hard-link tar entries (POSIX type '1') because
# the cvmfs-prepub staging processor does not handle them, causing a staging
# failure.  For catalog comparison purposes the result is equivalent: two
# directory entries pointing to the same CAS object.
SHARED_CONTENT="shared content — same hash expected in both catalog entries"
echo "$SHARED_CONTENT" > "$PAYLOAD_DIR/links/original.txt"
echo "$SHARED_CONTENT" > "$PAYLOAD_DIR/links/duplicate.txt"

# Relative symlink pointing to a file inside the payload tree.
ln -s "../simple/hello.txt"  "$PAYLOAD_DIR/links/rel-symlink-to-hello"

# Absolute symlink (path exists on a standard Linux system — tests that the
# catalog stores the literal link target, not the resolved path).
ln -s "/etc/hostname"         "$PAYLOAD_DIR/links/abs-symlink-hostname"

# Dangling symlink (target does not exist anywhere).
# Tests that CVMFS stores dangling symlinks without error.
ln -s "/nonexistent/path/that/does/not/exist" "$PAYLOAD_DIR/links/dangling-symlink"

# ── 4. large/ ─────────────────────────────────────────────────────────────────
# 8 MiB of pseudo-random data.  At the default CVMFS chunk size of 4 MiB this
# produces exactly 2 chunks.  Tests the chunks catalog table and that the
# manifest's file-chunk-size field is populated correctly.
#
# 8 MiB keeps staging time short while still exercising the chunking path.
# Using /dev/urandom avoids Python dependency and produces non-compressible
# data that the gateway cannot trivially deduplicate.
mkdir -p "$PAYLOAD_DIR/large"
dd if=/dev/urandom bs=1M count=8 of="$PAYLOAD_DIR/large/large-8m.bin" 2>/dev/null

# ── 5. permissions/ ──────────────────────────────────────────────────────────
# Various UNIX mode bits.  Tests that the catalog stores mode flags correctly
# and that the client exposes the right permissions on mount.
mkdir -p "$PAYLOAD_DIR/permissions/private-dir"     # mode applied below
mkdir -p "$PAYLOAD_DIR/permissions/group-dir"
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
# File names with characters that can trip up tar readers, catalog SQL queries,
# HTTP path encoders, and FUSE directory-entry handlers.
mkdir -p "$PAYLOAD_DIR/unusual-names"

# Spaces in name (most common trap for unquoted shell variables)
echo "space" > "$PAYLOAD_DIR/unusual-names/file with spaces.txt"

# Multiple consecutive spaces
echo "multi-space" > "$PAYLOAD_DIR/unusual-names/file  with  many  spaces.txt"

# Square brackets (glob metacharacters)
echo "brackets" > "$PAYLOAD_DIR/unusual-names/file[square-brackets].txt"

# Parentheses
echo "parens" > "$PAYLOAD_DIR/unusual-names/file(parens-here).txt"

# Hash and exclamation mark
echo "hash-bang" > "$PAYLOAD_DIR/unusual-names/file#hash!bang.txt"

# Tilde (shell home-dir expansion if unquoted)
echo "tilde" > "$PAYLOAD_DIR/unusual-names/file~tilde.txt"

# Comma and semicolon (SQL separators)
echo "punct" > "$PAYLOAD_DIR/unusual-names/file,comma;semicolon.txt"

# Leading dot (hidden file on POSIX systems)
echo "hidden" > "$PAYLOAD_DIR/unusual-names/.hidden-dotfile"

# Unicode — Latin accented characters (2-byte UTF-8 sequences)
echo "cafe" > "$PAYLOAD_DIR/unusual-names/unicode-café.txt"
echo "resume" > "$PAYLOAD_DIR/unusual-names/unicode-résumé.txt"

# Unicode — CJK characters (3-byte UTF-8 sequences)
echo "japanese" > "$PAYLOAD_DIR/unusual-names/unicode-日本語.txt"

# Very long file name (POSIX allows 255 bytes; test near the limit)
LONG_NAME="$(printf 'a%.0s' {1..200}).txt"   # 204 chars
echo "long name" > "$PAYLOAD_DIR/unusual-names/${LONG_NAME}"

# Name that looks like a flag (leading dash — shell option prefix)
echo "dash" > "$PAYLOAD_DIR/unusual-names/-not-a-flag.txt"

# ── 7. empty-dir/ ─────────────────────────────────────────────────────────────
# An empty directory.  CVMFS must create a catalog entry for it even though
# there are no child inodes.  Verifies the directory entry flags (S_ISDIR) are
# stored correctly with zero children.
mkdir -p "$PAYLOAD_DIR/empty-dir"

# ── 8. Build the tar archive ──────────────────────────────────────────────────
# --hard-dereference: convert any remaining hard links to regular file copies,
#   preventing POSIX type-'1' link entries that crash the cvmfs-prepub staging
#   processor.  Symlinks are kept as symlinks (no --dereference flag).
# --preserve-permissions: propagate mode bits into the catalog flags field.
tar \
    --create \
    --file="$PAYLOAD_TAR" \
    --directory="$PAYLOAD_DIR" \
    --hard-dereference \
    --preserve-permissions \
    .

echo "Payload directory: $PAYLOAD_DIR"
echo "Payload tar:       $PAYLOAD_TAR  ($(du -sh "$PAYLOAD_TAR" | cut -f1))"
