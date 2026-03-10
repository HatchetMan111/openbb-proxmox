# 🖥️ OpenBB Terminal – Proxmox Helper Script

Bloomberg-Alternative für dein Homelab. Ein Befehl, fertig.

---

## 🚀 Installation (1 Befehl in der Proxmox Shell)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/openbb-proxmox/main/setup.sh)"
```

> Diesen Befehl in der **Proxmox Shell** eingeben (nicht SSH zur VM!).
> Proxmox Webinterface → dein Node → **Shell**

---

## Was wird installiert?

| Service | Port | Beschreibung |
|---|---|---|
| **JupyterLab** | 8888 | Haupt-Interface für OpenBB Analysen |
| **OpenBB API** | 6900 | REST API + Swagger Dokumentation |
| **Portainer** | 9000 | Docker Web-GUI |

**Kostenlose Datenquellen:**
- 📈 Yahoo Finance – Aktien, ETFs, DAX, Crypto
- 🏛️ FRED – US-Makrodaten, CPI, Zinsen
- 🪙 Binance / CoinGecko – Kryptowährungen

---

## Schritt-für-Schritt (für Anfänger)

### 1. Proxmox Shell öffnen
- Browser: `https://DEINE-PROXMOX-IP:8006`
- Links im Baum: deinen **Node** (z.B. `pve`) anklicken
- Oben rechts: **Shell** klicken

### 2. Script ausführen
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/DEIN_GITHUB/openbb-proxmox/main/setup.sh)"
```

### 3. Dem Installer folgen
Das Script führt dich durch alles mit einfachen Dialogen:
- Setup-Typ wählen (Standard empfohlen)
- Passwort setzen
- Storage wählen
- Fertig ✔

### 4. Warten (~5 Minuten)
Die VM bootet und installiert OpenBB automatisch.

### 5. JupyterLab öffnen
```
http://VM-IP:8888
Token: openbb_local
```

---

## Installation verfolgen

```bash
# SSH in die VM
ssh openbb@VM-IP

# Installationslog live verfolgen
sudo tail -f /var/log/openbb-install.log
```

---

## Erstes OpenBB Notebook ausführen

1. JupyterLab öffnen: `http://VM-IP:8888`
2. Token eingeben: `openbb_local`
3. Datei `Schnellstart.py` öffnen
4. Kernel: **Python 3** wählen
5. ▶ Run All klicken

---

## VM-Ressourcen (optimiert für 4-8 GB RAM)

| Ressource | Wert |
|---|---|
| RAM | 4 GB |
| CPU | 2 Kerne |
| Disk | 20 GB |
| OS | Ubuntu 22.04 LTS |

---

## Nützliche Befehle in der VM

```bash
# Status aller Container
docker ps

# Logs von OpenBB
docker logs openbb -f

# Logs von JupyterLab
docker logs openbb-jupyter -f

# Alle Container neustarten
cd /opt/openbb && docker compose restart

# Update auf neueste Version
cd /opt/openbb && docker compose pull && docker compose up -d
```

---

## Optionale kostenlose API Keys

Mehr Daten mit kostenlosen Registrierungen:

| Provider | Link | Was? |
|---|---|---|
| **FRED** | fred.stlouisfed.org/docs/api | US-Makrodaten |
| **Alpha Vantage** | alphavantage.co | 25 Calls/Tag gratis |
| **CoinGecko** | coingecko.com/en/api | Crypto Daten |

Keys eintragen in: `/root/.openbb_platform/user_settings.json`

---

## Systemanforderungen

- Proxmox VE 7.x oder 8.x
- Mind. 6 GB freier RAM auf dem Host
- Mind. 25 GB freier Speicher
- Internetverbindung für Downloads
