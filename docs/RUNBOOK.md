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
6. [Lore is reachable only over the UniFi (UCG Fiber) WireGuard VPN](#vpn-only-network-posture)
7. [Rotate (TLS cert / JWT signing keys)](#rotate)
8. [Provision Azure DNS for ACME](#provision-azure-dns-for-acme)
9. [Set deploy-time secrets on the Debian colo box](#set-deploy-time-secrets-on-the-debian-colo-box)
10. [Reverse proxy + TLS](#reverse-proxy--tls)
11. [TLS renewal failed (troubleshooting)](#tls-renewal-failed)
12. [Why a pinned tag (never `:latest`)](#why-a-pinned-tag)
13. [Health, logs, capacity](#health-logs-capacity)
14. [Open questions (colo specifics)](#open-questions-colo-specifics)

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
   Set at minimum: `LORE_LAN_IP` (the host's **private LAN IP** — Lore binds here, VPN-only;
   never `0.0.0.0`/WAN), `LORE_DOMAIN` (`lore.sandboxservers.games`), `LE_EMAIL`,
   `LE_DNS_PROVIDER=azuredns` (the `sandboxservers.games` zone lives in **Azure DNS**), and
   **leave `LE_STAGING=true` for the first run** so a misconfig can't burn Let's Encrypt rate
   limits.

3. **Provision the Azure DNS service principal and drop its creds on the box.** Azure DNS
   authenticates with **multiple** values (not a single token), so this is two steps:
   - One-time, in Azure: create the app registration / service principal and grant it
     **DNS Zone Contributor scoped to the `sandboxservers.games` zone** — see
     [Provision Azure DNS for ACME](#provision-azure-dns-for-acme).
   - On the box: write the `AZURE_*` values into a root-owned `chmod 600` env file that
     compose loads via `env_file:` — see
     [Set deploy-time secrets on the Debian colo box](#set-deploy-time-secrets-on-the-debian-colo-box).

   Do **not** put any `AZURE_*` value (especially `AZURE_CLIENT_SECRET`) in `.env` or git —
   this repo is public.

4. **Create `/opt/lore/config/local.toml`** from the example. This sets the **private LAN
   bind addresses** (`<LORE_LAN_IP>`) for the QUIC/gRPC/HTTP endpoints **and** points Lore
   at the cert the lego sidecar writes (`<LORE_DOMAIN>`). Substitute both from `.env`:
   ```sh
   sed -e "s/<LORE_DOMAIN>/$(grep '^LORE_DOMAIN=' .env | cut -d= -f2)/g" \
       -e "s/<LORE_LAN_IP>/$(grep '^LORE_LAN_IP=' .env | cut -d= -f2)/g" \
       config/local.toml.example > config/local.toml
   cat config/local.toml      # sanity check: host = <your LAN IP> on quic/grpc/http; cert paths
   ```
   `<LORE_LAN_IP>` is the host's **private LAN IP** (the address the box has on the colo LAN
   behind the UCG Fiber). It must be a private/RFC1918 address — **never `0.0.0.0` and never
   the WAN/public IP**. The same value goes in `.env` as `LORE_LAN_IP` (compose uses it for
   the healthcheck). See
   [Lore is reachable only over the UniFi WireGuard VPN](#vpn-only-network-posture).

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

8. **Verify** (see [Health](#health-logs-capacity)). Lore binds the **private LAN IP**, not
   loopback, so probe that address (run from the box, which is on the LAN, or from a device on
   the VPN):
   ```sh
   LAN_IP=$(grep '^LORE_LAN_IP=' .env | cut -d= -f2)
   curl -i "http://$LAN_IP:41339/health_check"      # expect: HTTP/1.1 200 OK
   docker compose ps                                # State should be "running (healthy)"
   # Confirm the served cert is the LE one (CN/issuer), not Lore's ephemeral self-signed:
   echo | openssl s_client -connect "$LAN_IP:41337" -servername "$(grep '^LORE_DOMAIN=' .env | cut -d= -f2)" 2>/dev/null \
     | openssl x509 -noout -issuer -subject -dates
   ```
   Then confirm the ports are NOT reachable from the public internet — see
   [VPN-only network posture § firewall verification](#firewall-verification).

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
   curl -i "http://$(grep '^LORE_LAN_IP=' .env | cut -d= -f2):41339/health_check"
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
3. Verify: `curl -i "http://$(grep '^LORE_LAN_IP=' .env | cut -d= -f2):41339/health_check"`
   (expect 200) and a client clone over the VPN.

---

<a id="vpn-only-network-posture"></a>
## Lore is reachable only over the UniFi (UCG Fiber) WireGuard VPN

**The decision (settled):** Lore is **never exposed to the public internet.** It is reachable
**only** over the operators' existing **UniFi WireGuard VPN**, which runs on the colo's
**UCG Fiber** (UniFi Cloud Gateway Fiber) gateway. The Lore host sits on the colo LAN behind
that gateway. This is the team's standing way in — no new VPN software, no extra moving parts.

**Why VPN-only (not a public port + auth):** Lore ships with **authentication disabled** —
the gRPC API accepts unauthenticated requests out of the box (`[server.auth]` absent in every
shipped config). Bare public ports would be an open door to the team's *entire version-control
history*. Gating at the network layer (VPN) is mandatory regardless of TLS; **TLS is encryption,
not access control.**

**How the bind enforces it (two layers, defense in depth):**

1. **Lore binds the private LAN IP only.** `local.toml` sets `host = <LORE_LAN_IP>` on
   `[server.quic]`, `[server.grpc]`, and `[server.http]` (the upstream
   `lore-server-config` reference: each endpoint takes a `host` bind field defaulting to
   `0.0.0.0`; we override it). So 41337/TCP (gRPC), 41337/UDP (QUIC), and 41339/TCP (HTTP
   health) answer only on the colo LAN interface — never `0.0.0.0`, never the WAN.
2. **`compose.yml` uses `network_mode: host`** so that bind is real and direct (no docker
   bridge DNAT in the QUIC/UDP path). There is no `ports:` publish block — nothing is mapped
   to a public interface.

### How operators reach Lore

1. **Connect the UniFi WireGuard VPN** on your laptop/device exactly as you already do to get
   onto the colo network (the WireGuard app, using the config from the UCG Fiber). Once the
   tunnel is up you are "on the LAN."
2. **Hit `lore.sandboxservers.games`** with the `lore` client. Via split-horizon DNS (below)
   that name resolves to the host's **private LAN IP**, which is reachable over the tunnel. The
   Let's Encrypt cert's SAN is `lore.sandboxservers.games`, so TLS validates normally even
   though the address behind the name is private.

If you are **not** on the VPN, the name resolves to nothing useful and the ports do not answer
from the public internet — that is the intended behavior.

### Grant a new device access (add a WireGuard peer on the UCG Fiber)

Each device that needs Lore gets its own WireGuard **client (peer)** on the UCG Fiber's
built-in WireGuard VPN server. In the **UniFi Network** application:

1. Go to **Settings → VPN → VPN Server** and open the **WireGuard** server (the one already
   serving the operators). Note its **UDP listen port** (default **51820/UDP**) — that single
   UDP port is the *only* thing the gateway exposes on the WAN for VPN.
2. Click **Add Client** (i.e., add a peer).
3. Give it a descriptive **name** (e.g. `steven-laptop`, `derek-desktop`).
4. Let UniFi generate the client config (keypair + assigned tunnel IP). Optionally set a
   pre-shared key and the allowed/remote networks. For Lore access the client's allowed IPs
   must include the colo LAN subnet that holds `<LORE_LAN_IP>`.
5. **Download the configuration file** (or scan the **QR code** on mobile) and import it into
   the device's WireGuard app.
6. Connect, then verify the device can reach Lore:
   `curl -i https://lore.sandboxservers.games:41339/health_check` (expect `200`) once
   split-horizon DNS resolves the name to `<LORE_LAN_IP>`.

> Source for the UniFi steps: Ubiquiti Help Center, "UniFi Gateway – WireGuard VPN Server,"
> and WunderTech's UCG WireGuard guide. The exact menu labels can shift between UniFi Network
> versions — if **Settings → VPN → VPN Server** doesn't match your console, look under the
> **VPN** section for the WireGuard **server** and its **Add Client** action.
> **Flag:** confirm against the live console; UniFi relabels menus across releases.

<a id="firewall-verification"></a>
### Firewall verification — the public WAN must NOT forward Lore's ports

The UCG Fiber must have **no WAN port-forward / NAT rule** sending 41337 or 41339 to the Lore
host. The **only** inbound port open on the WAN should be the **WireGuard server's UDP listen
port** (default 51820/UDP). Verify it:

1. **In UniFi Network:** Settings → **Security / Port Forwarding** (a.k.a. NAT / firewall) —
   confirm there is **no** forward for `41337` or `41339`. The only WAN-facing inbound service
   should be the WireGuard VPN's UDP port.
2. **From OFF the VPN** (e.g. a phone on cellular, or any host on the public internet),
   confirm Lore's ports are **closed** against the colo's public/WAN IP. Replace
   `<COLO_WAN_IP>` with the colo's real WAN address:
   ```sh
   # TCP gRPC (41337) and HTTP health (41339) — expect "closed"/filtered, NO connection:
   nc -vz -w 5 <COLO_WAN_IP> 41337    # expect: timeout / refused, NOT "succeeded"
   nc -vz -w 5 <COLO_WAN_IP> 41339    # expect: timeout / refused, NOT "succeeded"
   # UDP QUIC (41337/udp) — should NOT respond on the WAN:
   nc -vzu -w 5 <COLO_WAN_IP> 41337   # expect: no open/QUIC response
   # If you have nmap:
   nmap -Pn -p 41337,41339 <COLO_WAN_IP>          # expect: closed/filtered
   nmap -Pn -sU -p 41337 <COLO_WAN_IP>            # expect: closed/filtered
   ```
   **Any of these succeeding from off-VPN is a red-alert misconfiguration** — Lore's
   auth-disabled ports would be world-reachable. Remove the offending WAN forward immediately
   and re-verify the LAN-only bind (`docker inspect lore-server`; confirm `host` in
   `local.toml` is the LAN IP, and `network_mode: host` with no `ports:` block).
3. **Confirm the bind on the box itself** — Lore should be listening on the LAN IP, not
   `0.0.0.0`:
   ```sh
   ss -tulpn | grep -E '41337|41339'    # addresses should be <LORE_LAN_IP>:..., NOT 0.0.0.0:...
   ```

<a id="split-horizon-dns"></a>
### Split-horizon DNS — `lore.sandboxservers.games` → private LAN IP for VPN clients

VPN clients must resolve `lore.sandboxservers.games` to the host's **private LAN IP**
(`<LORE_LAN_IP>`), while **public DNS** for `sandboxservers.games` carries **only** the
`_acme-challenge` TXT record Let's Encrypt needs (there is deliberately **no public A/AAAA
record** for the Lore name — nothing public should resolve it to a reachable address).

For a **2-person team**, simplest first, in order of preference:

- **Per-device hosts entry (simplest, zero infrastructure).** On each dev box, add one line:
  ```
  <LORE_LAN_IP>   lore.sandboxservers.games
  ```
  (`/etc/hosts` on Linux/macOS; `C:\Windows\System32\drivers\etc\hosts` on Windows.) Two
  people, two files. Done. The cert SAN still matches the name, so TLS validates.
- **UniFi DNS (cleaner, no per-device edits).** In **UniFi Network → Settings → Policy
  Engine / DNS** (label varies by version), add a **local DNS record** mapping
  `lore.sandboxservers.games → <LORE_LAN_IP>`. VPN clients that use the UCG Fiber as their
  resolver then get the private answer automatically. Recommended once a third device shows up;
  for two people the hosts entry is less to maintain.

Either way, **do not publish a public A/AAAA record** for `lore.sandboxservers.games`. Public
DNS for the zone holds only what ACME DNS-01 needs.

### TLS (DNS-01) is unaffected by the VPN-only posture

The lego sidecar proves domain control by writing a `_acme-challenge` **TXT** record to Azure
DNS and talking **outbound** to Let's Encrypt — **no inbound `:80`/`:443` and no public
exposure of Lore is required.** So DNS-01 issuance/renewal works exactly the same behind the
VPN. The issued cert's SAN stays **`lore.sandboxservers.games`**, which VPN clients hit over the
tunnel (resolving to the private LAN IP via split-horizon DNS) — the cert validates because the
client connects to the SAN *name*, regardless of the private address behind it. See
[Reverse proxy + TLS](#reverse-proxy--tls) for the full TLS design.

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

## Provision Azure DNS for ACME

The `lego` sidecar proves control of `lore.sandboxservers.games` by writing a temporary
`_acme-challenge` **TXT** record into the `sandboxservers.games` zone in **Azure DNS**. It does
that through an Azure AD **service principal** with **least-privilege** rights on *that one
zone* — not the whole subscription.

Do this **once** (or whenever you rotate the secret). You need an Azure account with rights to
create an app registration and assign a role on the DNS zone. Commands use the `az` CLI; the
portal works too.

1. **Log in and select the subscription that holds the DNS zone.**
   ```sh
   az login
   az account set --subscription "<SUBSCRIPTION_NAME_OR_ID>"
   SUBSCRIPTION_ID=$(az account show --query id -o tsv)
   RESOURCE_GROUP="<rg-that-contains-the-dns-zone>"      # the RG holding the zone, NOT a new one
   ZONE="sandboxservers.games"
   ```

2. **Confirm the zone exists and note its resource group.** (If the zone isn't in Azure DNS yet,
   that's a prerequisite — create the zone and point the registrar's NS records at Azure first.)
   ```sh
   az network dns zone show -g "$RESOURCE_GROUP" -n "$ZONE" --query id -o tsv
   # -> /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/dnszones/sandboxservers.games
   ```

3. **Create the app registration / service principal AND scope its role to the zone in one
   shot.** `az ad sp create-for-rbac` with `--scopes` set to the **zone resource ID** grants
   **DNS Zone Contributor on that zone only** — least privilege, not subscription-wide.
   ```sh
   ZONE_ID=$(az network dns zone show -g "$RESOURCE_GROUP" -n "$ZONE" --query id -o tsv)

   az ad sp create-for-rbac \
     --name "lore-acme-dns01" \
     --role "DNS Zone Contributor" \
     --scopes "$ZONE_ID"
   ```
   This prints JSON **once** — capture it now, the secret is not retrievable later:
   ```json
   {
     "appId":    "00000000-0000-0000-0000-000000000000",   // -> AZURE_CLIENT_ID
     "password": "the-generated-client-secret",            // -> AZURE_CLIENT_SECRET  (SECRET)
     "tenant":   "00000000-0000-0000-0000-000000000000"     // -> AZURE_TENANT_ID
   }
   ```

4. **Collect the five values lego needs** (source: lego upstream `azuredns` docs):

   | lego env var | Value | Secret? |
   | --- | --- | --- |
   | `AZURE_TENANT_ID` | `tenant` from step 3 | no |
   | `AZURE_CLIENT_ID` | `appId` from step 3 | no |
   | `AZURE_CLIENT_SECRET` | `password` from step 3 | **YES** |
   | `AZURE_SUBSCRIPTION_ID` | `$SUBSCRIPTION_ID` (step 1) | no |
   | `AZURE_RESOURCE_GROUP` | `$RESOURCE_GROUP` (the zone's RG) | no |

   We also set `AZURE_AUTH_METHOD=env` to pin lego to client-secret-from-env auth (skips the
   Azure credential auto-detection chain — fail fast and explicit).

5. **(Optional) verify the SP can edit the zone** before wiring it into lego:
   ```sh
   az role assignment list --assignee "<appId>" --scope "$ZONE_ID" -o table
   # expect a "DNS Zone Contributor" row scoped to the zone
   ```

Now put these values on the box — next section.

> **Least privilege, restated:** the role is scoped to the **zone resource ID**, so this
> principal can edit records in `sandboxservers.games` and nothing else. If you ever see it
> granted "Contributor" at subscription or RG scope, that's too broad — re-create it with
> `--scopes "$ZONE_ID"`.

---

## Set deploy-time secrets on the Debian colo box

The Azure service-principal creds live **only on the colo box**, in a root-owned `chmod 600`
env file that `docker compose` loads via `env_file:`. They are never in git (public repo) and
never baked into an image layer.

1. **Create the secrets dir** (first deploy only):
   ```sh
   ssh COLO
   sudo install -d -o root -g root -m 700 /opt/lore/secrets
   ```

2. **Write the env file** with the five values from
   [Provision Azure DNS for ACME](#provision-azure-dns-for-acme). Create it root-owned and
   `0600` from the start so the secret is never briefly world-readable:
   ```sh
   sudo install -o root -g root -m 600 /dev/null /opt/lore/secrets/azure-dns.env
   sudo tee /opt/lore/secrets/azure-dns.env >/dev/null <<'EOF'
   AZURE_AUTH_METHOD=env
   AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000
   AZURE_CLIENT_ID=00000000-0000-0000-0000-000000000000
   AZURE_CLIENT_SECRET=the-service-principal-secret
   AZURE_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000
   AZURE_RESOURCE_GROUP=dns-rg-holding-the-sandboxservers-games-zone
   EOF
   ```
   The variable names **must match `.env.example` exactly** — lego reads these literal
   `AZURE_*` names. No quotes around values (an env file is `KEY=value`, not shell).

3. **Lock down and verify permissions:**
   ```sh
   sudo chmod 600 /opt/lore/secrets/azure-dns.env
   sudo chown root:root /opt/lore/secrets/azure-dns.env
   ls -l /opt/lore/secrets/azure-dns.env      # expect: -rw------- root root
   ```

4. **How compose consumes it.** `compose.yml`'s `lego` service has:
   ```yaml
   env_file:
     - ${AZURE_DNS_ENV_FILE:-/opt/lore/secrets/azure-dns.env}
   ```
   `.env` sets the path (`AZURE_DNS_ENV_FILE=/opt/lore/secrets/azure-dns.env`, the default). On
   `docker compose up -d`, compose reads the env file and injects each `AZURE_*` var into the
   sidecar's environment, where lego's `azuredns` provider reads them. **The file must exist or
   `compose up` fails fast** — that's intentional (better than a sidecar that silently can't
   issue a cert).

5. **Rotating the secret later** (when the SP secret expires or is compromised): generate a new
   secret in Azure (`az ad sp credential reset --id <appId>`), update
   `/opt/lore/secrets/azure-dns.env`, then recreate just the sidecar so it picks up the new env:
   ```sh
   sudo $EDITOR /opt/lore/secrets/azure-dns.env     # paste the new AZURE_CLIENT_SECRET
   docker compose up -d --force-recreate lego
   docker compose logs --since 5m lego              # confirm it authenticates / renews cleanly
   ```

> **Higher-security variant.** If you'd rather keep `AZURE_CLIENT_SECRET` out of an env file
> entirely, lego honors the `_FILE` suffix: set `AZURE_CLIENT_SECRET_FILE=/run/secrets/azure_client_secret`
> (keep the non-secret IDs in the env file) and bind-mount that 0600 file read-only into the
> sidecar. The shipped default is the single env file — fewer moving parts for a 2am operator.

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
  it works entirely behind the firewall. Cost: it needs **DNS-provider credentials** — here, an
  **Azure DNS service principal** scoped to the `sandboxservers.games` zone, stored in
  `/opt/lore/secrets/azure-dns.env` (see [Provision Azure DNS for ACME](#provision-azure-dns-for-acme)).
- **Single-host cert, no wildcard.** lego issues for `lore.sandboxservers.games` only
  (`-d lore.sandboxservers.games`). DNS-01 *could* do a wildcard, but we deliberately don't —
  a single-name cert keeps the blast radius minimal if the key is ever exposed.
- lego writes `cert.pem`/`key.pem`-equivalents (`<domain>.crt` / `.key`) to the shared
  `lore-certs` volume; `local.toml` points Lore's `[server.quic.certificate]` and
  `[server.grpc.certificate]` at them.
- On issuance/renewal lego runs `renew-hook.sh`, which `docker restart`s `lore-server` so Lore
  reloads the cert.
- **Staging first:** `LE_STAGING=true` (the default) uses Let's Encrypt's staging CA — untrusted
  certs, but no risk to the strict production rate limits. Flip to `false` on the box only once
  staging issuance works (first-time deploy step 7a).

### Network exposure — SETTLED: VPN-only via the UCG Fiber WireGuard VPN

**TLS is not access control.** The network gate is the
[UniFi (UCG Fiber) WireGuard VPN](#vpn-only-network-posture) — that section is authoritative;
this is the short version:

- Lore binds the **private LAN IP** (`<LORE_LAN_IP>`) on all three endpoints via `local.toml`,
  with `network_mode: host` in compose. Nothing is published to a public interface.
- The **UCG Fiber** exposes only the **WireGuard UDP listen port** (default 51820/UDP) on the
  WAN — **no** WAN forward to 41337/41339. Verify with
  [firewall verification](#firewall-verification).
- DNS-01 still works because validation is **outbound** to Azure DNS, not inbound to the box.

This deliberately does **not** use Tailscale (the operators run their own UniFi WireGuard and
don't want a third-party control plane) and does not need a separate firewall-allowlist scheme —
the VPN is the allowlist.

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
| `credentials information are missing` / Azure credential build error | `azure-dns.env` missing, empty, or not loaded | Confirm `/opt/lore/secrets/azure-dns.env` exists, is `0600 root:root`, and has all five `AZURE_*` vars; confirm `.env`'s `AZURE_DNS_ENV_FILE` path matches; `docker compose up -d lego`. |
| `unauthorized` / `403` / `AuthorizationFailed` from Azure | SP lacks DNS Zone Contributor on the zone, or `AZURE_CLIENT_SECRET` expired/wrong | Verify the role assignment is scoped to the zone (`az role assignment list --assignee <appId> --scope <zoneId>`); if the secret expired, reset it (`az ad sp credential reset --id <appId>`), update `azure-dns.env`, `docker compose up -d --force-recreate lego`. |
| `tenant`/`client` ID error, `AADSTS700016` (app not found) | wrong `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` | Re-check the three IDs in `azure-dns.env` against the `az ad sp` output; recreate the SP if lost. |
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

- **Health:** Lore binds the **private LAN IP**, so probe that (from the box or over the VPN),
  not loopback:
  `curl -i "http://$(grep '^LORE_LAN_IP=' /opt/lore/.env | cut -d= -f2):41339/health_check"` →
  `200`. Container health: `docker compose ps` (look for `healthy`). The compose `HEALTHCHECK`
  probes `${LORE_LAN_IP}:41339` and flips to `unhealthy` after 3 failed probes.
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
- ~~**DNS provider for `sandboxservers.games`**~~ — RESOLVED: **Azure DNS** (`LE_DNS_PROVIDER=azuredns`).
  Creds are an Azure service principal scoped to the zone, stored in `/opt/lore/secrets/azure-dns.env`
  (see [Provision Azure DNS for ACME](#provision-azure-dns-for-acme)). Remaining sub-item: confirm
  the `sandboxservers.games` zone is actually hosted in Azure DNS (registrar NS records point at
  Azure) and note the zone's **subscription ID** and **resource group** for the env file.
- ~~**Exposed port + firewall / VPN** posture~~ — **RESOLVED: VPN-only via the UniFi
  (UCG Fiber) WireGuard VPN.** Lore is never publicly exposed; it binds the private LAN IP
  (`<LORE_LAN_IP>`) and is reached only over the operators' existing UCG Fiber WireGuard VPN.
  See [Lore is reachable only over the UniFi WireGuard VPN](#vpn-only-network-posture). The UCG
  must have no WAN forward to 41337/41339 (only the WireGuard UDP port) —
  [verify](#firewall-verification). Remaining sub-item for the operator: set the real
  `LORE_LAN_IP` in `.env` on the box, and pick split-horizon DNS (per-device hosts entry vs.
  UniFi local DNS).
- **Disk location for `lore-data` / `lore-certs`** on the box, and **headroom** vs. expected
  asset growth.
- ~~**TLS cert source**~~ — RESOLVED: auto-renewing Let's Encrypt via DNS-01 (lego sidecar).
  Self-signed `make-certs.sh` retained only as an air-gapped fallback.
- **Container registry** — GHCR assumed; confirm, and confirm the colo's pull credentials.
- **Pinned Lore version** — confirm `v0.8.3` is the intended production pin.
- **Offsite backup target** for `OFFSITE_DEST` (B2/S3/Drive via rclone, or a second box?).
