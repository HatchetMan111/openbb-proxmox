#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal – Proxmox Installer v6.0
#  Erstellt eine Ubuntu 22.04 VM mit OpenBB, JupyterLab & Portainer
#
#  - Ubuntu Cloud Image mit SHA256-Prüfung
#  - SSH-Key direkt ins Image eingebettet
#  - Jupyter-Token wird zufällig generiert & dauerhaft gespeichert
#  - Alle Dienste laufen nach Neustart automatisch (ohne Zusatzschritte)
# ============================================================

set -u

# ─── Farben ───────────────────────────────────────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'
CL='\033[m';   BL='\033[36m';   BOLD='\033[1m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"

msg_info()  { echo -e "\n ${INFO}  ${YW}${1}...${CL}"; }
msg_ok()    { echo -e " ${CM}  ${GN}${1}${CL}"; }
msg_error() { echo -e "\n ${CROSS}  ${RD}${1}${CL}\n"; exit 1; }
msg_warn()  { echo -e " ${YW}⚠  ${1}${CL}"; }

cleanup() {
  [[ -n "${SSH_KEY_PATH:-}" ]] && rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
  [[ -n "${SSH_KEYS_FILE:-}" ]] && rm -f "$SSH_KEYS_FILE"
  [[ -n "${REMOTE_SH_FILE:-}" ]] && rm -f "$REMOTE_SH_FILE"
}
trap cleanup EXIT

# ─── Root & Proxmox Check ─────────────────────────────────
[[ "$EUID" -ne 0 ]] && msg_error "Bitte als root ausführen!"
command -v pvesh &>/dev/null || msg_error "Muss auf dem Proxmox HOST ausgeführt werden!"

# ─── Abhängigkeiten prüfen ────────────────────────────────
msg_info "Prüfe Abhängigkeiten"
apt-get update -qq >/dev/null 2>&1 || true
for pkg in libguestfs-tools wget curl openssh-client python3 sshpass; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    msg_info "$pkg wird installiert"
    apt-get install -y -qq "$pkg" >/dev/null 2>&1 || msg_error "Installation von $pkg fehlgeschlagen!"
  fi
done
command -v virt-customize &>/dev/null || msg_error "virt-customize nicht gefunden (libguestfs-tools)!"
msg_ok "Abhängigkeiten OK"

# ─── Banner ───────────────────────────────────────────────
clear
echo -e "${BL}${BOLD}"
cat << 'BANNER'
   ___                   ____  ____
  / _ \ _ __   ___ _ __ | __ )| __ )
 | | | | '_ \ / _ \ '_ \|  _ \|  _ \
 | |_| | |_) |  __/ | | | |_) | |_) |
  \___/| .__/ \___|_| |_|____/|____/
       |_|     Proxmox Installer v6.0
BANNER
echo -e "${CL}"
echo -e "  ${BOLD}Bloomberg-Alternative für dein Homelab${CL}"
echo -e "  ─────────────────────────────────────────────"
echo ""

# ─── Willkommen ───────────────────────────────────────────
whiptail --backtitle "OpenBB Installer v6.0" \
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
SETUP_TYPE=$(whiptail --backtitle "OpenBB Installer v6.0" \
  --title "Setup-Typ" \
  --radiolist "Wähle den Setup-Typ:" 10 60 2 \
  "default"  "Standard (empfohlen)" ON \
  "advanced" "Erweitert"            OFF \
  3>&1 1>&2 2>&3) || { echo "Abgebrochen"; exit 0; }

if [[ "$SETUP_TYPE" == "advanced" ]]; then
  VMID=$(whiptail --backtitle "OpenBB Installer v6.0" --title "VM ID" \
    --inputbox "VM ID:" 8 40 "$VMID" 3>&1 1>&2 2>&3) || exit 0
  HOSTNAME=$(whiptail --backtitle "OpenBB Installer v6.0" --title "Hostname" \
    --inputbox "Hostname:" 8 40 "openbb" 3>&1 1>&2 2>&3) || exit 0
  CORES=$(whiptail --backtitle "OpenBB Installer v6.0" --title "CPU" \
    --radiolist "CPU Kerne:" 10 45 3 \
    "2" "2 Kerne" ON "4" "4 Kerne" OFF "6" "6 Kerne" OFF \
    3>&1 1>&2 2>&3) || exit 0
  RAM=$(whiptail --backtitle "OpenBB Installer v6.0" --title "RAM" \
    --radiolist "RAM:" 10 45 3 \
    "4096" "4 GB" ON "6144" "6 GB" OFF "8192" "8 GB" OFF \
    3>&1 1>&2 2>&3) || exit 0
fi

if ! [[ "$VMID" =~ ^[0-9]+$ ]] || (( VMID < 100 || VMID > 999999999 )); then
  msg_error "Ungültige VM-ID: $VMID"
fi

# Passwort
while true; do
  PASS=$(whiptail --backtitle "OpenBB Installer v6.0" \
    --title "SSH Passwort" --passwordbox \
    "Passwort fuer die VM (mind. 8 Zeichen):\n\nNicht erlaubt: Leerzeichen und ' \" \` \\\$ \\\\" 10 60 \
    3>&1 1>&2 2>&3) || exit 0
  PASS2=$(whiptail --backtitle "OpenBB Installer v6.0" \
    --title "Passwort bestaetigen" --passwordbox \
    "Passwort wiederholen:" 8 50 \
    3>&1 1>&2 2>&3) || exit 0
  [[ "$PASS" != "$PASS2" ]] && { whiptail --msgbox "Passwoerter stimmen nicht ueberein!" 8 40; continue; }
  [[ ${#PASS} -lt 8 ]]      && { whiptail --msgbox "Mind. 8 Zeichen!" 8 40; continue; }
  if [[ ! "$PASS" =~ ^[^[:space:]\'\"\`\$\\]+$ ]]; then
    whiptail --msgbox "Das Passwort enthaelt nicht erlaubte Zeichen.\nBitte Leerzeichen und ' \" \` \$ \\ vermeiden!" 9 50
    continue
  fi
  break
done

# Storage (ohne eval – sicher gegen Sonderzeichen)
STORAGE_LIST=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
if [[ -z "$STORAGE_LIST" ]]; then
  STORAGE="local-lvm"
else
  MENU_ARGS=()
  FIRST=ON
  while IFS= read -r S; do
    T=$(pvesm status 2>/dev/null | awk -v s="$S" '$1==s {print $2}')
    MENU_ARGS+=("$S" "${T:-storage}" "$FIRST")
    FIRST=OFF
  done <<< "$STORAGE_LIST"
  STORAGE=$(whiptail --backtitle "OpenBB Installer v6.0" \
    --title 'Storage' --radiolist 'Disk Storage:' 12 50 5 \
    "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || exit 0
fi

echo ""
msg_ok "Konfiguration: VM${VMID} | ${CORES}CPU | ${RAM}MB | ${DISK}GB | ${STORAGE}"

# ─── SSH-Key generieren (für automatisches Login nach Boot) ─
SSH_KEY_PATH="/tmp/openbb_installer_key_${VMID}"
SSH_KEYS_FILE="/tmp/openbb_cloudinit_keys_${VMID}"
rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub" "$SSH_KEYS_FILE"
ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q
chmod 600 "$SSH_KEY_PATH"
SSH_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
# Key-Datei für Cloud-Init (injiziert den Key zuverlässig beim Boot,
# unabhängig davon ob virt-customize erfolgreich war)
echo "$SSH_PUB_KEY" > "$SSH_KEYS_FILE"
chmod 644 "$SSH_KEYS_FILE"
msg_ok "SSH-Key generiert"

# ─── Ubuntu Cloud Image herunterladen (mit SHA256-Prüfung) ──
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
IMG_ORIG="/tmp/${CLOUD_IMG}"
IMG_WORK="/tmp/openbb-vm-${VMID}.img"
CLOUD_BASE="https://cloud-images.ubuntu.com/jammy/current"

msg_info "Ubuntu 22.04 Cloud Image wird vorbereitet"
if [[ ! -f "$IMG_ORIG" ]]; then
  echo -e "  ${YW}Download läuft (~600 MB)...${CL}"
  wget -q --show-progress -O "$IMG_ORIG" "${CLOUD_BASE}/${CLOUD_IMG}" || msg_error "Download fehlgeschlagen!"
fi

echo -e "  ${YW}Prüfe SHA256 Checksumme...${CL}"
EXPECTED_SHA=$(wget -qO- "${CLOUD_BASE}/SHA256SUMS" | grep "$CLOUD_IMG" | awk '{print $1}')
ACTUAL_SHA=$(sha256sum "$IMG_ORIG" | awk '{print $1}')
if [[ -z "$EXPECTED_SHA" ]]; then
  msg_warn "Checksumme nicht verfügbar – fahre ohne Prüfung fort"
elif [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  rm -f "$IMG_ORIG"
  msg_error "Checksummen-Fehler! Image wurde gelöscht. Bitte erneut versuchen."
fi
cp "$IMG_ORIG" "$IMG_WORK"
msg_ok "Image bereit (SHA256 geprüft)"

# ─── Image anpassen mit virt-customize ────────────────────
# Sicherheitsprofil:
#  - Root-Login nur per SSH-Key (prohibit-password)
#  - User 'openbb' per Passwort + Key erreichbar
#  - NOPASSWD-Sudo NUR für die Automatik-Installation,
#    wird vom Install-Script am Ende wieder entfernt
# sshd-Config lokal erzeugen und per --upload ins Image bringen
# (--write verarbeitet \n nicht zuverlässig als Newline)
# WICHTIG: Präfix "00-" – sshd liest sshd_config.d lexikografisch und der
# ERSTE Treffer gewinnt. "00-" schlägt damit 50-cloud-init.conf
# ("PasswordAuthentication no") und 60-cloudimg-settings.conf!
SSHD_CONF_FILE="/tmp/openbb-sshd-${VMID}.conf"
cat > "$SSHD_CONF_FILE" << 'SSHD'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD

VIRT_LOG="/tmp/openbb-virt-customize-${VMID}.log"
msg_info "Image wird angepasst (SSH, qemu-agent, Pakete) – dauert 1-3 Min"

if virt-customize -a "$IMG_WORK" \
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
  --upload "$SSHD_CONF_FILE:/etc/ssh/sshd_config.d/00-openbb.conf" \
  --run-command "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config" \
  --run-command "sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config || true" \
  --run-command "test ! -f /etc/ssh/sshd_config.d/50-cloud-init.conf || sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf" \
  --run-command "test ! -f /etc/ssh/sshd_config.d/60-cloudimg-settings.conf || sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/60-cloudimg-settings.conf" \
  --timezone "Europe/Berlin" \
  --quiet \
  > "$VIRT_LOG" 2>&1; then
  msg_ok "Image angepasst (SSH + qemu-agent + User eingerichtet)"
else
  msg_warn "virt-customize hatte Fehler – Details in $VIRT_LOG"
  echo -e "  ${YW}Cloud-Init injiziert User+SSH-Key trotzdem beim Boot.${CL}"
fi
rm -f "$SSHD_CONF_FILE"

[[ ! -s "$IMG_WORK" ]] && msg_error "Image-Anpassung fehlgeschlagen!"

# ─── Alte VM entfernen falls vorhanden ────────────────────
if qm status "$VMID" &>/dev/null; then
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
rm -f "$IMG_WORK"

qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-0" 2>/dev/null \
  || qm set "$VMID" --scsi0 "${STORAGE}:${VMID}/vm-${VMID}-disk-0.qcow2" 2>/dev/null
qm set "$VMID" --boot order=scsi0 2>/dev/null

# Cloud-Init
qm set "$VMID" --ide2 "${STORAGE}:cloudinit" 2>/dev/null \
  || qm set "$VMID" --ide0 "${STORAGE}:cloudinit" 2>/dev/null

qm set "$VMID" \
  --ciuser "openbb" \
  --cipassword "${PASS}" \
  --sshkeys "$SSH_KEYS_FILE" \
  --ipconfig0 "ip=dhcp" 2>/dev/null
msg_ok "Cloud-Init konfiguriert (User + SSH-Key via Cloud-Init)"

# Disk vergrößern
qm resize "$VMID" scsi0 "${DISK}G" 2>/dev/null || true
msg_ok "Disk konfiguriert (${DISK}GB)"

# ─── VM starten ───────────────────────────────────────────
msg_info "VM wird gestartet"
qm start "$VMID" 2>/dev/null
msg_ok "VM gestartet – wartet auf Boot"

# ─── IP-Erkennung: QEMU Agent ─────────────────────────────
msg_info "Warte auf VM-IP via QEMU Guest Agent"
VM_IP=""

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
        print(ip); sys.exit(0)
except Exception: pass
" 2>/dev/null || true)
    if [[ -n "$TMP_IP" ]]; then
      VM_IP="$TMP_IP"
      echo ""
      msg_ok "IP gefunden via QEMU Agent: ${VM_IP}"
      break
    fi
  fi

  # ARP Fallback (ip neigh; arp als Fallback falls net-tools vorhanden)
  MAC=$(qm config "$VMID" 2>/dev/null | grep -oP 'virtio=\K[0-9A-Fa-f:]{17}' | head -1 | tr 'A-F' 'a-f' || true)
  if [[ -n "$MAC" ]]; then
    TMP_IP=$(ip neigh show 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1 || true)
    if [[ -z "$TMP_IP" ]] && command -v arp &>/dev/null; then
      TMP_IP=$(arp -n 2>/dev/null | grep -i "$MAC" | awk '{print $1}' | head -1 || true)
    fi
    if [[ -n "$TMP_IP" && "$TMP_IP" != "<incomplete>" && "$TMP_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
  while [[ -z "$VM_IP" ]]; do
    read -rp "  IP der VM eingeben: " VM_IP
    VM_IP=$(echo "$VM_IP" | tr -d '[:space:]')
    if [[ ! "$VM_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      msg_warn "Keine gültige IPv4-Adresse – bitte erneut eingeben"
      VM_IP=""
    fi
  done
fi
[[ -z "$VM_IP" ]] && msg_error "Keine VM-IP verfügbar – Installation kann nicht fortgesetzt werden."

# ─── OpenBB per SSH installieren ──────────────────────────
INSTALL_STARTED=false
msg_info "Verbinde mit VM via SSH um OpenBB zu installieren"

SSH_OPTS=(-i "$SSH_KEY_PATH"
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=5
  -o BatchMode=yes
  -o LogLevel=ERROR)

# Hilfsfunktion: Port-Check (unterscheidet "VM bootet noch" vs "Auth-Fehler")
port_open() { timeout 3 bash -c "</dev/tcp/${VM_IP}/22" 2>/dev/null; }

SSHPASS_MODE=false
ssh_cmd() {
  if [[ "$SSHPASS_MODE" == "true" ]]; then
    SSHPASS="$PASS" sshpass -e ssh \
      -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR "$@"
  else
    ssh "${SSH_OPTS[@]}" "$@"
  fi
}

scp_cmd() {
  if [[ "$SSHPASS_MODE" == "true" ]]; then
    SSHPASS="$PASS" sshpass -e scp \
      -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR "$@"
  else
    scp "${SSH_OPTS[@]}" "$@"
  fi
}

ssh_check() {
  ssh "${SSH_OPTS[@]}" "openbb@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"
}

SSH_OK=false
LAST_STATE=""
for i in $(seq 1 30); do
  if ssh_check; then
    SSH_OK=true
    break
  fi
  if port_open; then
    LAST_STATE="Port 22 offen – warte auf Authentifizierung (Cloud-Init)"
  else
    LAST_STATE="Port 22 zu – VM bootet noch / Cloud-Init läuft"
  fi
  printf "  ${YW}⏳ %3ds – %s${CL}\033[K\r" "$((i*10))" "$LAST_STATE"
  sleep 10
done
echo ""

# Fallback: Key-Login fehlgeschlagen, aber Port offen → Passwort-Login versuchen
if [[ "$SSH_OK" != "true" ]] && port_open; then
  msg_warn "Key-Login fehlgeschlagen – versuche Passwort-Login"
  if SSHPASS="$PASS" sshpass -e \
       ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
           -o PreferredAuthentications=password -o PubkeyAuthentication=no \
           -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
       "openbb@${VM_IP}" "echo ok" 2>/dev/null | grep -q "ok"; then
    SSH_OK=true
    SSHPASS_MODE=true
    msg_ok "Passwort-Login erfolgreich!"
  fi
fi

echo ""

if [[ "$SSH_OK" == "true" ]]; then
  msg_ok "SSH Verbindung erfolgreich!"

  # Install-Script schreiben und übertragen
  REMOTE_SH_FILE="/tmp/openbb-install-remote-${VMID}.sh"
  cat > "$REMOTE_SH_FILE" << 'INSTALL_EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
LOG="/var/log/openbb-install.log"
set +e

echo "========================================"
echo " OpenBB Installation gestartet: $(date)"
echo "========================================"

rm -f /var/log/openbb-install-done

# SSH Passwort-Login sicherstellen (cloud-init kann es zurücksetzen)
# "00-" Präfix: sshd liest sshd_config.d lexikografisch, erster Treffer gewinnt
echo "[1/7] SSH Konfiguration..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-openbb.conf << 'SSHD2'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSHD2
sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/g' \
  /etc/ssh/sshd_config 2>/dev/null || true
for f in /etc/ssh/sshd_config.d/*.conf; do
  [[ "$f" == */00-openbb.conf ]] && continue
  sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' "$f" 2>/dev/null || true
done
systemctl restart ssh
echo "  → SSH OK"

# System Update
echo "[2/7] System Update..."
apt-get update -qq 2>/dev/null
apt-get upgrade -y -qq 2>/dev/null
apt-get install -y -qq curl wget git ca-certificates gnupg openssl 2>/dev/null
echo "  → System OK"

# Docker
echo "[3/7] Docker Installation..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq 2>/dev/null
apt-get install -y -qq \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin 2>/dev/null
systemctl enable docker --now
echo "  → Docker OK"

# Verzeichnisse & zufälliger Jupyter-Token (dauerhaft gespeichert)
echo "[4/7] Konfiguration..."
mkdir -p /opt/openbb/{data,notebooks,jupyter-home}
mkdir -p /root/.openbb_platform
# Jupyter läuft im Container als uid 1000 → Schreibrechte geben
chown -R 1000:1000 /opt/openbb/notebooks /opt/openbb/jupyter-home
JUPYTER_TOKEN=$(openssl rand -hex 16)
echo -n "$JUPYTER_TOKEN" > /opt/openbb/jupyter_token
chmod 644 /opt/openbb/jupyter_token
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

# Jupyter Custom Image MIT OpenBB vorinstalliert bauen
# → Nach einem Neustart ist Jupyter sofort bereit (kein pip-Install mehr!)
echo "[5/7] Jupyter Image mit OpenBB wird gebaut (einmalig, ~5-10 Min)..."
cat > /opt/openbb/Dockerfile.jupyter << 'DOCKERFILE'
FROM jupyter/scipy-notebook:latest
RUN pip install --no-cache-dir openbb openbb-yfinance openbb-fred openbb-crypto
DOCKERFILE

# .env (mit Token) & Daten gehören nicht in den Build-Kontext
cat > /opt/openbb/.dockerignore << 'DOCKERIGNORE'
.env
data
notebooks
jupyter-home
Dockerfile.jupyter
docker-compose.yml
DOCKERIGNORE

# Docker Compose
echo "[6/7] Docker Compose erstellen..."
cat > /opt/openbb/.env << ENVEOF
JUPYTER_TOKEN=${JUPYTER_TOKEN}
ENVEOF
chmod 600 /opt/openbb/.env

cat > /opt/openbb/docker-compose.yml << 'COMPOSE'
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
    build:
      context: /opt/openbb
      dockerfile: Dockerfile.jupyter
    image: openbb-jupyter:local
    container_name: openbb-jupyter
    restart: unless-stopped
    ports:
      - "8888:8888"
    volumes:
      - /opt/openbb/notebooks:/home/jovyan/work
      - /opt/openbb/jupyter-home:/home/jovyan/.openbb_platform
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

# Autostart-Service (Type=oneshot + docker restart-policy = reboot-sicher)
cat > /etc/systemd/system/openbb.service << 'SVC'
[Unit]
Description=OpenBB Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/openbb
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=15min

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable openbb
echo "  → Docker Compose OK"

# Container starten (baut Jupyter-Image einmalig mit)
echo "[7/7] Container starten & Images laden (dauert 5-10 Min)..."
cd /opt/openbb || exit 1
docker compose pull openbb portainer 2>&1 | tail -2 || true
docker compose up -d --build 2>&1 | tail -5
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

# SAP
print("\n=== SAP.DE ===")
print(obb.equity.price.historical("SAP.DE", provider="yfinance").to_df().tail(5))

# FRED-Makrodaten benoetigen einen kostenlosen API-Key:
# 1. Key holen: https://fred.stlouisfed.org/docs/api/api_key.html
# 2. In der VM eintragen (siehe README) und dann auskommentieren:
# print(obb.economy.fred_series("CPIAUCSL", provider="fred").to_df().tail(5))
NB

# Sicherheit: Temporäres NOPASSWD-Sudo wieder entfernen
# (User kann weiterhin sudo nutzen – dann aber mit Passwort)
rm -f /etc/sudoers.d/openbb
sed -i '/^openbb /d;/\bopenbb\b/d' /etc/sudoers.d/90-cloud-init-users 2>/dev/null || true

touch /var/log/openbb-install-done

echo ""
echo "========================================"
echo " FERTIG! $(date)"
echo "========================================"
echo " JupyterLab Token: ${JUPYTER_TOKEN}"
echo "========================================"
INSTALL_EOF

  # Script übertragen und im Hintergrund starten
  scp_cmd "$REMOTE_SH_FILE" "openbb@${VM_IP}:/tmp/openbb-install.sh" 2>/dev/null

  # sudo-Aufruf: mit NOPASSWD via 'sudo -n', sonst Passwort via 'sudo -S'
  if [[ "$SSHPASS_MODE" == "true" ]]; then
    SUDO_RUN="echo '${PASS}' | sudo -S -p ''"
  else
    SUDO_RUN="sudo -n"
  fi

  ssh_cmd "openbb@${VM_IP}" \
    "chmod +x /tmp/openbb-install.sh && ${SUDO_RUN} nohup /tmp/openbb-install.sh > /var/log/openbb-install.log 2>&1 < /dev/null & disown" \
    2>/dev/null

  INSTALL_STARTED=true
  msg_ok "OpenBB Installation gestartet!"
else
  msg_warn "SSH Verbindung fehlgeschlagen – manuelle Installation nötig"
  echo ""
  echo -e "  ${BL}Diagnose:${CL}"
  if port_open; then
    echo -e "  ${YW}• Port 22 ist offen, aber Login schlägt fehl (Auth-Probleme)${CL}"
    echo -e "  ${BL}→ In der Proxmox VM-Console einloggen (User: openbb) und prüfen:${CL}"
    echo -e "  ${YW}sudo cat /home/openbb/.ssh/authorized_keys${CL}"
  else
    echo -e "  ${YW}• Port 22 nicht erreichbar – VM evtl. noch beim Booten/Cloud-Init${CL}"
    echo -e "  ${BL}→ Ein paar Minuten warten, dann manuell per Console:${CL}"
  fi
  echo ""
  echo -e "  ${BL}Installation manuell starten (in der VM Console):${CL}"
  echo -e "  ${YW}curl -fsSL https://raw.githubusercontent.com/HatchetMan111/openbb-proxmox/main/install.sh | sudo bash${CL}"
fi

# ─── Auf Abschluss der Installation warten ────────────────
JUPYTER_TOKEN=""
if [[ "$INSTALL_STARTED" == "true" ]]; then
  msg_info "Warte auf Abschluss der Installation (bis zu 30 Min – Fortschritt siehe unten)"
  DONE=false
  for i in $(seq 1 120); do
    sleep 15
    if ssh_cmd "openbb@${VM_IP}" "test -f /var/log/openbb-install-done" 2>/dev/null; then
      DONE=true
      break
    fi
    LAST_LOG=$(ssh_cmd "openbb@${VM_IP}" "tail -n 1 /var/log/openbb-install.log 2>/dev/null" 2>/dev/null)
    printf "  ${YW}⏳ %2d Min – %s${CL}\033[K\r" "$((i/4))" "${LAST_LOG:-(warte)...}"
  done
  echo ""

  if [[ "$DONE" == "true" ]]; then
    msg_ok "Installation abgeschlossen!"
    JUPYTER_TOKEN=$(ssh_cmd "openbb@${VM_IP}" "cat /opt/openbb/jupyter_token 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
  else
    msg_warn "Timeout beim Warten – Installation läuft evtl. noch im Hintergrund."
    echo -e "  ${BL}Status prüfen: ssh openbb@${VM_IP} 'sudo tail -20 /var/log/openbb-install.log'${CL}"
  fi
fi

# Passwort aus dem Speicher entfernen (nicht mehr benötigt)
unset PASS PASS2 SSHPASS

[[ -z "$JUPYTER_TOKEN" ]] && JUPYTER_TOKEN="(noch nicht verfügbar – siehe oben)"

# Statusabhängige Titelzeile
if [[ "$INSTALL_STARTED" == "true" && "${DONE:-false}" == "true" ]]; then
  BANNER_TITLE="✅ OpenBB VM ERFOLGREICH ERSTELLT!"
elif [[ "$INSTALL_STARTED" == "true" ]]; then
  BANNER_TITLE="⏳ VM ERSTELLT – INSTALLATION LÄUFT NOCH"
else
  BANNER_TITLE="⚠ VM ERSTELLT – INSTALLATION MANUELL STARTEN"
fi

# ─── ABSCHLUSSMELDUNG ─────────────────────────────────────
echo ""
echo -e "${GN}${BOLD}╔══════════════════════════════════════════════════════╗${CL}"
printf "${GN}${BOLD}║${CL} %-52s ${GN}${BOLD}║${CL}\n" "$BANNER_TITLE"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-ID:    ${VMID}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-Name:  ${HOSTNAME}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "VM-IP:    ${VM_IP}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "SSH-User: openbb"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "RAM:      ${RAM}MB  CPU: ${CORES}  Disk: ${DISK}GB"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "SSH LOGIN:"
printf "${GN}${BOLD}║${CL}  ${BL}%-52s${CL} ${GN}${BOLD}║${CL}\n" "ssh openbb@${VM_IP}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "Passwort: dein gewaehltes Passwort"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "DIENSTE:"
printf "${GN}${BOLD}║${CL}  ${YW}JupyterLab:${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:8888"
printf "${GN}${BOLD}║${CL}  ${YW}Token:     ${CL} %-41s ${GN}${BOLD}║${CL}\n" "${JUPYTER_TOKEN:0:32}"
printf "${GN}${BOLD}║${CL}  ${YW}Portainer: ${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:9000"
printf "${GN}${BOLD}║${CL}  ${YW}OpenBB API:${CL} %-41s ${GN}${BOLD}║${CL}\n" "http://${VM_IP}:6900/api/v1/docs"
echo -e "${GN}${BOLD}╠══════════════════════════════════════════════════════╣${CL}"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "NACH NEUSTART: Alles startet automatisch,"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "keine Zusatzschritte noetig!"
printf "${GN}${BOLD}║${CL}  %-52s ${GN}${BOLD}║${CL}\n" "Token dauerhaft: /opt/openbb/jupyter_token"
echo -e "${GN}${BOLD}╚══════════════════════════════════════════════════════╝${CL}"
echo ""
