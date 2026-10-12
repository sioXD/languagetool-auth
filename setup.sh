#!/usr/bin/env bash
#
# Setup für LanguageTool + nginx Basic Auth
# - erzeugt die .env aus der Vorlage (falls nötig)
# - erzeugt die htpasswd-Datei für ALLE Benutzer aus LT_USERS in .env
# - startet die Container
#
set -euo pipefail
cd "$(dirname "$0")"

PASSWD_FILE="nginx/.htpasswd"

# ---------- Hilfsfunktionen ----------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # führende Leerzeichen entfernen
    s="${s%"${s##*[![:space:]]}"}"   # folgende Leerzeichen entfernen
    printf '%s' "$s"
}

# Erzeugt eine htpasswd-Zeile "benutzer:hash" (bevorzugt bcrypt)
hash_entry() {
    local user="$1" pass="$2"
    if command -v htpasswd >/dev/null 2>&1; then
        htpasswd -nbB "$user" "$pass"
    elif command -v openssl >/dev/null 2>&1; then
        local h
        h="$(printf '%s' "$pass" | openssl passwd -apr1 -stdin)"
        printf '%s:%s\n' "$user" "$h"
    else
        docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass"
    fi
}

# ---------- 1. .env sicherstellen ----------
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo
        echo "Es wurde eine neue Datei '.env' erstellt."
        echo "  -> Bitte öffne '.env' und trage deine Benutzer in LT_USERS ein."
        echo "  -> Dann dieses Skript erneut ausführen:  ./setup.sh"
        echo
        exit 1
    else
        echo "Fehler: Weder .env noch .env.example vorhanden." >&2
        exit 1
    fi
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

# Abwärtskompatibilität: LT_USER/LT_PASS weiterhin erlaubt
if [ -z "${LT_USERS:-}" ] && [ -n "${LT_USER:-}" ] && [ -n "${LT_PASS:-}" ]; then
    LT_USERS="${LT_USER}:${LT_PASS}"
fi

if [ -z "${LT_USERS:-}" ]; then
    echo "Fehler: LT_USERS ist in .env nicht gesetzt." >&2
    echo "Format: LT_USERS=\"benutzer1:passwort1,benutzer2:passwort2\"" >&2
    exit 1
fi

# ---------- 2. htpasswd-Datei für alle Benutzer erzeugen ----------
mkdir -p nginx

TMP_HTPASSWD="$(mktemp)"
trap 'rm -f "$TMP_HTPASSWD"' EXIT

echo "Erzeuge Basic-Auth-Datei für folgende Benutzer:"
count=0
first_user=""
IFS=',' read -ra _entries <<< "$LT_USERS"
for entry in "${_entries[@]}"; do
    entry="$(trim "$entry")"
    [ -z "$entry" ] && continue

    if [[ "$entry" != *:* ]]; then
        echo "Fehler: Eintrag ohne ':' in LT_USERS: '$entry'" >&2
        echo "Erwartetes Format: benutzer:passwort" >&2
        exit 1
    fi

    user="$(trim "${entry%%:*}")"
    pass="${entry#*:}"          # Passwort NICHT trimmen (Leerzeichen könnten gewollt sein)

    if [ -z "$user" ] || [ -z "$pass" ]; then
        echo "Fehler: Benutzer oder Passwort ist leer in: '$entry'" >&2
        exit 1
    fi

    hash_entry "$user" "$pass" >> "$TMP_HTPASSWD"
    echo "  + $user"
    [ -z "$first_user" ] && first_user="$user"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "Fehler: Es wurde kein gültiger Benutzer in LT_USERS gefunden." >&2
    exit 1
fi

mv "$TMP_HTPASSWD" "$PASSWD_FILE"
trap - EXIT
chmod 600 "$PASSWD_FILE"
echo "Fertig: $PASSWD_FILE ($count Benutzer)"

# ---------- 3. Container starten ----------
echo
echo "Starte Container ... (erster Start lädt die Images, kann dauern)"
docker compose up -d

echo
echo "Status:"
docker compose ps

echo
echo "Fertig!"
echo "Lokalen Test ausführen:"
echo "  curl -u '$first_user:****' http://localhost:${PUBLIC_PORT:-8082}/v2/languages"