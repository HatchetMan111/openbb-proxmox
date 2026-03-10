#!/usr/bin/env bash
# ============================================================
#  OpenBB Terminal – Proxmox Helper Script
#  Erstellt eine Ubuntu 22.04 VM & installiert OpenBB
#
#  AUSFÜHREN IN DER PROXMOX SHELL:
#  bash -c "$(curl -fsSL https://raw.githubusercontent.com/DEIN_REPO/openbb-proxmox/main/setup.sh)"
# ============================================================

# ─── Farben & Symbole (wie community-scripts) ─────────────
YW='\033[33m'; GN='\033[1;92m'; RD='\033[01;31m'
CL='\033[m';   BL='\033[36m';   BGN='\033[4;92m'
BOLD='\033[1m'; DGN='\033[32m'
CM="${GN}✔${CL}"; CROSS="${RD}✘${CL}"; INFO="${BL}ℹ${CL}"

msg_info()    { echo -e "\n ${INFO}  ${YW}${1}${CL}"; }
msg_ok()      { echo -e " ${CM}  ${GN}${1}${CL}"; }
msg_error()   { echo -e " ${CROSS}  ${RD}${1}${CL}\n"; exit 1; }

# ─── Root auf Proxmox prüfen ──────────────────────────────
if [ "$EUID" -ne 0 ]; then
  msg_error "Bitte als root in der Proxmox Shell ausführen!"
fi
if ! command -v pvesh &>/dev/null; then
  msg_error "Dieses Script muss auf dem Proxmox HOST ausgeführt werden!"
fi

# ─── Banner ───────────────────────────────────────────────
clear
cat << BANNER
${BL}
  ██████╗ ██████╗ ███████╗███╗   ██╗██████╗ ██████╗
 ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔══██╗██╔══██╗
 ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██████╔╝██████╔╝
 ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██╔══██╗██╔══██╗
 ╚██████╔╝██║     ███████╗██║ ╚████║██████╔╝██████╔╝
  ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝╚═════╝ ╚═════╝
${CL}${BOLD}      Bloomberg-Alternative für Proxmox Homelab${CL}
${DGN}      Ubuntu 22.04 VM + Docker + JupyterLab${CL}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BANNER

# ─── Standardwerte ────────────────────────────────────────
VMID=""
HOSTNAME="openbb"
CORES="2"
RAM="4096"
DISK="20"
BRIDGE="vmbr0"
STORAGE=""
VM_IP=""
VM_GW=""
VM_USER="openbb"
VM_PASS=""
SETUP_TYPE=""   # "default" oder "advanced"

# ─── Whiptail Hilfsfunktionen ─────────────────────────────
w_info()  { whiptail --backtitle "OpenBB Proxmox Installer" --title "$1" --msgbox "$2" 10 60 3>&1 1>&2 2>&3; }
w_yesno() { whiptail --backtitle "OpenBB Proxmox Installer" --title "$1" --yesno "$2" 10 60 3>&1 1>&2 2>&3; }

# ─── Willkommensscreen ────────────────────────────────────
if ! whiptail --backtitle "OpenBB Proxmox Installer" \
  --title "🚀 OpenBB Terminal Installer" \
  --yesno \
"Willkommen beim OpenBB Proxmox Installer!

Dieses Script erstellt automatisch:
  ✔  Ubuntu 22.04 VM (2 CPU, 4GB RAM, 20GB Disk)
  ✔  Docker + Docker Compose
  ✔  OpenBB Platform API
  ✔  JupyterLab (Haupt-Interface)
  ✔  Portainer (Docker Web-GUI)

Datenquellen (kostenlos):
  📈 Yahoo Finance, FRED, Binance, CoinGecko

Möchtest du jetzt mit der Installation beginnen?" \
  18 65; then
  echo -e "\n${YW}Installation abgebrochen.${CL}\n"
  exit 0
fi

# ─── Einfach oder Erweitert ───────────────────────────────
SETUP_TYPE=$(whiptail --backtitle "OpenBB Proxmox Installer" \
  --title "Setup-Typ wählen" \
  --radiolist "Wähle den Setup-Typ:" 12 60 2 \
  "default"   "Standardwerte verwenden (empfohlen)" ON \
  "advanced"  "Erweitert: VM selbst konfigurieren"   OFF \
  3>&1 1>&2 2>&3) || { echo "Abgebrochen"; exit 0; }

# ─── Nächste freie VM-ID finden ───────────────────────────
VMID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")

# ─── Erweiterte Konfiguration ─────────────────────────────
if [ "$SETUP_TYPE" = "advanced" ]; then

  VMID=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "VM ID" --inputbox \
    "VM ID eingeben (Standard: ${VMID}):" 8 50 "$VMID" \
    3>&1 1>&2 2>&3) || exit 0

  HOSTNAME=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "Hostname" --inputbox \
    "Hostname der VM:" 8 50 "openbb" \
    3>&1 1>&2 2>&3) || exit 0

  CORES=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "CPU Kerne" \
    --radiolist "Anzahl CPU-Kerne:" 12 50 3 \
    "2" "2 Kerne (Minimum)" ON \
    "4" "4 Kerne (empfohlen)" OFF \
    "6" "6 Kerne (Performance)" OFF \
    3>&1 1>&2 2>&3) || exit 0

  RAM=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "RAM" \
    --radiolist "Arbeitsspeicher (MB):" 12 50 3 \
    "4096" "4 GB (Minimum für 4-8GB System)" ON \
    "6144" "6 GB (empfohlen)" OFF \
    "8192" "8 GB (Performance)" OFF \
    3>&1 1>&2 2>&3) || exit 0

  DISK=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "Festplatte" --inputbox \
    "Disk-Größe in GB:" 8 50 "20" \
    3>&1 1>&2 2>&3) || exit 0

  BRIDGE=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "Netzwerk Bridge" --inputbox \
    "Netzwerk Bridge (Standard: vmbr0):" 8 50 "vmbr0" \
    3>&1 1>&2 2>&3) || exit 0

fi

# ─── Passwort abfragen (immer) ────────────────────────────
while true; do
  VM_PASS=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "VM Passwort" --passwordbox \
    "Passwort für den openbb-User in der VM:\n(mind. 6 Zeichen)" 10 55 \
    3>&1 1>&2 2>&3) || exit 0
  VM_PASS2=$(whiptail --backtitle "OpenBB Proxmox Installer" \
    --title "VM Passwort bestätigen" --passwordbox \
    "Passwort nochmal eingeben:" 8 55 \
    3>&1 1>&2 2>&3) || exit 0
  if [ "$VM_PASS" = "$VM_PASS2" ] && [ ${#VM_PASS} -ge 6 ]; then
    break
  elif [ ${#VM_PASS} -lt 6 ]; then
    whiptail --backtitle "OpenBB Proxmox Installer" --title "Fehler" \
      --msgbox "Passwort muss mindestens 6 Zeichen haben!" 8 45
  else
    whiptail --backtitle "OpenBB Proxmox Installer" --title "Fehler" \
      --msgbox "Passwörter stimmen nicht überein!" 8 45
  fi
done

# ─── Storage ermitteln ────────────────────────────────────
msg_info "Verfügbare Storages werden gesucht"
STORAGES=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1" "$1" OFF"}' | head -5)
if [ -z "$STORAGES" ]; then
  STORAGES="local local OFF"
fi
STORAGE=$(whiptail --backtitle "OpenBB Proxmox Installer" \
  --title "Storage wählen" \
  --radiolist "Wo soll die VM-Disk gespeichert werden?" 14 55 5 \
  $STORAGES \
  3>&1 1>&2 2>&3) || exit 0
msg_ok "Storage gewählt: $STORAGE"

# ─── ISO herunterladen ────────────────────────────────────
ISO_NAME="ubuntu-22.04-live-server-amd64.iso"
ISO_URL="https://releases.ubuntu.com/jammy/ubuntu-22.04.5-live-server-amd64.iso"
ISO_PATH="/var/lib/vz/template/iso"

msg_info "Ubuntu 22.04 ISO wird geprüft"
mkdir -p "$ISO_PATH"
if [ ! -f "$ISO_PATH/$ISO_NAME" ]; then
  msg_info "ISO wird heruntergeladen (~1.5 GB, bitte warten)"
  wget -q --show-progress -O "$ISO_PATH/$ISO_NAME" "$ISO_URL" || \
    msg_error "ISO-Download fehlgeschlagen! Internetverbindung prüfen."
  msg_ok "ISO heruntergeladen"
else
  msg_ok "ISO bereits vorhanden"
fi

# ─── Cloud-Init Image (Alternative ohne manuelle Installation) ─
# Ubuntu Cloud Image ist viel kleiner und braucht keine manuelle Installation
CLOUD_IMG="jammy-server-cloudimg-amd64.img"
CLOUD_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
msg_info "Ubuntu Cloud Image wird heruntergeladen (schnellere VM-Erstellung)"
if [ ! -f "/tmp/$CLOUD_IMG" ]; then
  wget -q --show-progress -O "/tmp/$CLOUD_IMG" "$CLOUD_URL" || \
    msg_error "Cloud Image Download fehlgeschlagen!"
fi
msg_ok "Cloud Image bereit"

# ─── Snippet-Verzeichnis für Cloud-Init ───────────────────
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# ─── Cloud-Init User-Data erstellen ───────────────────────
msg_info "Cloud-Init Konfiguration wird erstellt"
cat > "$SNIPPET_DIR/openbb-cloud-init.yml" << CLOUDINIT
#cloud-config
hostname: ${HOSTNAME}
timezone: Europe/Berlin
locale: de_DE.UTF-8

users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: "${VM_PASS}"
  - name: root
    lock_passwd: false
    plain_text_passwd: "${VM_PASS}"

ssh_pwauth: true
disable_root: false

package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - git
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent --now
  - curl -fsSL https://raw.githubusercontent.com/DEIN_REPO/openbb-proxmox/main/install.sh | bash > /var/log/openbb-install.log 2>&1

final_message: "OpenBB Installation abgeschlossen nach \$UPTIME Sekunden"
CLOUDINIT
msg_ok "Cloud-Init Konfiguration erstellt"

# ─── VM erstellen ─────────────────────────────────────────
msg_info "VM ${VMID} wird erstellt"

# VM anlegen
qm create "$VMID" \
  --name "$HOSTNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu host \
  --net0 virtio,bridge="$BRIDGE" \
  --ostype l26 \
  --agent enabled=1 \
  --tablet 0 \
  --serial0 socket \
  --vga serial0 \
  --scsihw virtio-scsi-pci \
  --boot order=scsi0 \
  --bootdisk scsi0 \
  2>/dev/null

# Disk aus Cloud Image erstellen und importieren
qm importdisk "$VMID" "/tmp/$CLOUD_IMG" "$STORAGE" -format qcow2 2>/dev/null | tail -1
qm set "$VMID" --scsi0 "$STORAGE:vm-${VMID}-disk-0,size=${DISK}G" 2>/dev/null

# Cloud-Init Drive hinzufügen
qm set "$VMID" --ide2 "$STORAGE:cloudinit" 2>/dev/null
qm set "$VMID" --cicustom "user=local:snippets/openbb-cloud-init.yml" 2>/dev/null
qm set "$VMID" --ciupgrade 1 2>/dev/null

# DHCP für IP
qm set "$VMID" --ipconfig0 ip=dhcp 2>/dev/null

msg_ok "VM ${VMID} erstellt"

# ─── Disk vergrößern ──────────────────────────────────────
msg_info "Disk auf ${DISK}GB erweitern"
qm resize "$VMID" scsi0 "${DISK}G" 2>/dev/null || true
msg_ok "Disk erweitert"

# ─── VM starten ───────────────────────────────────────────
msg_info "VM ${VMID} wird gestartet"
qm start "$VMID"
msg_ok "VM gestartet"

# ─── Auf IP-Adresse warten ────────────────────────────────
msg_info "Warte auf VM-IP (kann 60-90 Sek. dauern)"
for i in {1..30}; do
  sleep 5
  VM_IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
    python3 -c "
import sys,json
data=json.load(sys.stdin)
for iface in data:
  if iface.get('name') not in ['lo']:
    for addr in iface.get('ip-addresses',[]):
      if addr.get('ip-address-type')=='ipv4':
        print(addr['ip-address'])
        break
" 2>/dev/null | head -1)
  if [ -n "$VM_IP" ]; then
    break
  fi
  echo -ne "   ${YW}Warte... (${i}/30)${CL}\r"
done

if [ -z "$VM_IP" ]; then
  VM_IP="(IP noch nicht bekannt – in Proxmox unter VM > Summary nachschauen)"
fi
msg_ok "VM erreichbar unter: ${VM_IP}"

# ─── Abschlussmeldung ─────────────────────────────────────
whiptail --backtitle "OpenBB Proxmox Installer" \
  --title "✅ Installation erfolgreich!" \
  --msgbox \
"OpenBB VM wurde erfolgreich erstellt!

VM Details:
  ID:        ${VMID}
  Name:      ${HOSTNAME}
  IP:        ${VM_IP}
  User:      ${VM_USER}
  RAM:       ${RAM} MB
  CPU:       ${CORES} Kerne
  Disk:      ${DISK} GB

OpenBB wird jetzt im Hintergrund installiert.
Das dauert ca. 3-5 Minuten nach dem VM-Start.

Danach erreichbar unter:
  JupyterLab:  http://${VM_IP}:8888
               Token: openbb_local
  OpenBB API:  http://${VM_IP}:6900/api/v1/docs
  Portainer:   http://${VM_IP}:9000

SSH Zugang:
  ssh ${VM_USER}@${VM_IP}

Installationslog in der VM:
  sudo tail -f /var/log/openbb-install.log" \
  28 65

echo ""
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e "${GN} ✔  OpenBB VM ${VMID} läuft!${CL}"
echo -e "${GN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
echo -e " ${YW}JupyterLab:${CL}  http://${VM_IP}:8888  (Token: openbb_local)"
echo -e " ${YW}OpenBB API:${CL}  http://${VM_IP}:6900/api/v1/docs"
echo -e " ${YW}Portainer:${CL}   http://${VM_IP}:9000"
echo -e " ${YW}SSH:${CL}         ssh ${VM_USER}@${VM_IP}"
echo ""
echo -e " ${INFO} Log verfolgen: ${BL}ssh ${VM_USER}@${VM_IP} 'tail -f /var/log/openbb-install.log'${CL}"
echo ""
