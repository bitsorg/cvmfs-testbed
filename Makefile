# Makefile — cvmfs-testbed top-level build and lifecycle management.
#
# Targets:
#   make               Pull + build cvmfs-bits, install binaries, redeploy testbed
#   make build         git pull + make build inside cvmfs-bits/
#   make install       build, then copy binaries into software/
#   make redeploy      install + stop → clean → init → start
#   make clean         Stop containers and wipe all testbed state (no confirmation)
#   make test          Smoke test — bits method (default)
#   make test-ingest   Smoke test — cvmfs_server ingest path
#   make test-bits     Smoke test — cvmfs-prepub REST API path
#   make stresstest    Stress test — bits method, N jobs (default N=10)
#   make stresstest-ingest  Stress test — ingest path
#   make catdiff       Diff catalog dumps: ingest vs bits
#   make help          Print this summary
#
# Variables (override on the command line or in the environment):
#   BITS_DIR   Path to the cvmfs-bits source tree.
#              Default: $(CURDIR)/cvmfs-bits
#              Example: make BITS_DIR=/home/user/src/cvmfs-bits
#   N          Number of jobs for stresstest targets (default: 10)
#
# Examples:
#   make                          # full update + redeploy
#   make test                     # run bits smoke test
#   make test-ingest              # run ingest smoke test
#   make test-ingest test-bits    # run both and compare
#   make catdiff                  # diff catalog dumps
#   make stresstest N=50          # 50-job bits stress test
#   make BITS_DIR=~/cvmfs-bits    # use a custom bits source location

# ── Shell ─────────────────────────────────────────────────────────────────────
# All recipes run under bash so we can use [[ ]], -d tests, etc.
SHELL := /bin/bash

# ── Paths ─────────────────────────────────────────────────────────────────────
MAKEFILE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TESTBED      := $(MAKEFILE_DIR)/testbed.sh
INSTALL_SH   := $(MAKEFILE_DIR)/install.sh

# cvmfs-bits source directory — override if your clone lives elsewhere.
BITS_DIR ?= $(MAKEFILE_DIR)/cvmfs-bits

# Number of jobs for stresstest targets.
N ?= 10

# ── Default goal ──────────────────────────────────────────────────────────────
.DEFAULT_GOAL := all

.PHONY: all build install redeploy clean \
        test test-ingest test-bits \
        stresstest stresstest-ingest \
        catdump-ingest catdump-bits catdiff \
        help

# ── all ───────────────────────────────────────────────────────────────────────
# Full pipeline: update source → build → install binaries → redeploy testbed.
all: redeploy

# ── build ─────────────────────────────────────────────────────────────────────
# Pull the latest cvmfs-bits source and compile.
build:
	@if [[ ! -d "$(BITS_DIR)" ]]; then \
	    echo ""; \
	    echo "ERROR: BITS_DIR not found: $(BITS_DIR)"; \
	    echo "       Clone cvmfs-bits there, or override:"; \
	    echo "       make BITS_DIR=/path/to/cvmfs-bits"; \
	    echo ""; \
	    exit 1; \
	fi
	@echo ""
	@echo "── Pulling latest cvmfs-bits ──────────────────────────────────────"
	cd "$(BITS_DIR)" && git pull
	@echo ""
	@echo "── Building cvmfs-bits ────────────────────────────────────────────"
	cd "$(BITS_DIR)" && $(MAKE) build

# ── install ───────────────────────────────────────────────────────────────────
# Build cvmfs-bits, then copy all binaries and libraries into software/.
install: build
	@echo ""
	@echo "── Installing binaries into software/ ────────────────────────────"
	bash "$(INSTALL_SH)"

# ── redeploy ──────────────────────────────────────────────────────────────────
# Install binaries, then do a full testbed cycle: stop → clean → init → start.
# The leading - on stop means make ignores a non-zero exit (containers may not
# be running yet on the first invocation).
redeploy: install
	@echo ""
	@echo "── Stopping testbed ──────────────────────────────────────────────"
	-bash "$(TESTBED)" stop
	@echo ""
	@echo "── Cleaning testbed state ────────────────────────────────────────"
	bash "$(TESTBED)" clean --yes
	@echo ""
	@echo "── Initialising testbed ──────────────────────────────────────────"
	bash "$(TESTBED)" init
	@echo ""
	@echo "── Starting testbed ──────────────────────────────────────────────"
	bash "$(TESTBED)" start

# ── clean ─────────────────────────────────────────────────────────────────────
# Stop containers and remove all persistent testbed state.
# --yes suppresses the interactive "Continue? [y/N]" prompt.
clean:
	@echo ""
	@echo "── Stopping testbed ──────────────────────────────────────────────"
	-bash "$(TESTBED)" stop
	@echo ""
	@echo "── Cleaning testbed state ────────────────────────────────────────"
	bash "$(TESTBED)" clean --yes

# ── test targets ──────────────────────────────────────────────────────────────
test:
	bash "$(TESTBED)" test --method bits

test-ingest:
	bash "$(TESTBED)" test --method ingest

test-bits:
	bash "$(TESTBED)" test --method bits

# ── stresstest targets ────────────────────────────────────────────────────────
stresstest:
	bash "$(TESTBED)" stresstest $(N) --method bits

stresstest-ingest:
	bash "$(TESTBED)" stresstest $(N) --method ingest

# ── catalog comparison ────────────────────────────────────────────────────────
# Convenience targets that run a test, dump the resulting catalogs, and diff.
# Run them in sequence to populate both dump sets before comparing:
#   make test-ingest catdump-ingest test-bits catdump-bits catdiff
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
	@echo "  make                    Pull + build cvmfs-bits, install, redeploy"
	@echo "  make build              git pull + make build in cvmfs-bits/"
	@echo "  make install            build + copy binaries to software/"
	@echo "  make redeploy           install + stop/clean/init/start"
	@echo "  make clean              Stop containers and wipe all state"
	@echo ""
	@echo "  make test               Smoke test (bits method)"
	@echo "  make test-ingest        Smoke test (cvmfs_server ingest)"
	@echo "  make test-bits          Smoke test (cvmfs-prepub REST API)"
	@echo ""
	@echo "  make stresstest [N=10]  Stress test, N jobs (bits)"
	@echo "  make stresstest-ingest  Stress test (ingest path)"
	@echo ""
	@echo "  make catdump-ingest     Dump catalogs after ingest test"
	@echo "  make catdump-bits       Dump catalogs after bits test"
	@echo "  make catdiff            Diff ingest vs bits catalog dumps"
	@echo ""
	@echo "  Variables:"
	@echo "    BITS_DIR  = $(BITS_DIR)"
	@echo "    N         = $(N)  (jobs for stresstest)"
	@echo ""
	@echo "  Full comparison workflow:"
	@echo "    make test-ingest catdump-ingest test-bits catdump-bits catdiff"
	@echo ""
