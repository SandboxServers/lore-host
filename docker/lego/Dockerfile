# syntax=docker/dockerfile:1.7
#
# lego ACME sidecar for the Lore server's TLS certificate.
#
# This is a THIN layer on top of the official lego image: it adds the
# Docker CLI so the renew-hook can `docker restart lore-server` after a
# renewal (Lore has no cert hot-reload — see docker/lego/renew-hook.sh),
# and bakes in our entrypoint + hook scripts.
#
# Base is pinned by tag@sha256 digest (Dependabot bumps it). lego v5 is
# required — v4 used different hook env var names (LEGO_CERT_* vs the v5
# LEGO_HOOK_CERT_*) that renew-hook.sh relies on.
FROM goacme/lego:v5.2.2@sha256:d621ec01f3ca272d259a62e3e00be901293c2901ba8fc0214fe0b72523c3c278

# docker-cli: only the client, no daemon. The hook talks to the host's
# Docker socket (mounted by compose) to restart lore-server on renewal.
# The lego image is Alpine-based.
#
# The lego binary ships at /lego (NOT on PATH); symlink it onto PATH so the
# entrypoint/hook can call a bare `lego`.
RUN apk add --no-cache docker-cli \
    && ln -sf /lego /usr/local/bin/lego

COPY entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY renew-hook.sh   /usr/local/bin/renew-hook.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/renew-hook.sh

LABEL org.opencontainers.image.title="lore-lego" \
      org.opencontainers.image.description="DNS-01 ACME sidecar that issues/renews the Lore server TLS cert and restarts Lore on renewal" \
      org.opencontainers.image.source="https://github.com/SandboxServers/lore-host"

# The lego base sets ENTRYPOINT ["lego"]; override it with our renewal
# loop, which calls lego internally.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
