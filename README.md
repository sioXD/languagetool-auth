# LanguageTool selbst hosten + nginx Basic Auth

Selbst gehosteter **LanguageTool-Server** hinter einem **nginx-Reverse-Proxy mit
HTTP Basic Auth**. 

Wichtig zu wissen: Die **Browser-Extension** von LanguageTool kann bei einem
eigenen Server **kein Passwort senden** (Benutzer/Passwort nutzt sie nur beim
kostenpflichtigen Cloud-Konto). Deshalb gilt hier:

- **Im LAN / auf dem Server-PC** ist LanguageTool ohne Passwort erreichbar –
  damit die Extension zu Hause funktioniert.
- **Aus dem Internet** brauchen *Programme* (curl, Apps) `user:pass@` (Basic Auth);
  die *Extension* nutzt einen **geheimen Pfad** (`LT_SECRET`).

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

LanguageTool ist **nicht** direkt erreichbar – nur über nginx:
im LAN (und auf dem Server-PC) ohne Passwort, von außen mit Basic Auth für
Programme bzw. über einen geheimen Pfad für die Extension.

## Was du auf den anderen PC übertragen musst

Dieses ganze Verzeichnis (bzw. mindestens):

```
docker-compose.yml
.env.example
setup.sh
nginx/
    nginx.conf
    secret.conf              (wird von setup.sh automatisch erzeugt)
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
2. fragt (beim ersten Mal) nach den optionalen n-gram-Daten und lädt sie ggf.,
3. erzeugt einen **geheimen Pfad** (`LT_SECRET` in `.env`) und schreibt daraus
   `nginx/secret.conf`, über den die Extension ohne Passwort erreichbar ist,
4. startet die Container (`docker compose up -d`),
5. gibt am Ende die **fertigen Adressen** aus: für die Extension auf diesem PC,
   im LAN und aus dem Internet (geheimer Pfad) sowie für Programme mit Passwort.

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
Du solltest ein JSON mit einer Sprachliste bekommen. Ohne `-u` kommst du (von
außen) auf einen `401`.

> Hinweis: **Vom LAN/Server-PC selbst** zählt die LAN-Freigabe aus Abschnitt 5 –
> dort kommst du auch **ohne** `-u` ans Ziel.

## 5. In der LanguageTool-Extension eintragen

**Wichtig:** Die LanguageTool-Extension kann bei einem eigenen Server **kein
Passwort senden** – Benutzer/Passwort-Felder nutzt sie nur beim kostenpflichtigen
Cloud-Konto. Deshalb gilt: auf diesem PC/im LAN einfach die URL **ohne Passwort**,
aus dem Internet die URL mit dem **geheimen Pfad** (`LT_SECRET`).

In den Einstellungen der Extension gibt es dafür das Feld
"LanguageTool API Server URL" (unter "Erweitert" / "Advanced"). `./setup.sh`
gibt am Ende alle fertigen URLs aus – einfach die passende kopieren:

| Wo du dich befindest | In die Extension eintragen |
|---------------------|----------------------------|
| Auf dem Server-PC | `http://localhost:8082/v2` |
| Im Heimnetz (LAN) | `http://PC-LAN-IP:8082/v2` (z. B. `http://192.168.1.50:8082/v2`) |
| Aus dem Internet | `http://DEINE-IP-ODER-DDNS:8082/DEIN-LT-SECRET/v2` |

> Das `/v2` am Ende ist wichtig – nur so findet die Extension die API-Endpunkte.
> Der geheime Pfad (= `LT_SECRET` aus `.env`) ist wie ein zweites Passwort: **nicht
> weitergeben**. Zum Wechseln in `.env` einen neuen Wert setzen (oder die Zeile
> löschen – dann erzeugt das nächste `./setup.sh` einen neuen) und `./setup.sh` ausführen.

### Für Programme (curl, Apps) gibt es weiterhin Basic Auth

`http://BENUTZER:PASSWORT@HOST:8082/v2` – z. B.:

| Von wo | Eingabe |
|--------|---------|
| Aus dem Internet | `http://simon:passwort@123.123.123.123:8082/v2` |
| Per DDNS | `http://simon:passwort@meinedomain.ddns.net:8082/v2` |
| Mit Domain + HTTPS | `https://simon:passwort@lt.meinedomain.de:8443/v2` |

### Wie nginx das umsetzt

- **Server-PC + LAN** (private Netze `127.x`, `172.16/12`, `192.168/16`, `10/8`):
  Zugriff **ohne Passwort** – damit die Extension zu Hause funktioniert
  (`satisfy any` + `allow`/`deny` in `nginx/nginx.conf`).
- **Internet (normale Pfade):** es greift **Basic Auth** (ohne gültige
  Zugangsdaten → `401`), zusätzlich geschützt durch ein Rate-Limit.
- **Geheimer Pfad** (`/LT-SECRET/...`): eigener nginx-`location` ohne Passwort
  (die Datei `nginx/secret.conf` erzeugt `setup.sh` aus `LT_SECRET`). Er ist für
  die Extension gedacht, funktioniert aber genauso für curl & Co. – deshalb
  wie ein Passwort behandeln. Auch hier gilt das Rate-Limit.

### Browser-Hinweis

- Die Extension sendet in **allen** Browsern kein Basic-Auth-Passwort – das ist
  keine Eigenheit von Chrome/Edge.
- `user:pass@host`-URLs in der Adressleiste oder für Programme blockieren
  Chrome/Edge (und Firefox zunehmend). Für Programme einfach `curl -u ...`
  verwenden oder eine App mit separaten Benutzer/Passwort-Feldern.

## 5b. n-gram-Daten (optional, verbessert die Genauigkeit)

LanguageTool kann große **n-gram-Datensätze** nutzen, um verwechselte Wörter
besser zu erkennen (z. B. deutsch *das/dass*, englisch *their/there*). Ohne
diese Daten funktioniert alles normal – nur etwas weniger treffsicher.

Beim ersten `./setup.sh` wirst du gefragt:

```
── n-gram-Daten (optional) ─────────────────────────────
  1) Keine
  2) Nur Deutsch              (1,7 GB)
  3) Deutsch + Englisch       (~11 GB)
  4) Eigene Auswahl           (de,en,fr,es,nl)
  Auswahl [1]:
```

- Die Auswahl wird in `.env` unter `LT_NGRAMS` gemerkt – beim nächsten Lauf
  wirst du **nicht** erneut gefragt.
- Bereits heruntergeladene Sprachen werden **nicht** erneut geladen.
- Die Daten landen in `./ngrams/<sprache>/` und werden read-only als `/ngrams`
  in den Container gemountet; aktiviert über `langtool_languageModel=/ngrams`
  in `docker-compose.yml`.
- Nach einem Download wird LanguageTool automatisch neu erstellt, damit die
  n-gram-Daten beim Start eingelesen werden (aktiv erst nach dem Neustart).
- Verfügbar sind nur `de, en, fr, es, nl`.
- **SSD empfohlen** – ohne SSD kann LanguageTool mit n-grams deutlich langsamer
  werden. Bei knappem RAM ggf. `Java_Xmx` in `docker-compose.yml` erhöhen
  (z. B. auf `3g`).
- Auswahl später ändern: `LT_NGRAMS` in `.env` anpassen und `./setup.sh` erneut
  ausführen. Um das Menü wieder zu bekommen, die `LT_NGRAMS`-Zeile in `.env`
  löschen.

## 6. HTTPS (empfohlen, falls du eine Domain hast)

**Warnung:** Im obigen HTTP-Setup wird das Passwort nur Base64-kodiert übertragen –
also **im Klartext lesbar** für jeden im Netz. Das gilt ebenso für den **geheimen
Pfad**: Wer ihn auf der Leitung mitliest, kann LanguageTool mitnutzen. Wer den
Dienst ins Internet stellt, sollte daher HTTPS nehmen. Das geht nur mit einer
eigenen Domain (kostenlos z. B. per DDNS-Dienst mit eigenem Domainnamen).

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

- **nginx startet nicht:** Die Dateien `nginx/.htpasswd` **und**
  `nginx/secret.conf` müssen existieren (beide erzeugt `setup.sh`).
  Nie `docker compose up` vor `./setup.sh` ausführen.
- **HTTP 500 statt 401 (Log: `open() "/etc/nginx/.htpasswd" failed (13: Permission denied)`):**
  Die `.htpasswd` darf nicht nur für den Besitzer lesbar sein. nginx liest sie im
  Container als Worker-Benutzer `nginx` (uid/gid 101), nicht als root. Deshalb muss
  die Datei für Gruppe 101 lesbar sein:
  ```bash
  chgrp 101 nginx/.htpasswd && chmod 640 nginx/.htpasswd   # empfohlen
  # oder, wenn das nicht klappt:
  chmod 644 nginx/.htpasswd
  ```
  `setup.sh` setzt das inzwischen automatisch.
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
| `nginx/nginx.conf` | nginx-Konfiguration: LAN frei, Internet mit Basic Auth |
| `nginx/secret.conf` | vom Setup erzeugter Secret-`location` für die Extension (aus `LT_SECRET`) |
| `nginx/nginx.ssl.example.conf` | optionales HTTPS-Beispiel |
| `.env` / `.env.example` | Benutzerliste (`LT_USERS`), Port, `LT_SECRET`, optional `LT_NGRAMS` |
| `ngrams/` | optional heruntergeladene n-gram-Daten |
| `setup.sh` | erzeugt htpasswd + Secret-Pfad, fragt n-grams ab, startet alles |

## Auf GitHub veröffentlichen (optional)

Das Repo ist dafür vorbereitet – die `.gitignore` hält alle Geheimnisse und
großen Dateien draußen:

- `.env` / `.env.bak` (Benutzer + Passwörter, `LT_SECRET`)
- `nginx/.htpasswd`, `nginx/secret.conf`
- `nginx/certs/`, `*.pem`, `*.key`
- `ngrams/` (mehrere GB)

Vor dem ersten Push prüfen, was wirklich committet würde:

```bash
git init
git add -A
git status        # .env, .htpasswd, secret.conf und ngrams/ dürfen NICHT auftauchen
```

Dann committen und pushen:

```bash
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/BENUTZER/REPO.git
git push -u origin main
```

> Ist doch einmal ein Geheimnis in die Historie geraten, reicht Löschen im
> nächsten Commit **nicht** – Passwort/Token ändern und die Historie bereinigen
> (z. B. mit `git filter-repo`).