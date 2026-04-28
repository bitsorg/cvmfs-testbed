FROM ubuntu:22.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -r -s /sbin/nologin prepub

RUN mkdir -p /data/cas /data/spool /etc/cvmfs-prepub \
 && chown -R prepub:prepub /data /etc/cvmfs-prepub

USER prepub

EXPOSE 8080
