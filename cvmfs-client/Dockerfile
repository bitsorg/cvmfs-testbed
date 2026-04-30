FROM ubuntu:24.04

# Runtime dependencies only — cvmfs2 binary is injected from SOFTWARE_ROOT
# at startup so we can swap versions without rebuilding this image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        # FUSE user-space library required for cvmfs2
        libfuse2t64 \ # renamed from libfuse2 in Ubuntu 24.04
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
RUN mkdir -p /cvmfs /etc/cvmfs/config.d /var/cache/cvmfs \
 && chmod 755 /cvmfs

# Scripts are baked into the image (they don't change between test runs).
COPY scripts/verify-publish.sh /usr/local/bin/verify-publish.sh
RUN chmod +x /usr/local/bin/verify-publish.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# cvmfs2 needs /dev/fuse and SYS_ADMIN capability — provided by the
# docker-compose.yml (cap_add, device, security_opt) not by this image.
ENTRYPOINT ["/entrypoint.sh"]
