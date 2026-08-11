# Storage topology: `STORAGE=s3` by default, `local` still available

Status: agreed 2026-08-11, implementation in progress.

Not a numbered ADR on purpose — the ADR numbering in the sibling `bits` repo has
collisions and stale drafts, and this note is meant to be read, not catalogued.

## Why

Production serves repositories from S3. The testbed did not, so the two diverged
in a way that hid a real defect: with `direct_s3=true` the data objects go to the
bucket while the catalogs go through the gateway to whatever
`CVMFS_UPSTREAM_STORAGE` the *receiver* has — local disk, here. The result is a
repository split across two stores where **neither store is complete**:

| object | stratum0 | MinIO |
|---|---|---|
| `.cvmfspublished`, catalogs | 200 | 404 |
| data objects | 404 | 200 |

Metadata resolves, so `ls` works and reports correct sizes; every read fails with
`Input/output error`. `cvmfs_swissknife check` reports "no problems found" on it.

The publish is not at fault — the direct-S3 arm wrote 147,261 objects against the
gateway arm's 147,262, a difference of one. What is missing is a serving topology
in which catalogs and data share a store.

`cvmfs_server_ingest.sh` states the design plainly: direct-S3 sends data objects
to the object store "with the publisher's own S3 credentials; **catalogs still go
through the gateway**". So the feature is only complete when the gateway's
receiver writes into the same bucket. Its one guard checks the *publisher's*
upstream is `gw` — the wrong end of the pipe. `CVMFS_S3_BUCKET` appears zero times
in `cvmfs_server`, so nothing compares the two, and the mismatch is silent.

## Decisions

**1. `STORAGE=s3|local`, defaulting to `s3`.** One variable drives the compose
profile, the receiver's `CVMFS_UPSTREAM_STORAGE`, `CVMFS_STRATUM0` and the
client's `CVMFS_SERVER_URL`.

`S3_ENABLED` keeps its existing, narrower meaning — MinIO is running and the
per-job `direct_s3` capability is available. Conflating the two is precisely what
produced the split repository, so they stay separate knobs:

- `S3_ENABLED=1` — the object store exists.
- `STORAGE=s3` — the repository is *served from* it.

`local` remains fully supported. It is the comparison baseline for every
measurement taken so far, and those numbers stop being reproducible if it decays.

**2. One canonical `<repo>.s3.conf`.** Generated once by `init.sh` into
`config/s3/`, mounted read-only at `/etc/cvmfs/<repo>.s3.conf` everywhere it is
needed — gateway (receiver), prepub, native-publisher, bootstrap. Today the prepub
entrypoint writes its own copy, so three components could disagree about the
bucket while each looked internally consistent.

**3. Snapshot covers both stores.** `cmd_snapshot` captures the repository *and*
the bucket; `cmd_restore` puts both back. This keeps `make clean && make`
meaning what it has always meant, and keeps cold starts cheap.

The alternative — no snapshot under S3, always re-create — was considered and
rejected as too slow per cycle. The known cost of keeping snapshots is recorded
below.

**4. `mkfs` runs in a private mount namespace when autofs holds `/cvmfs`.**
`check_autofs_on_cvmfs` greps `/proc/mounts` for `^/etc/auto.cvmfs /cvmfs `, and a
build host that is itself a CVMFS client always matches. `init.sh`'s existing
remedy is an interactive prompt offering to stop autofs, which unmounts that
host's production repositories.

Instead, when autofs is detected the mkfs step re-executes under:

```
unshare -m --propagation private -- bash -c 'umount -l /cvmfs; <mkfs>'
```

The unmount does not propagate back, so the host keeps autofs and its mounts stay
readable throughout. Verified: inside the namespace `/cvmfs` has zero mounts;
outside, all four CERN repositories are still mounted and readable.

This also explains why `mkfs -s` succeeded in a container during the spike while
failing on the host — a container has its own mount namespace.

## Consequences, including the unwelcome ones

**The snapshot keeps standing in for the create path.** This is the known cost of
decision 3. `make clean` preserves the snapshot and `cmd_start` auto-restores from
it, so the `mkfs` path runs only when the snapshot is absent. That is exactly how
the create path silently stopped working on this host, and how a `cvmfs-bootstrap`
image that could not load `cvmfs_swissknife` at all reported success on every run.
Decision 4 removes the autofs half of that breakage; it does not remove the
masking. **The create path needs periodic exercise on purpose** — a CI job that
deletes the snapshot and rebuilds is the obvious mitigation and is not yet
written.

**Snapshot size.** A bucket snapshot taken after a real publish is ~8 GB, against
18 KB for a bootstrap-only repository snapshot. Snapshots are only meaningful
bootstrap-only; taking one after a publish has already caused a wrong measurement
once, when the seed reached 150 MB and pre-populated the repository while the
bucket was wiped. The size guard belongs in `cmd_snapshot`.

**`make clean` semantics under S3.** `data/minio` lives under `data/`, which
`clean` wipes — so `clean` destroys the repository itself, not just caches, and
restore is the only way back. Correct for measurement (both stores start cold and
symmetric, which was not true of the August runs) but less forgiving than the
local backend, where the repository survives in `repos/`.

**Direct-S3 becomes coherent.** With the receiver writing catalogs to the same
bucket, `direct_s3=true` stops producing split repositories. The per-job toggle
becomes a genuine transport choice rather than a way to break the repository.

## Not decided here

- Whether `cvmfs_server` should refuse `--direct-s3` when the gateway's upstream
  is not the same bucket. It should, and it would have turned this into one line
  of output, but it is an upstream change and is tracked separately.
- Stratum1 behaviour under an S3 stratum0.
- Latency injection, which is what would make any of the wall-clock numbers
  transferable to production.
