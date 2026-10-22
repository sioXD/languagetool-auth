#!/usr/bin/env bash
#
# Setup for LanguageTool behind nginx with a secret path
# - creates nginx/secret.conf with a random secret path (hash)
# - optionally downloads n-gram data
# - starts containers
# - outputs the ready-to-use link for the browser extension
#
# No .env file needed.
#
set -euo pipefail
cd "$(dirname "$0")"

# ======================= Configuration =======================
# Public port where LanguageTool is accessible.
# Change only here. docker-compose.yml will use this value automatically;
# nginx still listens internally on 8082.
PUBLIC_PORT=8082
# =============================================================

export PUBLIC_PORT

SECRET_CONF="nginx/secret.conf"

# ---------- Helper functions ----------
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # remove leading whitespace
    s="${s%"${s##*[![:space:]]}"}"   # remove trailing whitespace
    printf '%s' "$s"
}

# ---------- n-gram data (Language Model, optional) ----------
# Sources: fixed download filenames from https://languagetool.org/download/ngram-data/
NGRAM_BASE_URL="https://languagetool.org/download/ngram-data"
NGRAM_DIR="ngrams"
# Stores selection (e.g. "de,en"). Empty file means "None".
NGRAM_STATE="$NGRAM_DIR/.languages"

# Returns the ZIP filename for a language or fails for unknown language.
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

# Human-readable name for output.
ngram_label() {
    case "$1" in
        de) printf '%s' "German" ;;
        en) printf '%s' "English" ;;
        fr) printf '%s' "French" ;;
        es) printf '%s' "Spanish" ;;
        nl) printf '%s' "Dutch" ;;
        *)  printf '%s' "$1" ;;
    esac
}

# Normalizes a comma list: trim, lowercase, validate, deduplicate.
normalize_ngram_langs() {
    local input="$1" out="" lang
    local IFS=','
    for lang in $input; do
        lang="$(trim "$lang")"
        lang="$(printf '%s' "$lang" | tr '[:upper:]' '[:lower:]')"
        [ -z "$lang" ] && continue
        if ! ngram_zip "$lang" >/dev/null; then
            echo "Warning: unknown n-gram language '$lang' (allowed: de,en,fr,es,nl)" >&2
            continue
        fi
        case ",$out," in *",$lang,"*) continue ;; esac
        out="${out:+$out,}$lang"
    done
    printf '%s' "$out"
}

# Checks if a language is already fully extracted.
ngram_installed() {
    [ -d "$NGRAM_DIR/$1/1grams" ]
}

# Moves extracted data from temp dir to ngrams/<lang>/
# Detects direct structure (1grams/...) or nested variants.
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

# Ensures NGRAM_DIR exists and is writable by current user.
# Called before starting containers so Docker doesn't create it as root.
NGRAM_DIR_REPLACED=false
# Set if new n-gram data was downloaded -> container needs to be recreated
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
    echo "Warning: '$d' is not writable and could not be recreated." >&2
    echo "         Run once:  sudo chown -R \"\$USER\" $d" >&2
    return 0
}

# Extract ZIP. unzip may not be available; fallback to bsdtar and python3.
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

# Downloads missing languages and extracts them. Skips already installed ones.
ensure_ngrams() {
    local langs="$1"
    [ -z "$langs" ] && return 0

    if ! command -v curl >/dev/null 2>&1; then
        echo "Warning: 'curl' missing - skipping n-gram data." >&2
        return 0
    fi
    if ! command -v unzip >/dev/null 2>&1 \
        && ! command -v bsdtar >/dev/null 2>&1 \
        && ! command -v python3 >/dev/null 2>&1; then
        echo "Warning: no extractor found (unzip, bsdtar, or python3)" >&2
        echo "         - skipping n-gram data." >&2
        return 0
    fi

    ensure_ngram_dir_ready
    if [ ! -w "$NGRAM_DIR" ]; then
        echo "Warning: '$NGRAM_DIR' is not writable - skipping download." >&2
        return 0
    fi

    echo "Checking n-gram data:"
    local lang zip url tmp
    local IFS=','
    for lang in $langs; do
        [ -z "$lang" ] && continue
        if ngram_installed "$lang"; then
            echo "  - $lang ($(ngram_label "$lang")): already installed, skipping"
            continue
        fi
        zip="$(ngram_zip "$lang")" || continue
        url="$NGRAM_BASE_URL/$zip"
        echo "  - $lang ($(ngram_label "$lang")): downloading $zip (large, may take a while) ..."
        tmp="$(mktemp -d)"
        if ! curl -fL --retry 3 -o "$tmp/$zip" "$url"; then
            echo "    Error: download failed - skipping $lang." >&2
            rm -rf "$tmp"
            continue
        fi
        if ! extract_zip "$tmp/$zip" "$tmp/x"; then
            echo "    Error: extraction failed - skipping $lang." >&2
            rm -rf "$tmp"
            continue
        fi
        if install_extracted_ngram "$lang" "$tmp/x"; then
            echo "    Done: $lang in $NGRAM_DIR/$lang/"
            NGRAM_DOWNLOADED=true
        else
            echo "    Error: unexpected ZIP structure - skipping $lang." >&2
        fi
        rm -rf "$tmp"
    done
}

# Generates a random token (for the secret extension path).
gen_token() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# Saves n-gram selection.
save_ngrams_to_state() {
    mkdir -p "$NGRAM_DIR"
    printf '%s\n' "$1" > "$NGRAM_STATE"
    echo "  (Selection saved${1:+, current: $1})"
}

# ---------- Secret path (hash) ----------
# Reads the currently used secret path from nginx/secret.conf.
read_secret() {
    [ -f "$SECRET_CONF" ] || return 0
    sed -n 's|^location /\([^/]*\)/ {|\1|p' "$SECRET_CONF" | head -n1
}

# Writes nginx/secret.conf with the given secret path.
write_secret_conf() {
    local secret="$1"
    mkdir -p nginx
    cat > "$SECRET_CONF" <<EOF
# Automatically generated by setup.sh - do not edit manually.
# LanguageTool is only accessible via this secret path.
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

# ---------- Server address for LanguageTool extension ----------
# Detects local LAN IP (empty if not found).
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

# Detects public IP (empty if offline/not found).
detect_public_ip() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    printf '%s' "$ip"
}

# Prints the ready-to-use URL for the extension.
print_link() {
    local secret="$1"
    local lan_ip pub_ip
    lan_ip="$(detect_lan_ip)"
    pub_ip="$(detect_public_ip)"

    echo
    echo "============================================================"
    echo " LanguageTool URL for the Browser Extension"
    echo "============================================================"
    echo
    echo "Add this URL to 'LanguageTool API Server URL' (include '/v2' at the end):"
    echo
    echo "  On this PC:        http://localhost:${PUBLIC_PORT}/${secret}/v2"
    if [ -n "$lan_ip" ]; then
        echo "  On LAN:            http://${lan_ip}:${PUBLIC_PORT}/${secret}/v2"
    fi
    if [ -n "$pub_ip" ]; then
        echo "  From Internet:     http://${pub_ip}:${PUBLIC_PORT}/${secret}/v2"
    else
        echo "  From Internet:     http://YOUR-DDNS-OR-IP:${PUBLIC_PORT}/${secret}/v2"
    fi
    echo
    echo "  The secret path is like a password - keep it safe."
    echo "  You can generate a new link anytime with ./setup.sh."
}

# ---------- 1. Menu: show last link or create new one ----------
existing_secret="$(read_secret)"

if [ -t 0 ]; then
    echo
    echo "============================================================"
    echo " LanguageTool - Setup"
    echo "============================================================"
    echo
    echo "  1) Show last link (no changes)"
    echo "  2) Create new link (generate new secret path)"
    echo
    read -rp "  Choice [1]: " _menu || _menu=""
    case "$_menu" in
        2)
            write_secret_conf "$(gen_token)"
            existing_secret="$(read_secret)"
            echo
            echo "New secret path generated."
            ;;
        *)
            if [ -n "$existing_secret" ]; then
                echo
                echo "Last link:"
                print_link "$existing_secret"
                exit 0
            fi
            echo
            echo "No link found - creating a new one."
            write_secret_conf "$(gen_token)"
            existing_secret="$(read_secret)"
            ;;
    esac
else
    # Non-interactive: full setup, keep existing link if present.
    if [ -z "$existing_secret" ]; then
        write_secret_conf "$(gen_token)"
        existing_secret="$(read_secret)"
    fi
fi

# Ensure secret.conf exists.
if [ -z "$existing_secret" ]; then
    write_secret_conf "$(gen_token)"
    existing_secret="$(read_secret)"
fi

# ---------- 2. n-gram data (optional, interactive selection) ----------
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
        echo "── n-gram data (optional) ─────────────────────────────"
        echo "  Improves detection of commonly confused words"
        echo "  (e.g. their/there). Large download, one-time."
        echo
        echo "  1) None"
        echo "  2) German only              (1.7 GB)"
        echo "  3) German + English         (~11 GB)"
        echo "  4) Custom selection         (de,en,fr,es,nl)"
        if [ -n "$current_ngrams" ]; then
            echo "  (currently selected: $current_ngrams)"
        fi
        read -rp "  Choice [1]: " _choice || _choice=""
        case "$_choice" in
            2) current_ngrams="de" ;;
            3) current_ngrams="de,en" ;;
            4)
                read -rp "  Languages (comma-separated, e.g. de,en): " _custom || _custom=""
                current_ngrams="$(normalize_ngram_langs "$_custom")"
                ;;
            1) current_ngrams="" ;;
            "") ;;   # keep previous/default (None)
            *) echo "  Invalid choice - using 'None'."; current_ngrams="" ;;
        esac
        save_ngrams_to_state "$current_ngrams"
    else
        echo
        echo "Note: non-interactive run - skipping n-gram selection."
    fi
fi

ensure_ngrams "$current_ngrams"

# ---------- 3. Start containers ----------
ensure_ngram_dir_ready

echo
echo "Starting containers ... (first start may take a while to pull images)"
if [ "$NGRAM_DIR_REPLACED" = true ] || [ "$NGRAM_DOWNLOADED" = true ]; then
    docker compose up -d --force-recreate languagetool
else
    docker compose up -d
fi

# Test and reload nginx if running
if docker compose ps 2>/dev/null | grep -q "languagetool-nginx"; then
    echo "Testing nginx configuration ..."
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1; then
        docker compose exec -T nginx nginx -s reload >/dev/null 2>&1 \
            && echo "nginx configuration reloaded."
    else
        echo "WARNING: nginx configuration invalid - keeping old config." >&2
        docker compose exec -T nginx nginx -t || true
    fi
fi

echo
echo "Status:"
docker compose ps

echo
echo "Done!"
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
    echo "n-gram data installed: ${installed_ngrams}"
else
    echo "n-gram data: none installed"
fi
if [ -n "$missing_ngrams" ]; then
    echo "Not yet installed: ${missing_ngrams} (see messages above)"
    echo "  Run ./setup.sh again to retry the download."
fi

echo
echo "Local test:"
echo "  curl http://localhost:${PUBLIC_PORT}/${existing_secret}/v2/languages"

print_link "$existing_secret"
