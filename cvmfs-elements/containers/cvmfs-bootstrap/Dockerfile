FROM ubuntu:24.04

# Runtime dependencies — same set as cvmfs-native-publisher plus fuse3
# for mounting /cvmfs/<repo> during cvmfs_server transaction.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
        libsqlite3-0 \
        # Two curl flavours, both needed.  cvmfs_swissknife and cvmfs_publish
        # link libcurl-gnutls.so.4, which libcurl4 (the OpenSSL flavour,
        # libcurl.so.4) does NOT provide: without the gnutls package both stage
        # fine and are executable, but die at load time with "error while loading
        # shared libraries" and exit 127.
        #
        # This image needs the distro package where gateway/ does not, even
        # though cvmfs_receiver links the same soname, because of how the search
        # path is built: gateway sets LD_LIBRARY_PATH to the full SOFTWARE_ROOT
        # mount, while bootstrap.sh stages binaries to /run/cvmfs-bin and copies
        # only libcvmfs_*.so* and libfuse3.so* alongside them — so nothing here
        # resolves out of the mount.  (gateway also happens to pull the gnutls
        # flavour in transitively; that is undeclared and should not be relied on.)
        #
        # cvmfs-native-publisher carries both packages; cvmfs-client and
        # cvmfs-prepub carry the gnutls flavour only.  Name is noble-specific —
        # jammy calls it libcurl3-gnutls.
        libcurl4 \
        libcurl3t64-gnutls \
        zlib1g \
        libattr1 \
        uuid-runtime \
        attr \
        libcap2-bin \
        fuse3 \
        libfuse3-3 \
        bash \
        coreutils \
        curl \
        jq \
        python3 \
 && rm -rf /var/lib/apt/lists/*

# Directories expected by cvmfs_server
RUN mkdir -p /var/spool/cvmfs \
             /etc/cvmfs/repositories.d \
             /etc/cvmfs/keys \
             /srv/cvmfs \
             /cvmfs \
 && chmod 755 /var/spool/cvmfs /etc/cvmfs/repositories.d \
              /etc/cvmfs/keys /srv/cvmfs /cvmfs

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

CMD ["/scripts/bootstrap.sh"]
