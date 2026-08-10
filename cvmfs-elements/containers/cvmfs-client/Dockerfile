FROM ubuntu:24.04

# Runtime dependencies only — cvmfs2 binary is injected from SOFTWARE_ROOT
# at startup so we can swap versions without rebuilding this image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        # cvmfs2 loads libcvmfs_fuse3_stub.so at runtime via dlopen(); that stub
        # in turn requires libfuse3.so.4 (FUSE 3 userspace library).
        # libfuse2t64 is kept as a fallback in case a FUSE2 stub is present.
        libfuse3-3 \
        libfuse2t64 \
        # libcvmfs_fuse3.so links these DYNAMICALLY as of 2.15; the 2.14 build
        # did not, which is why this image worked without them until the
        # binaries under SOFTWARE_ROOT were rebuilt.  Without them the dlopen of
        # the fuse module fails and the entrypoint reports only
        #   CernVM-FS: loading Fuse module... (x3)
        #   ERROR: cvmfs2 mount failed after 3 attempts.
        # naming SYS_ADMIN, /dev/fuse and AppArmor — none of which is the cause.
        # Confirmed with: ldd libcvmfs_fuse3.so.2.15.0 vs .2.14.0.
        # gnutls flavour specifically: the binaries want libcurl-gnutls.so.4,
        # which libcurl4 (OpenSSL flavour, libcurl.so.4) does NOT provide.
        libcurl3t64-gnutls \
        libsqlite3-0 \
        # attr for xattr queries used by cvmfs_talk
        attr \
        # curl for the verify-publish.sh SSE poll
        curl \
        # jq for JSON parsing in verify-publish.sh
        jq \
        # bash >= 4 for timing arithmetic
        bash \
        # iproute2 / net-tools not required but handy for debug
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Directory layout:
#   /cvmfs/${REPO_NAME}  – FUSE mount point (created by entrypoint)
#   /etc/cvmfs            – generated default.local and per-repo conf
#   /var/cache/cvmfs      – client cache (backed by TESTBED_ROOT volume)
RUN mkdir -p /cvmfs /etc/cvmfs/config.d /var/cache/cvmfs /var/run/cvmfs \
 && chmod 755 /cvmfs

# Scripts are baked into the image (they don't change between test runs).
COPY scripts/verify-publish.sh /usr/local/bin/verify-publish.sh
COPY scripts/verify-ingest.sh  /usr/local/bin/verify-ingest.sh
RUN chmod +x /usr/local/bin/verify-publish.sh /usr/local/bin/verify-ingest.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# cvmfs2 needs /dev/fuse and SYS_ADMIN capability — provided by the
# docker-compose.yml (cap_add, device, security_opt) not by this image.
ENTRYPOINT ["/entrypoint.sh"]
