#!/bin/sh
# Generate a self-signed TLS certificate for the Lore QUIC/gRPC endpoint.
#
# This is a STOPGAP for getting a durable (non-ephemeral) cert in place
# quickly. A self-signed cert means every Lore client must trust it
# explicitly. For a real deployment, replace this with a cert from your
# CA (Let's Encrypt via DNS-01, or the team's internal CA) — see
# docs/RUNBOOK.md § Reverse proxy + TLS. The important durability win
# either way is that the cert is STABLE across restarts (the zero-config
# Lore cert is regenerated on every boot, which breaks pinned clients).
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
