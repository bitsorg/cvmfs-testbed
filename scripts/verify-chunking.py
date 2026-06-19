#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# verify-chunking.py — verify that bits' published catalog chunk boundaries
# match CVMFS's xor32 content-defined chunker (chunk_detector.cc) exactly.
#
# CVMFS's tarball *ingest* path does not chunk (swissknife ingest has no
# chunking option), so the oracle is CVMFS's chunking ALGORITHM, reproduced
# faithfully in cvmfs-chunk-reference.py. This compares, for every regular file
# in the latest bits-published subtree, the catalog chunk offsets against the
# reference cut points computed from the canonical payload.
#
# Usage: verify-chunking.py <cas-root> <payload-tar> <min> <avg> <max> [subtree-substr]
# Exit 0 on full match, 1 on any divergence.
import sys, os, tarfile, zlib, sqlite3, tempfile, importlib.util

cas, tar_path = sys.argv[1], sys.argv[2]
MN, AVG, MX = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
want = sys.argv[6] if len(sys.argv) > 6 else "smoke"

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ref", os.path.join(here, "cvmfs-chunk-reference.py"))
ref = importlib.util.module_from_spec(spec); spec.loader.exec_module(ref)

tf = tarfile.open(tar_path)
files = {os.path.basename(m.name): tf.extractfile(m).read()
         for m in tf.getmembers() if m.isfile() and m.name.endswith(".bin")}

def dec(h):
    raw = zlib.decompress(open(f"{cas}/data/{h[:2]}/{h[2:]}C", "rb").read())
    fd, t = tempfile.mkstemp(); os.write(fd, raw); os.close(fd); return t

root = [l[1:].strip().decode() for l in open(f"{cas}/.cvmfspublished", "rb") if l[:1] == b"C"][0]
c = sqlite3.connect(dec(root))
subs = [(p, h) for (p, h) in c.execute("select path,sha1 from nested_catalogs") if want in p]
if not subs:
    print(f"no subtree matching {want!r}"); sys.exit(2)
path, sha = subs[-1]
cc = sqlite3.connect(dec(sha))
print(f"verifying bits {path} vs CVMFS xor32({MN}/{AVG}/{MX})")
allok = True; n_checked = 0
for nm, data in sorted(files.items()):
    r = cc.execute("select md5path_1,md5path_2 from catalog where name=?", (nm,)).fetchone()
    if not r: continue
    offs = [o for (o,) in cc.execute(
        "select offset from chunks where md5path_1=? and md5path_2=? order by offset", (r[0], r[1]))]
    bits_cuts = offs[1:] if offs else []
    ref_cuts = ref.cuts(data, MN, AVG, MX)
    ok = bits_cuts == ref_cuts; allok = allok and ok; n_checked += 1
    print(f"  {nm:22s} bits={len(offs)} chunks  ref={len(ref_cuts)} cuts  {'OK' if ok else 'DIFFER'}")
    if not ok:
        print(f"     bits cuts: {bits_cuts}\n     ref  cuts: {ref_cuts}")
print(f"\n{'PASS' if allok else 'FAIL'}: {n_checked} files checked — "
      + ("bits reproduces CVMFS xor32 chunking exactly." if allok else "divergence detected."))
sys.exit(0 if allok else 1)
