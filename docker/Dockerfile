# syntax=docker/dockerfile:1.7

# Two-stage build for a self-supervised Lore server image:
#   builder  → clones the Lore source at a PINNED tag and compiles the
#              `loreserver` binary.
#   runtime  → carries the binary + s6-overlay supervising loreserver as
#              a single long-run service, with /data declared as a volume.
#
# Lore publishes NO official container image — upstream's own
# lore-server/Dockerfile builds from source (`cargo build --release
# --bin loreserver`). We do the same here, but pin the source to a
# specific release tag rather than building whatever `main` happens to
# be. See README "Why a pinned tag" — Lore is pre-1.0 and its on-disk
# format can change between releases, so the version that wrote the data
# directory must be a deliberate, recorded choice.

# ─── Pins ────────────────────────────────────────────────────────────
# LORE_VERSION is the Lore release tag we build. Bumping it is a
# deliberate act that REQUIRES a fresh backup first (see RUNBOOK §
# Upgrade) because a new release may change the on-disk store format.
# LORE_COMMIT is the commit that v0.8.3's annotated tag dereferences to;
# we check it out by SHA after fetching the tag so a re-tag upstream
# can't silently change what we build.
ARG LORE_VERSION=v0.8.3
ARG LORE_COMMIT=1532f574e511f5d1e8851d6d1ae3a65ba2a4e1f6

# Base images pinned by tag@sha256 digest, not just tag. Tags are mutable
# on Docker Hub, so the digest is the only true integrity guarantee.
# Dependabot (.github/dependabot.yml) watches these and opens PRs when
# upstream rebuilds; without that, digest-pinning would mean shipping
# known-CVE base images forever. The Rust base matches upstream Lore's
# Dockerfile (rust:slim-trixie → debian:trixie-slim).
ARG RUST_IMAGE=rust:slim-trixie@sha256:3b05f7c617a200c41c3506097f0d15fc193a1c93bfd8f141007b47cac8f95d3c
ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:4e401d95de7083948053197a9c3913343cd06b706bf15eb6a0c3ccd26f436a0e

# s6-overlay v3. SHA256s are the upstream `*.sha256` release-asset
# values; amd64 + arm64 are both checked so a future multi-arch build
# doesn't silently skip verification on one side. Bump the version and
# all three digests together.
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG S6_OVERLAY_NOARCH_SHA256=b720f9d9340efc8bb07528b9743813c836e4b02f8693d90241f047998b4c53cf
ARG S6_OVERLAY_AMD64_SHA256=a93f02882c6ed46b21e7adb5c0add86154f01236c93cd82c7d682722e8840563
ARG S6_OVERLAY_ARM64_SHA256=0952056ff913482163cc30e35b2e944b507ba1025d78f5becbb89367bf344581


# ─── Stage 1: builder ────────────────────────────────────────────────
FROM ${RUST_IMAGE} AS builder

ARG LORE_VERSION
ARG LORE_COMMIT

# Native deps Lore's build needs:
#   build-essential   — C/C++ toolchain for native crates.
#   protobuf-compiler — `protoc` itself, for Lore's gRPC/proto build (lore-proto).
#   libprotobuf-dev   — ships the well-known protobuf includes under
#                       /usr/include/google/protobuf/*.proto (timestamp.proto,
#                       etc.). lore-proto's .proto files `import` these; without
#                       this package protoc fails with
#                       "google/protobuf/timestamp.proto: File not found".
#                       (protobuf-compiler alone does NOT carry the includes.)
#   git, ca-certificates — to clone the pinned source over HTTPS.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        protobuf-compiler \
        libprotobuf-dev \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Fetch the Lore source at exactly the pinned tag, then hard-check the
# resolved commit against LORE_COMMIT. If upstream ever moves the tag,
# the build fails loudly here rather than silently compiling a different
# tree. Shallow fetch of just the tag keeps the build context small.
RUN set -eux; \
    git init -q; \
    git remote add origin https://github.com/EpicGames/lore.git; \
    git fetch --depth 1 origin "refs/tags/${LORE_VERSION}"; \
    git checkout -q FETCH_HEAD; \
    got="$(git rev-parse HEAD)"; \
    if [ "$got" != "${LORE_COMMIT}" ]; then \
        echo "FATAL: ${LORE_VERSION} resolved to $got, expected ${LORE_COMMIT} — tag moved upstream" >&2; \
        exit 1; \
    fi

ENV CARGO_INCREMENTAL=0

# Build just the server binary. Cache the cargo registry/git and the
# target dir so warm rebuilds skip recompiling unchanged deps.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/target \
    cargo build --release --bin loreserver \
 && cp /build/target/release/loreserver /tmp/loreserver \
 && cp /build/lore-server/config/default.toml /tmp/default.toml


# ─── Stage 2: runtime ────────────────────────────────────────────────
FROM ${DEBIAN_IMAGE} AS runtime

ARG LORE_VERSION
ARG S6_OVERLAY_VERSION
ARG S6_OVERLAY_NOARCH_SHA256
ARG S6_OVERLAY_AMD64_SHA256
ARG S6_OVERLAY_ARM64_SHA256

LABEL org.opencontainers.image.title="lore-server" \
      org.opencontainers.image.description="Self-hosted Epic Lore VCS server (the team's source of truth), supervised by s6-overlay, for the Wisconsin colo." \
      org.opencontainers.image.source="https://github.com/SandboxServers/lore-host" \
      org.opencontainers.image.licenses="MIT" \
      org.lore.upstream.version="${LORE_VERSION}"

# Runtime deps:
#   ca-certificates  — loreserver makes outbound TLS (e.g. JWKS fetch if
#                      auth is enabled); also needed by s6 extract.
#   xz-utils         — extract the s6-overlay tarballs.
#   curl             — download s6-overlay; also used by HEALTHCHECK to
#                      probe the HTTP /health_check endpoint.
#
# `apt-get upgrade -y` pulls Debian security patches that postdate the
# pinned base digest, closing the CVE window at build time rather than
# waiting for the base image to be rebuilt and the digest bumped.
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        xz-utils \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Install s6-overlay v3 — handles PID 1 duties (signal forwarding, zombie
# reaping) and supervises the longrun service under /etc/s6-overlay/s6-rc.d.
# Each tarball is downloaded to disk, sha256-verified against the pinned
# digest, then extracted.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) s6_arch=x86_64;  arch_sha="${S6_OVERLAY_AMD64_SHA256}" ;; \
        arm64) s6_arch=aarch64; arch_sha="${S6_OVERLAY_ARM64_SHA256}" ;; \
        *) echo "Unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -sL --retry 3 -o /tmp/s6-noarch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    echo "${S6_OVERLAY_NOARCH_SHA256}  /tmp/s6-noarch.tar.xz" | sha256sum -c -; \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz; \
    curl -sL --retry 3 -o /tmp/s6-arch.tar.xz \
        "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz"; \
    echo "${arch_sha}  /tmp/s6-arch.tar.xz" | sha256sum -c -; \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz; \
    rm -f /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz

# Dedicated unprivileged system user. An internet-adjacent VCS server has
# no business running as root inside the container. Fixed UID/GID so the
# /data volume's ownership is predictable across image rebuilds — if the
# UID drifts, an existing volume's files become unreadable.
RUN groupadd --system --gid 1001 lore \
 && useradd  --system --uid 1001 --gid 1001 \
             --home-dir /opt/lore --shell /usr/sbin/nologin lore

# The binary + the compiled-in default config (carried so an operator can
# diff against on-disk overrides). loreserver loads config from
# /etc/lore/config; we lay down default.toml there and a docker.toml that
# pins BOTH stores to /data. local.toml (certs etc.) is mounted at deploy.
COPY --from=builder /tmp/loreserver   /usr/local/bin/loreserver
COPY --from=builder /tmp/default.toml /etc/lore/config/default.toml

# docker.toml: pin the immutable AND mutable local stores to /data, the
# volume. Without an explicit path, loreserver derives a path under the
# OS temp dir which a reboot can clear — taking every fragment and branch
# pointer with it. This is the single most important durability line in
# the image. No QUIC certificate is set here: for a real deployment the
# operator mounts a cert + a local.toml override (see RUNBOOK § TLS); with
# none, loreserver generates an ephemeral self-signed cert (dev only).
RUN cat <<'EOF' > /etc/lore/config/docker.toml
# Generated at image build time. Pins Lore's stores to the /data volume.
# Override anything here with a mounted /etc/lore/config/local.toml.
[immutable_store.local]
path = "/data"

[mutable_store.local]
path = "/data"
EOF

# Data dir owned by the lore user so the non-root process can write it.
# Docker copies this ownership into a fresh named volume on first use.
RUN mkdir -p /data && chown -R lore:lore /data /etc/lore

# s6-rc service definition for loreserver.
COPY docker/s6/lore-server /etc/s6-overlay/s6-rc.d/lore-server
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
 && touch    /etc/s6-overlay/s6-rc.d/user/contents.d/lore-server \
 && chmod +x /etc/s6-overlay/s6-rc.d/lore-server/run \
             /etc/s6-overlay/s6-rc.d/lore-server/finish

# Entrypoint wrapper: asserts /data is usable, then hands off to s6.
COPY docker/entrypoint.sh /usr/local/bin/lore-entrypoint
RUN chmod +x /usr/local/bin/lore-entrypoint

# loreserver reads config from here and tags its env "docker" so the
# docker.toml layer above is applied.
ENV LORE_CONFIG_PATH=/etc/lore/config \
    LORE_ENV=docker \
    RUST_LOG=info \
    S6_KEEP_ENV=1

# Ports: 41337 carries gRPC (TCP) and QUIC (UDP); 41339 is HTTP (health
# + presigned URLs). 41340 (internal replication) is intentionally NOT
# exposed — it's off by default and single-node has no peers.
EXPOSE 41337/tcp 41337/udp 41339/tcp

VOLUME ["/data"]

# Liveness probe: Lore's own HTTP health endpoint. A 200 means the
# server is up and serving; a wedged process fails the probe and shows
# as `unhealthy` instead of looking alive. start-period covers the cold
# first-build / first-boot. --fail makes curl exit non-zero on non-2xx.
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl --fail --silent --show-error http://127.0.0.1:41339/health_check || exit 1

ENTRYPOINT ["/usr/local/bin/lore-entrypoint"]
