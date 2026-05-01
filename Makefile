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
#   make bootstrap     Run privileged bootstrap container, create snapshot
#   make snapshot      Save repo state to repo-seed.tar.gz (called by bootstrap)
#   make restore       Restore repo state from repo-seed.tar.gz
#   make redeploy      install + full reset + bootstrap
#   make clean         Stop containers and wipe all testbed state (keeps snapshot)
#   make test          Smoke test — bits method (default)
#   make test-ingest   Smoke test — cvmfs_server ingest path (needs bootstrap)
#   make test-bits     Smoke test — cvmfs-prepub REST API path
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
#
# Examples:
#   make                            # full pipeline from scratch
#   make bootstrap                  # seed nested catalog + snapshot (once)
#   make test-ingest                # run ingest smoke test (needs bootstrap)
#   make test-ingest test-bits      # run both paths
#   make catdiff                    # diff catalog dumps
#   make stresstest N=50            # 50-job bits stress test
#   make BITS_DIR=~/cvmfs-bits      # custom bits source location
#   rm .make/bootstrap && make bootstrap  # force re-bootstrap

# ── Shell ─────────────────────────────────────────────────────────────────────
SHELL := /bin/bash

# ── Paths ─────────────────────────────────────────────────────────────────────
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TESTBED      := $(MAKEFILE_DIR)/testbed.sh
INSTALL_SH   := $(MAKEFILE_DIR)/install.sh
MAKE_DIR     := $(MAKEFILE_DIR)/.make

# cvmfs-bits source directory — override if your clone lives elsewhere.
BITS_DIR ?= $(MAKEFILE_DIR)/cvmfs-bits

# Number of jobs for stresstest targets.
N ?= 10

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := all

.PHONY: all build install init start bootstrap snapshot restore redeploy clean \
        test test-ingest test-bits \
        stresstest stresstest-ingest \
        catdump-ingest catdump-bits catdiff \
        help

# ── Sentinel directory ────────────────────────────────────────────────────────
$(MAKE_DIR):
	mkdir -p $(MAKE_DIR)

# ── all ───────────────────────────────────────────────────────────────────────
# Full pipeline: build → install → init → start → bootstrap.
all: $(MAKE_DIR)/bootstrap

# ── build ─────────────────────────────────────────────────────────────────────
$(MAKE_DIR)/build: $(MAKE_DIR)
	@if [[ ! -d "$(BITS_DIR)" ]]; then \
	    echo "ERROR: BITS_DIR not found: $(BITS_DIR)"; \
	    echo "  Clone cvmfs-bits there, or override: make BITS_DIR=/path/to/cvmfs-bits"; \
	    exit 1; \
	fi
	@echo "── Pulling latest cvmfs-bits ─────────────────────────────────────────"
	cd "$(BITS_DIR)" && git pull
	@echo "── Building cvmfs-bits ───────────────────────────────────────────────"
	cd "$(BITS_DIR)" && $(MAKE) build
	@touch $@

build: $(MAKE_DIR)/build

# ── install ───────────────────────────────────────────────────────────────────
$(MAKE_DIR)/install: $(MAKE_DIR)/build
	@echo "── Installing binaries into software/ ────────────────────────────────"
	BITS_DIR="$(BITS_DIR)" bash "$(INSTALL_SH)"
	@touch $@

install: $(MAKE_DIR)/install

# ── init ──────────────────────────────────────────────────────────────────────
$(MAKE_DIR)/init: $(MAKE_DIR)/install
	@echo "── Initialising testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" init
	@touch $@

init: $(MAKE_DIR)/init

# ── start ─────────────────────────────────────────────────────────────────────
# Not a sentinel target — containers can start/stop independently of make state.
# Depends on init having run.  auto-restores snapshot if repo is absent.
start: $(MAKE_DIR)/init
	@echo "── Starting testbed ──────────────────────────────────────────────────"
	bash "$(TESTBED)" start

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
# Stop containers and remove runtime state.  Snapshot is PRESERVED.
# Wipe .make/init and .make/bootstrap so make knows to re-run them next time.
clean:
	@echo "── Stopping testbed ──────────────────────────────────────────────────"
	-bash "$(TESTBED)" stop
	@echo "── Cleaning testbed state ────────────────────────────────────────────"
	bash "$(TESTBED)" clean --yes
	rm -f $(MAKE_DIR)/init $(MAKE_DIR)/bootstrap

# ── test targets ──────────────────────────────────────────────────────────────
test:
	bash "$(TESTBED)" test --method bits

# test-ingest requires the bootstrap to have run (nested catalog in snapshot).
test-ingest: $(MAKE_DIR)/bootstrap
	bash "$(TESTBED)" test --method ingest

test-bits:
	bash "$(TESTBED)" test --method bits

# ── stresstest targets ────────────────────────────────────────────────────────
stresstest:
	bash "$(TESTBED)" stresstest $(N) --method bits

stresstest-ingest: $(MAKE_DIR)/bootstrap
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
	@echo "  make bootstrap            Seed nested catalog + create snapshot (once)"
	@echo "  make snapshot             Save repo state to repo-seed.tar.gz"
	@echo "  make restore              Restore repo state from repo-seed.tar.gz"
	@echo "  make redeploy             Full rebuild from scratch"
	@echo "  make clean                Stop + wipe state (keeps snapshot)"
	@echo ""
	@echo "  make test                 Smoke test (bits method)"
	@echo "  make test-ingest          Smoke test (cvmfs_server ingest, needs bootstrap)"
	@echo "  make test-bits            Smoke test (cvmfs-prepub REST API)"
	@echo ""
	@echo "  make stresstest [N=10]    Stress test, N jobs (bits)"
	@echo "  make stresstest-ingest    Stress test (ingest path)"
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
	@echo ""
	@echo "  Full comparison workflow:"
	@echo "    make test-ingest catdump-ingest test-bits catdump-bits catdiff"
	@echo ""
