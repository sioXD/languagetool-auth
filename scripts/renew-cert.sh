#!/usr/bin/env bash
# Erneuert das Let's-Encrypt-Zertifikat per DNS-01 (DuckDNS) und lädt nginx neu.
# `lego run` erneuert nur, wenn das Zertifikat tatsächlich fällig ist.
# Aufruf: scripts/renew-cert.sh
set -euo pipefail

# Projektverzeichnis = ein Level über diesem Skript (portabel, kein fester Pfad)
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="sioxd.duckdns.org"
TOKEN_FILE="${HOME}/.duckdns-token"

if [[ ! -r "${TOKEN_FILE}" ]]; then
    echo "Token-Datei fehlt oder nicht lesbar: ${TOKEN_FILE}" >&2
    exit 1
fi

TOKEN="$(cat "${TOKEN_FILE}")"

# --user, damit die Dateien nicht als root im lego-Ordner landen.
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e DUCKDNS_TOKEN="${TOKEN}" \
    -v "${BASE}/lego:/data" \
    goacme/lego run --path /data --accept-tos --dns duckdns --domains "${DOMAIN}"

# lego legt Leaf + Zwischenzertifikate bereits gebündelt in <domain>.crt ab.
install -m 644 "${BASE}/lego/certificates/${DOMAIN}.crt" "${BASE}/certs/fullchain.pem"
install -m 600 "${BASE}/lego/certificates/${DOMAIN}.key" "${BASE}/certs/privkey.pem"

docker exec languagetool-nginx nginx -s reload
