# Aurelio auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App: `https://github.com/LosaLosSantos/aurelio-finance` (Self-hosted Wealth-Management, FastAPI + React, SQLite)
> Dieser Ordner enthält Installer (`install/`) und systemd-Unit (`systemd/`). Der App-Code wird zur Installzeit per `git clone` aus dem Upstream geholt (GitHub-first, immer aktuell).

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AurelioFinanceProxmox/main/install/aurelio.sh)"
```

> Per Env-Override auf ein anderes Repo zeigen (ohne Script zu ändern):
> ```bash
> RAW_BASE=https://raw.githubusercontent.com/DEIN/REPO/main bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN/REPO/main/install/aurelio.sh)"
> ```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=12 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/AurelioFinanceProxmox/main/install/aurelio.sh)"
bash aurelio.sh --ctid 150 --cores 2 --memory 4096 --disk 12 --bridge vmbr0 --storage local-lvm --ref main
bash aurelio.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/aurelio-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `aurelio` |
| Zweck | Self-hosted Wealth-Management (Net Worth, Portfolio, Cashflow, KI-Chat optional), 100% lokal lauffähig |
| Tech-Stack | Python 3.12+ / FastAPI + Uvicorn (`:8000`), React/Vite-Frontend (wird im Container gebaut nach `frontend/dist`), SQLite `backend/data.db`, `uv` + Node 22 |
| GitHub-Repo (Upstream) | `https://github.com/LosaLosSantos/aurelio-finance` |
| Web UI | `http://<LXC-IP>:8000` (App), Health `GET /api/health` |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 12 GB Disk (npm-Build + venv brauchen Luft) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `aurelio` (`onboot: 1`, unprivilegiert),
3. installiert im Container OS-Basis + Node 22 + `uv`, legt User `aurelio` an, klont/pullt Upstream nach `/opt/aurelio` (`--ref` wählbar), baut Frontend (`npm ci + npm run build`), installiert Backend (`uv sync`), legt `backend/.env` aus `.env.example` an (Key optional), schreibt `aurelio.service`, `systemctl enable --now aurelio`,
4. verifiziert `systemctl is-active aurelio` + HTTP auf `localhost:8000/api/health` und gibt die finale URL + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active aurelio = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:8000/api/health).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Aurelio – Self-hosted Wealth-Management mit Web-UI
  Upstream     : https://github.com/LosaLosSantos/aurelio-finance @ main
  Container    : CT 100 (Hostname: aurelio, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 12 GB Disk
  Web UI       : http://192.168.1.100:8000
  Health       : http://192.168.1.100:8000/api/health
  ...
  Log          : /tmp/aurelio-install-2026-....log
══════════════════════════════════════════════════════════
```

## KI-Chat (optional, OpenRouter-Key)

Der Installer fragt den Key während der Installation ab (maskiert, 120s Timeout, Enter = überspringen). Er landet per Datei-Übergabe in `/opt/aurelio/backend/.env` – nie im Log, nie in der Ausgabe. Alternativen für Automation:

```bash
OPENROUTER_API_KEY=sk-or-... bash aurelio.sh --ctid 100   # per Env
bash aurelio.sh --ctid 100 --openrouter-key sk-or-...     # per Flag
bash aurelio.sh --ctid 100 --no-input                     # nie nachfragen
```

Später nachtragen: Key in `/opt/aurelio/backend/.env` als `OPENROUTER_API_KEY=...` setzen (Datei gehört `aurelio`, Modus 640), dann `pct exec <CT> -- systemctl restart aurelio`. Key unter `https://openrouter.ai/keys` erstellen.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active aurelio
curl -fs http://<LXC-IP>:8000/api/health >/dev/null && echo WEB_UI_OK
curl -fs http://<LXC-IP>:8000/ >/dev/null && echo FRONTEND_OK
```

## Update / Deinstall

```bash
bash aurelio.sh --ctid 100            # Update: idempotent (git pull + rebuild + restart)
bash aurelio.sh --ctid 100 --ref v1.2.3  # gezielter Upstream-Ref
pct stop 100 && pct destroy 100       # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/aurelio-install-*.log`.
- `bash aurelio.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status aurelio --no-pager`, `journalctl -u aurelio -n 100`.
- Häufig: `frontend/dist` fehlt → `npm run build`-Log im Install-Log suchen; `.venv` fehlt → `uv sync`-Fehler (Netz/Disk) prüfen.

## Dateien

- `install/aurelio.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/aurelio.service` – Unit (`:8000`, `After=network-online.target`, `Restart=always`).
- `docs/superpowers/specs/2026-10-12-aurelio-design.md` – Design-Spec.
