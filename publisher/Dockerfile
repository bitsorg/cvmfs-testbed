FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        curl jq coreutils \
 && rm -rf /var/lib/apt/lists/*

COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

WORKDIR /scripts
