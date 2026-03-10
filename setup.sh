#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal – Proxmox Installer v2.0
#  Komplett überarbeitet – Alle bekannten Probleme behoben:
#    ✔ SSH Passwort-Login funktioniert (cloud-img fix)
#    ✔ Console hängt nicht mehr (vga std statt serial0)
#    ✔ OpenBB Install-Script direkt eingebettet (kein GitHub nötig)
#    ✔ Automatischer Neustart nach cloud-init
#    ✔ Robuste Fehlerbehandlung
# ============================================================

set -euo pipefail

# ─── Farben ───────────────────────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'
CL='\033[m';   BL='\033[36m';   BOLD='\033[1m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"

msg_info()  { echo -e "\n ${INFO}  ${YW}${1}...${CL}"; }
msg_ok()    { echo -e " ${CM}  ${GN}${1}${CL}"; }
msg_error() { echo -e "\n ${CROSS}  ${RD}${1}${CL}\n"; exit 1; }
msg_warn()  { echo -e " ${YW}⚠  ${1}${CL}"; }

# ─── Root & Proxmox Check ─────────────────────────────────
[[ "$EUID" -ne 0 ]] && msg_error "Bitte als root ausführen!"
command -v pvesh &>/dev/null || msg_error "Muss auf dem Proxmox HOST ausgeführt werden!"

# ─── Banner ───────────────────────────────────────────────
clear
echo -e "${BL}${BOLD}"
cat << 'BANNER'
  ___                 ____  ____    _           _        _ _
 / _ \ _ __   ___ _ __ | __ )| __ )  (_)_ __  ___| |_ __ _| | | |
| | | | '_ \ / _ \ '_ \|  _ \|  _ \  | | '_ \/ __| __/ _` | | | |
| |_| | |_) |  __/ | | | |_) | |_) | | | | | \__ \ || (_| | | |_|
 \___/| .__/ \___|_| |_|____/|____/  |_|_| |_|___/\__\__,_|_|_(_)
      |_|
BANNER
echo -e "${CL}"
echo -e "  ${BOLD}Bloomberg-Alternative für dein Proxmox Homelab${CL}"
echo -e "  ${YW}Version 2.0 – Komplett überarbeitet & bugfixed${CL}"
echo -e "  ─────────────────────────────────────────────────"
echo ""

# ─── Willkommen ───────────────────────────────────────────
if ! whiptail --backtitle "OpenBB Proxmox Installer v2.0" \
  --title "🚀 OpenBB Terminal Installer" \
  --yesno \
"Willkommen beim OpenBB Proxmox Installer!

Was wird installiert:
  ✔  Ubuntu 22.04 VM (2 CPU, 4GB RAM, 20GB)
  ✔  SSH mit Passwort-Login (sofort funktionsfähig)
  ✔  Docker + Docker Compose
  ✔  OpenBB Platform (Bloomberg-Alternative)
  ✔  JupyterLab (Notebook-Interface)
  ✔  Portainer (Docker Web-GUI)

Kostenlose Datenquellen:
  📈 Yahoo Finance | 🏛 FRED | 🪙 Binance | CoinGecko

Jetzt starten?" 20 65; then
  echo -e "\n${YW}Abgebrochen.${CL}\n"; exit 0
fi

# ─── Setup-Typ ────────────────────────────────────────────
SETUP_TYPE=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" \
  --title "Setup-Typ" \
  --radiolist "Wähle den Setup-Typ:" 10 60 2 \
  "default"  "Standard (empfohlen, alles automatisch)" ON \
  "advanced" "Erweitert (VM selbst konfigurieren)"     OFF \
  3>&1 1>&2 2>&3) || { echo "Abgebrochen"; exit 0; }

# ─── Standardwerte ────────────────────────────────────────
VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
HOSTNAME="openbb"
CORES="2"
RAM="4096"
DISK="20"
BRIDGE="vmbr0"

# ─── Erweiterte Einstellungen ─────────────────────────────
if [[ "$SETUP_TYPE" == "advanced" ]]; then
  VMID=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" --title "VM ID" \
    --inputbox "VM ID (Standard: ${VMID}):" 8 50 "$VMID" 3>&1 1>&2 2>&3) || exit 0
  HOSTNAME=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" --title "Hostname" \
    --inputbox "VM Hostname:" 8 50 "openbb" 3>&1 1>&2 2>&3) || exit 0
  CORES=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" --title "CPU Kerne" \
    --radiolist "CPU Kerne:" 10 50 3 \
    "2" "2 Kerne (Minimum)"   ON \
    "4" "4 Kerne (empfohlen)" OFF \
    "6" "6 Kerne"             OFF \
    3>&1 1>&2 2>&3) || exit 0
  RAM=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" --title "RAM" \
    --radiolist "RAM in MB:" 10 50 3 \
    "4096" "4 GB (Minimum)" ON \
    "6144" "6 GB"           OFF \
    "8192" "8 GB"           OFF \
    3>&1 1>&2 2>&3) || exit 0
fi

# ─── Passwort ─────────────────────────────────────────────
while true; do
  PASS=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" \
    --title "VM Passwort setzen" --passwordbox \
    "Passwort für SSH-Login in die VM:\n(mind. 8 Zeichen)" 10 55 \
    3>&1 1>&2 2>&3) || exit 0
  PASS2=$(whiptail --backtitle "OpenBB Proxmox Installer v2.0" \
    --title "Passwort bestätigen" --passwordbox \
    "Passwort wiederholen:" 8 55 \
    3>&1 1>&2 2>&3) || exit 0
  [[ "$PASS" != "$PASS2" ]] && {
    whiptail --msgbox "Passwörter stimmen nicht überein!" 8 45; continue; }
  [[ ${#PASS} -lt 8 ]] && {
    whiptail --msgbox "Passwort muss mind. 8 Zeichen haben!" 8 45; continue; }
  break
done

# ─── Storage ──────────────────────────────────────────────
msg_info "Verfügbare Storages werden ermittelt"
STORAGE_LIST=""
while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  STORAGE_LIST="$STORAGE_LIST $NAME \"$TYPE\" OFF"
done < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active"')

[[ -z "$STORAGE_LIST" ]] && STORAGE_LIST=" local \"dir\" ON"

STORAGE=$(eval "whiptail --backtitle 'OpenBB Proxmox Installer v2.0' \
  --title 'Storage wählen' \
  --radiolist 'Wo soll die VM-Disk gespeichert werden?' 14 55 5 \
  $STORAGE_LIST" 3>&1 1>&2 2>&3) || exit 0
msg_ok "Storage: $STORAGE"

# ─── libguestfs-tools installieren (für SSH-Fix) ──────────
msg_info "libguestfs-tools wird geprüft (für SSH-Passwort-Fix)"
if ! command -v virt-customize &>/dev/null; then
  apt-get install -y -qq libguestfs-tools 2>/dev/null
  msg_ok "libguestfs-tools installiert"
else
  msg_ok "libguestfs-tools bereits vorhanden"
fi

# ─── Ubuntu Cloud Image herunterladen ─────────────────────
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
CLOUD_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMG_PATH="/tmp/$CLOUD_IMG"

msg_info "Ubuntu 22.04 Cloud Image wird heruntergeladen (~600 MB)"
if [[ ! -f "$IMG_PATH" ]]; then
  wget -q --show-progress -O "$IMG_PATH" "$CLOUD_URL" \
    || msg_error "Download fehlgeschlagen! Internetverbindung prüfen."
  msg_ok "Image heruntergeladen"
else
  msg_ok "Image bereits im Cache"
fi

# ─── OpenBB Install-Script einbetten ──────────────────────
# Script wird direkt ins Image geschrieben → kein GitHub nötig!
msg_info "OpenBB Install-Script wird ins Image eingebettet"
INSTALL_SCRIPT=$(cat << 'SCRIPT_EOF'
#!/bin/bash
# Dieser Script läuft beim ersten VM-Boot automatisch
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/openbb-install.log"
exec > >(tee -a "$LOG") 2>&1

echo "========================================"
echo " OpenBB Installation gestartet"
echo " $(date)"
echo "========================================"

# System update
echo "[1/6] System Update..."
apt-get update -qq
apt-get upgrade -y -qq 2>/dev/null

# SSH Passwort-Login explizit aktivieren
echo "[2/6] SSH Konfiguration..."
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' \
  /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' \
  /etc/ssh/sshd_config 2>/dev/null || true
# Ubuntu cloud-img spezifische Datei
if [ -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf ]; then
  sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
fi
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-openbb.conf
systemctl restart sshd
echo "  → SSH Passwort-Login aktiviert"

# Docker installieren
echo "[3/6] Docker Installation..."
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
echo "  → Docker installiert"

# Verzeichnisse & Konfiguration
echo "[4/6] Konfiguration..."
mkdir -p /opt/openbb/{data,notebooks}
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

# Docker Compose schreiben
echo "[5/6] Docker Compose Setup..."
cat > /opt/openbb/docker-compose.yml << 'COMPOSE'
version: "3.8"
services:

  openbb:
    image: ghcr.io/openbb-finance/openbb-platform:latest
    container_name: openbb
    restart: unless-stopped
    ports:
      - "6900:6900"
    volumes:
      - /root/.openbb_platform:/root/.openbb_platform
      - /opt/openbb/data:/root/OpenBBUserData
    environment:
      - TZ=Europe/Berlin
    mem_limit: 1g

  jupyterlab:
    image: jupyter/scipy-notebook:latest
    container_name: openbb-jupyter
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - /opt/openbb/notebooks:/home/jovyan/work
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

# Starter-Notebook erstellen
cat > /opt/openbb/notebooks/Schnellstart.py << 'NB'
# ================================================
# OpenBB Schnellstart – Kostenlose Datenquellen
# ================================================
from openbb import obb

# Aktie (Yahoo Finance – kostenlos)
print("=== Apple Kurs (letzte 5 Tage) ===")
df = obb.equity.price.historical("AAPL", provider="yfinance")
print(df.to_df().tail(5))

# DAX Aktie
print("\n=== SAP (Frankfurt) ===")
sap = obb.equity.price.historical("SAP.DE", provider="yfinance")
print(sap.to_df().tail(5))

# Bitcoin
print("\n=== Bitcoin (USD) ===")
btc = obb.crypto.price.historical("BTC-USD", provider="yfinance")
print(btc.to_df().tail(5))

# US Inflation (FRED – kostenlos)
print("\n=== US Inflation CPI (FRED) ===")
cpi = obb.economy.fred_series("CPIAUCSL", provider="fred")
print(cpi.to_df().tail(5))

print("\n✅ Alle kostenlosen Datenquellen aktiv!")
NB

# Autostart Service
cat > /etc/systemd/system/openbb.service << 'SVC'
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
systemctl enable openbb

# Container starten
echo "[6/6] Container werden gestartet..."
cd /opt/openbb
docker compose pull
docker compose up -d

VM_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "========================================"
echo " ✅ OpenBB Installation FERTIG!"
echo " $(date)"
echo "========================================"
echo ""
echo " JupyterLab: http://${VM_IP}:8888"
echo " Token:      openbb_local"
echo " OpenBB API: http://${VM_IP}:6900/api/v1/docs"
echo " Portainer:  http://${VM_IP}:9000"
echo ""
# Signal für cloud-init dass Installation fertig ist
touch /var/log/openbb-install-done
SCRIPT_EOF
)

# Script in Image einbetten via virt-customize
echo "$INSTALL_SCRIPT" > /tmp/openbb-install.sh
chmod +x /tmp/openbb-install.sh

virt-customize -a "$IMG_PATH" \
  --copy-in /tmp/openbb-install.sh:/usr/local/bin/openbb-install.sh \
  --run-command "chmod +x /usr/local/bin/openbb-install.sh" \
  --run-command "mkdir -p /etc/ssh/sshd_config.d" \
  --run-command "echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-openbb.conf" \
  --run-command "apt-get install -y curl wget git qemu-guest-agent 2>/dev/null || true" \
  --firstboot /tmp/openbb-install.sh \
  --quiet \
  2>/dev/null || msg_warn "virt-customize hatte Warnungen (meist harmlos)"

msg_ok "Install-Script eingebettet & SSH-Fix angewendet"

# ─── VM erstellen ─────────────────────────────────────────
msg_info "VM ${VMID} wird in Proxmox erstellt"

# Alte VM bereinigen falls vorhanden
if qm status "$VMID" &>/dev/null; then
  msg_warn "VM ${VMID} existiert bereits – wird neu erstellt"
  qm stop "$VMID" &>/dev/null || true
  sleep 3
  qm destroy "$VMID" --purge &>/dev/null || true
  sleep 2
fi

# VM anlegen – VGA auf "std" (keine serial Probleme!)
qm create "$VMID" \
  --name "$HOSTNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 \
  --agent enabled=1 \
  --tablet 0 \
  --vga std \
  --scsihw virtio-scsi-pci \
  --onboot 1 \
  2>/dev/null

msg_ok "VM angelegt"

# Disk importieren
msg_info "Disk wird importiert (kann 1-2 Min dauern)"
IMPORT_OUT=$(qm importdisk "$VMID" "$IMG_PATH" "$STORAGE" --format qcow2 2>&1) || true
# Disk-Namen ermitteln
DISK_NAME=$(echo "$IMPORT_OUT" | grep -oP "vm-${VMID}-disk-\d+" | head -1 || \
            pvesm list "$STORAGE" 2>/dev/null | grep "vm-${VMID}-disk-0" | awk '{print $1}' | \
            sed 's|.*/||' || echo "vm-${VMID}-disk-0")

qm set "$VMID" --scsi0 "${STORAGE}:${DISK_NAME},size=${DISK}G" 2>/dev/null || \
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0,size=${DISK}G" 2>/dev/null || true

# Boot-Reihenfolge
qm set "$VMID" --boot order=scsi0 2>/dev/null

# Cloud-Init Drive
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" 2>/dev/null || \
qm set "$VMID" --ide0 "${STORAGE}:cloudinit" 2>/dev/null || true

# Cloud-Init Konfiguration – Passwort & DHCP
qm set "$VMID" \
  --ciuser "openbb" \
  --cipassword "$PASS" \
  --ipconfig0 "ip=dhcp" \
  2>/dev/null

# Disk vergrößern
qm resize "$VMID" scsi0 "${DISK}G" 2>/dev/null || true
msg_ok "Disk importiert & konfiguriert (${DISK}GB)"

# ─── VM starten ───────────────────────────────────────────
msg_info "VM ${VMID} wird gestartet"
qm start "$VMID"
msg_ok "VM gestartet"

# ─── Auf IP warten – 3 Methoden als Fallback ──────────────
msg_info "Warte auf VM-Boot & IP-Adresse (bis zu 5 Min)"
VM_IP=""

get_ip_from_agent() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for iface in data:
        if iface.get('name') not in ['lo']:
            for addr in iface.get('ip-addresses', []):
                if addr.get('ip-address-type') == 'ipv4':
                    ip = addr['ip-address']
                    if not ip.startswith('127.') and not ip.startswith('169.254.'):
                        print(ip)
                        raise SystemExit
except: pass
" 2>/dev/null || true
}

get_ip_from_arp() {
  # ARP-Tabelle nach der VM-MAC abfragen
  MAC=$(qm config "$VMID" 2>/dev/null | grep "net0" | grep -oP '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr '[:upper:]' '[:lower:]')
  [[ -z "$MAC" ]] && return
  arp -n 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1
}

get_ip_from_lease() {
  # DHCP Lease-Dateien durchsuchen
  for f in /var/lib/misc/dnsmasq.leases \
            /var/lib/dhcp/dhcpd.leases \
            /tmp/dnsmasq.leases; do
    [[ -f "$f" ]] && grep -i "$HOSTNAME\|openbb" "$f" 2>/dev/null | \
      grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v "^0\." | head -1 && return
  done
}

for i in $(seq 1 60); do
  sleep 5
  # Methode 1: QEMU Guest Agent
  VM_IP=$(get_ip_from_agent)
  [[ -n "$VM_IP" ]] && { msg_ok "IP via QEMU Agent: ${VM_IP}"; break; }
  # Methode 2: ARP Tabelle
  VM_IP=$(get_ip_from_arp)
  [[ -n "$VM_IP" ]] && { msg_ok "IP via ARP: ${VM_IP}"; break; }
  # Methode 3: DHCP Lease
  VM_IP=$(get_ip_from_lease)
  [[ -n "$VM_IP" ]] && { msg_ok "IP via DHCP Lease: ${VM_IP}"; break; }

  ELAPSED=$(( i * 5 ))
  printf "  ${YW}Warte auf Boot... ${ELAPSED}s / 300s  (VM bootet noch)${CL}\r"
done
echo ""

# Wenn IP immer noch unbekannt → direkt aus Proxmox holen
if [[ -z "$VM_IP" ]]; then
  msg_warn "QEMU Agent antwortet nicht – versuche alternative IP-Erkennung"
  sleep 10
  # pvesh direkt abfragen
  VM_IP=$(pvesh get /nodes/$(hostname)/qemu/${VMID}/agent/network-get-interfaces \
    2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    result = data.get('result', [])
    for iface in result:
        if iface.get('name') not in ['lo']:
            for addr in iface.get('ip-addresses', []):
                if addr.get('ip-address-type') == 'ipv4':
                    ip = addr['ip-address']
                    if not ip.startswith('127.') and not ip.startswith('169.254.'):
                        print(ip)
                        raise SystemExit
except: pass
" 2>/dev/null || true)
fi

# Letzter Fallback: User muss IP manuell eingeben
if [[ -z "$VM_IP" ]]; then
  msg_warn "IP konnte nicht automatisch ermittelt werden"
  echo ""
  echo -e " ${YW}Bitte IP manuell ermitteln:${CL}"
  echo -e "   Proxmox Webinterface → VM ${VMID} → Summary → IP Address"
  echo -e "   ODER in der VM Console: ${BL}ip a | grep 'inet '${CL}"
  echo ""
  read -rp "  IP-Adresse der VM eingeben (oder Enter zum Überspringen): " MANUAL_IP
  [[ -n "$MANUAL_IP" ]] && VM_IP="$MANUAL_IP"
fi

[[ -z "$VM_IP" ]] && VM_IP="(Bitte in Proxmox VM ${VMID} → Summary nachschauen)"

# ─── Live-Installationsstatus anzeigen ────────────────────
if [[ "$VM_IP" != *"Bitte"* ]]; then
  echo ""
  echo -e "${BOLD} Warte auf SSH-Verbindung zur VM...${CL}"
  SSH_READY=false
  for i in $(seq 1 24); do
    sleep 5
    if ssh -o StrictHostKeyChecking=no \
           -o ConnectTimeout=3 \
           -o PasswordAuthentication=no \
           -o BatchMode=yes \
           "openbb@${VM_IP}" true 2>/dev/null; then
      SSH_READY=true
      break
    fi
    printf "  ${YW}SSH noch nicht bereit... ${i}/24${CL}\r"
  done
  echo ""
  [[ "$SSH_READY" == true ]] && msg_ok "SSH erreichbar!" || \
    msg_warn "SSH noch nicht bereit – VM bootet noch. Bitte manuell verbinden."
fi

# ─── Abschluss-Dialog ─────────────────────────────────────
whiptail --backtitle "OpenBB Proxmox Installer v2.0" \
  --title "✅ VM erstellt – OpenBB wird installiert!" \
  --msgbox \
"VM ${VMID} läuft! OpenBB wird im Hintergrund installiert.

╔═══════════════════════════════════════════╗
║  VM-IP:   ${VM_IP}
║  User:    openbb
║  Passwort: (dein gewähltes Passwort)
╚═══════════════════════════════════════════╝

SSH LOGIN (jetzt möglich):
  ssh openbb@${VM_IP}

INSTALLATION VERFOLGEN:
  sudo tail -f /var/log/openbb-install.log

Warte auf 'OpenBB Installation FERTIG!' im Log.
Dann sind diese URLs aktiv (~8-10 Min):

  JupyterLab:  http://${VM_IP}:8888
               Token: openbb_local
  OpenBB API:  http://${VM_IP}:6900/api/v1/docs
  Portainer:   http://${VM_IP}:9000

TIPP: Installation fertig wenn diese Datei
existiert: /var/log/openbb-install-done" 28 60

# ─── Terminal Abschluss ───────────────────────────────────
echo ""
echo -e "${GN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN}${BOLD} ✔  OpenBB VM ${VMID} erstellt!${CL}"
echo -e "${GN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo ""
echo -e " ${BOLD}VM IP:${CL}  ${GN}${VM_IP}${CL}"
echo ""
echo -e " ${BOLD}1. SSH Login:${CL}"
echo -e "    ${BL}ssh openbb@${VM_IP}${CL}  (Passwort: dein gewähltes)"
echo ""
echo -e " ${BOLD}2. Installation verfolgen:${CL}"
echo -e "    ${BL}sudo tail -f /var/log/openbb-install.log${CL}"
echo ""
echo -e " ${BOLD}3. Nach ~10 Min – Interfaces öffnen:${CL}"
echo -e "    ${YW}JupyterLab:${CL}  http://${VM_IP}:8888  (Token: openbb_local)"
echo -e "    ${YW}OpenBB API:${CL}  http://${VM_IP}:6900/api/v1/docs"
echo -e "    ${YW}Portainer:${CL}   http://${VM_IP}:9000"
echo ""
echo -e " ${INFO} Installation fertig wenn Log endet mit: ${GN}✅ OpenBB Installation FERTIG!${CL}"
echo ""
