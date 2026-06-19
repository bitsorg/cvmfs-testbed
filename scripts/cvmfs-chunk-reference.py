#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# cvmfs-chunk-reference.py — faithful port of CVMFS's content-defined chunker
# (cvmfs/cvmfs/ingestion/chunk_detector.cc, Xor32Detector). The CVMFS tarball
# *ingest* path does not chunk (swissknife ingest has no chunking option); the
# xor32 detector is what cvmfs_server publish/sync uses. This reference computes
# the exact CVMFS chunk boundaries for a file so the testbed can verify bits
# reproduces them.  Returns the cut offsets (exclusive chunk ends / next starts).
import sys

WINDOW = 32
MAGIC = 0x7FFFFFFF  # UINT32_MAX/2

def to_s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if (v & 0x80000000) else v

def cuts(data, mn, avg, mx):
    n = len(data)
    if mn == 0 or n <= mn:
        return []
    th = 0xFFFFFFFF // avg
    out = []
    last = 0
    while True:
        if n - last <= mn:
            break
        ss = last + mn
        hard = last + mx
        se = min(hard, n)
        x = 0
        for i in range(ss - WINDOW, ss):
            x = ((x << 1) ^ data[i]) & 0xFFFFFFFF
        cut = -1
        for i in range(ss, se):
            x = ((x << 1) ^ data[i]) & 0xFFFFFFFF
            d = to_s32((to_s32(x) - MAGIC) & 0xFFFFFFFF)
            if d < 0:
                d = to_s32((-d) & 0xFFFFFFFF)
            if d < th:
                cut = i
                break
        if cut < 0:
            if se == hard:
                cut = hard
            else:
                break
        out.append(cut)
        last = cut
    return out

if __name__ == "__main__":
    mn, avg, mx = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    data = open(sys.argv[1], "rb").read()
    print(",".join(str(c) for c in cuts(data, mn, avg, mx)))
