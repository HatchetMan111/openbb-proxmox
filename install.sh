#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal - Install Script (läuft INSIDE der VM)
#  Wird automatisch von setup.sh aufgerufen
# ============================================================

source /dev/stdin <<< "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)" 2>/dev/null || true

set -e
export DEBIAN_FRONTEND=noninteractive
TZ="Europe/Berlin"
OPENBB_DIR="/opt/openbb"
JUPYTER_PORT=8888
OPENBB_PORT=6900

# ─── Farben ───────────────────────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'
CL='\033[m'; BL='\033[36m'; CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"
INFO="${BL}ℹ${CL}"

msg_info()  { echo -e " ${INFO} ${1}..."; }
msg_ok()    { echo -e " ${CM} ${1}"; }
msg_error() { echo -e " ${CROSS} ${1}"; exit 1; }

# ─── 1. System vorbereiten ────────────────────────────────
msg_info "System wird aktualisiert"
apt-get update -qq
apt-get upgrade -y -qq 2>/dev/null
apt-get install -y -qq \
  curl wget git ca-certificates gnupg \
  lsb-release apt-transport-https \
  software-properties-common htop nano 2>/dev/null
msg_ok "System aktualisiert"

# ─── 2. Docker installieren ───────────────────────────────
msg_info "Docker wird installiert"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin 2>/dev/null
systemctl enable docker --now
msg_ok "Docker installiert"

# ─── 3. Verzeichnisse & Konfiguration ─────────────────────
msg_info "Verzeichnisse werden erstellt"
mkdir -p "$OPENBB_DIR"/{data,notebooks}
mkdir -p /root/.openbb_platform
cat > /root/.openbb_platform/user_settings.json << 'CONF'
{
  "preferences": {
    "data_directory": "/root/OpenBBUserData",
    "export_directory": "/root/OpenBBUserData/exports",
    "timezone": "Europe/Berlin",
    "use_rich_outputs": true
  },
  "credentials": {}
}
CONF
msg_ok "Konfiguration erstellt"

# ─── 4. Docker Compose schreiben ──────────────────────────
msg_info "Docker Compose wird konfiguriert"
cat > "$OPENBB_DIR/docker-compose.yml" << COMPOSE
version: "3.8"
services:

  openbb:
    image: ghcr.io/openbb-finance/openbb-platform:latest
    container_name: openbb
    restart: unless-stopped
    ports:
      - "${OPENBB_PORT}:${OPENBB_PORT}"
    volumes:
      - /root/.openbb_platform:/root/.openbb_platform
      - ${OPENBB_DIR}/data:/root/OpenBBUserData
    environment:
      - TZ=Europe/Berlin
    mem_limit: 1g

  jupyterlab:
    image: jupyter/scipy-notebook:latest
    container_name: openbb-jupyter
    restart: unless-stopped
    ports:
      - "${JUPYTER_PORT}:8888"
    volumes:
      - ${OPENBB_DIR}/notebooks:/home/jovyan/work
      - /root/.openbb_platform:/home/jovyan/.openbb_platform
    environment:
      - TZ=Europe/Berlin
      - JUPYTER_ENABLE_LAB=yes
    command: >
      bash -c "pip install --quiet openbb openbb-yfinance openbb-fred openbb-crypto &&
               start-notebook.sh --NotebookApp.token='openbb_local'
               --NotebookApp.ip='0.0.0.0' --no-browser"
    mem_limit: 2g

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    mem_limit: 256m

volumes:
  portainer_data:
COMPOSE
msg_ok "Docker Compose konfiguriert"

# ─── 5. Starter-Notebook ──────────────────────────────────
msg_info "Beispiel-Notebook wird erstellt"
cat > "$OPENBB_DIR/notebooks/Schnellstart.py" << 'NB'
# OpenBB Schnellstart – Kostenlose Datenquellen
from openbb import obb

# Aktie (Yahoo Finance)
df = obb.equity.price.historical("AAPL", provider="yfinance")
print(df.to_df().tail(5))

# Bitcoin (CoinGecko)
btc = obb.crypto.price.historical("BTC-USD", provider="yfinance")
print(btc.to_df().tail(5))

# Makrodaten USA (FRED)
cpi = obb.economy.fred_series("CPIAUCSL", provider="fred")
print(cpi.to_df().tail(5))
NB
msg_ok "Beispiel-Notebook erstellt"

# ─── 6. Container starten ─────────────────────────────────
msg_info "Container werden heruntergeladen & gestartet (kann 2-3 Min dauern)"
cd "$OPENBB_DIR"
docker compose pull -q
docker compose up -d
msg_ok "Alle Container gestartet"

# ─── Systemd Service für Autostart ────────────────────────
msg_info "Autostart-Service wird eingerichtet"
cat > /etc/systemd/system/openbb.service << SVC
[Unit]
Description=OpenBB Terminal Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
WorkingDirectory=/opt/openbb
ExecStart=/usr/bin/docker compose up
ExecStop=/usr/bin/docker compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
systemctl enable openbb --now 2>/dev/null || true
msg_ok "Autostart eingerichtet"

echo ""
VM_IP=$(hostname -I | awk '{print $1}')
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} OpenBB Installation abgeschlossen!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}JupyterLab:${CL}  http://${VM_IP}:8888  (Token: openbb_local)"
echo -e " ${YW}OpenBB API:${CL}  http://${VM_IP}:6900/api/v1/docs"
echo -e " ${YW}Portainer:${CL}   http://${VM_IP}:9000"
echo ""
