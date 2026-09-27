# Reproducible toolchain for the study. Builds natively for linux/amd64 and
# linux/arm64 (Apple Silicon via Docker Desktop):
#
#   docker build -t pq-kem-study -f docker/Dockerfile .
#   docker run --rm -it --cap-add=NET_ADMIN -v "$PWD":/work pq-kem-study make quick
#
# Dependencies are built into /opt/pqbuild inside the image, so the repo you
# mount stays small. NET_ADMIN is only needed for E2 (tc netem).
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates perl pkg-config \
      python3 python3-numpy python3-pandas python3-matplotlib python3-scipy \
      valgrind iproute2 tshark procps util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/pq-kem-study
COPY versions.env ./
COPY scripts/build_deps.sh scripts/
RUN BUILD_DIR=/opt/pqbuild scripts/build_deps.sh \
    && rm -rf /opt/pqbuild/src/openssl /opt/pqbuild/oqs-provider.build

ENV BUILD_DIR=/opt/pqbuild
WORKDIR /work
CMD ["make", "help"]
