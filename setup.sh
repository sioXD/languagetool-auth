#!/usr/bin/env bash
#
# Setup für LanguageTool hinter nginx mit geheimem Pfad
# - erzeugt nginx/secret.conf mit einem zufälligen geheimen Pfad (Hash)
# - lädt optional n-gram-Daten
# - startet die Container
# - gibt den fertigen Link für die Browser-Extension aus
#
# Es wird KEINE .env-Datei mehr benötigt.
#
set -euo pipefail
cd "$(dirname "$0")"

# ======================= Konfiguration =======================
# Öffentlicher Port, unter dem LanguageTool erreichbar ist.
# Bei Änderung nur hier anpassen. docker-compose.yml übernimmt den Wert
# automatisch; nginx lauscht intern weiterhin auf 8082.
PUBLIC_PORT=8082
# =============================================================

export PUBLIC_PORT

SECRET_CONF="nginx/secret.conf"

# ---------- Hilfsfunktionen ----------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # führende Leerzeichen entfernen
    s="${s%"${s##*[![:space:]]}"}"   # folgende Leerzeichen entfernen
    printf '%s' "$s"
}

# ---------- n-gram-Daten (Language Model, optional) ----------
# Quellen: feste Download-Dateinamen von https://languagetool.org/download/ngram-data/
NGRAM_BASE_URL="https://languagetool.org/download/ngram-data"
NGRAM_DIR="ngrams"
# Merkt sich die Auswahl (z. B. "de,en"). Leere Datei = bewusst "Keine".
NGRAM_STATE="$NGRAM_DIR/.languages"

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

# Entpackt ein ZIP. unzip ist nicht überall vorhanden (z. B. NixOS),
# deshalb Fallbacks auf bsdtar und python3.
extract_zip() {
    local zip="$1" dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$zip" -d "$dest"
    elif command -v bsdtar >/dev/null 2>&1; then
        mkdir -p "$dest"
        bsdtar -xf "$zip" -C "$dest"
    elif command -v python3 >/dev/null 2>&1; then
        mkdir -p "$dest"
        python3 -m zipfile -e "$zip" "$dest"
    else
        return 1
    fi
}

# Lädt fehlende Sprachen herunter und entpackt sie. Vorhandene werden übersprungen.
ensure_ngrams() {
    local langs="$1"
    [ -z "$langs" ] && return 0

    if ! command -v curl >/dev/null 2>&1; then
        echo "Warnung: 'curl' fehlt – n-gram-Daten werden übersprungen." >&2
        return 0
    fi
    if ! command -v unzip >/dev/null 2>&1 \
        && ! command -v bsdtar >/dev/null 2>&1 \
        && ! command -v python3 >/dev/null 2>&1; then
        echo "Warnung: kein Entpacker gefunden (unzip, bsdtar oder python3)" >&2
        echo "         – n-gram-Daten werden übersprungen." >&2
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
        if ! extract_zip "$tmp/$zip" "$tmp/x"; then
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

# Speichert die n-gram-Auswahl (ohne .env).
save_ngrams_to_state() {
    mkdir -p "$NGRAM_DIR"
    printf '%s\n' "$1" > "$NGRAM_STATE"
    echo "  (Auswahl gespeichert${1:+, aktuell: $1})"
}

# ---------- Geheimer Pfad (Hash) ----------
# Liest den aktuell verwendeten geheimen Pfad aus nginx/secret.conf.
read_secret() {
    [ -f "$SECRET_CONF" ] || return 0
    sed -n 's|^location /\([^/]*\)/ {|\1|p' "$SECRET_CONF" | head -n1
}

# Schreibt nginx/secret.conf mit dem übergebenen geheimen Pfad.
write_secret_conf() {
    local secret="$1"
    mkdir -p nginx
    cat > "$SECRET_CONF" <<EOF
# Automatisch erzeugt von setup.sh – nicht manuell bearbeiten.
# LanguageTool ist ausschließlich über diesen geheimen Pfad erreichbar.
location /${secret}/ {
    limit_req zone=lt burst=20 nodelay;
    proxy_pass http://languagetool:8010/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
EOF
    chmod 600 "$SECRET_CONF" 2>/dev/null || true
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

# Gibt den fertigen Link für die Extension aus.
print_link() {
    local secret="$1"
    local lan_ip pub_ip
    lan_ip="$(detect_lan_ip)"
    pub_ip="$(detect_public_ip)"

    echo
    echo "============================================================"
    echo " LanguageTool-Adresse für die Browser-Extension"
    echo "============================================================"
    echo
    echo "Diese URL im Feld 'Server-URL' bzw. 'LanguageTool API Server URL'"
    echo "eintragen ('/v2' am Ende gehört dazu):"
    echo
    echo "  auf diesem PC:      http://localhost:${PUBLIC_PORT}/${secret}/v2"
    if [ -n "$lan_ip" ]; then
        echo "  im Heimnetz (LAN):  http://${lan_ip}:${PUBLIC_PORT}/${secret}/v2"
    fi
    if [ -n "$pub_ip" ]; then
        echo "  aus dem Internet:   http://${pub_ip}:${PUBLIC_PORT}/${secret}/v2"
    else
        echo "  aus dem Internet:   http://DEINE-DDNS-ODER-IP:${PUBLIC_PORT}/${secret}/v2"
    fi
    echo
    echo "  Der geheime Pfad ist wie ein Passwort: nicht weitergeben."
    echo "  Ein neuer Link lässt sich jederzeit mit ./setup.sh erzeugen."
}

# ---------- 1. Menü: letzten Link ausgeben oder neuen erstellen ----------
existing_secret="$(read_secret)"

if [ -t 0 ]; then
    echo
    echo "============================================================"
    echo " LanguageTool – Setup"
    echo "============================================================"
    echo
    echo "  1) Letzten Link ausgeben (nichts ändern)"
    echo "  2) Neuen Link erstellen (neuen geheimen Pfad erzeugen)"
    echo
    read -rp "  Auswahl [1]: " _menu || _menu=""
    case "$_menu" in
        2)
            write_secret_conf "$(gen_token)"
            existing_secret="$(read_secret)"
            echo
            echo "Neuer geheimer Pfad erzeugt."
            ;;
        *)
            if [ -n "$existing_secret" ]; then
                echo
                echo "Letzter Link:"
                print_link "$existing_secret"
                exit 0
            fi
            echo
            echo "Es gibt noch keinen Link – es wird ein neuer erstellt."
            write_secret_conf "$(gen_token)"
            existing_secret="$(read_secret)"
            ;;
    esac
else
    # Nicht-interaktiv: vollständiges Setup, vorhandenen Link beibehalten.
    if [ -z "$existing_secret" ]; then
        write_secret_conf "$(gen_token)"
        existing_secret="$(read_secret)"
    fi
fi

# Sicherstellen, dass secret.conf existiert (z. B. bei kaputter/fehlender Datei).
if [ -z "$existing_secret" ]; then
    write_secret_conf "$(gen_token)"
    existing_secret="$(read_secret)"
fi

# ---------- 2. n-gram-Daten (optional, interaktive Auswahl) ----------
# Merker: Existiert die Zustandsdatei, gilt die Frage als beantwortet. Fehlt sie,
# fragen wir; fehlt eine gewünschte Sprache (z. B. nach abgebrochenem Download),
# fragen wir erneut.
ngrams_key_present=false
if [ -f "$NGRAM_STATE" ]; then
    ngrams_key_present=true
fi

current_ngrams=""
if [ -f "$NGRAM_STATE" ]; then
    current_ngrams="$(normalize_ngram_langs "$(cat "$NGRAM_STATE" 2>/dev/null || true)")"
fi

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
        save_ngrams_to_state "$current_ngrams"
    else
        echo
        echo "Hinweis: nicht-interaktive Ausführung – n-gram-Auswahl übersprungen."
    fi
fi

ensure_ngrams "$current_ngrams"

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
installed_ngrams=""
missing_ngrams=""
for _l in $(printf '%s' "${current_ngrams:-}" | tr ',' ' '); do
    if ngram_installed "$_l"; then
        installed_ngrams="${installed_ngrams:+$installed_ngrams,}$_l"
    else
        missing_ngrams="${missing_ngrams:+$missing_ngrams,}$_l"
    fi
done
if [ -n "$installed_ngrams" ]; then
    echo "n-gram-Daten installiert: ${installed_ngrams}"
else
    echo "n-gram-Daten: keine installiert"
fi
if [ -n "$missing_ngrams" ]; then
    echo "Noch nicht installiert: ${missing_ngrams} (siehe Meldungen oben)"
    echo "  Erneut ./setup.sh ausführen, um den Download nachzuholen."
fi

echo
echo "Lokaler Test:"
echo "  curl http://localhost:${PUBLIC_PORT}/${existing_secret}/v2/languages"

print_link "$existing_secret"
