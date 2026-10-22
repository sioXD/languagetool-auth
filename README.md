# LanguageTool selbst hosten (geheimer Pfad)

Selbst gehosteter **LanguageTool-Server** hinter einem **nginx-Reverse-Proxy**.

Der Zugriff läuft **ausschließlich über einen geheimen Pfad (Hash)** in der URL,
z. B.:

```
http://192.168.178.168:8082/591f6fcd7573863a47a8b7b265310e65/v2
```

Es gibt **keine Benutzernamen und keine Passwörter** mehr. Auch eine `.env`-Datei
wird **nicht** benötigt: Der Port steht direkt in `setup.sh`, der geheime Pfad
wird in `nginx/secret.conf` gespeichert.

Der geheime Pfad ist wie ein Passwort zu behandeln – wer ihn kennt, kann den
Server nutzen.

## Aufbau

```
Internet / Router (Port 8082 freigegeben)
        │
        ▼
   nginx (nur /GEHEIMER-PFAD/ erreichbar)  ◄── öffentlicher Port 8082
        │
        ▼
   languagetool (Port 8010, nur im internen Docker-Netz)
```

Alle anderen Pfade beantwortet nginx mit `404`.

## Dateien

```
docker-compose.yml
setup.sh
nginx/
    nginx.conf
    secret.conf              (wird von setup.sh erzeugt/gespeichert)
    nginx.ssl.example.conf   (optional, nur für HTTPS)
ngrams/                      (optional heruntergeladene n-gram-Daten)
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

## 2. Port einstellen (in `setup.sh`)

Der öffentliche Port steht oben in `setup.sh`:

```bash
# ======================= Konfiguration =======================
PUBLIC_PORT=8082
# =============================================================
```

Bei Änderung nur diesen Wert anpassen – `docker-compose.yml` übernimmt ihn
automatisch. nginx selbst lauscht intern weiterhin auf `8082`.

Zusätzlich ggf. die Portfreigabe am Router und die Firewall anpassen:

```bash
sudo ufw allow 8082/tcp
```

## 3. Starten

```bash
./setup.sh
```

Am Anfang erscheint ein Menü:

```
  1) Letzten Link ausgeben (nichts ändern)
  2) Neuen Link erstellen (neuen geheimen Pfad erzeugen)
```

- **1** zeigt nur den zuletzt erzeugten Link an und beendet das Skript.
  Vorhandene Container und Einstellungen bleiben unverändert.
- **2** erzeugt einen **neuen** geheimen Pfad. Der alte Link ist danach ungültig.
  Anschließend läuft das normale Setup weiter (n-gram-Auswahl, Container starten).

Beim ersten Start bzw. nach **2** erledigt das Setup außerdem:

1. erzeugt/aktualisiert `nginx/secret.conf` mit dem geheimen Pfad,
2. fragt (beim ersten Mal) nach den optionalen n-gram-Daten und lädt sie ggf.,
3. startet die Container (`docker compose up -d`),
4. gibt am Ende die fertigen Links aus (PC, LAN, Internet).

Der erste Start lädt die Images herunter (LanguageTool ist groß, ~500 MB) und
LanguageTool braucht beim ersten Check etwas Zeit (Java startet einmal).

Status und Logs:

```bash
docker compose ps
docker compose logs -f languagetool
```

## 4. In der LanguageTool-Extension eintragen

In den Einstellungen der Extension gibt es das Feld „LanguageTool API Server URL“
(unter „Erweitert“ / „Advanced“). Dort eine der fertigen URLs eintragen, die
`./setup.sh` ausgibt:

| Wo du dich befindest | In die Extension eintragen |
|---------------------|----------------------------|
| Auf dem Server-PC | `http://localhost:8082/GEHEIMER-PFAD/v2` |
| Im Heimnetz (LAN) | `http://PC-LAN-IP:8082/GEHEIMER-PFAD/v2` (z. B. `http://192.168.1.50:8082/…/v2`) |
| Aus dem Internet | `http://DEINE-IP-ODER-DDNS:8082/GEHEIMER-PFAD/v2` |

> Das `/v2` am Ende ist wichtig – nur so findet die Extension die API-Endpunkte.
>
> Den geheimen Pfad (`GEHEIMER-PFAD`) findest du in `nginx/secret.conf` oder
> indem du `./setup.sh` ausführst und **1** wählst.

Test von der Kommandozeile:

```bash
curl http://localhost:8082/GEHEIMER-PFAD/v2/languages
```

Von außen:

```bash
curl http://DEINE-ÖFFENTLICHE-IP:8082/GEHEIMER-PFAD/v2/languages
```

Du solltest ein JSON mit einer Sprachliste bekommen. Ohne den geheimen Pfad
liefert nginx `404`.

### Neuen Link erzeugen

```bash
./setup.sh    # -> 2 wählen
```

Damit wird ein neuer Hash erzeugt und `nginx/secret.conf` überschrieben. nginx
wird am Ende neu geladen. Der alte Link funktioniert danach nicht mehr.

### Link nur anzeigen

```bash
./setup.sh    # -> 1 wählen (oder einfach Enter)
```

## 5. n-gram-Daten (optional, verbessert die Genauigkeit)

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

- Die Auswahl wird in `ngrams/.languages` gemerkt – beim nächsten Lauf wirst du
  **nicht** erneut gefragt.
- Bereits heruntergeladene Sprachen werden **nicht** erneut geladen.
- Die Daten landen in `./ngrams/<sprache>/` und werden read-only als `/ngrams`
  in den Container gemountet; aktiviert über `langtool_languageModel=/ngrams`
  in `docker-compose.yml`.
- Nach einem Download wird LanguageTool automatisch neu erstellt, damit die
  n-gram-Daten beim Start eingelesen werden (aktiv erst nach dem Neustart).
- Verfügbar sind nur `de, en, fr, es, nl`.
- Zum Herunterladen wird `curl` benötigt, zum Entpacken `unzip`, `bsdtar` oder
  `python3` (einer davon reicht).
- **SSD empfohlen** – ohne SSD kann LanguageTool mit n-grams deutlich langsamer
  werden. Bei knappem RAM ggf. `Java_Xmx` in `docker-compose.yml` erhöhen
  (z. B. auf `3g`).
- Auswahl später ändern: `ngrams/.languages` anpassen und `./setup.sh` erneut
  ausführen. Um das Menü wieder zu bekommen, die Datei löschen.

## 6. HTTPS (empfohlen, falls du eine Domain hast)

**Warnung:** Im HTTP-Setup wird der geheime Pfad im Klartext übertragen – wer
ihn auf der Leitung mitliest, kann LanguageTool mitnutzen. Wer den Dienst ins
Internet stellt, sollte daher HTTPS nehmen. Das geht nur mit einer eigenen
Domain (kostenlos z. B. per DDNS-Dienst mit eigenem Domainnamen).

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
#        - ./nginx/secret.conf:/etc/nginx/secret.conf:ro
#      ports:
#        - "${PUBLIC_PORT:-8082}:8082"
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

- **nginx startet nicht:** `nginx/secret.conf` muss existieren. Einmal
  `./setup.sh` ausführen (erzeugt die Datei).
- **404 bei jeder URL:** Der geheime Pfad fehlt oder ist falsch. `./setup.sh`
  ausführen und **1** wählen, um den aktuellen Link anzuzeigen.
- **Kein Zugriff von außen:** Router-Portfreigabe prüfen (nur TCP nötig), und
  `ufw status` auf dem Host. Test immer erst von außen (Handy-Netz!).
- **Erster Check dauert ewig:** Normal – Java + LanguageTool brauchen beim ersten
  Mal einige Sekunden bis Minuten. Danach ist es schneller.
- **n-gram-Download wird übersprungen:** Es fehlen `curl` oder ein Entpacker.
  Installiere z. B. `unzip` – oder stelle sicher, dass `python3` vorhanden ist
  (wird automatisch als Fallback verwendet). Danach `./setup.sh` erneut starten.
- **RAM voll / Container stirbt:** In `docker-compose.yml` `Java_Xmx` reduzieren
  (z. B. von `2g` auf `1g`).
- **Port 8082 schon belegt:** `PUBLIC_PORT` in `setup.sh` ändern und
  `./setup.sh` erneut ausführen.
- **Alter Link funktioniert nicht mehr:** Es wurde ein neuer Link erzeugt.
  `./setup.sh` → **1** zeigt den aktuellen.

## Auf GitHub veröffentlichen (optional)

Die `.gitignore` hält alle Geheimnisse und großen Dateien draußen:

- `nginx/secret.conf` (geheimer Pfad)
- `nginx/certs/`, `*.pem`, `*.key`
- `ngrams/` (mehrere GB, inkl. Auswahl `.languages`)
- Altlasten wie `.env` und `nginx/.htpasswd`

Vor dem ersten Push prüfen, was wirklich committet würde:

```bash
git init
git add -A
git status        # secret.conf und ngrams/ dürfen NICHT auftauchen
```

Dann committen und pushen:

```bash
git commit -m "Initial commit"
git branch -M main
git remote add origin https://github.com/BENUTZER/REPO.git
git push -u origin main
```

> Ist doch einmal ein Geheimnis in die Historie geraten, reicht Löschen im
> nächsten Commit **nicht** – Hash ändern (`./setup.sh` → 2) und die Historie
> bereinigen (z. B. mit `git filter-repo`).
