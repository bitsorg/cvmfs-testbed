#!/usr/bin/env bash
# make-stress-payload.sh — Generate realistic test tar files for deduplication stress testing.
#
# Creates NUM_TARS plain (uncompressed) tar files in OUTPUT_DIR, each containing:
#   - SHARED_FILES identical binary files (same content across all tars)
#   - UNIQUE_FILES unique binary files (different per tar)
#
# Shared files are generated once from /dev/urandom and then hard-linked into
# each package directory.  Because the bytes are byte-for-byte identical, every
# occurrence has the same SHA-1 and SHA-256 digest.  When the bits pipeline
# processes jobs 2 through N, its CAS bloom-filter detects that the shared
# objects were already uploaded during job 1 and skips re-uploading them —
# demonstrating CAS deduplication in a realistic multi-package scenario.
#
# Unique files differ per tar so each job still contributes some novel content,
# preventing a degenerate 100 % dedup scenario that is not representative of
# real workloads.
#
# Flat file layout (no subdirectories inside the tar):
#   ./shared-001.bin ... ./shared-NNN.bin   (identical across all tars)
#   ./unique-001.bin ... ./unique-NNN.bin   (different per tar)
#
# The flat layout avoids sub-directory entries inside the ingest base path,
# which sidesteps the FindCatalog panic triggered by nested paths in mountless
# gateway ingest mode.
#
# Environment variables:
#   NUM_TARS      Number of tar files to create   (default: 5)
#   SHARED_FILES  Number of shared files per tar  (default: 10)
#   SHARED_SIZE   Bytes per shared file            (default: 5242880  = 5 MB)
#   UNIQUE_FILES  Number of unique files per tar  (default: 3)
#   UNIQUE_SIZE   Bytes per unique file            (default: 2097152  = 2 MB)
#   OUTPUT_DIR    Directory to write tar files to  (default: ./stress-payload)
#
# Output:
#   $OUTPUT_DIR/package-1.tar … $OUTPUT_DIR/package-N.tar
#   Each tar contains the shared + unique files at the top level.
#
# Usage example:
#   NUM_TARS=5 SHARED_FILES=10 SHARED_SIZE=$((5*1024*1024)) \
#       UNIQUE_FILES=3 UNIQUE_SIZE=$((2*1024*1024)) \
#       OUTPUT_DIR=./stress-payload \
#       ./scripts/make-stress-payload.sh
#
# Then run the bits stress test pointing at the pre-built tars:
#   PAYLOAD_DIR=./stress-payload ./scripts/stress-test.sh

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
NUM_TARS="${NUM_TARS:-5}"
SHARED_FILES="${SHARED_FILES:-10}"
SHARED_SIZE="${SHARED_SIZE:-5242880}"    # 5 MB per shared file
UNIQUE_FILES="${UNIQUE_FILES:-3}"
UNIQUE_SIZE="${UNIQUE_SIZE:-2097152}"    # 2 MB per unique file
OUTPUT_DIR="${OUTPUT_DIR:-./stress-payload}"

# ── Derived values ─────────────────────────────────────────────────────────────
TOTAL_SHARED_MB=$(( SHARED_FILES * SHARED_SIZE / 1048576 ))
TOTAL_UNIQUE_MB=$(( UNIQUE_FILES * UNIQUE_SIZE / 1048576 ))
TAR_SIZE_MB=$(( TOTAL_SHARED_MB + TOTAL_UNIQUE_MB ))

echo "make-stress-payload: configuration"
echo "  NUM_TARS      = ${NUM_TARS}"
echo "  SHARED_FILES  = ${SHARED_FILES} × $(( SHARED_SIZE / 1048576 )) MB = ${TOTAL_SHARED_MB} MB shared content"
echo "  UNIQUE_FILES  = ${UNIQUE_FILES} × $(( UNIQUE_SIZE / 1048576 )) MB = ${TOTAL_UNIQUE_MB} MB unique content per tar"
echo "  TAR_SIZE      ≈ ${TAR_SIZE_MB} MB per tar (uncompressed)"
echo "  TOTAL OUTPUT  ≈ $(( TAR_SIZE_MB * NUM_TARS )) MB across ${NUM_TARS} tars"
echo "  OUTPUT_DIR    = ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}"

# ── Stage 1: Generate shared files (once) ─────────────────────────────────────
# These files are byte-for-byte identical across all tars.  The CAS pipeline
# hashes each file and checks the bloom filter; on job 2+ the filter reports a
# hit and the object is not re-uploaded.
SHARED_DIR=$(mktemp -d)
trap 'rm -rf "${SHARED_DIR}"' EXIT

echo "Generating ${SHARED_FILES} shared binary files (${TOTAL_SHARED_MB} MB total)..."
for (( s=1; s<=SHARED_FILES; s++ )); do
    printf "  shared file %3d / %d ...\r" "$s" "$SHARED_FILES"
    dd if=/dev/urandom \
       of="${SHARED_DIR}/$(printf 'shared-%03d.bin' $s)" \
       bs=65536 count=$(( SHARED_SIZE / 65536 )) \
       status=none 2>/dev/null
done
echo "  Shared files ready.                          "

# ── Stage 2: Build one tar per package ────────────────────────────────────────
# Each tar is assembled in a temp directory:
#   - shared-*.bin  copied from SHARED_DIR  (identical bytes → same CAS hash)
#   - unique-*.bin  generated fresh          (different bytes per tar)
PKG_TMP=$(mktemp -d)
trap 'rm -rf "${SHARED_DIR}" "${PKG_TMP}"' EXIT

echo "Creating ${NUM_TARS} tar files..."
for (( i=1; i<=NUM_TARS; i++ )); do
    PKG_DIR="${PKG_TMP}/pkg-${i}"
    mkdir -p "${PKG_DIR}"

    # Copy shared files (cp preserves bytes; ln -s would work too but cp is
    # simpler and avoids any platform-specific symlink behaviour in tar).
    cp "${SHARED_DIR}"/shared-*.bin "${PKG_DIR}/"

    # Generate unique files for this package.
    for (( u=1; u<=UNIQUE_FILES; u++ )); do
        dd if=/dev/urandom \
           of="${PKG_DIR}/$(printf 'unique-%03d.bin' $u)" \
           bs=65536 count=$(( UNIQUE_SIZE / 65536 )) \
           status=none 2>/dev/null
    done

    TAR_OUT="${OUTPUT_DIR}/package-${i}.tar"
    tar -cf "${TAR_OUT}" -C "${PKG_DIR}" .

    TAR_BYTES=$(stat -c%s "${TAR_OUT}" 2>/dev/null || stat -f%z "${TAR_OUT}")
    echo "  package-${i}.tar  ($(( TAR_BYTES / 1048576 )) MB)"

    # Clean up package staging dir immediately to avoid accumulating ~N×TAR_SIZE
    # of temp data when NUM_TARS is large.
    rm -rf "${PKG_DIR}"
done

echo ""
echo "Done.  ${NUM_TARS} tar files written to ${OUTPUT_DIR}/"
echo ""
echo "Run the bits stress test with:"
echo "  PAYLOAD_DIR=${OUTPUT_DIR} \\"
echo "  NUM_JOBS=${NUM_TARS} \\"
echo "  PREPUB_API_TOKEN=\$PREPUB_API_TOKEN \\"
echo "  PREPUB_URL=\$PREPUB_URL \\"
echo "  REPO_NAME=\$REPO_NAME \\"
echo "    ./scripts/stress-test.sh"
