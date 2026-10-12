#!/usr/bin/env bash
#
# Aurelio Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Aurelio – Self-hosted Wealth-Management (Net Worth, Portfolio, Chat)
# Upstream: https://github.com/LosaLosSantos/aurelio-finance
# Stack:    Python/FastAPI + Uvicorn (:8000, serviert frontend/dist selbst),
#           React/Vite-Frontend (Build im Container), SQLite backend/data.db,
#           ohne Docker, ohne Cloud-Zwang (OpenRouter-Key optional).
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AurelioFinanceProxmox/main/install/aurelio.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AurelioFinanceProxmox/main/install/aurelio.sh)"
#   bash aurelio.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --bridge vmbr0 --debug
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="aurelio"                                     # Container-Hostname + Service-Name
APP_PORT="8000"                                   # Web-UI + API
AURELIO_REPO="${AURELIO_REPO:-https://github.com/LosaLosSantos/aurelio-finance}"
AURELIO_REF="${AURELIO_REF:-main}"                # Branch/Tag/Commit des Upstreams
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/HatchetMan111/AurelioFinanceProxmox}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/HatchetMan111/AurelioFinanceProxmox/main}"
SERVICE_URL="${SERVICE_URL:-$RAW_BASE/systemd/aurelio.service}"

DEFAULT_CORES="2"                                 # vCPU (Build + Uvicorn reichen 2)
DEFAULT_RAM="4096"                                # RAM in MB (npm-Build + uv brauchen Luft; 2048 Minimum)
DEFAULT_SWAP="1024"                               # Swap (MB)
DEFAULT_DISK="12"                                 # Disk in GB (OS + node_modules + .venv + data.db-Reserve)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                    # Storage fuer CT-Templates
DEFAULT_OS="debian-12-standard"                   # Template-Familie
UNPRIVILEGED="1"                                  # 1 = unprivilegiert (reicht hier)
FEATURES="nesting=1"                              # nesting fuer Build-Robustheit

APP_USER="aurelio"
APP_DIR="/opt/aurelio"
BACKEND_DIR="/opt/aurelio/backend"
VENV_PYTHON="/opt/aurelio/backend/.venv/bin/python"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=12 ./aurelio.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"
REF_ARG="${REF:-$AURELIO_REF}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash aurelio.sh [OPTIONEN]
  CT_ID=150 bash aurelio.sh
  bash -c "\$(wget -qLO - ${RAW_BASE}/install/aurelio.sh)"

Optionen:
  --ctid ID            Container-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --ref REF            Upstream-Ref (Branch/Tag/Commit, Default: ${AURELIO_REF})
  --password PW        Root-Passwort (Default: zufaellig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container uebernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG" UPSTREAM_REF="$REF_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --ref) UPSTREAM_REF="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v pct >/dev/null || { msg_error "pct nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --ctid gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie CT-ID: $CT_ID"
fi

# RootFS-Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content rootdir | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein RootFS-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Template-Store: $TEMPLATE_STORE | Bridge: $BRIDGE"
msg_info "Upstream: $AURELIO_REPO @ $UPSTREAM_REF"

# ---------------------------------------------------------------------------
# 2. Template sicherstellen (neuestes debian-12-standard)
# ---------------------------------------------------------------------------
msg_info "Pruefe LXC-Template ..."
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Templates."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
# Hinweis: Proxmox liefert Templates heute als .tar.zst (nicht nur .tar.gz/.tar.xz).
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template – suche neuestes Debian-Standard-Template als Fallback ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden. Verfuegbare System-Templates:"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell pruefen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -q "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template bereit: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# ---------------------------------------------------------------------------
# 3. Container erstellen (idempotent: existiert die ID, wird aktualisiert)
# ---------------------------------------------------------------------------
if pct status "$CT_ID" >/dev/null 2>&1; then
  msg_warn "CT $CT_ID existiert – ueberspringe Erstellung (Update-Modus)."
else
  [[ -z "$PASSWORD_ARG" ]] && PASSWORD_ARG="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  msg_info "Erstelle CT $CT_ID ($HOSTNAME_ARG): $CORES vCPU / $RAM MB / ${DISK}G ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE_ARG}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 0 \
    --password "$PASSWORD_ARG"
  msg_ok "CT $CT_ID erstellt (unprivilegiert, nesting, onboot=1)."
fi

if [[ -n "$SSH_KEY_ARG" ]]; then
  [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
  pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null \
    || { pct exec "$CT_ID" -- mkdir -p /root/.ssh; pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys; }
fi

pct start "$CT_ID" 2>/dev/null || true
msg_info "Warte auf Container-Netz ..."
CT_IP=""
for i in $(seq 1 24); do
  sleep 5
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "${CT_IP:-}" ]] && break
done
[[ -n "${CT_IP:-}" ]] || { msg_error "Keine Container-IP (pct exec hostname -I). Netzwerk/Bridge pruefen."; exit 1; }
msg_ok "Container-IP: $CT_IP"

# ---------------------------------------------------------------------------
# 4. Aurelio im Container (via pct exec, idempotent)
# ---------------------------------------------------------------------------
msg_info "Installiere OS-Basis im Container ..."
# Hinweis: aeussere Single-Quotes – der Block laeuft dadurch 1:1 im Container,
# ohne dass die Host-Shell $ oder $(...) anfasst (kein Escaping noetig).
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git curl ca-certificates build-essential python3
  id aurelio >/dev/null 2>&1 || useradd -m -s /bin/bash aurelio
  mkdir -p /opt/aurelio
  chown -R aurelio:aurelio /opt/aurelio
'
# Hinweis: bewusst kein "| tail" hier – mit pipefail wuerde der trap sonst
# die Pipe (tail) statt des gescheiterten pct-Befehls melden. Voll-Output steht im Log.

msg_info "Installiere Node.js 22 + uv im Container (idempotent) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  # pct exec hat einen minimalen PATH (ohne /usr/local/bin) – explizit setzen,
  # sonst findet die Shell uv trotz erfolgreicher Installation nicht (Exit 127).
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin"
  export LANG=C.UTF-8 LC_ALL=C.UTF-8
  # Node 22 via NodeSource, falls fehlend oder < 22
  need_node=0
  if ! command -v node >/dev/null 2>&1; then need_node=1;
  else major="$(node -v 2>/dev/null | sed -E "s/^v([0-9]+).*/\\1/")";
    if [ "${major:-0}" -lt 22 ] 2>/dev/null; then need_node=1; fi
  fi
  if [ "$need_node" = 1 ]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi
  node -v; npm -v
  # uv via offizieller Installer, falls nirgends vorhanden
  # Kaputte Symlinks aus frueheren Laeufen (z. B. Selbst-Loop) aufraeumen
  if [ -L /usr/local/bin/uv ] && [ ! -x /usr/local/bin/uv ]; then
    rm -f /usr/local/bin/uv
  fi
  UV_BIN="$(command -v uv || true)"
  if [ -n "$UV_BIN" ]; then UV_BIN="$(readlink -f "$UV_BIN" 2>/dev/null || echo "$UV_BIN")"; fi
  if [ -z "$UV_BIN" ] || [ ! -x "$UV_BIN" ]; then
    if [ -x /root/.local/bin/uv ]; then UV_BIN=/root/.local/bin/uv;
    elif [ -x /usr/local/bin/uv ]; then UV_BIN=/usr/local/bin/uv;
    else
      curl -LsSf https://astral.sh/uv/install.sh | sh
      UV_BIN=/root/.local/bin/uv
    fi
  fi
  [ -x "$UV_BIN" ] || { echo "FEHLER: uv fehlt nach Installation ($UV_BIN nicht ausfuehrbar)" >&2; exit 1; }
  # Nur verlinken, wenn Ziel != Link (sonst Selbst-Loop mit ELOOP/Exit 126)
  if [ "$UV_BIN" != "/usr/local/bin/uv" ]; then
    ln -sf "$UV_BIN" /usr/local/bin/uv
  fi
  hash -r
  /usr/local/bin/uv --version
'

msg_info "Hole Aurelio-Code ($AURELIO_REPO @ $UPSTREAM_REF) ..."
pct exec "$CT_ID" -- bash -c "
  set -euo pipefail
  # Repo gehoert User aurelio, git laeuft hier als root -> Ausnahme setzen,
  # sonst 'fatal: detected dubious ownership' (Exit 128).
  git config --global --add safe.directory $APP_DIR || true
  if [ -d $APP_DIR/.git ]; then
    git -C $APP_DIR fetch --all --prune
    git -C $APP_DIR checkout $UPSTREAM_REF
    git -C $APP_DIR pull --ff-only || git -C $APP_DIR reset --hard origin/$UPSTREAM_REF || true
  else
    rm -rf $APP_DIR
    git clone --branch $UPSTREAM_REF --depth 1 $AURELIO_REPO $APP_DIR
  fi
  chown -R aurelio:aurelio $APP_DIR
  # Geteilter, fuer alle lesbarer Ort fuer uv-gemanagte Python-Interpreter
  # (default waere /root/.local/share/uv – fuer User aurelio unbetretbar -> 203/EXEC).
  mkdir -p /opt/uv-python
  chown -R aurelio:aurelio /opt/uv-python
  test -f $BACKEND_DIR/app/main.py || { echo \"FEHLER: $BACKEND_DIR/app/main.py fehlt (Upstream-Layout geaendert?)\" >&2; exit 1; }
  test -f $APP_DIR/frontend/package.json || { echo \"FEHLER: frontend/package.json fehlt\" >&2; exit 1; }
"

msg_info "Baue Frontend als User aurelio (npm ci + npm run build, dauert Minuten) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home/aurelio
  chown -R aurelio:aurelio /opt/aurelio
  su -s /bin/bash aurelio -c "cd /opt/aurelio/frontend && ([ -d node_modules ] || npm ci || npm install) && npm run build"
  test -d /opt/aurelio/frontend/dist || { echo "FEHLER: frontend/dist fehlt nach npm run build" >&2; exit 1; }
  chown -R aurelio:aurelio /opt/aurelio/frontend
'

msg_info "Installiere Backend-Deps als User aurelio (uv sync, holt Python 3.12 bei Bedarf) ..."
pct exec "$CT_ID" -- bash -c '
  set -euo pipefail
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/.local/bin"
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 HOME=/home/aurelio UV_PYTHON_INSTALL_DIR=/opt/uv-python
  mkdir -p /opt/uv-python
  chown -R aurelio:aurelio /opt/uv-python /opt/aurelio
  # .venv aus frueheren Root-Laeufen zeigt nach /root (fuer aurelio unlesbar,
  # Service stuerbe mit 203/EXEC) -> verwerfen, als aurelio neu aufbauen.
  if [ -d /opt/aurelio/backend/.venv ]; then
    owner="$(stat -c %U /opt/aurelio/backend/.venv)"
    target="$(readlink -f /opt/aurelio/backend/.venv/bin/python 2>/dev/null || true)"
    if [ "$owner" != "aurelio" ] || [[ "$target" == /root/* ]]; then
      echo "Bestehende .venv (Owner: $owner, Python: $target) wird als aurelio neu aufgebaut ..."
      rm -rf /opt/aurelio/backend/.venv
    fi
  fi
  su -s /bin/bash aurelio -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/aurelio UV_PYTHON_INSTALL_DIR=/opt/uv-python; cd /opt/aurelio/backend && /usr/local/bin/uv sync"
  test -x /opt/aurelio/backend/.venv/bin/python || { echo "FEHLER: .venv fehlt nach uv sync" >&2; exit 1; }
  su -s /bin/bash aurelio -c "cd /opt/aurelio/backend && .venv/bin/python -c \"import fastapi, uvicorn; print(fastapi.__version__)\""
  # .env aus Vorlage anlegen (Key optional, Datei bleibt sonst leer konfigurierbar)
  if [ ! -f /opt/aurelio/backend/.env ] && [ -f /opt/aurelio/backend/.env.example ]; then
    cp /opt/aurelio/backend/.env.example /opt/aurelio/backend/.env
  fi
  chown -R aurelio:aurelio /opt/aurelio
'

# Host-seitiger Guard: bricht laut ab, falls der App-Code fehlt.
pct exec "$CT_ID" -- test -f /opt/aurelio/backend/app/main.py \
  || { msg_error "App-Code unvollstaendig: /opt/aurelio/backend/app/main.py fehlt im Container."; exit 1; }
pct exec "$CT_ID" -- test -d /opt/aurelio/frontend/dist \
  || { msg_error "Frontend-Build unvollstaendig: /opt/aurelio/frontend/dist fehlt."; exit 1; }
msg_ok "App-Code ok (main.py + frontend/dist vorhanden)."

# systemd-Unit aus diesem Repo uebernehmen (faellt auf Inline-Unit zurueck)
if pct exec "$CT_ID" -- curl -fsSL -o /etc/systemd/system/aurelio.service "$SERVICE_URL" 2>/dev/null; then
  msg_ok "aurelio.service aus Repo uebernommen."
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  pct push "$CT_ID" /dev/stdin /etc/systemd/system/aurelio.service <<UNIT
[Unit]
Description=Aurelio – Self-hosted Wealth-Management mit Web-UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aurelio
Group=aurelio
WorkingDirectory=/opt/aurelio/backend
Environment=PYTHONUNBUFFERED=1
ExecStart=/opt/aurelio/backend/.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-access-log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi
pct exec "$CT_ID" -- systemctl daemon-reload
pct exec "$CT_ID" -- systemctl enable --now aurelio

# ---------------------------------------------------------------------------
# 5. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
pct exec "$CT_ID" -- systemctl is-active aurelio || { msg_error "systemd-Service aurelio ist nicht active."; pct exec "$CT_ID" -- systemctl status aurelio --no-pager || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active aurelio = active)."

msg_info "Warte auf Web UI (max. 3 Min) ..."
WEB_OK=0
for _ in $(seq 1 18); do
  if pct exec "$CT_ID" -- curl -fs -m 10 "http://localhost:${APP_PORT}/api/health" >/dev/null 2>&1; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/api/health."; pct exec "$CT_ID" -- systemctl status aurelio --no-pager || true; pct exec "$CT_ID" -- journalctl -u aurelio --no-pager -n 100 || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/api/health)."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Aurelio – Self-hosted Wealth-Management mit Web-UI"
echo "  Upstream     : $AURELIO_REPO @ $UPSTREAM_REF"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${CT_IP}:${APP_PORT}"
echo "  Health       : http://${CT_IP}:${APP_PORT}/api/health"
echo "  Hinweis      : Eigene Daten in backend/data.db; KI-Chat optional per OPENROUTER_API_KEY in /opt/aurelio/backend/.env"
echo "  Root-Passwort: ${PASSWORD_ARG:-<bestehender CT, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status aurelio  (im Container via: pct enter $CT_ID)"
echo "  Update       : Skript erneut laufen lassen (idempotent, ggf. --ref <Branch/Tag>)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Reboot-Test  : pct reboot $CT_ID && sleep 60 && curl -fs http://${CT_IP}:${APP_PORT}/api/health"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
