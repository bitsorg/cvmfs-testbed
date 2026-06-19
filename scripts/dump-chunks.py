#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# dump-chunks.py — normalized, COMPRESSOR-INDEPENDENT chunk-level catalog dump.
#
# Emits one line per catalog entry under a subtree, sorted by relative path:
#   <relpath>\t<type>\t<mode>\t<size>\t<symlink>\t<nchunks>\t<off:size:csha1,...>
# where csha1 is SHA-1 of the DECOMPRESSED chunk content. Two repos produced by
# different zlib implementations (bits vs native cvmfs_server) compare EQUAL iff
# their content and chunk boundaries match. Compressed-object hashes, mtimes,
# revision and md5path (all legitimately divergent) are excluded.
#
# Usage: dump-chunks.py <cas-root> <strip-prefix>
#   cas-root      repo CAS root (contains data/ and .cvmfspublished)
#   strip-prefix  subtree mount path to strip, e.g. /test/smoke.17
import sys, os, zlib, sqlite3, tempfile, hashlib, stat as st
from collections import defaultdict

cas_root = sys.argv[1]
strip_prefix = sys.argv[2].rstrip('/')

def obj(h, suf=""): return os.path.join(cas_root, "data", h[:2], h[2:] + suf)
def decat(h):
    raw = zlib.decompress(open(obj(h, "C"), "rb").read())
    fd, t = tempfile.mkstemp(suffix=".sqlite"); os.write(fd, raw); os.close(fd); return t
def csha1(h, partial):
    p = obj(h.lower(), "P" if partial else "")
    try: raw = zlib.decompress(open(p, "rb").read())
    except FileNotFoundError: return "MISSING"
    except zlib.error: return "ZLIBERR"
    return hashlib.sha1(raw).hexdigest()

root = None
for line in open(os.path.join(cas_root, ".cvmfspublished"), "rb"):
    if line[:1] == b"C": root = line[1:].strip().decode(); break

queue=[root]; seen=set(); out=[]
while queue:
    h = queue.pop(0)
    if h in seen: continue
    seen.add(h)
    db = decat(h); cc = sqlite3.connect(db)
    rp = dict(cc.execute("select key,value from properties")).get("root_prefix", "")
    for (_p, nh) in cc.execute("select path,sha1 from nested_catalogs"):
        if nh and nh not in seen: queue.append(nh)
    ents = {}
    for m1,m2,p1,p2,name,mode,size,flags,symlink,hh in cc.execute(
        "select md5path_1,md5path_2,parent_1,parent_2,name,mode,size,flags,symlink,hex(hash) from catalog"):
        ents[(m1,m2)] = (( p1,p2), name, mode, size, flags, symlink or "", hh or "")
    children = defaultdict(list)
    for k,v in ents.items(): children[v[0]].append(k)
    roots = [k for k,v in ents.items() if v[0] not in ents]
    chunks = defaultdict(list)
    for m1,m2,off,sz,ch in cc.execute("select md5path_1,md5path_2,offset,size,hex(hash) from chunks order by offset"):
        chunks[(m1,m2)].append((off,sz,ch))
    for r in roots:
        stack=[(r, rp)]
        while stack:
            key, full = stack.pop()
            v = ents[key]
            for ck in children.get(key, []):
                stack.append((ck, full + "/" + ents[ck][1]))
            out.append((full, v, chunks.get(key, [])))
    os.unlink(db)

def typ(m):
    if st.S_ISDIR(m): return "d"
    if st.S_ISLNK(m): return "l"
    if st.S_ISREG(m): return "f"
    return "?"

lines=[]
for full, v, chs in out:
    if not full.startswith(strip_prefix): continue
    rel = full[len(strip_prefix):].lstrip("/")
    if rel == "": continue
    (_p, name, mode, size, flags, symlink, hh) = v
    t = typ(mode); perm = oct(mode & 0o7777)[2:]
    if t == "f":
        if chs:
            cs = ",".join(f"{o}:{s}:{csha1(c, True)}" for (o,s,c) in chs); n = len(chs)
        elif hh and hh != "0"*40:
            cs = f"0:{size}:{csha1(hh, False)}"; n = 1
        else:
            cs = "EMPTY"; n = 0
        lines.append(f"{rel}\t{t}\t{perm}\t{size}\t\t{n}\t{cs}")
    elif t == "l":
        lines.append(f"{rel}\t{t}\t{perm}\t0\t{symlink}\t0\t")
    else:
        lines.append(f"{rel}\t{t}\t{perm}\t0\t\t0\t")

lines.sort()
sys.stdout.write("\n".join(lines) + "\n")
