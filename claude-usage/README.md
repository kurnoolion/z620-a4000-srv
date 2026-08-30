# claude-usage — Claude Code team usage observability + model grants

Standalone stack. Copy this directory to any Docker host (or run it in place
inside `z620-a4000-srv`) and you get:

- **Per-developer token / cost / session dashboards** for Claude Code, fed by
  Claude Code's built-in OpenTelemetry export — no Anthropic admin access needed.
- **A model allowlist** pushed to every developer machine via managed settings,
  with **time-boxed grants** for Opus / Fable on request.

```
 developer machines (Linux · WSL · Windows · macOS)        this host
 ┌──────────────────────────────────────┐     OTLP      ┌───────────────┐   ┌────────────┐   ┌─────────┐
 │ claude sessions, all users           ├────:4317─────▶│ otel-collector│──▶│ Prometheus │──▶│ Grafana │
 │ managed-settings.json (installed once)│               │               │   │  (180 d)   │   │  :3000  │
 └──────────────────────────────────────┘               └───────────────┘   └────────────┘   └─────────┘
```

Footprint ~400 MB RAM, negligible disk. Nothing here needs GPU, root, or the
rest of the z620 stack.

## Prerequisites

| Where | Needs |
|---|---|
| **Server** (any Linux box) | Docker Engine + Compose v2 (`docker compose version`) **from Docker's apt repo or your distro — not the snap**: snap Docker is confined and cannot read `/srv`, `/opt`, etc. (symptom: `no configuration file provided: not found`, or `open /var/lib/snapd/void/...`). `make`, ~400 MB RAM. Not root — your normal user in the `docker` group. |
| **Linux / WSL clients** | `python3`, `sudo`, `cron` (for grant expiry — **WSL doesn't run cron by default**, see below), a recent Claude Code (`claude update`; `managed-settings.d/` and `availableModels` are newer features). |
| **Windows clients** | An elevated PowerShell; run scripts with `-ExecutionPolicy Bypass` (see below). Recent Claude Code. |
| **Network** | Clients must reach the server on TCP 4317. Grafana on 3000 for whoever views it. |

## Deploy end-to-end (checklist)

1. **Get the stack onto the server.** `git clone git@github.com:kurnoolion/z620-a4000-srv.git` and use its `claude-usage/` directory — or copy just that directory anywhere.
2. **Bring it up** — see *Quick start (server side)* below. `make status` must show the `claude-code` target `up`.
3. **Open the firewall** — `ufw allow … 4317` (clients) and `3000` (dashboard viewers), if a firewall is on.
4. **Canary** — install managed settings on *your own* machine first (`--monitor-only`), start `claude`, run `/status` (managed settings listed), then check the dashboard: your email appears within a minute.
5. **Roll out monitor-only** to every developer machine — *Quick start (each developer machine)* below. Announce what's collected the same day.
6. **Let it run 1–2 weeks**, read the *Tokens by model* and *Opus / Fable by user* panels, decide the allowlist.
7. **Enforce** — edit `availableModels` in `clients/claude-code/managed-settings.json` if needed, re-run the installers *without* the flag. Standing grants for known heavy users first.
8. **Steady state** — `make grant …` on request; dashboard weekly.

The guide's *Migrating existing users* section explains steps 4–7 in detail.

## Quick start (server side)

```bash
cd claude-usage
make init                  # creates .env + data dirs, no sudo
$EDITOR .env               # at least GRAFANA_PASSWORD
make pull                  # only if `docker pull` is blocked by the corp proxy (skopeo + docker load)
make up
make status                # containers up, collector answering, Prometheus target UP
sudo ufw allow from <LAN-CIDR> to any port 4317 proto tcp    # clients → collector   (if a firewall is on)
sudo ufw allow from <LAN-CIDR> to any port 3000 proto tcp    # dashboard viewers
```

Grafana: `http://<this-host>:3000/` → dashboard **APEX — Claude Code Usage**
(`/d/apex-claude-code-usage`). Anonymous viewing is on by default; the admin
login is only for editing (`GRAFANA_ANON_VIEW=false` in `.env` to require login).

## Quick start (each developer machine, once)

The client machine needs the `clients/claude-code/` directory — clone the
repo there, or `scp -r clients/claude-code user@machine:` from the server.

```bash
# Linux / WSL (as root) — installs managed settings + the grant tool + expiry cron
sudo ./clients/claude-code/install-managed-settings.sh <this-host-ip> <team-name>
```
```powershell
# Windows (elevated PowerShell). Default execution policy blocks .ps1 files;
# Bypass applies to this invocation only.
powershell -ExecutionPolicy Bypass -File .\clients\claude-code\Install-ManagedSettings.ps1 -Collector <this-host-ip> -Team <team-name>
```

**WSL:** cron is not running by default, so grant expiry would never fire.
The installer warns if it detects this; fix with `sudo service cron start`
and, on Windows 11 / systemd-enabled WSL, `sudo systemctl enable cron`
(or add `[boot] command="service cron start"` to `/etc/wsl.conf`).

**Verify on each machine:** start `claude`, run `/status` — the managed
settings file should be listed — then `/model` shows only allowed models
(unless monitor-only). On the dashboard, the user's email appears within a
minute of their first prompt.

Add `--monitor-only` (Linux) / `-MonitorOnly` (Windows) to install telemetry
**without** the model allowlist — the right first step when people are already
using Claude Code (see the guide's "Migrating existing users"). Re-run without
the flag later to enforce. Use an **IP** unless you know the hostname resolves
on every client. Users pick it up at their next `claude` start; the dashboard
fills in within a minute.

## Model grants

Baseline allowlist: `clients/claude-code/managed-settings.json`
(`availableModels`, default `["sonnet","haiku"]`). Case-by-case:

`make grant`/`grants`/`revoke` reach Linux/WSL targets over ssh and run
`sudo claude-model-grant` there — you need ssh access and sudo on the target
(a password prompt is fine). Windows targets: run `Grant-Model.ps1` on the PC.

```bash
make grant  host=alice@ws-01 models=opus hours=4     # Linux/WSL target over ssh
make grants host=alice@ws-01                         # list active
make revoke host=alice@ws-01 models=opus             # or models=--all
# on the machine itself: sudo claude-model-grant grant opus 4
# Windows:               .\Grant-Model.ps1 -Models opus -Hours 4   (elevated)
```

Grants expire on their own (cron sweeper on Linux, scheduled task on Windows).
The dashboard's **"Opus / Fable tokens per hour, by user"** panel is the audit.

## Co-hosting behind a reverse proxy (e.g. z620 Caddy at `/grafana/`)

Set in `.env`:
```
GRAFANA_ROOT_URL=https://<site-host>/grafana/
GRAFANA_SUB_PATH=true
```
and have the proxy forward `/grafana/*` to this host's `:3000`. On the z620
specifically, after `git pull`:

```bash
make apply svc=caddy       # picks up the /grafana route + the host.docker.internal alias
make usage-up              # = make -C claude-usage init up
make usage-status
```

Then Grafana is at `https://<SITE_HOST>/grafana/` (also plain http). Port
3000 need not be opened to the LAN in this case — only 4317.

## Upkeep

- **Upgrade images:** `docker compose pull && make up`.
- **Data:** everything durable is under `DATA_ROOT` (default `./data`) — back
  that up or move it; `make down` keeps it, `rm -rf data/` purges it.
- **Change the allowlist:** edit `clients/claude-code/managed-settings.json`,
  re-run the installer on each machine (it merges; grants are unaffected).
- **Move the server:** only the clients' endpoint changes — re-run the
  installers with the new IP.

## Files

- `compose.yaml`, `.env.example`, `Makefile` — the stack
- `skopeo-pull.sh` — `make pull`: fetch the three images through skopeo when Docker Hub is unreachable for the daemon (corp proxy). Pinned tags; `KEEP_TARS=1` keeps the tarballs for sneakernet to an offline box (`docker load -i`).
- `observability/` — collector config, Prometheus scrape config, Grafana provisioning + dashboard
- `clients/claude-code/` — `managed-settings.json` template; installers for Linux/WSL (`.sh`) and Windows (`.ps1`); grant tooling (`claude-model-grant`, `grant-model.sh`, `Grant-Model.ps1`)
- `CLAUDE-CODE-TELEMETRY.md` — the full guide: how it works, what's captured, what isn't (chat/Cowork), model control, caveats, troubleshooting

## Ports

| Port | What | Exposure |
|---|---|---|
| 4317 | OTLP gRPC — what clients send to | must be reachable from developer machines |
| 4318 | OTLP HTTP — alternative | optional |
| 3000 | Grafana | LAN (or proxy only) |
