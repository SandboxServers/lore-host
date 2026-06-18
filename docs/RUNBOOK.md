# Lore server — operations runbook

This is the **2am operator** guide for the team's self-hosted Lore VCS server on the
Wisconsin colo box. Lore holds the team's **entire version-control history** and is the
single source of truth. The cardinal rule everywhere below: **never destroy `/data` (the
`lore-data` volume) without a verified backup in hand.**

Conventions used below (replace with your colo's real values — see
[Open questions](#open-questions-colo-specifics)):

| Placeholder | Meaning | Assumed default |
| --- | --- | --- |
| `COLO` | ssh target for the colo box | `colo` |
| `/opt/lore` | deploy dir on the box (holds `compose.yml`, `certs/`, `backups/`) | `/opt/lore` |
| `IMAGE` | the GHCR image | `ghcr.io/sandboxservers/lore-server` |
| `TAG` | the pinned dated tag you're running | e.g. `2026-06-18.1` |

All `docker compose` commands run from `/opt/lore` on the colo unless noted.

---

## Contents
1. [First-time deploy](#first-time-deploy)
2. [Routine deploy / upgrade (backup-first)](#routine-deploy--upgrade)
3. [Roll back](#roll-back)
4. [Backup strategy](#backup-strategy)
5. [Restore from backup](#restore-from-backup)
6. [Rotate (TLS cert / JWT signing keys)](#rotate)
7. [Reverse proxy + TLS](#reverse-proxy--tls)
8. [Why a pinned tag (never `:latest`)](#why-a-pinned-tag)
9. [Health, logs, capacity](#health-logs-capacity)
10. [Open questions (colo specifics)](#open-questions-colo-specifics)

---

## First-time deploy

1. **Put the deploy files on the box.**
   ```sh
   ssh COLO 'mkdir -p /opt/lore/certs /opt/lore/config /opt/lore/backups'
   scp docker/compose.yml COLO:/opt/lore/compose.yml
   scp scripts/backup.sh scripts/restore.sh scripts/make-certs.sh COLO:/opt/lore/
   ```

2. **Generate a durable TLS cert** (stopgap self-signed; for production prefer a real CA —
   see [Reverse proxy + TLS](#reverse-proxy--tls)). The zero-config Lore cert is regenerated
   every restart, which breaks pinned clients — we want a stable one.
   ```sh
   ssh COLO
   cd /opt/lore
   ./make-certs.sh lore.colo.example.com /opt/lore/certs    # use the real DNS name
   ```

3. **Create `/opt/lore/config/local.toml`** pointing Lore at the cert:
   ```toml
   [server.quic.certificate]
   cert_file = "/etc/lore/cert.pem"
   pkey_file = "/etc/lore/key.pem"
   ```

4. **Pin the image tag** in `/opt/lore/compose.yml`. Change the `image:` line from the rolling
   `latest-prerelease` pointer to the specific immutable dated tag you intend to run:
   ```yaml
   image: ghcr.io/sandboxservers/lore-server:2026-06-18.1   # the TAG you chose
   ```
   and **uncomment the cert + `local.toml` mounts** in the `volumes:` block.

5. **Authenticate to GHCR** (the package is private):
   ```sh
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
   ```

6. **Bring it up.**
   ```sh
   docker compose pull
   docker compose up -d
   ```

7. **Verify** (see [Health](#health-logs-capacity)):
   ```sh
   curl -i http://127.0.0.1:41339/health_check     # expect: HTTP/1.1 200 OK
   docker compose ps                                # State should be "running (healthy)"
   ```

8. **Confirm the volume is the named one** (not an accidental anonymous volume):
   ```sh
   docker volume inspect lore-data >/dev/null && echo "lore-data OK"
   docker inspect lore-server -f '{{json .Mounts}}'   # should show source=lore-data
   ```

9. **Take your first backup and TEST THE RESTORE** before anyone pushes real history —
   see [Backup](#backup-strategy) + [Restore](#restore-from-backup). A fresh deploy is the
   cheapest time to prove the restore path works.

---

## Routine deploy / upgrade

Use this for any image change, **especially a Lore version bump** (changing `LORE_VERSION` in
the Dockerfile and cutting a new release). Lore is pre-1.0 — a new version **may change the
on-disk store format**, so this procedure is **backup-first, always**.

1. **Take a fresh backup and confirm it exists.**
   ```sh
   ssh COLO
   cd /opt/lore
   ./backup.sh /opt/lore/backups
   ls -lh /opt/lore/backups/lore-data-*.tar.zst | tail -1
   ```
   If `OFFSITE_DEST` is configured, confirm the offsite copy landed too. **Do not proceed
   without a backup you can see.**

2. **Note the currently-running tag** (your rollback target):
   ```sh
   docker inspect lore-server -f '{{.Config.Image}}'    # write this down
   ```

3. **Edit `compose.yml`** to the new immutable dated `TAG`.

4. **Pull + recreate.** The named `lore-data` volume is reused as-is (compose does not touch
   it unless you pass `-v`):
   ```sh
   docker compose pull
   docker compose up -d
   ```

5. **Verify health and a real client operation** (a small `lore` clone/push from a client),
   not just the health endpoint — a format mismatch can pass `/health_check` but fail real
   reads. If anything looks wrong, **[roll back](#roll-back) immediately** and restore the
   pre-upgrade backup if `/data` was touched.

---

## Roll back

If a new image is bad but `/data` is still intact and compatible:

1. **Edit `compose.yml`** back to the previous `TAG` (the one you noted in the upgrade step).
2. ```sh
   docker compose pull
   docker compose up -d
   curl -i http://127.0.0.1:41339/health_check
   ```

If the bad version **migrated `/data` to an incompatible format**, an image rollback alone
won't help — you must also [restore the pre-upgrade backup](#restore-from-backup). This is
exactly why the upgrade step takes a backup first.

---

## Backup strategy

**What:** the `lore-data` named volume (immutable content store + mutable branch pointers).
That single volume is the whole source of truth.

**How:** `scripts/backup.sh` briefly **stops** the server (so the on-disk store isn't mutated
mid-copy — Lore's local store flushes on an interval, so a hot copy can be torn), streams a
zstd-compressed tar of the volume to `/opt/lore/backups`, writes a `.sha256` sidecar, and —
if `OFFSITE_DEST` is set — pushes both offsite.

**Schedule (nightly, offsite):** install a cron job on the colo:
```sh
# /etc/cron.d/lore-backup  (runs 03:30 colo time)
30 3 * * *  root  OFFSITE_DEST="rclone:REMOTE:lore-backups" COMPOSE_FILE=/opt/lore/compose.yml /opt/lore/backup.sh /opt/lore/backups >> /var/log/lore-backup.log 2>&1
```
Set `OFFSITE_DEST` to the team's real offsite target (rclone remote for B2/S3/Drive, or
`user@host:/path` for a second physical box). **A local-only backup dies with the box** — the
script warns loudly if `OFFSITE_DEST` is unset.

**Retention:** keep ~14 nightly archives locally; let the offsite target keep a longer tail
(e.g. 30–90 days) per the offsite provider's lifecycle rules. Old local archives can be pruned
to protect disk headroom (see [Capacity](#health-logs-capacity)).

> **A backup you have never restored is a rumor, not a backup.** See the next section and
> actually run it. Record the **last-tested-restore date** in this runbook when you do.
>
> Last tested restore: _NOT YET TESTED — do this on first deploy (see step 9)._

---

## Restore from backup

> **The restore path must be tested, not assumed.** Practice it against a SCRATCH volume so
> you trust it before the night you need it for real.

### A. Test restore (non-destructive — do this regularly)

Restore a backup into a throwaway volume and boot a temporary server against it, leaving the
live `lore-data` untouched:
```sh
ssh COLO
cd /opt/lore
# Restore into a scratch volume (script refuses to touch lore-data here):
./restore.sh /opt/lore/backups/lore-data-<TS>.tar.zst lore-data-test

# Boot a throwaway server on alternate host ports, pointed at the scratch volume:
docker run --rm -d --name lore-restore-test \
  -p 51339:41339/tcp \
  -v lore-data-test:/data \
  ghcr.io/sandboxservers/lore-server:<TAG>

curl -i http://127.0.0.1:51339/health_check    # expect HTTP/1.1 200 OK
# Ideally also do a `lore` clone from a client against this instance.

docker rm -f lore-restore-test
docker volume rm lore-data-test
```
If health is 200 and a clone works, the backup is **proven restorable**. Update the
*Last tested restore* date above.

### B. Real restore (DESTRUCTIVE — only when the live store is lost/corrupt)

1. Stop the server: `docker compose stop lore-server`
2. ```sh
   ./restore.sh /opt/lore/backups/lore-data-<TS>.tar.zst lore-data
   ```
   The script verifies the `.sha256`, prompts for `yes`, wipes `lore-data`, repopulates it
   from the archive, fixes ownership to UID/GID 1001, and restarts the server.
3. Verify: `curl -i http://127.0.0.1:41339/health_check` (expect 200) and a client clone.

---

## Rotate

### TLS cert
When the QUIC/gRPC cert nears expiry (the self-signed one is 825 days; a CA cert is shorter):
1. Generate/obtain the new cert into `/opt/lore/certs` (e.g. re-run `./make-certs.sh`, or drop
   in the renewed CA cert/key with the **same filenames** `cert.pem` / `key.pem`).
2. Recreate the container so it picks up the new files:
   ```sh
   docker compose up -d --force-recreate lore-server
   ```
3. Verify health, and confirm clients still connect (a CA change may require clients to trust
   the new chain).

### JWT signing keys (only if auth is enabled)
Lore verifies JWTs against a JWKS endpoint (`[server.auth.jwk] endpoint`). Key rotation happens
at the **identity provider**, not here — Lore re-fetches keys on an unknown key ID. After
rotating keys at the IdP, no Lore-side action is needed beyond confirming new tokens validate.
If you change the issuer/audience/JWKS URL, edit `local.toml` and `docker compose up -d
--force-recreate lore-server`. (Enabling auth at all is an app/identity decision — see the
seam note in the PR; the supervision and mounts are ours, the IdP config is the owning
engineer's.)

---

## Reverse proxy + TLS

**Do not expose Lore's raw ports to the open internet.** Put a gate in front of it.

Important nuance specific to Lore: the push/clone path is **QUIC over UDP** (port 41337) and
**gRPC over HTTP/2 TCP** (also 41337). A normal **L7 HTTP reverse proxy (nginx/Caddy/Traefik
HTTP routers) cannot terminate QUIC/gRPC for Lore** — so the usual "terminate TLS at the proxy"
pattern does not apply cleanly. Options, in order of preference for a small team:

1. **Lore terminates its own TLS** (the cert from [Rotate](#rotate)/`make-certs.sh`) and you
   restrict exposure at the network layer:
   - **Tailscale / WireGuard VPN** (recommended): only team devices on the tailnet reach
     41337; nothing is published to the public internet. Simplest and safest.
   - **Firewall allowlist**: open 41337/tcp+udp and (if needed) 41339/tcp only to known team
     IPs.
2. **L4 stream passthrough** (nginx `stream{}` / HAProxy TCP mode + a UDP proxy for QUIC) if
   you must front it with a box on a public IP — more moving parts; document it here if you go
   this route.
3. Keep **41339 (HTTP health)** bound to loopback or the VPN only — it's for health/presigned
   URLs, not something the public needs (`127.0.0.1:41339:...` in compose).

Whatever you choose, the cert Lore presents must be **stable across restarts** (not the
zero-config ephemeral cert) so pinned clients don't break.

---

## Why a pinned tag

Lore is **pre-1.0 and under active development; its on-disk format can change between
releases.** If the colo pulled `:latest` (or any auto-updater pulled a new build unattended),
a routine refresh could swap in a server whose format doesn't match the existing `/data` and
**silently corrupt or strand the team's history**. So:

- `compose.yml` pins an **immutable dated tag** (`YYYY-MM-DD.N`), never `:latest` and never the
  rolling `latest-prerelease` pointer in production.
- There is **no Watchtower / auto-update** on this deployment (deliberately unlike Cimmeria).
- Every version bump is **manual and backup-first** (see [Upgrade](#routine-deploy--upgrade)).

The Lore source version is pinned in `docker/Dockerfile` via `LORE_VERSION` (currently
`v0.8.3`) and verified against a commit SHA at build time so a re-tagged upstream can't change
what we build.

---

## Health, logs, capacity

- **Health:** `curl -i http://127.0.0.1:41339/health_check` → `200`. Container health:
  `docker compose ps` (look for `healthy`). The image's `HEALTHCHECK` flips to `unhealthy`
  after 3 failed probes.
- **Logs:** `docker compose logs -f lore-server` (JSON to stdout). Capped at 5×20 MB per
  `compose.yml` so logs can't fill the disk.
- **Capacity (finite colo hardware — watch it):**
  ```sh
  df -h /var/lib/docker            # overall Docker disk
  docker system df                 # images/volumes/build cache
  du -sh /opt/lore/backups         # local backup footprint
  docker run --rm -v lore-data:/d:ro alpine:3.20 du -sh /d   # live store size
  ```
  The store grows with every committed binary asset (that's the point of Lore). Trend it.
  When `/var/lib/docker` headroom gets tight: prune old local backups, run the
  `prune-container` workflow to GC old GHCR tags, and `docker image prune` stale local images.
  Flag low headroom early — there is no elastic cloud to absorb a full disk here.

---

## Open questions (colo specifics)

These need Steven's answers before this is production-final — see the PR description:
- **Hostname / DNS** for the server (sets the TLS cert CN/SAN and what clients point at).
- **Disk location for `lore-data`** on the box, and how much **headroom** it has vs. expected
  asset growth.
- **TLS cert source** — self-signed stopgap, internal CA, or Let's Encrypt (DNS-01)?
- **Exposed port + firewall / VPN** posture (Tailscale assumed? public IP? allowlist?).
- **Container registry** — GHCR assumed; confirm, and confirm the colo's pull credentials.
- **Pinned Lore version** — confirm `v0.8.3` is the intended production pin.
- **Offsite backup target** for `OFFSITE_DEST` (B2/S3/Drive via rclone, or a second box?).
