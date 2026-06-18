#!/bin/sh
# Generate a self-signed TLS certificate for the Lore QUIC/gRPC endpoint.
#
# # OFFLINE / AIR-GAPPED FALLBACK ONLY.
#
# The PRODUCTION TLS path is now auto-renewing Let's Encrypt via the lego
# DNS-01 sidecar (see docker/compose.yml `lego` service + docs/RUNBOOK.md
# § Reverse proxy + TLS). Prefer that.
#
# Use THIS script only when LE is not an option:
#   - air-gapped / no outbound internet to reach the ACME API,
#   - the DNS provider has no API (so DNS-01 can't work) and :80 isn't
#     publicly reachable (so HTTP-01 can't work either),
#   - a quick local bring-up before the DNS token is provisioned.
#
# A self-signed cert means every Lore client must trust it explicitly, and
# it does NOT auto-renew — you must re-run this and recreate the container
# before the 825-day expiry. The durability win it shares with LE is that
# the cert is STABLE across restarts (the zero-config Lore cert is
# regenerated on every boot, which breaks pinned clients).
#
# Usage:
#   scripts/make-certs.sh <CN> [outdir]
# Example:
#   scripts/make-certs.sh lore.colo.example.com /opt/lore/certs
set -eu

CN="${1:?usage: make-certs.sh <CN> [outdir]}"
OUTDIR="${2:-./certs}"

mkdir -p "${OUTDIR}"

# 825 days is the max many clients accept for a leaf cert. SANs cover the
# CN plus loopback so local health probes over TLS still validate.
openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "${OUTDIR}/key.pem" \
    -out    "${OUTDIR}/cert.pem" \
    -days 825 \
    -subj "/CN=${CN}" \
    -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1,IP:::1"

chmod 600 "${OUTDIR}/key.pem"
chmod 644 "${OUTDIR}/cert.pem"

echo "Wrote ${OUTDIR}/cert.pem and ${OUTDIR}/key.pem (CN=${CN})."
echo "Next: reference them from /etc/lore/config/local.toml:"
echo
echo "  [server.quic.certificate]"
echo "  cert_file = \"/etc/lore/cert.pem\""
echo "  pkey_file = \"/etc/lore/key.pem\""
echo
echo "and uncomment the cert + local.toml mounts in docker/compose.yml."
