# Self-Hosted LanguageTool with Secret Path

Run a self-hosted [LanguageTool](https://languagetool.org/) server behind nginx with a secret path for access.

## Installation

1. **Install prerequisites** (Linux):

   ```bash
   sudo apt update
   sudo apt install -y docker.io docker-compose-v2
   sudo systemctl enable --now docker
   sudo usermod -aG docker $USER
   ```

   Log out and back in after adding your user to the docker group.

2. **Set your port** (optional): Edit `PUBLIC_PORT` in `setup.sh` if `8082` is already in use.

3. **Start the Setup Process**:
   ```bash
   ./setup.sh
   ```
   On first run, choose option `2` to generate a new secret path. This will pull images, start containers, and show your access URLs.

## Usage

Add one of the URLs shown by `setup.sh` to your LanguageTool extension under "LanguageTool API Server URL" (Advanced). Make sure to include `/v2` at the end.

| Location  | URL                                              |
| --------- | ------------------------------------------------ |
| Localhost | `http://localhost:8082/<SECRET_PATH>/v2`         |
| LAN       | `http://<LAN-IP>:8082/<SECRET_PATH>/v2`          |
| Internet  | `http://<YOUR-IP-OR-DDNS>:8082/<SECRET_PATH>/v2` |

- Only the secret path grants access. All other paths return `404`.
- Show or regenerate the secret path: run `./setup.sh` (option `1` to view, option `2` to regenerate).
- Check status/logs: `docker compose ps` / `docker compose logs -f languagetool`
