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

## Quick start (server side)

```bash
cd claude-usage
make init                  # creates .env (edit GRAFANA_PASSWORD) + data dirs, no sudo
make up
make status                # containers up, collector answering, Prometheus target UP
sudo ufw allow from <LAN-CIDR> to any port 4317 proto tcp    # if a firewall is on
```

Grafana: `http://<this-host>:3000/` → dashboard **APEX — Claude Code Usage**
(`/d/apex-claude-code-usage`). Anonymous viewing is on by default; the admin
login is only for editing (`GRAFANA_ANON_VIEW=false` in `.env` to require login).

## Quick start (each developer machine, once)

```bash
# Linux / WSL (as root) — installs managed settings + the grant tool + expiry cron
sudo ./clients/claude-code/install-managed-settings.sh <this-host-ip> <team-name>
```
```powershell
# Windows (elevated PowerShell)
.\clients\claude-code\Install-ManagedSettings.ps1 -Collector <this-host-ip> -Team <team-name>
```

Use an **IP** unless you know the hostname resolves on every client. Users
pick it up at their next `claude` start; the dashboard fills in within a minute.

## Model grants

Baseline allowlist: `clients/claude-code/managed-settings.json`
(`availableModels`, default `["sonnet","haiku"]`). Case-by-case:

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
and have the proxy forward `/grafana/*` to this host's `:3000` (the z620
`Caddyfile` already does, via `host.docker.internal`). From the parent
directory, `make usage-up` / `make usage-status` delegate here.

## Files

- `docker-compose.yml`, `.env.example`, `Makefile` — the stack
- `observability/` — collector config, Prometheus scrape config, Grafana provisioning + dashboard
- `clients/claude-code/` — `managed-settings.json` template; installers for Linux/WSL (`.sh`) and Windows (`.ps1`); grant tooling (`claude-model-grant`, `grant-model.sh`, `Grant-Model.ps1`)
- `CLAUDE-CODE-TELEMETRY.md` — the full guide: how it works, what's captured, what isn't (chat/Cowork), model control, caveats, troubleshooting

## Ports

| Port | What | Exposure |
|---|---|---|
| 4317 | OTLP gRPC — what clients send to | must be reachable from developer machines |
| 4318 | OTLP HTTP — alternative | optional |
| 3000 | Grafana | LAN (or proxy only) |
