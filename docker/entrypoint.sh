#!/bin/sh
# Lore server entrypoint. Prepares the data directory, then hands off to
# s6-overlay (which supervises loreserver).
#
# # CRITICAL: this entrypoint NEVER deletes or reseeds /data.
#
# Cimmeria's entrypoint deliberately WIPES its Postgres data on every
# start — that service is ephemeral-by-design (fresh DB per deploy). Lore
# is the OPPOSITE: /data holds the team's entire version-control history
# and is the single source of truth. Wiping it would be the exact failure
# this whole repo exists to prevent. So this script only ever *prepares*
# the directory; it must never clear it. If you find yourself adding an
# `rm -rf` here, stop.
#
# What it does do:
#   - Verify /data exists and is writable by the lore user.
#   - Fix ownership for the bind-mount case (Docker auto-copies image
#     contents + ownership into a fresh NAMED volume, but a bind-mounted
#     host directory arrives with the host's ownership, which the
#     non-root `lore` user may not be able to write).
set -eu

DATA_DIR="/data"

if [ ! -d "${DATA_DIR}" ]; then
    echo "[lore-entrypoint] FATAL: ${DATA_DIR} does not exist" >&2
    exit 1
fi

# Ensure the lore user (UID/GID 1001) owns the data dir. This is cheap
# and idempotent on a named volume (already owned correctly) and is what
# makes a freshly bind-mounted host directory writable. We chown the
# directory itself and only fix up entries whose owner differs, to avoid
# rewriting metadata on a large existing store on every boot.
if [ "$(stat -c '%u' "${DATA_DIR}")" != "1001" ]; then
    echo "[lore-entrypoint] taking ownership of ${DATA_DIR} for the lore user"
    chown lore:lore "${DATA_DIR}"
fi
# Repair only mis-owned entries (no-op on a correctly-owned store).
find "${DATA_DIR}" \( ! -uid 1001 -o ! -gid 1001 \) -exec chown lore:lore {} + 2>/dev/null || true

echo "[lore-entrypoint] data dir ${DATA_DIR} ready; handing off to s6"

# Hand control to s6-overlay v3: it becomes PID 1, brings up the
# lore-server longrun service, forwards signals, and reaps zombies.
exec /init "$@"
