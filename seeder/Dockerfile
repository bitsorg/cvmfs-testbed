FROM python:3.11-slim

# Install git and other required tools
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        curl \
        jq \
        nodejs \
        npm \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
RUN pip install --no-cache-dir \
        requests \
        pyyaml \
        gitpython

WORKDIR /seeder

COPY seed.py /seeder/seed.py

# git needs a user identity for commits
RUN git config --global user.email "seeder@testbed.local" && \
    git config --global user.name "Testbed Seeder"

CMD ["python", "-u", "/seeder/seed.py"]
