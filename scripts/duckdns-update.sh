#!/usr/bin/env bash
# Aktualisiert den A-Record (IPv4) von sioxd.duckdns.org bei DuckDNS.
# Token wird aus ~/.duckdns-token gelesen (chmod 600).
set -euo pipefail

DOMAIN="sioxd"
TOKEN_FILE="${HOME}/.duckdns-token"

if [[ ! -r "${TOKEN_FILE}" ]]; then
    echo "Token-Datei fehlt oder nicht lesbar: ${TOKEN_FILE}" >&2
    exit 1
fi

TOKEN="$(cat "${TOKEN_FILE}")"
IPV4="$(curl -4 -fsS --max-time 10 https://api.ipify.org)"

curl -fsS --max-time 15 \
    "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=${IPV4}&verbose=true"
echo
