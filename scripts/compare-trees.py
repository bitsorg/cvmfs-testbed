#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 CERN
# SPDX-License-Identifier: Apache-2.0
#
# compare-trees.py — directly compare two published subtrees (e.g. a bits
# publish vs the native cvmfs_server-ingest golden) for content + metadata
# equivalence, independent of compressor and chunking. For every regular file
# it computes the SHA-1 of the DECOMPRESSED whole-file content (reassembling
# chunks when present); for dirs/symlinks it compares type/mode/target. Diffs
# in compressed-object hashes, chunk layout, mtimes etc. are intentionally
# ignored — this answers "is the content + structure the same?".
#
# Usage: compare-trees.py <cas-root> <prefix-a> <prefix-b>
import sys, os, zlib, sqlite3, tempfile, hashlib, stat as st
from collections import defaultdict
cas = sys.argv[1]

def obj(h, suf=""): return f"{cas}/data/{h[:2]}/{h[2:]}{suf}"
def decat(h):
    raw = zlib.decompress(open(obj(h, "C"), "rb").read())
    fd, t = tempfile.mkstemp(); os.write(fd, raw); os.close(fd); return t
def content(catalog_hash, chunks):
    h = hashlib.sha1()
    if chunks:
        for (_o, _s, ch) in chunks:
            h.update(zlib.decompress(open(obj(ch, "P"), "rb").read()))
    elif catalog_hash and catalog_hash != "0"*40:
        try: h.update(zlib.decompress(open(obj(catalog_hash), "rb").read()))
        except FileNotFoundError: return "MISSING"
    return h.hexdigest()

def tree(prefix):
    root = [l[1:].strip().decode() for l in open(f"{cas}/.cvmfspublished","rb") if l[:1]==b"C"][0]
    q=[root]; seen=set(); out={}
    while q:
        hh=q.pop(0)
        if hh in seen: continue
        seen.add(hh)
        cc=sqlite3.connect(decat(hh))
        rp=dict(cc.execute("select key,value from properties")).get("root_prefix","")
        for (_p,nh) in cc.execute("select path,sha1 from nested_catalogs"):
            if nh and nh not in seen: q.append(nh)
        ents={}
        for m1,m2,p1,p2,name,mode,size,symlink,h in cc.execute(
            "select md5path_1,md5path_2,parent_1,parent_2,name,mode,size,symlink,hex(hash) from catalog"):
            ents[(m1,m2)]=((p1,p2),name,mode,size,symlink or "",(h or "").lower())
        ch=defaultdict(list)
        for m1,m2,o,s,c in cc.execute("select md5path_1,md5path_2,offset,size,hex(hash) from chunks order by offset"):
            ch[(m1,m2)].append((o,s,c.lower()))
        kids=defaultdict(list)
        for k,v in ents.items(): kids[v[0]].append(k)
        roots=[k for k,v in ents.items() if v[0] not in ents]
        for r in roots:
            stack=[(r,rp)]
            while stack:
                key,full=stack.pop()
                v=ents[key]
                for ck in kids.get(key,[]): stack.append((ck, full+"/"+ents[ck][1]))
                if not full.startswith(prefix): continue
                rel=full[len(prefix):].lstrip("/")
                if rel=="": continue
                _p,name,mode,size,symlink,h=v
                if st.S_ISDIR(mode): rec=("d", oct(mode&0o7777), 0, "")
                elif st.S_ISLNK(mode): rec=("l", oct(mode&0o7777), 0, symlink)
                else: rec=("f", oct(mode&0o7777), size, content(h, ch.get(key,[])))
                out[rel]=rec
    return out

a=tree(sys.argv[2].rstrip('/')); b=tree(sys.argv[3].rstrip('/'))
keys=sorted(set(a)|set(b))
only_a=[k for k in keys if k not in b]; only_b=[k for k in keys if k not in a]
content_diff=[]; meta_diff=[]
for k in keys:
    if k not in a or k not in b: continue
    if a[k]==b[k]: continue
    if a[k][0]=="f" and b[k][0]=="f" and a[k][3]!=b[k][3]: content_diff.append((k,a[k][3],b[k][3]))
    else: meta_diff.append((k,a[k],b[k]))
print(f"A={sys.argv[2]} ({len(a)} entries)  B={sys.argv[3]} ({len(b)} entries)")
print(f"only in A: {len(only_a)}   only in B: {len(only_b)}")
print(f"CONTENT mismatches: {len(content_diff)}   metadata-only diffs: {len(meta_diff)}")
for k,x,y in content_diff[:10]: print(f"  CONTENT  {k}: {x[:12]} vs {y[:12]}")
for k,x,y in meta_diff[:15]: print(f"  META     {k}: {x} vs {y}")
print("\n==> CONTENT IDENTICAL" if not content_diff else "\n==> CONTENT DIFFERS")
sys.exit(0 if not content_diff else 1)
