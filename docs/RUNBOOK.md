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
8. [TLS renewal failed (troubleshooting)](#tls-renewal-failed)
9. [Why a pinned tag (never `:latest`)](#why-a-pinned-tag)
10. [Health, logs, capacity](#health-logs-capacity)
11. [Open questions (colo specifics)](#open-questions-colo-specifics)

---

## First-time deploy

1. **Put the deploy files on the box.**
   ```sh
   ssh COLO 'mkdir -p /opt/lore/config /opt/lore/secrets /opt/lore/backups'
   scp docker/compose.yml COLO:/opt/lore/compose.yml
   scp .env.example COLO:/opt/lore/.env.example
   scp docker/config/local.toml.example COLO:/opt/lore/config/local.toml.example
   scp -r docker/lego COLO:/opt/lore/lego          # sidecar build context
   scp scripts/backup.sh scripts/restore.sh scripts/make-certs.sh COLO:/opt/lore/
   ```

2. **Configure `.env`** (deploy-time config; gitignored, lives only on the box):
   ```sh
   ssh COLO
   cd /opt/lore
   cp .env.example .env
   $EDITOR .env
   ```
   Set at minimum: `LORE_DOMAIN` (e.g. `lore.sandboxservers.games`), `LE_EMAIL`,
   `LE_DNS_PROVIDER` (the provider hosting the `sandboxservers.games` zone — see
   [Open questions](#open-questions-colo-specifics)), and **leave `LE_STAGING=true` for the
   first run** so a misconfig can't burn Let's Encrypt rate limits.

3. **Drop in the DNS-provider API token** as a 0600 file (NOT in `.env`, NOT in git):
   ```sh
   install -m 600 /dev/stdin /opt/lore/secrets/dns_api_token    # then paste the token, Ctrl-D
   ```
   The compose `lego` service mounts this read-only and hands it to lego via the provider's
   `*_FILE` env var (the Cloudflare default is `CLOUDFLARE_DNS_API_TOKEN_FILE`; if your
   provider differs, change that var name in `compose.yml` — see `.env.example`). The token
   should be **zone-scoped to `sandboxservers.games`, DNS-edit only** — least privilege.

4. **Create `/opt/lore/config/local.toml`** from the example, pointing Lore at the cert the
   lego sidecar writes (replace `<LORE_DOMAIN>` with your real domain):
   ```sh
   sed "s/<LORE_DOMAIN>/$(grep '^LORE_DOMAIN=' .env | cut -d= -f2)/" \
       config/local.toml.example > config/local.toml
   cat config/local.toml      # sanity check the paths
   ```

5. **Pin the image tag** in `.env`. Set `LORE_IMAGE` to the specific immutable dated tag you
   intend to run (not the rolling `latest-prerelease` pointer):
   ```sh
   # in .env:
   LORE_IMAGE=ghcr.io/sandboxservers/lore-server:2026-06-18.1   # the TAG you chose
   ```

6. **Authenticate to GHCR** (the package is private) and bring it up:
   ```sh
   echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin
   docker compose build lego     # build the lego sidecar image from ./lego
   docker compose pull           # pulls the pinned lore-server tag
   docker compose up -d
   ```
   On first boot the `lego` sidecar obtains the cert via DNS-01 and its deploy-hook restarts
   `lore-server` so Lore loads it. Watch it happen:
   ```sh
   docker compose logs -f lego          # expect "[lego] ... running lego" then a cert, no errors
   ```
   If lego errors, see [TLS renewal failed](#tls-renewal-failed) — and note that with
   `LE_STAGING=true` the cert is **untrusted by design**; that's expected until you flip to
   production (step 7a).

   **7a. Promote to a real (trusted) cert** once staging issuance works end-to-end:
   ```sh
   sed -i 's/^LE_STAGING=true/LE_STAGING=false/' .env
   docker compose up -d lego                 # recreate lego with prod ACME
   # lego sees the staging cert and re-issues from production; deploy-hook restarts lore-server
   docker compose logs -f lego
   ```

8. **Verify** (see [Health](#health-logs-capacity)):
   ```sh
   curl -i http://127.0.0.1:41339/health_check     # expect: HTTP/1.1 200 OK
   docker compose ps                                # State should be "running (healthy)"
   # Confirm the served cert is the LE one (CN/issuer), not Lore's ephemeral self-signed:
   echo | openssl s_client -connect 127.0.0.1:41337 -servername "$(grep '^LORE_DOMAIN=' .env | cut -d= -f2)" 2>/dev/null \
     | openssl x509 -noout -issuer -subject -dates
   ```

9. **Confirm the volumes are the named ones** (not accidental anonymous volumes):
   ```sh
   docker volume inspect lore-data lore-certs >/dev/null && echo "volumes OK"
   docker inspect lore-server -f '{{json .Mounts}}'   # should show source=lore-data and lore-certs
   ```

10. **Take your first backup and TEST THE RESTORE** before anyone pushes real history —
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
**Normally this is automatic** — the `lego` sidecar renews within `RENEW_WITHIN_DAYS` (default
30) of expiry and its deploy-hook restarts `lore-server` to load the new cert. You should not
have to do anything. To confirm renewal is healthy:
```sh
docker compose logs --since 48h lego | tail -n 40       # look for a renewal + "restarted"
# Inspect the live cert's expiry:
docker run --rm -v lore-certs:/c:ro alpine:3.20 \
  sh -c 'apk add -q openssl && openssl x509 -enddate -noout \
  -in /c/certificates/'"$(grep '^LORE_DOMAIN=' /opt/lore/.env | cut -d= -f2)"'.crt'
```

**Force an early renewal** (e.g. before a planned outage, or to recover from a missed window):
```sh
docker compose exec lego sh -c \
  'lego run --accept-tos --email "$LE_EMAIL" \
     --server "$( [ "$LE_STAGING" = false ] && echo letsencrypt || echo letsencrypt-staging )" \
     --dns "$LE_DNS_PROVIDER" --domains "$LORE_DOMAIN" --path "$LEGO_PATH" \
     --renew-days 90 --renew-force --deploy-hook /usr/local/bin/renew-hook.sh'
```
If renewal is failing, see [TLS renewal failed](#tls-renewal-failed).

**Air-gapped / no-ACME fallback** (self-signed, manual): generate with `./make-certs.sh`,
write the files to the `lore-certs` volume at `certificates/<domain>.crt` / `.key`, then
`docker compose up -d --force-recreate lore-server`. This does NOT auto-renew. See
[Reverse proxy + TLS](#reverse-proxy--tls).

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

### Why there is no reverse proxy terminating TLS

Lore's push/clone path is **QUIC over UDP** (41337) and its control path is **gRPC over HTTP/2
TCP** (also 41337). **Lore terminates its own TLS** — it reads `cert_file`/`pkey_file` for both
the QUIC and gRPC endpoints (confirmed in the upstream `lore-server-config` reference). A normal
**L7 HTTP reverse proxy (nginx/Caddy/Traefik HTTP routers) cannot terminate Lore's QUIC/gRPC**,
so the usual "let Caddy/Traefik get the Let's Encrypt cert and terminate TLS" pattern does **not**
apply. That is *why* this deployment uses an ACME **sidecar that hands the cert to Lore**, not a
TLS-terminating proxy.

Also important: **Lore loads its cert at startup only — there is no hot-reload.** A renewed cert
does nothing until `lore-server` restarts. The sidecar's deploy-hook handles that restart.

### How TLS works here (the production path)

The `lego` service in `compose.yml` obtains and auto-renews a real Let's Encrypt cert via the
**DNS-01** challenge:

- **DNS-01, not HTTP-01**, because the colo is firewalled / VPN-only — we can't assume public
  inbound :80. DNS-01 proves control by writing a TXT record through the DNS provider's API, so
  it works entirely behind the firewall and also supports wildcards. Cost: it needs a
  **DNS-provider API token** (the deploy-time secret in `/opt/lore/secrets/dns_api_token`).
- lego writes `cert.pem`/`key.pem`-equivalents (`<domain>.crt` / `.key`) to the shared
  `lore-certs` volume; `local.toml` points Lore's `[server.quic.certificate]` and
  `[server.grpc.certificate]` at them.
- On issuance/renewal lego runs `renew-hook.sh`, which `docker restart`s `lore-server` so Lore
  reloads the cert.
- **Staging first:** `LE_STAGING=true` (the default) uses Let's Encrypt's staging CA — untrusted
  certs, but no risk to the strict production rate limits. Flip to `false` on the box only once
  staging issuance works (first-time deploy step 7a).

### Network exposure (still your job — TLS is not access control)

**Do not expose Lore's raw ports to the open internet.** Gate it at the network layer:

- **Tailscale / WireGuard VPN** (recommended): only team devices on the tailnet reach 41337;
  nothing is published publicly. Simplest and safest. DNS-01 still works because validation is
  outbound to the DNS API, not inbound to the box.
- **Firewall allowlist**: open 41337/tcp+udp (and 41339/tcp only if needed) to known team IPs.
- Keep **41339 (HTTP health)** bound to loopback (`127.0.0.1:41339:...`, as shipped) or the VPN
  — it's for health/presigned URLs, not the public.

### The Docker-socket tradeoff, and the no-socket alternative

The `lego` sidecar mounts `/var/run/docker.sock` so its hook can restart `lore-server`. **Socket
access is effectively host root** — we accept it on this single-box colo for simplicity (the
sidecar drops all caps, sets `no-new-privileges`, runs only lego + one `docker restart`, and is
not network-exposed). If you want **zero socket exposure**, run lego from the host instead:

1. Remove the `lego` service and the socket mount from `compose.yml`; keep the `lore-certs`
   volume and the `local.toml` cert wiring.
2. Install lego on the host (or run `goacme/lego` as a one-shot container writing into the
   `lore-certs` volume).
3. Add a host **systemd timer** (preferred over cron — randomized delay, journaled) that runs
   `lego ... run --renew-days 30 --deploy-hook 'docker restart lore-server'` daily. The hook
   then runs on the host with host docker, so nothing inside a container touches the socket.

### Air-gapped / no-ACME fallback (self-signed)

Only when ACME is impossible (no outbound internet to the ACME API, and a DNS provider with no
API plus no public :80): `scripts/make-certs.sh <domain>` generates a stable self-signed cert.
Write it into the `lore-certs` volume at `certificates/<domain>.crt` / `.key`, then
`docker compose up -d --force-recreate lore-server`. **It does not auto-renew** and every client
must trust it explicitly — track its 825-day expiry yourself.

---

## TLS renewal failed

The lego sidecar logs a `WARNING: lego run failed` line and retries every
`RENEW_INTERVAL_SECONDS` (default daily). Because lego renews ~30 days before expiry, **a few
failed days are not an emergency** — you have weeks of runway. But don't ignore it.

**1. Look at the error:**
```sh
docker compose logs --since 24h lego | grep -iE 'error|warning' | tail -n 20
```

**2. Common causes and fixes:**

| Symptom in logs | Cause | Fix |
| --- | --- | --- |
| `credentials information are missing` | token file empty / wrong provider var | Check `/opt/lore/secrets/dns_api_token` is non-empty and 0600; confirm the `*_FILE` env var in `compose.yml` matches `LE_DNS_PROVIDER`. |
| `unauthorized` / `403` from the DNS API | token lacks DNS-edit on the zone, or expired | Re-issue a zone-scoped, DNS-edit token at the provider; update the secret file; `docker compose up -d lego`. |
| `propagation` / `timeout` waiting for TXT | DNS propagation slow, or split-horizon DNS | Usually transient — let it retry. If persistent, set `LEGO_DNS_RESOLVERS` to the authoritative NS, or raise `--dns.propagation.wait`. |
| `acme: error ... rateLimited` | hit production LE limits (too many real issuances) | Stop forcing issuance. Wait out the window. Use `LE_STAGING=true` for any experimentation. |
| hook ran but clients still see old/ephemeral cert | `docker restart lore-server` failed (socket?) | Check `docker compose logs lego` for the renew-hook error; restart manually: `docker restart lore-server`; verify the socket mount. |

**3. If expiry is imminent and you can't fix DNS-01 in time:** drop in a self-signed cert via the
[air-gapped fallback](#reverse-proxy--tls) to keep the server serving a *stable* cert (better
than letting Lore fall back to its per-boot ephemeral cert, which breaks pinned clients), then
fix DNS-01 without time pressure.

**4. The data is never at risk here.** A TLS failure stops *new TLS sessions from validating*; it
does not touch `/data`. Never wipe `lore-data` to "fix" a cert problem.

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
- **Hostname / DNS** — `lore.sandboxservers.games` is the assumed name (set in `.env.example`).
  Confirm it's the intended FQDN and that an A/AAAA record points it at the box.
- **DNS provider for `sandboxservers.games`** — **decides the `LE_DNS_PROVIDER` plugin and which
  `*_FILE` token env var `compose.yml` must set.** `.env.example`/`compose.yml` default to
  `cloudflare`; if the zone lives at Route 53 / Gandi / Namecheap / etc., update both. (This is
  the single biggest blocker for TLS go-live.)
- **Exposed port + firewall / VPN** posture — Tailscale assumed? Public IP? Allowlist? This
  decides network exposure; DNS-01 works either way, so it does **not** block TLS issuance.
- **Disk location for `lore-data` / `lore-certs`** on the box, and **headroom** vs. expected
  asset growth.
- ~~**TLS cert source**~~ — RESOLVED: auto-renewing Let's Encrypt via DNS-01 (lego sidecar).
  Self-signed `make-certs.sh` retained only as an air-gapped fallback.
- **Container registry** — GHCR assumed; confirm, and confirm the colo's pull credentials.
- **Pinned Lore version** — confirm `v0.8.3` is the intended production pin.
- **Offsite backup target** for `OFFSITE_DEST` (B2/S3/Drive via rclone, or a second box?).
