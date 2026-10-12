# LanguageTool selbst hosten + nginx Basic Auth

Selbst gehosteter **LanguageTool-Server** hinter einem **nginx-Reverse-Proxy mit
HTTP Basic Auth**. Damit kannst du in der LanguageTool-Extension eine Server-Adresse
im Format `user:pass@host:port` eintragen und deinen Server ist nicht öffentlich nutzbar.

## Aufbau

```
Internet / Router (Port 8082 freigegeben)
        │
        ▼
   nginx (Basic Auth)  ◄── öffentlicher Port 8082
        │
        ▼
   languagetool (Port 8010, nur im internen Docker-Netz)
```

LanguageTool ist **nicht** direkt nach außen erreichbar – nur durch nginx mit Passwort.

## Was du auf den anderen PC übertragen musst

Dieses ganze Verzeichnis (bzw. mindestens):

```
docker-compose.yml
.env.example
setup.sh
nginx/
    nginx.conf
    nginx.ssl.example.conf   (optional, nur für HTTPS)
```

---

## 1. Voraussetzungen

- **Linux** mit Docker + Docker Compose (plugin). Beispiel (Debian/Ubuntu):
  ```bash
  sudo apt update
  sudo apt install -y docker.io docker-compose-v2
  sudo systemctl enable --now docker
  sudo usermod -aG docker $USER   # danach neu einloggen!
  ```
  (Unter Windows: WSL2 + Docker Desktop geht genauso, Git-Bash für die Skripte.)
- Mindestens **1–2 GB freier RAM** (LanguageTool ist Java-basiert).
- Damit du von außen rankommst: **statische IP** oder **DDNS** beim Provider,
  und einen Port, der in deinem Heimrouter noch frei ist.

## 2. Konfigurieren (`.env`)

```bash
cd languagetool-auth
cp .env.example .env
nano .env      # oder vi / gedit / Notepad
```

Dort die Benutzer und den Port eingeben:

```ini
# Benutzer im Format  name:passwort  – mehrere durch Komma getrennt
LT_USERS="simon:passwort1,anna:passwort2"

PUBLIC_PORT=8082
```

> **Wichtig:** In den Passwörtern keine `:` `,` `@` `/` oder Leerzeichen verwenden,
> sonst musst du sie in der Extension-URL prozent-encodieren (z. B. `@` → `%40`)
> bzw. der `LT_USERS`-Parser kann sie nicht trennen.
> `PUBLIC_PORT` muss **identisch** mit dem Port in `nginx/nginx.conf` sein.

## 3. Starten

```bash
./setup.sh
```

Das Skript:
1. erzeugt `nginx/.htpasswd` für **alle** Benutzer aus `LT_USERS`,
2. startet die Container (`docker compose up -d`).

Der erste Start lädt die Images herunter (LanguageTool ist groß, ~500 MB) und
LanguageTool braucht beim ersten Check etwas Zeit (Java startet einmal).

Status und Logs:

```bash
docker compose ps
docker compose logs -f languagetool
```

### Benutzer hinzufügen / Passwort ändern / entfernen

Die Benutzerliste steht in der `.env` unter `LT_USERS` – einfach dort ergänzen
und `./setup.sh` erneut ausführen (das erzeugt die `.htpasswd` komplett neu):

```ini
LT_USERS="simon:passwort1,anna:passwort2,ben:passwort3"
```

Danach:
```bash
./setup.sh
```

Ein neuer Benutzer ist **sofort** aktiv (nginx liest die Datei bei jedem Request
neu, kein Neustart nötig). Zum Entfernen einfach aus `LT_USERS` streichen und
`./setup.sh` erneut laufen lassen.

> Alle Benutzer teilen sich dieselbe LanguageTool-Instanz – es gibt keine
> getrennten Konten oder Limits pro Person, nur Zugangskontrolle.

Alternativ kannst du einzelne Benutzer auch manuell per `htpasswd` ergänzen
(geht aber beim nächsten `./setup.sh` wieder verloren):
```bash
sudo apt install -y apache2-utils
htpasswd -B nginx/.htpasswd anna        # fragt nach dem Passwort
```

## 4. Portfreigabe + Firewall

Am **Router** eine Portweiterleitung einrichten:

| Richtung | Quell-Port | Ziel (PC) |
|----------|-----------|-----------|
| TCP      | `8082`     | `PC-LAN-IP:8082` |

Falls eine Firewall auf dem PC aktiv ist (`ufw`):
```bash
sudo ufw allow 8082/tcp
```

Zugriff von außen testen (`meinuser` durch einen Benutzer aus `LT_USERS` ersetzen):
```bash
curl -u meinuser:PASSWORT http://DEINE_ÖFFENTLICHE_IP:8082/v2/languages
```
Du solltest ein JSON mit einer Sprachliste bekommen. Ohne `-u` kommst du auf einen `401`.

## 5. In der LanguageTool-Extension eintragen

In den Einstellungen der Extension gibt es ein Feld "LanguageTool API Server URL"
(unter "Erweitert" / "Advanced"). Dort eintragen:

```
https://USER:PASSWORT@SERVER_HOSTNAME:8082/v2
```

Beispiele:

| Variante | Eingabe |
|----------|---------|
| Per IP / HTTP | `http://meinuser:passwort@123.123.123.123:8082/v2` |
| Per DDNS / HTTP | `http://meinuser:passwort@meinedomain.ddns.net:8082/v2` |
| Mit Domain + HTTPS | `https://meinuser:passwort@lt.meinedomain.de:8443/v2` |

> Das `/v2` am Ende ist wichtig – nur so findet die Extension die API-Endpunkte.

### Browser-Hinweis (wichtig!)

- **Firefox**: `user:pass@host` in der Server-URL funktioniert in der Regel problemlos. ✅
- **Chrome / Edge**: Chrome blockiert eingebettete Zugangsdaten in URLs bei
  Subresource-Requests (bewusste Chromium-Entscheidung). Die Extension bekommt dort
  einen **Netzwerkfehler**, der Server selbst funktioniert weiterhin korrekt
  (mit `curl` oder im Browser-Tab klappt's).
  - Lösung: **Firefox** verwenden, **IP-Freigabe** nutzen (siehe unten), oder
    **VPN/Tailscale** statt Portfreigabe.

### Alternative ohne Passwort in der URL: Nur deine IP zulassen

Wer keinen Browser-Basic-Auth-Support braucht (oder im LAN bleiben will), kann in
`nginx/nginx.conf` unter `location /` statt `auth_basic` einfach nur echte IPs
zulassen:

```nginx
location / {
    allow 192.168.0.0/16;      # dein LAN
    allow 1.2.3.4;             # deine öffentliche IP
    deny  all;
    proxy_pass http://languagetool:8010;
    ...
}
```
Dann braucht die Extension gar kein Passwort – aber nur nutzen, wenn du **sicher**
bist, dass wirklich nur erlaubte IPs dazukommen.

## 6. HTTPS (empfohlen, falls du eine Domain hast)

**Warnung:** Im obigen HTTP-Setup wird das Passwort nur Base64-kodiert übertragen –
also **im Klartext lesbar** für jeden im Netz. Wer den Dienst ins Internet stellt,
sollte HTTPS nehmen. Das geht nur mit einer eigenen Domain (kostenlos z. B.
per DDNS-Dienst mit eigenem Domainnamen).

Kurz-Anleitung (Let's Encrypt, `certbot` direkt auf dem Host):

```bash
# 1. nginx-Stop (damit certbot Port 80 nutzen kann)
docker compose stop nginx

# 2. Zertifikat besorgen (Domain muss auf den PC zeigen!)
sudo apt install -y certbot
sudo certbot certonly --standalone -d lt.meinedomain.de

# 3. Zertifikate in das Projektverzeichnis kopieren
sudo cp /etc/letsencrypt/live/lt.meinedomain.de/fullchain.pem ./nginx/certs/
sudo cp /etc/letsencrypt/live/lt.meinedomain.de/privkey.pem  ./nginx/certs/

# 4. HTTPS-Konfiguration aktivieren
cp nginx/nginx.ssl.example.conf nginx/nginx.conf

# 5. In docker-compose.yml den Port 8443 zusätzlich freigeben und
#    die Zertifikate in den nginx-Container mounten:
#      volumes:
#        - ./nginx/certs:/etc/nginx/certs:ro
#        - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
#      ports:
#        - "8082:8082"
#        - "8443:8443"

# 6. Neu starten
docker compose up -d
```

Erneuerung (alle ~90 Tage):
```bash
sudo docker compose stop nginx
sudo certbot renew
sudo docker compose up -d
```

## Fehlerbehebung

- **nginx startet nicht:** Die Datei `nginx/.htpasswd` muss existieren
  (wird von `setup.sh` erzeugt). Nie `docker compose up` vor `./setup.sh` ausführen.
- **Kein Zugriff von außen:** Router-Portfreigabe prüfen (auch UDP nicht nötig,
  nur TCP), und `ufw status` auf dem Host. Test immer erst von außen (Handy-Netz!).
- **Erster Check dauert ewig:** Normal – Java + LanguageTool brauchen beim ersten
  Mal einige Sekunden bis Minuten. Danach ist es schneller.
- **RAM voll / Container stirbt:** In `docker-compose.yml` `Java_Xmx` reduzieren
  (z. B. von `2g` auf `1g`).
- **Port 8082 schon belegt:** Anderen Port in `.env` **und** in
  `nginx/nginx.conf` setzen, dann `docker compose up -d`.

## Dateiübersicht

| Datei | Zweck |
|-------|-------|
| `docker-compose.yml` | Container-Definition (LanguageTool + nginx) |
| `nginx/nginx.conf` | nginx-Konfiguration mit Basic Auth |
| `nginx/nginx.ssl.example.conf` | optionales HTTPS-Beispiel |
| `.env` / `.env.example` | Benutzerliste (`LT_USERS`) + Port |
| `setup.sh` | erzeugt htpasswd und startet alles |