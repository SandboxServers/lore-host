#!/bin/sh
# lego ACME sidecar entrypoint — obtains and auto-renews the Lore server's
# TLS certificate via DNS-01, writing it to the shared `lore-certs` volume
# that the lore-server container reads.
#
# # Why a sidecar and not a reverse proxy
#
# Lore TERMINATES ITS OWN TLS on the QUIC (UDP) and gRPC (HTTP/2 TCP)
# endpoints — it reads cert_file/pkey_file off disk. A normal L7 HTTP
# reverse proxy cannot terminate Lore's QUIC/gRPC, so the usual
# "Caddy/Traefik gets the LE cert" pattern does not apply. Instead this
# sidecar obtains the cert and drops it where Lore reads it.
#
# # Why DNS-01
#
# The colo is firewalled / VPN-only, so inbound :80 for HTTP-01 can't be
# assumed. DNS-01 validates by creating a TXT record via the DNS
# provider's API, so it works behind a firewall. (DNS-01 also CAN do
# wildcards, but this deployment issues a SINGLE-HOST cert for
# ${LORE_DOMAIN} only — no wildcard — to keep the blast radius minimal.)
# It needs DNS-provider API credentials (a deploy-time secret) — for
# Azure DNS these are the AZURE_* service-principal vars; see .env.
#
# # Why it restarts lore-server on renewal
#
# Lore loads its cert at STARTUP ONLY (no hot-reload as of v0.8.x). So a
# renewed cert does nothing until the server restarts. The deploy-hook
# (renew-hook.sh) restarts the lore-server container via the Docker
# socket. If a future Lore release adds cert hot-reload, soften the hook.
#
# # lego v5 CLI note
#
# lego v5 has a single `run` command that both ISSUES (if missing) and
# RENEWS (if within --renew-days of expiry) and is otherwise a no-op. All
# flags below are `run` options (only --log.* / --config / --help /
# --version are global in v5 — even --path is a `run` flag), so they ALL
# come AFTER `run`. The deploy-hook fires only when a cert is actually
# created or renewed.
set -eu

# --- Required configuration (from compose env / .env) ---------------------
: "${LORE_DOMAIN:?set LORE_DOMAIN, e.g. lore.sandboxservers.games}"
: "${LE_EMAIL:?set LE_EMAIL — the ACME account contact address}"
: "${LE_DNS_PROVIDER:?set LE_DNS_PROVIDER, e.g. azuredns (see lego --dns)}"

# Output dir on the shared volume. lego writes:
#   ${LEGO_PATH}/certificates/${LORE_DOMAIN}.crt   (leaf + issuer chain)
#   ${LEGO_PATH}/certificates/${LORE_DOMAIN}.key
# Lore's local.toml points cert_file/pkey_file straight at these.
LEGO_PATH="${LEGO_PATH:-/certs}"

# Renewal cadence. `lego run` renews only when within --renew-days of
# expiry, so a daily check is cheap and resilient to a missed run.
RENEW_INTERVAL_SECONDS="${RENEW_INTERVAL_SECONDS:-86400}"  # 24h
RENEW_WITHIN_DAYS="${RENEW_WITHIN_DAYS:-30}"

# Staging vs production. DEFAULT TO STAGING so a misconfigured deploy can
# never burn Let's Encrypt's strict production rate limits. The colo's
# real deploy sets LE_STAGING=false explicitly (see RUNBOOK § TLS).
# lego v5 accepts the shortcodes "letsencrypt" / "letsencrypt-staging".
LE_STAGING="${LE_STAGING:-true}"
if [ "${LE_STAGING}" = "true" ]; then
    LE_SERVER="letsencrypt-staging"
    echo "[lego] LE_STAGING=true — using Let's Encrypt STAGING (untrusted certs, no rate-limit risk)."
    echo "[lego] Set LE_STAGING=false on the colo for real, client-trusted certs."
else
    LE_SERVER="letsencrypt"
    echo "[lego] LE_STAGING=false — using Let's Encrypt PRODUCTION. Rate limits apply."
fi

# All flags are `run` options in lego v5. --accept-tos records ToS
# acceptance; --renew-days makes the same command a no-op until near expiry;
# --deploy-hook restarts lore-server only when a cert is actually issued or
# renewed. lego v4.8+ adds a random pre-renewal sleep to spread CA load.
run_lego() {
    # shellcheck disable=SC2086
    lego \
        run \
        --accept-tos \
        --email "${LE_EMAIL}" \
        --server "${LE_SERVER}" \
        --dns "${LE_DNS_PROVIDER}" \
        --domains "${LORE_DOMAIN}" \
        `# SINGLE-HOST cert: exactly one --domains (no wildcard ` \
        `# *.sandboxservers.games). Add more only by adding more --domains.` \
        --path "${LEGO_PATH}" \
        --renew-days "${RENEW_WITHIN_DAYS}" \
        --deploy-hook "/usr/local/bin/renew-hook.sh"
}

# --- Issue/renew loop -----------------------------------------------------
# First pass issues the cert (and fires the deploy-hook so lore-server picks
# it up). Subsequent passes are no-ops until within RENEW_WITHIN_DAYS of
# expiry, at which point lego renews and the deploy-hook restarts Lore.
echo "[lego] Managing cert for ${LORE_DOMAIN} via DNS-01 (${LE_DNS_PROVIDER}); check every ${RENEW_INTERVAL_SECONDS}s, renew within ${RENEW_WITHIN_DAYS} days of expiry."
while true; do
    echo "[lego] $(date -u +%FT%TZ) running lego for ${LORE_DOMAIN}"
    run_lego \
        || echo "[lego] WARNING: lego run failed (will retry next interval). See RUNBOOK § 'Renewal failed'."
    sleep "${RENEW_INTERVAL_SECONDS}"
done
