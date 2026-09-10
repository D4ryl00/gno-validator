# ----- Builder stage: clones gno source, builds the gnoland binary
# Go 1.25+ is required by gno versions carrying the tmkms_listener support
# (their go.mod requires >= 1.25.x); backward-compatible with older gno.
FROM    golang:1.25-alpine AS builder
ENV     GNOROOT="/gnoroot"
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
# GNO_COMMIT_HASH pins the exact commit; changing it busts the cache for all downstream layers
ARG     GNO_COMMIT_HASH

RUN     apk add --no-cache git ca-certificates
RUN     git clone https://github.com/${GNO_REPO}.git /gnoroot && \
  git -C /gnoroot checkout ${GNO_COMMIT_HASH:-${GNO_VERSION}}

WORKDIR /gnoroot

RUN     go build -o /usr/local/bin/gnoland ./gno.land/cmd/gnoland

# ----- gnoland final stage
FROM    alpine:3 AS gnoland
ENV     GNOROOT="/gnoroot"
ARG     GNO_COMMIT_HASH
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
ARG     BUILD_DATE
ARG     DOCKERFILE_HASH
ARG     ENTRYPOINT_HASH
LABEL   gno.commit="${GNO_COMMIT_HASH}" \
  gno.version="${GNO_VERSION}" \
  gno.repo="${GNO_REPO}" \
  build.commit="${GNO_COMMIT_HASH}" \
  build.version="${GNO_VERSION}" \
  build.repo="${GNO_REPO}" \
  build.date="${BUILD_DATE}" \
  build.dockerfile_hash="${DOCKERFILE_HASH}" \
  build.entrypoint_hash="${ENTRYPOINT_HASH}"

RUN     apk add --no-cache ca-certificates

COPY    --from=builder /usr/local/bin/gnoland /usr/local/bin/gnoland
COPY    --from=builder /gnoroot/gnovm/stdlibs /gnoroot/gnovm/stdlibs
COPY    --from=builder /gnoroot/gnovm/tests/stdlibs /gnoroot/gnovm/tests/stdlibs

COPY    docker/gnoland-entrypoint.sh /entrypoint.sh
RUN     chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# ----- tmkms builder stage: builds tmkms from source (softsign backend only)
# Built from the gno fork (aeddi/tmkms) rather than the crates.io release: the
# fork carries validator-relevant hardening not in upstream 0.15.0 — the Ed25519
# seed no longer leaks through Debug output, consensus state writes are fsynced,
# a non-Ed25519 priv_validator_key.json is rejected instead of panicking, and the
# validator peer ID is required unless explicitly opted out. Pin a tag (not a
# branch) so the build stays reproducible and cacheable.
# The softsign feature needs only a C compiler — no libusb/OpenSSL (those are
# pulled in by the yubihsm/ledger backends, which we don't build).
# Cold build is ~5 min; pinning TMKMS_VERSION keeps it cacheable.
FROM    rust:1-slim-bookworm AS tmkms-builder
ARG     TMKMS_REPO=https://github.com/aeddi/tmkms
ARG     TMKMS_VERSION=v0.16.0-gno.3
# build-essential + pkg-config/libssl/libusb/libudev cover tmkms's native build
# deps on slim Debian (ubuntu-latest, where gno's CI builds it, ships these). The
# heavy HSM backends aren't built (softsign feature), but their -sys crates may
# still probe for the libs during resolution — installing them keeps the build
# robust across tmkms default-feature changes.
RUN     apt-get update && apt-get install -y --no-install-recommends \
  build-essential pkg-config libssl-dev libusb-1.0-0-dev libudev-dev git && \
  rm -rf /var/lib/apt/lists/*
RUN     cargo install --git ${TMKMS_REPO} --tag ${TMKMS_VERSION} tmkms \
  --features softsign --locked --root /usr/local

# ----- tmkms final stage
FROM    debian:bookworm-slim AS tmkms
ARG     GNO_COMMIT_HASH
ARG     GNO_VERSION=master
ARG     GNO_REPO=gnolang/gno
ARG     BUILD_DATE
ARG     DOCKERFILE_HASH
ARG     ENTRYPOINT_HASH
LABEL   gno.commit="${GNO_COMMIT_HASH}" \
  gno.version="${GNO_VERSION}" \
  gno.repo="${GNO_REPO}" \
  build.commit="${GNO_COMMIT_HASH}" \
  build.version="${GNO_VERSION}" \
  build.repo="${GNO_REPO}" \
  build.date="${BUILD_DATE}" \
  build.dockerfile_hash="${DOCKERFILE_HASH}" \
  build.entrypoint_hash="${ENTRYPOINT_HASH}"

RUN     apt-get update && apt-get install -y --no-install-recommends ca-certificates && \
  rm -rf /var/lib/apt/lists/*

COPY    --from=tmkms-builder /usr/local/bin/tmkms /usr/local/bin/tmkms

COPY    docker/tmkms-entrypoint.sh /entrypoint.sh
RUN     chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
