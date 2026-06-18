# lore-host

Docker hosting for the team's self-hosted **[Lore](https://github.com/EpicGames/lore)**
version-control server on the **Wisconsin colo** box.

Lore is the team's **single source of truth** — every other repo depends on the history
stored here. This repo containerizes `loreserver`, supervises it with s6-overlay, ships it
through a GitHub Actions container pipeline, and documents how to operate it durably on real
hardware. The whole game is **not losing the team's history** to a reboot, a full disk, a bad
image pull, or a 2am operator who isn't the person who set it up.

> **Operators start here:** [`docs/RUNBOOK.md`](docs/RUNBOOK.md) — deploy, roll back,
> restore-from-backup, rotate, plus the backup strategy and reverse-proxy/TLS guidance.

---

## What this is

- `docker/Dockerfile` — builds `loreserver` **from a pinned Lore source tag** (there is no
  official published Lore image), on top of a digest-pinned Rust/Debian base, supervised by
  s6-overlay. See the [pinned-tag rationale](#why-a-pinned-tag-never-latest).
- `docker/compose.yml` — single-file colo deployment: a **named persistent volume** for
  Lore's content store, port mappings, a `/health_check` healthcheck, and
  `restart: unless-stopped`.
- `docker/s6/lore-server/` — the s6-overlay service tree (one supervised long-run process).
- `.github/workflows/` — `pr-container` (build + smoke-test every PR), `release-container`
  + `release-on-comment` (publish to GHCR), `prune-container` (GC old tags so the registry
  and colo disk don't fill).
- `docs/RUNBOOK.md` — the operations runbook.

## Durability posture (the short version)

| Concern | How it's handled |
| --- | --- |
| Where the data lives | Named Docker volume **`lore-data`** mounted at `/data` (immutable + mutable stores). Never anonymous, never a forgotten bind mount. |
| Survives a reboot? | Yes — named volume + `restart: unless-stopped`. The store path is explicit (the Lore default lands in a temp dir a reboot can wipe). |
| Backups | Nightly snapshot of `lore-data`, pushed **offsite**. See [RUNBOOK § Backup strategy](docs/RUNBOOK.md#backup-strategy). |
| Restore | Documented, copy-pasteable, and **must be tested, not assumed** — a backup you have never restored is a rumor. See [RUNBOOK § Restore](docs/RUNBOOK.md#restore-from-backup). |
| Image tag | **Pinned** to a specific Lore source tag (`LORE_VERSION` in the Dockerfile). No `:latest`, no auto-pull. |
| Health | `HEALTHCHECK` hits `GET :41339/health_check`; a wedged process shows up as `unhealthy` instead of silently broken. |
| Least privilege | Runs as a non-root `lore` user; capabilities dropped; minimal mounts. |
| TLS / exposure | Lore terminates QUIC/gRPC TLS itself with a real cert; raw ports are **not** thrown open to the internet. See [RUNBOOK § Reverse proxy + TLS](docs/RUNBOOK.md#reverse-proxy--tls). |
| Secrets | Certs/keys/JWT config are **mounted at deploy time**, never baked into image layers (layers are forever and shareable). |

## Why a pinned tag, never `:latest`

Lore is **pre-1.0 and under active development — its on-disk format can change between
releases.** If we ran `:latest` (or any auto-pull like Watchtower), a routine image refresh
could pull a build whose on-disk format the previous data directory doesn't match, and
silently corrupt or strand the team's entire history. So:

1. The image is built from an explicit `LORE_VERSION` git tag pinned in `docker/Dockerfile`.
2. There is **no auto-update** on the colo. Version bumps are deliberate.
3. **Every bump takes a fresh backup first** (RUNBOOK § Upgrade), so a bad format migration
   is recoverable rather than terminal.

Currently pinned: **`v0.8.3`** (the latest Lore release as of 2026-06-18). Confirm with
Steven before treating this as the production-final pin — see open questions in the PR.

---

## Decision record — why Lore?

The team stores large binary assets (purchased Humble Bundle / FAB asset packs, cooked
content) **in the repo by design**, alongside code. We evaluated the alternatives and chose
Lore deliberately:

- **GitHub LFS — rejected.** The free tier caps at ~10 GB of LFS storage/bandwidth, far too
  small for the purchased asset bundles we keep in-repo. Paid LFS data packs exist but the
  cost scales badly with the binary volume we expect, and we'd still be renting someone
  else's storage for our source of truth.
- **Azure DevOps LFS — rejected.** Same Git-LFS pointer model and its sharp edges, just a
  different host; doesn't solve the "large binaries are first-class" problem, and ties the
  team's source of truth to a vendor we'd otherwise not run.
- **Perforce — rejected.** It genuinely handles large binaries, but it's centralized,
  license-encumbered, and operationally heavy (Helix Core admin, typemap discipline, per-seat
  licensing). Too much ongoing ops weight for a small team, and the workflow is a poor fit for
  people who think in Git branches.
- **Lore — chosen.** Git-style branching workflow **plus** native content-addressed chunk
  tracking of large binaries that live in the repo by design — exactly our shape. It's
  open-source (MIT), self-hostable on our own hardware (no per-seat license, no rented
  storage for our own history), and built by Epic for code-plus-large-binary projects. The
  team are experienced power users who accept its **bleeding-edge, pre-1.0 state** — which is
  precisely why this repo treats durability (pinned tags, tested restores, offsite backups)
  as the whole job.

---

## Quick links

- Lore upstream: <https://github.com/EpicGames/lore> · docs: <https://epicgames.github.io/lore/>
- Deploy / roll back / restore / rotate: [`docs/RUNBOOK.md`](docs/RUNBOOK.md)
- House deployment pattern this mirrors: `SandboxServers/Cimmeria`
