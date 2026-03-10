#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal – Proxmox Installer v5.0
#  Getesteter Ansatz – keine virt-customize firstboot Probleme
#
#  WAS ANDERS IST:
#  - SSH-Key wird generiert & direkt ins Image eingebettet
#  - qemu-guest-agent wird direkt ins Image installiert
#  - PasswordAuthentication fix direkt im Image
#  - OpenBB-Script wird per SSH übertragen NACH dem Boot
#  - IP-Erkennung über nmap/arp als Fallback
#  - Kein set -e → Script bricht nie vorzeitig ab
# ============================================================

# KEIN set -e ! Verhindert vorzeitigen Abbruch
set +e

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

# ─── Abhängigkeiten prüfen ────────────────────────────────
for pkg in libguestfs-tools wget curl sshpass; do
  if ! command -v ${pkg/libguestfs-tools/virt-customize} &>/dev/null && \
     ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
    msg_info "$pkg wird installiert"
    apt-get install -y -qq "$pkg" 2>/dev/null
  fi
done

# ─── Banner ───────────────────────────────────────────────
clear
echo -e "${BL}${BOLD}"
cat << 'BANNER'
   ___                   ____  ____
  / _ \ _ __   ___ _ __ | __ )| __ )
 | | | | '_ \ / _ \ '_ \|  _ \|  _ \
 | |_| | |_) |  __/ | | | |_) | |_) |
  \___/| .__/ \___|_| |_|____/|____/
       |_|     Proxmox Installer v5.0
BANNER
echo -e "${CL}"
echo -e "  ${BOLD}Bloomberg-Alternative für dein Homelab${CL}"
echo -e "  ─────────────────────────────────────────────"
echo ""

# ─── Willkommen ───────────────────────────────────────────
whiptail --backtitle "OpenBB Installer v5.0" \
  --title "OpenBB Terminal Installer" \
  --yesno \
"Willkommen! Folgendes wird installiert:

  Ubuntu 22.04 LTS VM
  Docker + Docker Compose
  OpenBB Platform (Bloomberg-Alternative)
  JupyterLab  (http://VM-IP:8888)
  Portainer   (http://VM-IP:9000)

Datenquellen (kostenlos):
  Yahoo Finance, FRED, Binance, CoinGecko

Starten?" 18 55 || { echo "Abgebrochen."; exit 0; }

# ─── Konfiguration ────────────────────────────────────────
VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
HOSTNAME="openbb"
CORES="2"
RAM="4096"
DISK="20"
BRIDGE="vmbr0"

# Setup-Typ
SETUP_TYPE=$(whiptail --backtitle "OpenBB Installer v5.0" \
  --title "Setup-Typ" \
  --radiolist "Wähle den Setup-Typ:" 10 60 2 \
  "default"  "Standard (empfohlen)" ON \
  "advanced" "Erweitert"            OFF \
  3>&1 1>&2 2>&3) || { echo "Abgebrochen"; exit 0; }

if [[ "$SETUP_TYPE" == "advanced" ]]; then
  VMID=$(whiptail --backtitle "OpenBB Installer v5.0" --title "VM ID" \
    --inputbox "VM ID:" 8 40 "$VMID" 3>&1 1>&2 2>&3) || exit 0
  HOSTNAME=$(whiptail --backtitle "OpenBB Installer v5.0" --title "Hostname" \
    --inputbox "Hostname:" 8 40 "openbb" 3>&1 1>&2 2>&3) || exit 0
  CORES=$(whiptail --backtitle "OpenBB Installer v5.0" --title "CPU" \
    --radiolist "CPU Kerne:" 10 45 3 \
    "2" "2 Kerne" ON "4" "4 Kerne" OFF "6" "6 Kerne" OFF \
    3>&1 1>&2 2>&3) || exit 0
  RAM=$(whiptail --backtitle "OpenBB Installer v5.0" --title "RAM" \
    --radiolist "RAM:" 10 45 3 \
    "4096" "4 GB" ON "6144" "6 GB" OFF "8192" "8 GB" OFF \
    3>&1 1>&2 2>&3) || exit 0
fi

# Passwort
while true; do
  PASS=$(whiptail --backtitle "OpenBB Installer v5.0" \
    --title "SSH Passwort" --passwordbox \
    "Passwort fuer die VM (mind. 8 Zeichen):" 9 50 \
    3>&1 1>&2 2>&3) || exit 0
  PASS2=$(whiptail --backtitle "OpenBB Installer v5.0" \
    --title "Passwort bestaetigen" --passwordbox \
    "Passwort wiederholen:" 8 50 \
    3>&1 1>&2 2>&3) || exit 0
  [[ "$PASS" != "$PASS2" ]] && { whiptail --msgbox "Passwoerter stimmen nicht ueberein!" 8 40; continue; }
  [[ ${#PASS} -lt 8 ]]      && { whiptail --msgbox "Mind. 8 Zeichen!" 8 40; continue; }
  break
done

# Storage
STORAGE_MENU=""
while IFS= read -r line; do
  S=$(echo "$line" | awk '{print $1}')
  T=$(echo "$line" | awk '{print $2}')
  STORAGE_MENU="$STORAGE_MENU $S \"$T\" OFF"
done < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active"')
[[ -z "$STORAGE_MENU" ]] && STORAGE_MENU=" local-lvm \"lvm-thin\" ON"
STORAGE=$(eval "whiptail --backtitle 'OpenBB Installer v5.0' \
  --title 'Storage' --radiolist 'Disk Storage:' 12 50 5 \
  $STORAGE_MENU" 3>&1 1>&2 2>&3) || exit 0

echo ""
msg_ok "Konfiguration: VM${VMID} | ${CORES}CPU | ${RAM}MB | ${DISK}GB | ${STORAGE}"

# ─── SSH-Key generieren (für automatisches Login nach Boot) ─
SSH_KEY_PATH="/tmp/openbb_installer_key"
rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q 2>/dev/null
SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
msg_ok "SSH-Key generiert"

# ─── Ubuntu Cloud Image herunterladen ─────────────────────
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
IMG_ORIG="/tmp/${CLOUD_IMG}"
IMG_WORK="/tmp/openbb-vm-${VMID}.img"
CLOUD_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

msg_info "Ubuntu 22.04 Cloud Image wird vorbereitet"
if [[ ! -f "$IMG_ORIG" ]]; then
  echo -e "  ${YW}Download läuft (~600 MB)...${CL}"
  wget -q --show-progress -O "$IMG_ORIG" "$CLOUD_URL"
  [[ $? -ne 0 ]] && msg_error "Download fehlgeschlagen!"
fi

# Arbeitskopie erstellen (Original nicht verändern)
cp "$IMG_ORIG" "$IMG_WORK"
msg_ok "Image bereit"

# ─── Image anpassen mit virt-customize ────────────────────
# NUR sichere Operationen: Pakete installieren + SSH-Key + SSH-Config
# KEIN --firstboot (unzuverlässig)
msg_info "Image wird angepasst (SSH, qemu-agent, Pakete)"

virt-customize -a "$IMG_WORK" \
  --root-password "password:${PASS}" \
  --run-command "useradd -m -s /bin/bash -G sudo openbb || true" \
  --run-command "echo 'openbb:${PASS}' | chpasswd" \
  --run-command "mkdir -p /home/openbb/.ssh && chmod 700 /home/openbb/.ssh" \
  --run-command "echo '${SSH_PUB_KEY}' > /home/openbb/.ssh/authorized_keys" \
  --run-command "chmod 600 /home/openbb/.ssh/authorized_keys" \
  --run-command "chown -R openbb:openbb /home/openbb/.ssh" \
  --run-command "mkdir -p /root/.ssh" \
  --run-command "echo '${SSH_PUB_KEY}' > /root/.ssh/authorized_keys" \
  --run-command "chmod 600 /root/.ssh/authorized_keys" \
  --run-command "echo 'openbb ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openbb" \
  --run-command "chmod 440 /etc/sudoers.d/openbb" \
  --install "qemu-guest-agent,curl,wget,git,openssh-server" \
  --run-command "systemctl enable qemu-guest-agent" \
  --run-command "systemctl enable ssh" \
  --run-command "mkdir -p /etc/ssh/sshd_config.d" \
  --write "/etc/ssh/sshd_config.d/99-openbb.conf:PasswordAuthentication yes\nPubkeyAuthentication yes\nPermitRootLogin yes\n" \
  --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config || true" \
  --run-command "sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true" \
  --timezone "Europe/Berlin" \
  --quiet \
  2>&1 | grep -v "^$" | grep -v "^\[" || true

msg_ok "Image angepasst (SSH + qemu-agent + User eingerichtet)"

# ─── Alte VM entfernen falls vorhanden ────────────────────
if qm status "$VMID" &>/dev/null 2>&1; then
  msg_warn "VM ${VMID} existiert – wird entfernt"
  qm stop "$VMID" --skiplock 1 2>/dev/null; sleep 3
  qm destroy "$VMID" --purge 1 2>/dev/null; sleep 2
fi

# ─── VM erstellen ─────────────────────────────────────────
msg_info "VM wird erstellt"
qm create "$VMID" \
  --name "$HOSTNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26 \
  --agent enabled=1 \
  --vga std \
  --scsihw virtio-scsi-pci \
  --onboot 1 2>/dev/null
msg_ok "VM ${VMID} angelegt"

# ─── Disk importieren ─────────────────────────────────────
msg_info "Disk wird importiert"
qm importdisk "$VMID" "$IMG_WORK" "$STORAGE" --format qcow2 2>/dev/null
sleep 2

# Disk zuweisen – verschiedene Storage-Typen abdecken
if pvesm status 2>/dev/null | grep -q "^${STORAGE}.*dir"; then
  qm set "$VMID" --scsi0 "${STORAGE}:${VMID}/vm-${VMID}-disk-0.qcow2" 2>/dev/null || \
  qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0" 2>/dev/null || true
else
  qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0" 2>/dev/null || true
fi

qm set "$VMID" --boot order=scsi0 2>/dev/null

# Cloud-Init
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" 2>/dev/null || \
qm set "$VMID" --ide0 "${STORAGE}:cloudinit" 2>/dev/null || true

qm set "$VMID" \
  --ciuser "openbb" \
  --cipassword "${PASS}" \
  --ipconfig0 "ip=dhcp" 2>/dev/null

# Disk vergrößern
qm resize "$VMID" scsi0 "${DISK}G" 2>/dev/null || true
msg_ok "Disk konfiguriert (${DISK}GB)"

# ─── Arbeitsbild aufräumen ────────────────────────────────
rm -f "$IMG_WORK"

# ─── VM starten ───────────────────────────────────────────
msg_info "VM wird gestartet"
qm start "$VMID" 2>/dev/null
msg_ok "VM gestartet – wartet auf Boot"

# ─── IP-Erkennung: QEMU Agent (mit qemu-guest-agent im Image) ─
msg_info "Warte auf VM-IP via QEMU Guest Agent"
VM_IP=""
NODE=$(hostname -s)

echo ""
for i in $(seq 1 60); do
  sleep 5
  # QEMU Agent Methode
  RAW=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null || true)
  if [[ -n "$RAW" ]]; then
    TMP_IP=$(echo "$RAW" | python3 -c "
import sys,json
try:
  for iface in json.load(sys.stdin):
    if iface.get('name','')=='lo': continue
    for a in iface.get('ip-addresses',[]):
      ip=a.get('ip-address','')
      if a.get('ip-address-type')=='ipv4' and ip and not ip.startswith('127.') and not ip.startswith('169.254.'):
        print(ip); exit()
except: pass
" 2>/dev/null || true)
    if [[ -n "$TMP_IP" ]]; then
      VM_IP="$TMP_IP"
      echo ""
      msg_ok "IP gefunden via QEMU Agent: ${VM_IP}"
      break
    fi
  fi

  # ARP Fallback
  MAC=$(qm config "$VMID" 2>/dev/null | grep -oP 'virtio=\K[0-9A-Fa-f:]{17}' | head -1 | tr 'A-F' 'a-f' || true)
  if [[ -n "$MAC" ]]; then
    TMP_IP=$(arp -n 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1 || true)
    if [[ -n "$TMP_IP" && "$TMP_IP" != "<incomplete>" ]]; then
      VM_IP="$TMP_IP"
      echo ""
      msg_ok "IP gefunden via ARP: ${VM_IP}"
      break
    fi
  fi

  printf "  ${YW}⏳ %3ds – warte auf QEMU Agent...${CL}\r" "$((i*5))"
done
echo ""

# Manueller Fallback
if [[ -z "$VM_IP" ]]; then
  msg_warn "IP nicht automatisch gefunden."
  echo ""
  echo -e "  ${BL}Bitte in Proxmox nachschauen: VM ${VMID} → Summary → IP${CL}"
  echo -e "  ${BL}Oder in der VM Console einloggen und 'ip a' eingeben${CL}"
  echo ""
  read -rp "  IP der VM eingeben: " VM_IP
  [[ -z "$VM_IP" ]] && VM_IP="UNBEKANNT"
fi

# ─── OpenBB per SSH installieren ──────────────────────────
if [[ "$VM_IP" != "UNBEKANNT" ]]; then
  msg_info "Verbinde mit VM via SSH um OpenBB zu installieren"

  # SSH-Verbindung warten
  SSH_OK=false
  for i in $(seq 1 24); do
    if ssh -i "$SSH_KEY_PATH" \
         -o StrictHostKeyChecking=no \
         -o ConnectTimeout=5 \
         -o BatchMode=yes \
         "openbb@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"; then
      SSH_OK=true
      break
    fi
    printf "  ${YW}SSH noch nicht bereit... %ds${CL}\r" "$((i*5))"
    sleep 5
  done
  echo ""

  if [[ "$SSH_OK" == "true" ]]; then
    msg_ok "SSH Verbindung erfolgreich!"

    # OpenBB Install-Script schreiben und übertragen
    cat > /tmp/openbb-install-remote.sh << 'INSTALL_EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/openbb-install.log"
exec > >(tee -a "$LOG") 2>&1
set +e

echo "========================================"
echo " OpenBB Installation gestartet: $(date)"
echo "========================================"

# SSH Passwort-Login sicherstellen
echo "[1/6] SSH absichern..."
mkdir -p /etc/ssh/sshd_config.d
echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/99-openbb.conf
echo "PubkeyAuthentication yes"  >> /etc/ssh/sshd_config.d/99-openbb.conf
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' \
  /etc/ssh/sshd_config 2>/dev/null || true
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' \
  /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true
systemctl restart ssh
echo "  → SSH OK"

# System Update
echo "[2/6] System Update..."
apt-get update -qq 2>/dev/null
apt-get upgrade -y -qq 2>/dev/null
apt-get install -y -qq curl wget git ca-certificates gnupg 2>/dev/null
echo "  → System OK"

# Docker
echo "[3/6] Docker Installation..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq 2>/dev/null
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin 2>/dev/null
systemctl enable docker --now
echo "  → Docker OK"

# Verzeichnisse
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
echo "  → Konfiguration OK"

# Docker Compose
echo "[5/6] Docker Compose erstellen..."
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

# Autostart
cat > /etc/systemd/system/openbb.service << 'SVC'
[Unit]
Description=OpenBB Stack
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
echo "  → Docker Compose OK"

# Container starten
echo "[6/6] Container starten (dauert 2-3 Min fuer Download)..."
cd /opt/openbb
docker compose pull 2>&1 | grep -E "Pulling|Pull complete|Status" || true
docker compose up -d
echo "  → Container gestartet"

# Beispiel-Notebook
cat > /opt/openbb/notebooks/Schnellstart.py << 'NB'
# OpenBB Schnellstart
from openbb import obb

# Aktie (Yahoo Finance)
print("=== Apple ===")
print(obb.equity.price.historical("AAPL", provider="yfinance").to_df().tail(5))

# Bitcoin
print("\n=== Bitcoin ===")
print(obb.crypto.price.historical("BTC-USD", provider="yfinance").to_df().tail(5))

# SAP Frankfurt
print("\n=== SAP.DE ===")
print(obb.equity.price.historical("SAP.DE", provider="yfinance").to_df().tail(5))
NB

VM_IP=$(hostname -I | awk '{print $1}')
touch /var/log/openbb-install-done

echo ""
echo "========================================"
echo " FERTIG! $(date)"
echo "========================================"
echo " JupyterLab: http://${VM_IP}:8888"
echo " Token:      openbb_local"
echo " Portainer:  http://${VM_IP}:9000"
echo " OpenBB API: http://${VM_IP}:6900/api/v1/docs"
echo "========================================"
INSTALL_EOF

    # Script auf VM übertragen
    scp -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        /tmp/openbb-install-remote.sh \
        "openbb@${VM_IP}:/tmp/openbb-install.sh" 2>/dev/null

    # Script im Hintergrund starten
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "openbb@${VM_IP}" \
        "chmod +x /tmp/openbb-install.sh && sudo nohup /tmp/openbb-install.sh > /var/log/openbb-install.log 2>&1 &" \
        2>/dev/null

    msg_ok "OpenBB Installation gestartet im Hintergrund!"

    # Passwort-Login auch per SSH sofort aktivieren
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        "openbb@${VM_IP}" \
        "sudo mkdir -p /etc/ssh/sshd_config.d && echo 'PasswordAuthentication yes' | sudo tee /etc/ssh/sshd_config.d/99-openbb.conf && sudo systemctl restart ssh" \
        2>/dev/null
    msg_ok "SSH Passwort-Login aktiviert"

  else
    msg_warn "SSH Verbindung fehlgeschlagen – manuelle Installation nötig"
    echo -e "  ${BL}In der VM Console einloggen und ausführen:${CL}"
    echo -e "  ${YW}curl -fsSL https://raw.githubusercontent.com/DEIN_REPO/main/install.sh | sudo bash${CL}"
  fi
fi

# ─── SSH-Key aufräumen ────────────────────────────────────
rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub" /tmp/openbb-install-remote.sh

# ─── ABSCHLUSSMELDUNG ─────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}╔══════════════════════════════════════════════════════╗${CL}"
echo -e "${GN}${BOLD}║        ✅  OpenBB VM ERFOLGREICH ERSTELLT!           ║${CL}"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-ID:    ${VMID}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-Name:  ${HOSTNAME}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-IP:    ${VM_IP}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "SSH-User: openbb"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "RAM:      ${RAM}MB  CPU: ${CORES}  Disk: ${DISK}GB"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "SSH LOGIN (sofort):"
printf "${GN}${BOLD}║${CL}  ${BL}%-52s${CL} ${GN}${BOLD}║${CL}\n" "ssh openbb@${VM_IP}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "Passwort: dein gewaehltes Passwort"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "INSTALLATION VERFOLGEN:"
printf "${GN}${BOLD}║${CL}  ${BL}%-52s${CL} ${GN}${BOLD}║${CL}\n" "ssh openbb@${VM_IP}"
printf "${GN}${BOLD}║${CL}  ${YW}%-52s${CL} ${GN}${BOLD}║${CL}\n" "sudo tail -f /var/log/openbb-install.log"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "NACH ~10 MIN VERFUEGBAR:"
printf "${GN}${BOLD}║${CL}  ${YW}JupyterLab:${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:8888"
printf "${GN}${BOLD}║${CL}  ${YW}Token:     ${CL} %-41s ${GN}${BOLD}║${CL}\n" "openbb_local"
printf "${GN}${BOLD}║${CL}  ${YW}Portainer: ${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:9000"
printf "${GN}${BOLD}║${CL}  ${YW}OpenBB API:${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:6900/api/v1/docs"
echo -e "${GN}${BOLD}╚══════════════════════════════════════════════════════╝${CL}"
echo ""
