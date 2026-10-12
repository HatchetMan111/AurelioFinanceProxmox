# Aurelio auf Proxmox – Design (2026-10-12)

## Verstandnis (mit User abgestimmt)
- Ziel: Aurelio (`https://github.com/LosaLosSantos/aurelio-finance`) als LXC auf Proxmox, Einzeiler im Stil Proxmox VE Community Scripts.
- User-Vorgabe: selbständig entscheiden (LXC vs. VM), nächste freie ID, passender Hostname, lokal ohne Cloud-Zwang, systemd + reboot-sicher, Selbst-Verifikation, komplette Fehlerkette.
- Approval: 2026-10-12 „ja" zu LXC-Ansatz (2 vCPU / 4096 MB / 12 GB, Port 8000, Upstream-Main als Default).

## Fakten aus Upstream (gelesen, nicht geraten)
- `start.sh`: `frontend: npm install + npm run build` → `frontend/dist`; `backend: uv run uvicorn app.main:app --port 8000`; Demo via `DATABASE_URL=sqlite:///demo.db`.
- `backend/pyproject.toml`: `requires-python >=3.12`, deps u.a. `fastapi, uvicorn[standard], sqlalchemy, alembic, yfinance, mstarpy, openai, python-dotenv`, git-Dep `justetf-scraping`.
- `frontend/package.json`: `build = gen:types + tsc -b + vite build`, Node 22+ nötig.
- `backend/app/main.py`: `GET /api/health → {status:ok}`, Frontend wird von `/` aus `frontend/dist` serviert (wenn gebaut), Router unter `/api/*`.
- `backend/.env.example`: nur `OPENROUTER_API_KEY` nötig (optional, nur Chat/Analyse).

## Entscheidung: LXC (keine VM)
- Aurelio: kein GPU-, kein Kernel-, kein Docker-Bedarf; SQLite + Uvicorn + statisches dist. LXC reicht.
- VM-Option verworfen (schwerer, langsamer, kein Mehrwert). Prebuilt-Tarball verworfen (GitHub-first gefordert).

## Architektur
- Host-Script `install/aurelio.sh` läuft auf Proxmox-Host als root:
  1. Host/Tool-Check (`pct`, `pvesh`), CT-ID = nächste freie (`pvesh get /cluster/nextid`) außer `--ctid`.
  2. Storage-Auto (`local-lvm` bevorzugt, sonst erstes `rootdir`), neuestes `debian-12-standard`-Template (`.tar.gz|.tar.xz|.tar.zst`), `pveam update/download`.
  3. `pct create`: Hostname `aurelio`, 2 vCPU / 4096 MB / 12 GB (überschreibbar), `unprivileged 1`, `nesting=1`, `onboot 1`, DHCP `vmbr0`.
  4. `pct exec` Setup im Container (idempotent): apt (git/curl/ca-certs/build-essential), User `aurelio`, `/opt/aurelio` git clone/pull (`AURELIO_REPO`, `AURELIO_REF=main`), Node 22 via NodeSource, `uv` via offizieller Installer, `frontend: npm ci + npm run build`, `backend: uv sync`, `.env` aus `.env.example` falls fehlend, `chown`.
  5. systemd-Unit aus Repo (`systemd/aurelio.service`), Fallback Inline-Unit, `daemon-reload + enable --now`.
  6. Verifikation: `systemctl is-active aurelio` + bis 3 Min `curl localhost:8000/api/health` + `/`, dann finale URL `http://<LXC-IP>:8000`.
- Fehler: `set -euo pipefail`, `trap ERR` (Befehl+Zeile+Exit-Code+Log), Tee-Log `/tmp/aurelio-install-*.log`, `--debug` = `set -x`.

## Komponenten / Schnittstellen
- `install/aurelio.sh`: einzige Host-Schnittstelle; Env-Overrides `CT_ID/CORES/RAM/DISK`, Flags `--ctid/--hostname/--cores/--memory/--disk/--storage/--template-store/--bridge/--password/--ssh-key/--ref/--debug`.
- `systemd/aurelio.service`: `User=aurelio`, `WorkingDirectory=/opt/aurelio/backend`, `ExecStart=/opt/aurelio/backend/.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-access-log`, `Restart=always`, `After=network-online.target`.
- `README.md`: Einzeiler + Overrides + Reboot-Test + Update/Deinstall + Debugging.
- Keine App-Vendor-Kopie: Upstream wird zur Installzeit geclont (GitHub-first, immer aktuell).

## Datenfluss
Proxmox-Host → pct create → Container (Debian 12) → git clone → npm build → dist → uv sync → uvicorn :8000 (0.0.0.0) → systemd → Host-Verifikation → URL-Ausgabe.

## Fehlerbehandlung
- Jede Stufe mit klarer Meldung + Log-Verweis; Service-Fail → `systemctl status + journalctl -n 100`; Web-Fail → Status + Logs + Exit 1.
- Idempotent: existierende CT-ID → Update-Modus (kein Neu-Erstellen); `uv sync`/Build wiederholbar; `.env` wird nicht überschrieben.

## Tests
- `bash -n install/aurelio.sh`, ShellCheck (wenn vorhanden), Pfad-Checks gegen echte Upstream-Dateien (`backend/app/main.py`, `/api/health`, `frontend/dist`-Logik).
- Echter Proxmox-Lauf + Reboot-Test nur auf User-Hardware (hier kein Proxmox), mit Befehlen im README belegbar.

## Self-Review (2026-10-12)
- [x] Keine TBD/TODO-Platzhalter (USER/REPO im Einzeiler ist bewusst als zu ersetzender Fork-Hinweis mit RAW_BASE-Override dokumentiert).
- [x] Konsistent: Port 8000 überall, `/api/health` überall, Hostname `aurelio` überall.
- [x] Scope: ein Plan, ein LXC-Weg; keine VM-, keine Release-Pipeline-Nebenpfade.
- [x] Eindeutig: Defaults (2/4096/12, debian-12, unprivilegiert, onboot=1) fest; Overrides benannt.
