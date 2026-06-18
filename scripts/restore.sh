#!/bin/sh
# Restore Lore's content store from a backup archive produced by
# scripts/backup.sh into the `lore-data` named volume.
#
# THIS IS DESTRUCTIVE: it replaces the entire contents of the target
# volume with the archive. Run it against a SCRATCH volume first to prove
# the backup is restorable (RUNBOOK § Restore — test, don't assume).
#
# Usage:
#   scripts/restore.sh <archive.tar.zst> [target_volume]
# Env:
#   COMPOSE_FILE   path to compose.yml (default /opt/lore/compose.yml)
set -eu

ARCHIVE="${1:?usage: restore.sh <archive.tar.zst> [target_volume]}"
VOLUME="${2:-lore-data}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/lore/compose.yml}"

[ -f "${ARCHIVE}" ] || { echo "[restore] FATAL: ${ARCHIVE} not found" >&2; exit 1; }

# Verify integrity against the .sha256 sidecar if present.
if [ -f "${ARCHIVE}.sha256" ]; then
    echo "[restore] verifying checksum"
    ( cd "$(dirname "${ARCHIVE}")" && sha256sum -c "$(basename "${ARCHIVE}").sha256" )
else
    echo "[restore] WARNING: no ${ARCHIVE}.sha256 sidecar — skipping integrity check"
fi

echo "[restore] target volume: ${VOLUME}"
printf "[restore] this ERASES the current contents of '%s'. Type 'yes' to continue: " "${VOLUME}"
read -r confirm
[ "${confirm}" = "yes" ] || { echo "[restore] aborted"; exit 1; }

# Stop the server if it's running against this volume.
if [ "${VOLUME}" = "lore-data" ]; then
    echo "[restore] stopping lore-server"
    docker compose -f "${COMPOSE_FILE}" stop lore-server || true
fi

# Ensure the target volume exists.
docker volume create "${VOLUME}" >/dev/null

echo "[restore] wiping and repopulating ${VOLUME} from ${ARCHIVE}"
docker run --rm \
    -v "${VOLUME}:/data" \
    -v "$(cd "$(dirname "${ARCHIVE}")" && pwd):/backup:ro" \
    alpine:3.20 \
    sh -c "apk add --no-cache zstd >/dev/null && \
           rm -rf /data/* /data/.[!.]* 2>/dev/null; \
           zstd -dc /backup/$(basename "${ARCHIVE}") | tar -C /data -xf - && \
           chown -R 1001:1001 /data"

echo "[restore] restore into ${VOLUME} complete."
if [ "${VOLUME}" = "lore-data" ]; then
    echo "[restore] starting lore-server"
    docker compose -f "${COMPOSE_FILE}" start lore-server
    echo "[restore] verify: curl -i http://127.0.0.1:41339/health_check (expect 200)"
else
    echo "[restore] NOTE: restored into scratch volume '${VOLUME}', not the live store."
    echo "[restore] To test it, run a throwaway server pointed at this volume."
fi
