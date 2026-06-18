#!/bin/sh
# lego deploy/renew hook — runs after a certificate is freshly issued or
# renewed. Lore loads its TLS cert at STARTUP ONLY (no hot-reload), so a
# renewed cert on disk does nothing until lore-server restarts. This hook
# restarts the lore-server container so it picks up the new cert.
#
# lego sets these env vars when invoking the hook (lego v5 names):
#   LEGO_HOOK_CERT_NAME      — the cert's main domain (== LORE_DOMAIN)
#   LEGO_HOOK_CERT_PATH      — path to the new .crt
#   LEGO_HOOK_CERT_KEY_PATH  — path to the new .key
#
# Restart mechanism: the sidecar image (docker/lego/Dockerfile) adds the
# docker CLI on top of goacme/lego, and compose mounts the Docker socket
# so this hook can `docker restart lore-server`. The socket is powerful
# (≈ root on the host) — see the SECURITY TRADEOFF note in compose.yml and
# the no-socket alternative in RUNBOOK § TLS. We restart (not recreate) so
# nothing about lore-server's definition changes; it just re-reads the
# cert files from the shared volume on boot.
set -eu

TARGET_CONTAINER="${LORE_CONTAINER_NAME:-lore-server}"

echo "[renew-hook] Certificate for ${LEGO_HOOK_CERT_NAME:-?} updated at ${LEGO_HOOK_CERT_PATH:-?}."
echo "[renew-hook] Restarting ${TARGET_CONTAINER} so Lore loads the new certificate."

if ! command -v docker >/dev/null 2>&1; then
    echo "[renew-hook] ERROR: docker CLI not found in sidecar image." >&2
    echo "[renew-hook] Cert is renewed on disk but lore-server was NOT restarted." >&2
    echo "[renew-hook] Restart it manually on the colo:  docker restart ${TARGET_CONTAINER}" >&2
    exit 1
fi

if ! docker restart "${TARGET_CONTAINER}"; then
    echo "[renew-hook] ERROR: 'docker restart ${TARGET_CONTAINER}' failed." >&2
    echo "[renew-hook] The new cert is on disk; restart lore-server manually to load it." >&2
    exit 1
fi

echo "[renew-hook] Done — ${TARGET_CONTAINER} restarted with the renewed certificate."
