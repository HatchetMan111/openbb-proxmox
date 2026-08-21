#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal - Install Script (läuft INSIDE der VM)
#  Wird automatisch von setup.sh aufgerufen – oder manuell:
#  curl -fsSL https://raw.githubusercontent.com/HatchetMan111/openbb-proxmox/main/install.sh | sudo bash
# ============================================================

set -e
export DEBIAN_FRONTEND=noninteractive
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
apt-get upgrade -y -qq 2>/dev/null || true
apt-get install -y -qq \
  curl wget git ca-certificates gnupg openssl \
  lsb-release apt-transport-https \
  software-properties-common htop nano 2>/dev/null || true
msg_ok "System aktualisiert"

# ─── 2. SSH absichern ─────────────────────────────────────
msg_info "SSH wird konfiguriert"
mkdir -p /etc/ssh/sshd_config.d
# "00-" Präfix: sshd liest sshd_config.d lexikografisch, erster Treffer gewinnt
cat > /etc/ssh/sshd_config.d/00-openbb.conf << 'SSHD'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config 2>/dev/null || true
for f in /etc/ssh/sshd_config.d/*.conf; do
  [[ "$f" == */00-openbb.conf ]] && continue
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$f" 2>/dev/null || true
done
systemctl restart ssh
msg_ok "SSH konfiguriert (Root-Login nur mit Key)"

# ─── 3. Docker installieren ───────────────────────────────
msg_info "Docker wird installiert"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
systemctl enable docker --now
msg_ok "Docker installiert"

# ─── 4. Verzeichnisse & Token ─────────────────────────────
msg_info "Verzeichnisse werden erstellt"
mkdir -p "$OPENBB_DIR"/{data,notebooks,jupyter-home}
# Jupyter läuft im Container als uid 1000 → Schreibrechte geben
chown -R 1000:1000 "$OPENBB_DIR/notebooks" "$OPENBB_DIR/jupyter-home"
mkdir -p /root/.openbb_platform

# Zufälligen Jupyter-Token generieren (oder bestehenden behalten)
if [[ -f "$OPENBB_DIR/jupyter_token" ]]; then
  JUPYTER_TOKEN=$(cat "$OPENBB_DIR/jupyter_token")
else
  JUPYTER_TOKEN=$(openssl rand -hex 16)
  echo -n "$JUPYTER_TOKEN" > "$OPENBB_DIR/jupyter_token"
  chmod 644 "$OPENBB_DIR/jupyter_token"
fi

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

# ─── 5. Jupyter Image mit OpenBB bauen ────────────────────
# Wird EINMAL gebaut → nach Neustart sofort bereit, kein pip-Install mehr
msg_info "Jupyter Image wird erstellt (OpenBB vorinstalliert)"
cat > "$OPENBB_DIR/Dockerfile.jupyter" << 'DOCKERFILE'
FROM jupyter/scipy-notebook:latest
RUN pip install --no-cache-dir openbb openbb-yfinance openbb-fred openbb-crypto
DOCKERFILE

# .env (mit Token) & Daten gehören nicht in den Build-Kontext
cat > "$OPENBB_DIR/.dockerignore" << 'DOCKERIGNORE'
.env
data
notebooks
jupyter-home
Dockerfile.jupyter
docker-compose.yml
DOCKERIGNORE
msg_ok "Jupyter Dockerfile erstellt"

# ─── 6. Docker Compose schreiben ──────────────────────────
msg_info "Docker Compose wird konfiguriert"
echo "JUPYTER_TOKEN=${JUPYTER_TOKEN}" > "$OPENBB_DIR/.env"
chmod 600 "$OPENBB_DIR/.env"

cat > "$OPENBB_DIR/docker-compose.yml" << COMPOSE
services:

  openbb:
    image: ghcr.io/openbb-finance/openbb-platform:latest
    container_name: openbb
    restart: unless-stopped
    ports:
      - "${OPENBB_PORT}:6900"
    volumes:
      - /root/.openbb_platform:/root/.openbb_platform
      - ${OPENBB_DIR}/data:/root/OpenBBUserData
    environment:
      - TZ=Europe/Berlin
    mem_limit: 1g

  jupyterlab:
    build:
      context: ${OPENBB_DIR}
      dockerfile: Dockerfile.jupyter
    image: openbb-jupyter:local
    container_name: openbb-jupyter
    restart: unless-stopped
    ports:
      - "${JUPYTER_PORT}:8888"
    volumes:
      - ${OPENBB_DIR}/notebooks:/home/jovyan/work
      - ${OPENBB_DIR}/jupyter-home:/home/jovyan/.openbb_platform
    environment:
      - TZ=Europe/Berlin
      - JUPYTER_ENABLE_LAB=yes
      - JUPYTER_TOKEN
    command: >
      start-notebook.sh
      --ServerApp.token='${JUPYTER_TOKEN}'
      --ServerApp.ip='0.0.0.0'
      --no-browser
    mem_limit: 2g

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    mem_limit: 256m

volumes:
  portainer_data:
COMPOSE
msg_ok "Docker Compose konfiguriert"

# ─── 7. Starter-Notebook ──────────────────────────────────
msg_info "Beispiel-Notebook wird erstellt"
cat > "$OPENBB_DIR/notebooks/Schnellstart.py" << 'NB'
# OpenBB Schnellstart – Kostenlose Datenquellen
from openbb import obb

# Aktie (Yahoo Finance)
df = obb.equity.price.historical("AAPL", provider="yfinance")
print(df.to_df().tail(5))

# Bitcoin
btc = obb.crypto.price.historical("BTC-USD", provider="yfinance")
print(btc.to_df().tail(5))

# SAP
sap = obb.equity.price.historical("SAP.DE", provider="yfinance")
print(sap.to_df().tail(5))

# FRED-Makrodaten benoetigen einen kostenlosen API-Key:
# 1. Key holen: https://fred.stlouisfed.org/docs/api/api_key.html
# 2. In der VM eintragen (siehe README) und dann auskommentieren:
# print(obb.economy.fred_series("CPIAUCSL", provider="fred").to_df().tail(5))
NB
msg_ok "Beispiel-Notebook erstellt"

# ─── 8. Autostart-Service ─────────────────────────────────
msg_info "Autostart-Service wird eingerichtet"
cat > /etc/systemd/system/openbb.service << SVC
[Unit]
Description=OpenBB Terminal Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${OPENBB_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=15min

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable openbb
msg_ok "Autostart eingerichtet"

# ─── 9. Container starten (gestaffelt) ────────────────────
msg_info "Container werden gestartet (mehrere GB Download – Portainer zuerst)"
cd "$OPENBB_DIR"
docker compose up -d portainer
msg_ok "Portainer gestartet: http://$(hostname -I | awk '{print $1}'):9000"
docker compose pull openbb || true
docker compose up -d openbb || true
msg_ok "OpenBB gestartet"
msg_info "Jupyter-Image wird gebaut (dauert am längsten)"
if docker compose build jupyterlab; then
  docker compose up -d jupyterlab
  msg_ok "JupyterLab gestartet"
else
  msg_error "Jupyter-Build fehlgeschlagen – Log siehe oben"
fi

# ─── Abschluss ────────────────────────────────────────────
echo ""
VM_IP=$(hostname -I | awk '{print $1}')
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} OpenBB Installation abgeschlossen!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}VM-IP:${CL}       ${VM_IP}"
echo -e " ${YW}JupyterLab:${CL}  http://${VM_IP}:${JUPYTER_PORT}"
echo -e " ${YW}Token:${CL}       siehe /opt/openbb/jupyter_token"
echo -e " ${YW}OpenBB API:${CL}  http://${VM_IP}:${OPENBB_PORT}/api/v1/docs"
echo -e " ${YW}Portainer:${CL}   http://${VM_IP}:9000"
echo -e " Nach Neustart startet alles automatisch."
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
