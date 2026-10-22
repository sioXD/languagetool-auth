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

# ---------- n-gram-Daten (Language Model, optional) ----------
# Quellen: feste Download-Dateinamen von https://languagetool.org/download/ngram-data/
NGRAM_BASE_URL="https://languagetool.org/download/ngram-data"
NGRAM_DIR="ngrams"

# Liefert den ZIP-Dateinamen für eine Sprache oder scheitert bei unbekannter Sprache.
ngram_zip() {
    case "$1" in
        de) printf '%s' "ngrams-de-20150819.zip" ;;
        en) printf '%s' "ngrams-en-20150817.zip" ;;
        fr) printf '%s' "ngrams-fr-20150913.zip" ;;
        es) printf '%s' "ngrams-es-20150915.zip" ;;
        nl) printf '%s' "ngrams-nl-20181229.zip" ;;
        *)  return 1 ;;
    esac
}

# Menschenlesbarer Name für die Ausgabe.
ngram_label() {
    case "$1" in
        de) printf '%s' "Deutsch" ;;
        en) printf '%s' "Englisch" ;;
        fr) printf '%s' "Französisch" ;;
        es) printf '%s' "Spanisch" ;;
        nl) printf '%s' "Niederländisch" ;;
        *)  printf '%s' "$1" ;;
    esac
}

# Normalisiert eine Komma-Liste: trimmt, lowercase, prüft, entdoppelt.
normalize_ngram_langs() {
    local input="$1" out="" lang
    local IFS=','
    for lang in $input; do
        lang="$(trim "$lang")"
        lang="$(printf '%s' "$lang" | tr '[:upper:]' '[:lower:]')"
        [ -z "$lang" ] && continue
        if ! ngram_zip "$lang" >/dev/null; then
            echo "Warnung: unbekannte n-gram-Sprache '$lang' (erlaubt: de,en,fr,es,nl)" >&2
            continue
        fi
        case ",$out," in *",$lang,"*) continue ;; esac
        out="${out:+$out,}$lang"
    done
    printf '%s' "$out"
}

# Prüft, ob eine Sprache bereits (vollständig) entpackt vorliegt.
ngram_installed() {
    [ -d "$NGRAM_DIR/$1/1grams" ]
}

# Entpackte Daten aus einem Temp-Verzeichnis nach ngrams/<lang>/ einsortieren.
# Erkennt sowohl die direkte Struktur (1grams/...) als auch verschachtelte
# Varianten (z. B. <lang>/1grams oder eine einzelne Unterebene).
install_extracted_ngram() {
    local lang="$1" src="$2" cand
    mkdir -p "$NGRAM_DIR/$lang"

    if [ -d "$src/$lang/1grams" ]; then
        mv "$src/$lang/"* "$NGRAM_DIR/$lang/" && return 0
    fi
    if [ -d "$src/1grams" ]; then
        mv "$src/"* "$NGRAM_DIR/$lang/" && return 0
    fi
    for cand in "$src"/*/; do
        [ -d "$cand" ] || continue
        if [ -d "$cand$lang/1grams" ]; then
            mv "$cand$lang/"* "$NGRAM_DIR/$lang/" && return 0
        fi
        if [ -d "$cand/1grams" ]; then
            mv "$cand"* "$NGRAM_DIR/$lang/" && return 0
        fi
    done
    return 1
}

# Stellt sicher, dass NGRAM_DIR existiert und vom aktuellen Benutzer beschreibbar
# ist. Wird VOR dem Start der Container aufgerufen, damit Docker den Ordner nicht
# selbst (als root) anlegt. Ist er doch root-owned und leer, wird er neu erstellt;
# wurde er dabei ersetzt, muss der Container neu erstellt werden (NGRAM_DIR_REPLACED).
NGRAM_DIR_REPLACED=false
# Wird gesetzt, wenn tatsächlich neue n-gram-Daten geladen wurden -> Container
# muss danach neu gestartet werden, damit LanguageTool sie einliest.
NGRAM_DOWNLOADED=false
ensure_ngram_dir_ready() {
    local d="$NGRAM_DIR"
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        return 0
    fi
    if [ -w "$d" ]; then
        return 0
    fi
    if [ -z "$(ls -A "$d" 2>/dev/null)" ] && rmdir "$d" 2>/dev/null && mkdir -p "$d"; then
        NGRAM_DIR_REPLACED=true
        return 0
    fi
    echo "Warnung: '$d' ist nicht beschreibbar und konnte nicht neu angelegt werden." >&2
    echo "         Bitte einmalig ausführen:  sudo chown -R \"\$USER\" $d" >&2
    return 0
}

# Lädt fehlende Sprachen herunter und entpackt sie. Vorhandene werden übersprungen.
ensure_ngrams() {
    local langs="$1"
    [ -z "$langs" ] && return 0

    if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
        echo "Warnung: 'curl' und/oder 'unzip' fehlen – n-gram-Daten werden übersprungen." >&2
        return 0
    fi

    ensure_ngram_dir_ready
    if [ ! -w "$NGRAM_DIR" ]; then
        echo "Warnung: '$NGRAM_DIR' ist nicht beschreibbar – Download wird übersprungen." >&2
        return 0
    fi

    echo "Prüfe n-gram-Daten:"
    local lang zip url tmp
    local IFS=','
    for lang in $langs; do
        [ -z "$lang" ] && continue
        if ngram_installed "$lang"; then
            echo "  - $lang ($(ngram_label "$lang")): bereits vorhanden, übersprungen"
            continue
        fi
        zip="$(ngram_zip "$lang")" || continue
        url="$NGRAM_BASE_URL/$zip"
        echo "  - $lang ($(ngram_label "$lang")): lade $zip (groß, kann dauern) ..."
        tmp="$(mktemp -d)"
        if ! curl -fL --retry 3 -o "$tmp/$zip" "$url"; then
            echo "    Fehler: Download fehlgeschlagen – $lang wird übersprungen." >&2
            rm -rf "$tmp"
            continue
        fi
        if ! unzip -q "$tmp/$zip" -d "$tmp/x"; then
            echo "    Fehler: Entpacken fehlgeschlagen – $lang wird übersprungen." >&2
            rm -rf "$tmp"
            continue
        fi
        if install_extracted_ngram "$lang" "$tmp/x"; then
            echo "    Fertig: $lang in $NGRAM_DIR/$lang/"
            NGRAM_DOWNLOADED=true
        else
            echo "    Fehler: unerwartete ZIP-Struktur – $lang wird übersprungen." >&2
        fi
        rm -rf "$tmp"
    done
}

# Erzeugt ein zufälliges Token (für den geheimen Extension-Pfad).
gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Setzt/ersetzt KEY="WERT" in .env (legt vorher ein Backup .env.bak an).
set_env_var() {
    local key="$1" val="$2" tmp
    cp -f .env .env.bak
    chmod 600 .env.bak 2>/dev/null || true
    tmp="$(mktemp)"
    awk -v key="$key" -v val="$val" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" { print key "=\"" val "\""; done = 1; next }
        { print }
        END { if (!done) print key "=\"" val "\"" }
    ' .env > "$tmp"
    mv "$tmp" .env
}

# Speichert die n-gram-Auswahl in .env.
save_ngrams_to_env() {
    set_env_var LT_NGRAMS "$1"
    echo "  (Auswahl in .env gespeichert${1:+, aktuell: $1})"
}

# ---------- Server-Adresse für die LanguageTool-Extension ----------
# Ermittelt die lokale LAN-IP (leer, wenn nicht ermittelbar).
detect_lan_ip() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s' "$ip"
}

# Ermittelt die öffentliche IP (leer, wenn offline/nicht ermittelbar).
detect_public_ip() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

# Gibt die fertige Server-Adresse für die Extension und für Programme aus.
print_extension_hint() {
    local user="$1" pass="$2" port="$3" secret="$4"
    local lan_ip pub_ip
    lan_ip="$(detect_lan_ip)"
    pub_ip="$(detect_public_ip)"

    echo
    echo "============================================================"
    echo " Server-Adresse für die LanguageTool-Extension"
    echo "============================================================"
    echo
    echo "WICHTIG: Die Extension kann KEIN Passwort senden."
    echo "  -> auf diesem PC / im LAN: normale URL OHNE Passwort"
    if [ -n "$secret" ]; then
        echo "  -> aus dem Internet:       der geheime Pfad /${secret}/ (statt Passwort)"
    fi
    echo
    echo "Eine davon in der Extension eintragen"
    echo "(Felder 'Server-URL' bzw. 'LanguageTool API Server URL'):"
    echo
    echo "  auf diesem PC:      http://localhost:${port}/v2"
    if [ -n "$lan_ip" ]; then
        echo "  im Heimnetz (LAN):  http://${lan_ip}:${port}/v2"
    fi
    if [ -n "$secret" ]; then
        if [ -n "$pub_ip" ]; then
            echo "  aus dem Internet:   http://${pub_ip}:${port}/${secret}/v2"
        else
            echo "  aus dem Internet:   http://DEINE-DDNS-ODER-IP:${port}/${secret}/v2"
        fi
    fi
    echo
    echo "Für andere Programme (curl, Skripte, Apps) MIT Passwort:"
    if [ -n "$pub_ip" ]; then
        echo "  http://${user}:${pass}@${pub_ip}:${port}/v2"
    fi
    if [ -n "$lan_ip" ]; then
        echo "  http://${user}:${pass}@${lan_ip}:${port}/v2"
    fi
    if [ -z "$lan_ip" ] && [ -z "$pub_ip" ]; then
        echo "  http://${user}:${pass}@HOST:${port}/v2"
    fi
    echo
    echo "  Wichtig: das '/v2' am Ende gehört dazu."
    case "$pass" in
        *[@:/%,]*|*" "*)
            echo "  ACHTUNG: Das Passwort enthält Sonderzeichen (@ : / % , Leerzeichen)"
            echo "  – in der URL prozent-encodieren (z. B. '@' -> %40) oder einfacheres wählen."
            ;;
    esac
    if [ -n "$secret" ]; then
        echo "  Der geheime Pfad ist ein Ersatz für das Passwort bei der Extension:"
        echo "  wie ein Passwort behandeln, über 'LT_SECRET' in .env änderbar."
    fi
    echo "  Hinweis: Chrome/Edge blockieren 'benutzer:passwort@...' – nutze Firefox."
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
first_pass=""
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
    if [ -z "$first_user" ]; then
        first_user="$user"
        first_pass="$pass"
    fi
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "Fehler: Es wurde kein gültiger Benutzer in LT_USERS gefunden." >&2
    exit 1
fi

mv "$TMP_HTPASSWD" "$PASSWD_FILE"
trap - EXIT

# Wichtig: nginx liest die Datei im Container als Worker-Prozess mit dem
# Benutzer "nginx" (uid/gid 101), NICHT als root. Deshalb muss sie fuer die
# Gruppe 101 lesbar sein - chmod 600 wuerde zu "Permission denied" (HTTP 500)
# fuehren. Wir setzen 640 + Gruppe 101; falls die Gruppe hier nicht passt,
# fallen wir auf 644 zurueck.
if chgrp 101 "$PASSWD_FILE" 2>/dev/null; then
    chmod 640 "$PASSWD_FILE"
else
    chmod 644 "$PASSWD_FILE"
fi
echo "Fertig: $PASSWD_FILE ($count Benutzer)"

# ---------- 2b. n-gram-Daten (optional, interaktive Auswahl) ----------
# Merker: Existiert der Schlüssel LT_NGRAMS in .env, gilt die Frage als
# beantwortet. Fehlt er, fragen wir; fehlt eine gewünschte Sprache (z. B. nach
# abgebrochenem Download), fragen wir erneut.
ngrams_key_present=false
if grep -qE '^[[:space:]]*(export[[:space:]]+)?LT_NGRAMS=' .env; then
    ngrams_key_present=true
fi

current_ngrams="$(normalize_ngram_langs "${LT_NGRAMS:-}")"

ngrams_missing=false
for _l in $(printf '%s' "$current_ngrams" | tr ',' ' '); do
    ngram_installed "$_l" || ngrams_missing=true
done

if [ "$ngrams_key_present" = false ] || [ "$ngrams_missing" = true ]; then
    if [ -t 0 ]; then
        echo
        echo "── n-gram-Daten (optional) ─────────────────────────────"
        echo "  Verbessert die Erkennung verwechselter Wörter"
        echo "  (z. B. das/dass, their/there). Großer Download, nur einmalig."
        echo
        echo "  1) Keine"
        echo "  2) Nur Deutsch              (1,7 GB)"
        echo "  3) Deutsch + Englisch       (~11 GB)"
        echo "  4) Eigene Auswahl           (de,en,fr,es,nl)"
        if [ -n "$current_ngrams" ]; then
            echo "  (bisher gewählt: $current_ngrams)"
        fi
        read -rp "  Auswahl [1]: " _choice || _choice=""
        case "$_choice" in
            2) current_ngrams="de" ;;
            3) current_ngrams="de,en" ;;
            4)
                read -rp "  Sprachen (Komma-getrennt, z. B. de,en): " _custom || _custom=""
                current_ngrams="$(normalize_ngram_langs "$_custom")"
                ;;
            1) current_ngrams="" ;;
            "") ;;   # leere Eingabe: bisherige Auswahl (Default Keine) behalten
            *) echo "  Ungültige Auswahl – verwende 'Keine'."; current_ngrams="" ;;
        esac
        save_ngrams_to_env "$current_ngrams"
    else
        echo
        echo "Hinweis: nicht-interaktive Ausführung – n-gram-Auswahl übersprungen."
    fi
fi

ensure_ngrams "$current_ngrams"

# ---------- 2c. Geheimer Pfad für die Browser-Extension ----------
# Die Extension kann kein Basic-Auth-Passwort senden. Deshalb gibt es einen
# zufälligen geheimen Pfad, über den der Server ohne Passwort erreichbar ist.
LT_SECRET="${LT_SECRET:-}"
if [ -z "$LT_SECRET" ]; then
    LT_SECRET="$(gen_token)"
    set_env_var LT_SECRET "$LT_SECRET"
    echo "Neuer geheimer Extension-Pfad erzeugt und in .env gespeichert."
fi

mkdir -p nginx
SECRET_CONF="nginx/secret.conf"
{
    echo "# Automatisch erzeugt von setup.sh aus LT_SECRET – nicht manuell bearbeiten."
    if [ -n "$LT_SECRET" ]; then
        cat <<EOF
location /${LT_SECRET}/ {
    limit_req zone=lt burst=20 nodelay;
    proxy_pass http://languagetool:8010/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
    else
        echo "# (kein Secret-Pfad aktiv)"
    fi
} > "$SECRET_CONF"
chmod 600 "$SECRET_CONF" 2>/dev/null || true
echo "Geheimer Extension-Pfad: /${LT_SECRET}/"

# ---------- 3. Container starten ----------
# ngrams-Ordner vor dem Mounten anlegen, damit Docker ihn nicht als root erstellt.
ensure_ngram_dir_ready

echo
echo "Starte Container ... (erster Start lädt die Images, kann dauern)"
if [ "$NGRAM_DIR_REPLACED" = true ] || [ "$NGRAM_DOWNLOADED" = true ]; then
    # Neuer ngrams-Ordner und/oder neue Daten -> Container neu erstellen, damit
    # der Mount stimmt und LanguageTool die n-gram-Daten beim Start einliest.
    docker compose up -d --force-recreate languagetool
else
    docker compose up -d
fi

# nginx-Konfiguration testen und neu laden (falls nginx schon läuft)
if docker compose ps 2>/dev/null | grep -q "languagetool-nginx"; then
    echo "Prüfe nginx-Konfiguration ..."
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 \
            && echo "nginx-Konfiguration neu geladen."
    else
        echo "WARNUNG: nginx-Konfiguration ungültig – die alte bleibt aktiv." >&2
        docker compose exec -T nginx nginx -t || true
    fi
fi

echo
echo "Status:"
docker compose ps

echo
echo "Fertig!"
if [ -n "${current_ngrams:-}" ]; then
    echo "n-gram-Daten aktiv: ${current_ngrams}"
else
    echo "n-gram-Daten: keine (optional über ./setup.sh nachholbar)"
fi

echo
echo "Lokaler Test:"
echo "  curl -u '$first_user:****' http://localhost:${PUBLIC_PORT:-8082}/v2/languages"

print_extension_hint "$first_user" "$first_pass" "${PUBLIC_PORT:-8082}" "${LT_SECRET:-}"