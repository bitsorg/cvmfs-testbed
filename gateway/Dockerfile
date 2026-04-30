FROM ubuntu:24.04

# Runtime dependencies for cvmfs_gateway (Go binary — needs libc, libssl, ca-certs)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
 && rm -rf /var/lib/apt/lists/*

# Binary injected at runtime from the software mount.
# Config injected at runtime from ${TESTBED_ROOT}/config/gateway/.
EXPOSE 4929
