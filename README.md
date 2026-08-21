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
| **Portainer** | 9000 (HTTP) / 9443 (HTTPS) | Docker Web-GUI |

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
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/openbb-proxmox/main/setup.sh)"
```

### 3. Dem Installer folgen
Das Script führt dich durch alles mit einfachen Dialogen:
- Setup-Typ wählen (Standard empfohlen)
- Passwort setzen
- Storage wählen
- Fertig ✔

### 4. Warten (15–60 Min je nach Internetleitung)
Die VM bootet und installiert alles automatisch. Dabei werden mehrere GB
Docker-Images geladen (OpenBB ~1-2 GB, Jupyter ~3 GB) – das dauert.

Der Installer zeigt **live an, in welcher Phase** er ist:

| Phase | Erreichbar |
|---|---|
| Portainer wird gestartet | `http://VM-IP:9000` nach ~3–5 Min |
| OpenBB Image wird geladen | – |
| Jupyter-Image wird gebaut (längster Schritt) | – |
| Fertig | Alle Dienste + IP + Token werden angezeigt |

Am Ende zeigt das Script die **VM-IP**, alle Zugangs-URLs, den Jupyter-Token
und eine Erreichbarkeitsprüfung aller Ports an.

### 5. JupyterLab öffnen
```
http://VM-IP:8888
Token: wird dir am Ende angezeigt
       (dauerhaft gespeichert in der VM unter /opt/openbb/jupyter_token)
```

---

## 🔄 Nach einem Neustart

Es sind **keine Zusatzschritte notwendig**:

- Die VM startet automatisch (`onboot`)
- Alle Container starten automatisch (systemd + Docker restart-policy)
- OpenBB ist im Jupyter-Image fest eingebaut → **sofort bereit**, keine erneute Installation

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
2. Token eingeben (siehe Installer-Ausgabe bzw. `/opt/openbb/jupyter_token`)
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

# Jupyter-Token anzeigen
cat /opt/openbb/jupyter_token

# Alle Container neustarten
cd /opt/openbb && docker compose restart

# Update auf neueste Version
cd /opt/openbb && docker compose pull && docker compose up -d --build
```

---

## Optionale kostenlose API Keys

Mehr Daten mit kostenlosen Registrierungen:

| Provider | Link | Was? |
|---|---|---|
| **FRED** | fred.stlouisfed.org/docs/api | US-Makrodaten |
| **Alpha Vantage** | alphavantage.co | 25 Calls/Tag gratis |
| **CoinGecko** | coingecko.com/en/api | Crypto Daten |

Keys eintragen – je nachdem wo du sie nutzt:
- **JupyterLab (empfohlen):** in der VM unter `/opt/openbb/jupyter-home/user_settings.json`
  ```json
  { "credentials": { "fred": { "api_key": "DEIN_KEY" } } }
  ```
- **OpenBB API Container:** `/root/.openbb_platform/user_settings.json`

Danach den Container neu starten: `cd /opt/openbb && docker compose restart`

---

## 🔒 Sicherheitshinweise

- **Root-SSH-Login** ist nur per SSH-Key möglich (`prohibit-password`)
- **Jupyter-Token** wird bei jeder Installation zufällig generiert und dauerhaft gespeichert
- Das Setup richtet nur für die Automatik-Installation temporär passwortloses Sudo ein und **entfernt es danach automatisch**
- ⚠️ Alle Dienste sind im LAN ohne HTTPS erreichbar – für den Betrieb außerhalb des eigenen Netzwerks einen Reverse Proxy mit TLS vorschalten
- ⚠️ Portainer beim ersten Aufruf sofort absichern (Admin-Account erstellen, innerhalb weniger Minuten!)

---

## 🛠️ Problembehebung

**SSH-Verbindung schlägt fehl / Dienste nicht erreichbar?**
- Der **erste Boot** kann einige Minuten dauern (Cloud-Init, Disk-Vergrößerung) – einfach warten
- Installer zeigt an, ob Port 22 zu ist (VM bootet noch) oder offen (Auth-Thema)
- Der SSH-Key wird **doppelt** installiert: direkt im Image *und* per Cloud-Init – sollte einer der Wege fehlschlagen, greift der andere
- Notfall-Zugang: Proxmox Webinterface → VM → **Console** (User `openbb`, dein Passwort)
- Installation manuell in der VM-Console starten:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/HatchetMan111/openbb-proxmox/main/install.sh | sudo bash
  ```

**Jupyter-Token vergessen?**
```bash
ssh openbb@VM-IP 'cat /opt/openbb/jupyter_token'
```

---

## Systemanforderungen

- Proxmox VE 7.x oder 8.x
- Mind. 6 GB freier RAM auf dem Host
- Mind. 25 GB freier Speicher
- Internetverbindung für Downloads
