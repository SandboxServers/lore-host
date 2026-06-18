#!/bin/sh
# Back up Lore's content store (the `lore-data` named volume) to a single
# compressed archive, then (optionally) push it offsite.
#
# This produces a CONSISTENT snapshot by briefly stopping the server so
# the on-disk store isn't mutated mid-copy. Lore's local store flushes on
# an interval (flush_delay_seconds), so a hot copy of a running server can
# capture a torn write. A few seconds of downtime nightly is a fair price
# for a restorable backup of the team's source of truth.
#
# A backup you have never restored is a rumor — pair this with
# scripts/restore.sh and actually exercise it (RUNBOOK § Restore).
#
# Usage:
#   scripts/backup.sh [outdir]
# Env:
#   COMPOSE_FILE   path to compose.yml (default /opt/lore/compose.yml)
#   OFFSITE_DEST   optional rclone/scp destination; if set, the archive is
#                  pushed there after creation (e.g. "rclone:b2:lore-backups"
#                  or "user@host:/backups"). Wire to your offsite target.
set -eu

OUTDIR="${1:-/opt/lore/backups}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/lore/compose.yml}"
VOLUME="lore-data"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${OUTDIR}/lore-data-${TS}.tar.zst"

mkdir -p "${OUTDIR}"

echo "[backup] stopping lore-server for a consistent snapshot"
docker compose -f "${COMPOSE_FILE}" stop lore-server

# Trap so the server comes back up even if the copy fails.
trap 'echo "[backup] restarting lore-server"; docker compose -f "${COMPOSE_FILE}" start lore-server' EXIT INT TERM

echo "[backup] archiving volume ${VOLUME} -> ${ARCHIVE}"
# Mount the named volume read-only into a throwaway container and stream a
# zstd-compressed tar of its contents to the host. busybox tar + zstd via
# a small alpine image keeps the dependency surface tiny.
docker run --rm \
    -v "${VOLUME}:/data:ro" \
    -v "${OUTDIR}:/backup" \
    alpine:3.20 \
    sh -c "apk add --no-cache zstd >/dev/null && tar -C /data -cf - . | zstd -19 -o /backup/$(basename "${ARCHIVE}")"

# Record a checksum next to the archive so restore can verify integrity.
( cd "${OUTDIR}" && sha256sum "$(basename "${ARCHIVE}")" > "$(basename "${ARCHIVE}").sha256" )

echo "[backup] created ${ARCHIVE}"
echo "[backup] $(du -h "${ARCHIVE}" | cut -f1) on disk"

if [ -n "${OFFSITE_DEST:-}" ]; then
    echo "[backup] pushing offsite to ${OFFSITE_DEST}"
    # Replace with your real offsite transport. rclone is shown because it
    # handles B2/S3/Drive uniformly; scp works for a second physical box.
    if command -v rclone >/dev/null 2>&1 && [ "${OFFSITE_DEST#rclone:}" != "${OFFSITE_DEST}" ]; then
        rclone copy "${ARCHIVE}"        "${OFFSITE_DEST#rclone:}"
        rclone copy "${ARCHIVE}.sha256" "${OFFSITE_DEST#rclone:}"
    else
        scp "${ARCHIVE}" "${ARCHIVE}.sha256" "${OFFSITE_DEST}/"
    fi
    echo "[backup] offsite push complete"
else
    echo "[backup] WARNING: OFFSITE_DEST not set — backup is LOCAL ONLY."
    echo "[backup] A local-only backup dies with the box. Set OFFSITE_DEST."
fi
