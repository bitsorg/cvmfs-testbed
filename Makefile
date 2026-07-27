# Makefile — cvmfs-testbed top-level build and lifecycle management.
#
# Sentinel-file pattern
# ─────────────────────
# Each one-time setup step touches a file in .make/ when it succeeds.
# Make uses the sentinel as the target so it only reruns if the sentinel is
# absent or older than its dependencies.  Delete a sentinel to force a step
# to rerun:
#   rm .make/bootstrap && make bootstrap   # re-run bootstrap only
#   rm -rf .make        && make            # re-run everything
#
# Key sentinels:
#   .make/build        cvmfs-bits compiled
#   .make/install      binaries copied to software/
#   .make/init         testbed initialised (secrets, configs, host repo)
#   .make/bootstrap    cvmfs-bootstrap container ran + snapshot created
#
# Targets:
#   make               Full pipeline: build → install → init → start → bootstrap
#   make build         git pull + make build inside cvmfs-bits/
#   make install       build, then copy binaries into software/
#   make init          One-time testbed initialisation
#   make start         Start containers (auto-restores from snapshot if present)
#   make ensure        Make the testbed ready (init+payload+start+golden), idempotent
#   make bootstrap     Run privileged bootstrap container, create snapshot
#   make snapshot      Save repo state to repo-seed.tar.gz (called by bootstrap)
#   make restore       Restore repo state from repo-seed.tar.gz
#   make redeploy      install + full reset + bootstrap
#   make clean         Stop containers and wipe all testbed state (keeps snapshot and .env)
#   make cleanall      Like clean, but also deletes .env (full credential reset)
#   make test          FULL test suite — all six tests (records metrics);
#                      auto-runs 'ensure' first so it works from ANY state;
#                      subset via  make test TESTS="bits chunking content"
#   make test-suite    Alias of `make test` (honors TESTS=)
#   make test-ingest   Suite: cvmfs_server ingest smoke (auto-ensure; skips if no golden)
#   make test-bits     Suite: cvmfs-prepub REST API smoke
#   make test-chunking Suite: bits publish + xor32 chunk verify
#   make test-content  Suite: compare-trees vs golden/smoke
#   make test-stress   Suite: stress N=10 (bits)
#   make stresstest    Stress test — bits method, N jobs (default N=10)
#   make stresstest-ingest  Stress test — ingest path
#   make catdiff       Diff catalog dumps: ingest vs bits
#   make help          Print this summary
#
# Variables (override on the command line or in the environment):
#   BITS_DIR      Path to the cvmfs-bits source tree.
#                 Default: $(CURDIR)/cvmfs-bits
#                 Example: make BITS_DIR=/home/user/src/cvmfs-bits
#   TESTBED_ROOT  Path to testbed data root (default: $HOME/cvmfs-testbed).
#                 Used to locate repo-seed.tar.gz for the bootstrap target.
#   N             Number of jobs for stresstest targets (default: 10)
#   C             Concurrency (max parallel jobs) for the bits stresstest (default: unset = script default of 2)
#
# Examples:
#   make                            # full pipeline from scratch
#   make bootstrap                  # seed nested catalog + snapshot (once)
#   make test-ingest                # run ingest smoke test (needs bootstrap)
#   make test-ingest test-bits      # run both paths
#   make catdiff                    # diff catalog dumps
#   make stresstest N=50            # 50-job bits stress test (concurrency=2)
#   make stresstest N=50 C=10       # 50-job bits stress test, 10 at a time
#   make BITS_DIR=~/cvmfs-bits      # custom bits source location
#   rm .make/bootstrap && make bootstrap  # force re-bootstrap

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Paths ─────────────────────────────────────────────────────────────────────
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TESTBED      := $(MAKEFILE_DIR)/testbed
INSTALL_SH   := $(MAKEFILE_DIR)/scripts/install.sh
MAKE_DIR     := $(MAKEFILE_DIR)/.make

# cvmfs-bits source directory — override if your clone lives elsewhere.
BITS_DIR ?= $(MAKEFILE_DIR)/cvmfs-bits

# ── Runtime introspection helpers (used by verify-* recipes) ───────────────────
# Resolve the testbed data root: prefer TESTBED_ROOT from .env, else CURDIR.
# (verify-* use relative-looking repos/ and data/ paths; this makes them work
# regardless of where the data root actually lives.)
# The value is trimmed of surrounding whitespace, a trailing CR (a .env saved
# with CRLF endings) and optional surrounding quotes.  Without the trim, a
# trailing space in .env produced paths like "/home/u/cvmfs-testbed /repos/..."
# and every verify-* target failed with a confusing "No such file or directory".
GET_TESTBED_ROOT = r=$$(sed -n 's/^TESTBED_ROOT=//p' "$(MAKEFILE_DIR)/.env" 2>/dev/null | tail -1 \
	| tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$$//' -e 's/^"\(.*\)"$$/\1/' -e "s/^'\(.*\)'$$/\1/"); \
	echo "$${r:-$(MAKEFILE_DIR)}"

# "MIN AVG MAX" chunk sizes, read from config.yaml by testbed.sh (single source
# of truth) so verify-chunking never hard-codes them and can't report a false
# divergence when config.yaml changes.
GET_CHUNK_SIZES = bash "$(TESTBED)" chunksizes

# Number of jobs for stresstest targets.
N ?= 10

# Concurrency (max parallel active jobs) for the bits stresstest.
# Leave unset to use the script's built-in default (currently 2).
# Example: make stresstest N=100 C=20
C ?=
_CONCURRENCY := $(if $(C),--concurrency $(C),)

# The ADR-0001 pull distribution (embedded MQTT-over-WSS broker) is ON BY DEFAULT.
# Set WSS=0 to start the bare base stack.
#   make start          # pull overlay on (default)
#   make WSS=0 start     # bare stack, no pull overlay
WSS ?= 1
_WSS := $(if $(filter 0 no false,$(WSS)),--no-wss,)

# Publishing method (bits|ingest) passed to start/ensure for this invocation.
METHOD ?= bits
_METHOD := $(if $(METHOD),--method $(METHOD),)

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := all

.PHONY: all build install init start start-wss ensure bootstrap snapshot restore redeploy clean cleanall baseline \
        test test-suite test-ingest test-bits test-pull test-pull-wss pull-status \
        test-chunking test-content test-stress \
        stresstest stresstest-ingest \
        verify verify-chunking verify-content \
        catdump-ingest catdump-bits catdiff \
        help

# ── Sentinel directory ────────────────────────────────────────────────────────
$(MAKE_DIR):
	mkdir -p $(MAKE_DIR)

# ── all ───────────────────────────────────────────────────────────────────────
# Full pipeline: always rebuild bits + refresh software, then init → start →
# bootstrap only when their sentinels are absent.
all: install $(MAKE_DIR)/bootstrap

# ── build ─────────────────────────────────────────────────────────────────────
# Always runs: git pull + incremental make build inside cvmfs-bits.
# No sentinel — the cvmfs-bits build system handles incrementality itself
# (unchanged source compiles in seconds).
build:
	@if [[ ! -d "$(BITS_DIR)" ]]; then \
	    echo "ERROR: BITS_DIR not found: $(BITS_DIR)"; \
	    echo "  Clone cvmfs-bits there, or override: make BITS_DIR=/path/to/cvmfs-bits"; \
	    exit 1; \
	fi
	@echo "── Pulling latest cvmfs-bits ─────────────────────────────────────────"
	cd "$(BITS_DIR)" && git pull
	@echo "── Building cvmfs-bits ───────────────────────────────────────────────"
	cd "$(BITS_DIR)" && $(MAKE) build

# ── install ───────────────────────────────────────────────────────────────────
# Always runs: copies fresh binaries from both build trees into software/.
# Depends on build so bits is up to date before the copy.
install: build
	@echo "── Installing binaries into software/ ────────────────────────────────"
	BITS_DIR="$(BITS_DIR)" bash "$(INSTALL_SH)"

# ── init ──────────────────────────────────────────────────────────────────────
# Sentinel-protected: runs only once (or after make clean).
# Order-only dependency on $(MAKE_DIR) — the phony install target is NOT listed
# here so that the sentinel is not invalidated on every make all.  The all
# target sequences install before $(MAKE_DIR)/bootstrap which depends on this.
$(MAKE_DIR)/init: | $(MAKE_DIR)
	@echo "── Initialising testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" init
	@touch $@

init: $(MAKE_DIR)/init

# ── start ─────────────────────────────────────────────────────────────────────
# Not a sentinel target — containers can start/stop independently of make state.
# Depends on init having run.  auto-restores snapshot if repo is absent.
start: $(MAKE_DIR)/init
	@echo "── Starting testbed ──────────────────────────────────────────────────"
	bash "$(TESTBED)" start $(_WSS) $(_METHOD)

# Back-compat alias — the pull overlay is on by default, so this == start.
start-wss: start

# ── ensure ────────────────────────────────────────────────────────────────────
# Idempotent readiness gate: bring up whatever is missing (init, canonical
# payload, container stack, golden tree) so the test targets ALWAYS run from any
# starting state — fresh checkout, after `make clean`, stopped stack, or already
# running.  Fast and quiet on the happy path (every sub-step is checked first).
#
# This is the RUNTIME source of truth for "is the testbed ready" — it inspects
# live container/repo state, which the .make/init and .make/bootstrap file
# sentinels cannot (those can go stale after the stack stops or is cleaned).
# The test targets therefore depend on `ensure`, NOT on the sentinels.
#
# Starts the wss overlay so the pull-wss test can also run from any state.
#
# After a successful ensure, reconcile the make sentinels so a later plain
# `make` / `make bootstrap` sees init+bootstrap as already done (ensure has
# brought the live stack to that state).  Order-only dep on $(MAKE_DIR) so the
# directory exists before we touch into it.
ensure: | $(MAKE_DIR)
	bash "$(TESTBED)" ensure $(_WSS) $(_METHOD)
	@touch $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap

# ── bootstrap ─────────────────────────────────────────────────────────────────
# Run once: seeds the nested-catalog structure required by cvmfs_server ingest,
# then creates repo-seed.tar.gz.  Re-run by deleting .make/bootstrap.
$(MAKE_DIR)/bootstrap: $(MAKE_DIR)/init
	@echo "── Starting testbed (bootstrap needs running containers) ─────────────"
	bash "$(TESTBED)" start
	@echo "── Bootstrapping repository ──────────────────────────────────────────"
	bash "$(TESTBED)" bootstrap
	@touch $@

bootstrap: $(MAKE_DIR)/bootstrap

# ── snapshot ──────────────────────────────────────────────────────────────────
# Save repo state manually (normally called automatically by bootstrap).
snapshot:
	bash "$(TESTBED)" snapshot

# ── restore ───────────────────────────────────────────────────────────────────
restore:
	bash "$(TESTBED)" restore

# ── redeploy ──────────────────────────────────────────────────────────────────
# Full rebuild: wipe sentinels + state, then run the full pipeline from scratch.
redeploy: install
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Run '"'"'make'"'"' instead to do a clean first-time setup.\n'; \
	    printf '\n'; \
	    exit 1; \
	fi
	@echo "── Stopping testbed ──────────────────────────────────────────────────"
	-bash "$(TESTBED)" stop
	@echo "── Full reset (wipes snapshot too) ───────────────────────────────────"
	bash "$(TESTBED)" clean --yes --purge-snapshot
	rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap
	@echo "── Initialising testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" init && touch $(MAKE_DIR)/init
	@echo "── Starting testbed ──────────────────────────────────────────────────"
	bash "$(TESTBED)" start
	@echo "── Bootstrapping ─────────────────────────────────────────────────────"
	bash "$(TESTBED)" bootstrap && touch $(MAKE_DIR)/bootstrap

# ── clean ─────────────────────────────────────────────────────────────────────
# Stop containers and remove runtime state.  Snapshot and .env are PRESERVED so
# services can restart with the same credentials on the next 'make start'.
# Wipe .make/init and .make/bootstrap so make knows to re-run them next time.
#
# Guard: refuse to run if the testbed has never been initialised.  Without this
# guard, docker compose expands unset ${TESTBED_ROOT} volume paths to wrong
# host paths, creating root-owned placeholder directories that overwrite files
# in the repo tree.
clean:
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Nothing to clean.  Run '"'"'make'"'"' first to set up the testbed.\n'; \
	    printf '\n'; \
	else \
	    echo "── Stopping testbed ──────────────────────────────────────────────────"; \
	    bash "$(TESTBED)" stop || true; \
	    echo "── Cleaning testbed state ────────────────────────────────────────────"; \
	    bash "$(TESTBED)" clean --yes; \
	    rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap; \
	fi

# ── cleanall ──────────────────────────────────────────────────────────────────
# Like clean, but also deletes .env — full credential reset.
# Use this when you want to regenerate secrets (gateway key, API token, etc.).
# The next 'make' will run init from scratch and create a fresh .env.
cleanall:
	@if [[ ! -f "$(MAKE_DIR)/init" ]]; then \
	    printf '\n'; \
	    printf '[WARN] testbed is not initialised — $(MAKE_DIR)/init not found.\n'; \
	    printf '       Nothing to clean.  Run '"'"'make'"'"' first to set up the testbed.\n'; \
	    printf '\n'; \
	else \
	    echo "── Stopping testbed ──────────────────────────────────────────────────"; \
	    bash "$(TESTBED)" stop || true; \
	    echo "── Cleaning testbed state (including .env) ───────────────────────────"; \
	    bash "$(TESTBED)" clean --yes --purge-snapshot --purge-env; \
	    rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap; \
	fi

# ── test targets ──────────────────────────────────────────────────────────────
# `make test` runs the FULL selectable suite (all six tests incl. stress N=10),
# recording per-test metrics to data/test-results.ndjson and live progress to
# data/test-suite-status.json.  Select a subset with TESTS:
#   make test                              # all six
#   make test TESTS="bits chunking content"
# TESTS is passed straight through to `testbed.sh suite`.
test: | ensure
	bash "$(TESTBED)" suite $(TESTS)

# Native-ingest REFERENCE BASELINE (golden/smoke). bits is the default/monitored
# path; this slow, occasional native reference feeds the content/ingest tests and
# the bits-vs-ingest comparison. Captured in the snapshot. Run once after setup.
baseline: | ensure
	bash "$(TESTBED)" baseline

# Individual smoke targets delegate to the suite so they ALSO log a
# test-results.ndjson record (keeping history complete).
test-ingest: | ensure
	bash "$(TESTBED)" suite ingest

test-bits: | ensure
	bash "$(TESTBED)" suite bits

# End-to-end pull test over the embedded MQTT-over-WSS control plane (no mosquitto).
# Requires the wss stack: run `make start-wss` (or `make WSS=1 start`) first.
test-pull-wss: | ensure
	bash "$(TESTBED)" suite pull-wss

# Convenience alias: pull distribution is now wss-only.
test-pull: test-pull-wss

# Monitoring: dump pull-relevant log lines from publisher + receivers.
pull-status:
	bash "$(TESTBED)" pullstatus --wss

# ── stresstest targets ────────────────────────────────────────────────────────
# Direct stress run (raw, N/C configurable, no test-results record).
stresstest: | ensure
	bash "$(TESTBED)" stresstest $(N) $(_CONCURRENCY) --method bits

# Suite-wrapped stress (fixed N=10) — logs a test-results.ndjson record.
test-stress: | ensure
	bash "$(TESTBED)" suite stress

stresstest-ingest: | ensure
	bash "$(TESTBED)" stresstest $(N) --method ingest

# ── catalog comparison ────────────────────────────────────────────────────────
catdump-ingest:
	bash "$(TESTBED)" catdump ingest

catdump-bits:
	bash "$(TESTBED)" catdump bits

catdiff:
	bash "$(TESTBED)" catdiff ingest bits

# ── help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "cvmfs-testbed Makefile"
	@echo ""
	@echo "  make                      Full pipeline (build→install→init→start→bootstrap)"
	@echo "  make build                git pull + compile cvmfs-bits"
	@echo "  make install              build + copy binaries to software/"
	@echo "  make init                 One-time testbed initialisation"
	@echo "  make start                Start containers (auto-restores snapshot)"
	@echo "  make ensure               Make the testbed ready (init+payload+start+golden), idempotent"
	@echo "  make bootstrap            Seed nested catalog + create snapshot (once)"
	@echo "  make snapshot             Save repo state to repo-seed.tar.gz"
	@echo "  make restore              Restore repo state from repo-seed.tar.gz"
	@echo "  make redeploy             Full rebuild from scratch"
	@echo "  make clean                Stop + wipe state (keeps snapshot and .env)"
	@echo "  make cleanall             Stop + wipe state + delete .env (fresh credentials)"
	@echo ""
	@echo "  All test/verify/stress targets auto-run 'ensure' first, so they work"
	@echo "  from ANY state (fresh checkout, after 'make clean', stopped or running)."
	@echo ""
	@echo "  make test                 FULL test suite — all six tests (records metrics)"
	@echo "  make test TESTS=\"bits chunking content\"   Run a selected subset"
	@echo "  make test-suite           Alias of 'make test' (honors TESTS=)"
	@echo "  make test-ingest          Suite: native ingest into golden/smoke (auto-ensure; skips if no golden)"
	@echo "  make test-bits            Suite: cvmfs-prepub REST API smoke"
	@echo "  make test-chunking        Suite: bits publish + xor32 chunk verify"
	@echo "  make test-content         Suite: compare-trees vs golden/smoke"
	@echo "  make test-stress          Suite: stress N=10 (bits)"
	@echo "  make test-pull-wss        Suite: end-to-end pull over embedded wss (auto-ensure --wss; skips if not up)"
	@echo "  make test-pull            Alias of test-pull-wss"
	@echo "  make pull-status          Dump pull-relevant publisher/receiver logs"
	@echo ""
	@echo "  Suite tests (names for TESTS=): bits ingest pull-wss chunking content stress"
	@echo "  Results: data/test-results.ndjson  ·  Live status: data/test-suite-status.json"
	@echo ""
	@echo "  make stresstest [N=10]    Stress test, N jobs (bits)"
	@echo "  make stresstest-ingest    Stress test (ingest path)"
	@echo ""
	@echo "  make start-wss            Start testbed with embedded MQTT-over-WSS broker (ADR-0001)"
	@echo "  make WSS=1 <target>       Enable embedded MQTT-over-WSS overlay for any target"
	@echo ""
	@echo "  make catdump-ingest       Dump catalogs after ingest test"
	@echo "  make catdump-bits         Dump catalogs after bits test"
	@echo "  make catdiff              Diff ingest vs bits catalog dumps"
	@echo ""
	@echo "  Sentinels in .make/ track completed steps."
	@echo "  Delete a sentinel to force that step to rerun:"
	@echo "    rm .make/bootstrap && make bootstrap"
	@echo "    rm -rf .make       && make           # full rebuild"
	@echo ""
	@echo "  Variables:"
	@echo "    BITS_DIR  = $(BITS_DIR)"
	@echo "    N         = $(N)  (jobs for stresstest)"
	@echo "    C         = $(if $(C),$(C),(unset = script default of 2))  (concurrency for stresstest)"
	@echo ""
	@echo "  Examples:"
	@echo "    make stresstest N=50           # 50 jobs, default concurrency"
	@echo "    make stresstest N=100 C=20     # 100 jobs, 20 at a time"
	@echo ""
	@echo "  Full comparison workflow:"
	@echo "    make test-ingest catdump-ingest test-bits catdump-bits catdiff"
	@echo ""

# verify-chunking — publish via bits at the configured chunk sizes, then verify
# the published catalog's chunk boundaries match CVMFS's xor32 content-defined
# chunker (cvmfs/ingestion/chunk_detector.cc) exactly. CVMFS's tarball ingest
# path does not chunk, so the oracle is the algorithm itself (reproduced in
# scripts/cvmfs-chunk-reference.py).
#
# Chunk sizes are READ from config.yaml (no longer hard-coded) so they cannot
# drift out of sync and report a false divergence.  TESTBED_ROOT is resolved
# from .env (falling back to CURDIR) so the relative repos/ and data/ paths work
# even when the testbed data root is not the repo checkout.
verify-chunking: | ensure
	bash "$(TESTBED)" test --method bits
	@root=$$($(GET_TESTBED_ROOT)); \
	sizes=$$($(GET_CHUNK_SIZES)); \
	r=$$(basename $$(dirname $$(ls "$$root"/repos/*/.cvmfspublished | head -1))); \
	python3 scripts/verify-chunking.py "$$root/repos/$$r" "$$root/data/payload/payload.tar" $$sizes

# verify-content — directly compare the latest bits publish to the native
# cvmfs_server-ingest golden (golden/smoke) for byte-identical decompressed
# content (compressor/chunking-independent). Reports metadata diffs as warnings.
verify-content: | ensure
	@root=$$($(GET_TESTBED_ROOT)); \
	r=$$(basename $$(dirname $$(ls "$$root"/repos/*/.cvmfspublished | head -1))); \
	a=$$(CAS="$$root/repos/$$r" python3 -c "import zlib,sqlite3,os,tempfile;cas=os.environ['CAS'];root=[l[1:].strip().decode() for l in open(cas+'/.cvmfspublished','rb') if l[:1]==b'C'][0];raw=zlib.decompress(open(cas+'/data/'+root[:2]+'/'+root[2:]+'C','rb').read());fd,t=tempfile.mkstemp();os.write(fd,raw);os.close(fd);print(sorted([p for (p,h) in sqlite3.connect(t).execute('select path,sha1 from nested_catalogs') if '/test/smoke.' in p])[-1])"); \
	python3 scripts/compare-trees.py "$$root/repos/$$r" "$$a" /golden/smoke

# verify — full bits-reproduces-CVMFS check: chunk boundaries + content.
verify: verify-chunking verify-content

# Suite-wrapped chunking / content checks — these log a test-results.ndjson
# record (unlike the raw verify-chunking / verify-content targets above).
test-chunking: | ensure
	bash "$(TESTBED)" suite chunking

test-content: | ensure
	bash "$(TESTBED)" suite content

# Full suite — explicit alias for `make test` with all six tests.
test-suite: | ensure
	bash "$(TESTBED)" suite $(TESTS)
