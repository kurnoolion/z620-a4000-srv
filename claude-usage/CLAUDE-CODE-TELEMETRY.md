# CLAUDE CODE TELEMETRY — team usage + model control without the org admin

Who on the team is using Claude Code, how many tokens, on which models, at
what estimated cost — in Grafana on this box — plus a per-machine allowlist
of which models members can pick. No Anthropic Teams admin access needed.

## How it works

Claude Code has a built-in OpenTelemetry exporter (all plans, Teams
included). Each session emits counters — tokens by type and model, estimated
cost, sessions, lines of code — tagged with the user's login email. A
**managed settings** file on each developer machine points every session at
the collector here and pins the model allowlist. Managed settings override
each user's own `~/.claude/settings.json`, so nobody can opt out.

```
 Developer machines                            z620-a4000-srv
 ┌────────────────────────────┐              ┌──────────────┐  ┌────────────┐  ┌─────────┐
 │ shared Linux WS (12 users) │  OTLP gRPC   │ otel-        │  │ Prometheus │  │ Grafana │
 │ Windows PCs (Claude Code)  ├────:4317────▶│ collector    │─▶│ (180d)     │─▶│ /grafana│
 │ WSL, macOS laptops         │              │ :8889/metrics│  │            │  │         │
 └────────────────────────────┘              └──────────────┘  └────────────┘  └─────────┘
   one managed-settings.json per machine
```

Managed settings are **a file on the developer machine**, deployed by
whoever has root/Administrator there — not by the Anthropic org admin.

| OS | Path | Installer (in `clients/claude-code/`) |
|---|---|---|
| Linux, **WSL** | `/etc/claude-code/managed-settings.json` | `sudo ./install-managed-settings.sh <collector> [team]` |
| Windows | `C:\Program Files\ClaudeCode\managed-settings.json` | `.\Install-ManagedSettings.ps1 -Collector <ip> -Team <team>` (elevated PowerShell) |
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` | copy the JSON by hand (same content) |

Windows notes: the path is `Program Files`, **not** `C:\ProgramData` (Claude
Code doesn't read that). WSL on the same PC is a separate install — run the
`.sh` inside WSL too, or set `wslInheritsWindowsSettings` so WSL inherits the
Windows file. For fleet rollout, Group Policy / Intune can deliver the same
JSON as a `Settings` value under `HKLM\SOFTWARE\Policies\ClaudeCode`.

Managed settings reach: CLI, VS Code / JetBrains extensions, Claude Desktop
*local* Claude Code sessions, and Cowork (for the model allowlist). They do
**not** reach Claude Code sessions running in Anthropic's cloud (web/mobile
"cloud sessions") — those only honor server-managed settings from the admin
console.

## Setup

### 1. Server — bring up the stack

This directory is a standalone compose project; run it here or copy it anywhere.

```bash
make init                    # .env from template (edit GRAFANA_PASSWORD) + data dirs; no sudo
make up
make status                  # containers, collector endpoint, Prometheus target, users seen
sudo ufw allow from <LAN-CIDR> to any port 4317 proto tcp   # if ufw is on
```

Grafana is at `http://<host>:3000/`. Co-hosted on the z620 behind Caddy, set
`GRAFANA_ROOT_URL=https://<SITE_HOST>/grafana/` and `GRAFANA_SUB_PATH=true`
in `.env` and use `https://<SITE_HOST>/grafana/` instead.

### 2. Developer machines — install managed settings (once each)

```bash
# Linux / WSL (as root)
sudo ./clients/claude-code/install-managed-settings.sh <server-ip> <team>
```
```powershell
# Windows (elevated PowerShell)
.\clients\claude-code\Install-ManagedSettings.ps1 -Collector <server-ip> -Team <team>
```

Use the box's **IP address** unless you know the hostname resolves on *every*
client, Windows included — an unresolvable endpoint fails silently (Claude
Code never blocks on telemetry). The installers do a TCP check to `:4317`.

Users pick it up on their next `claude` start: `/status` shows managed
settings, `/model` shows only the allowed models, `/usage` still shows their
own numbers.

### 3. Grafana

Dashboard **APEX — Claude Code Usage** at `http://<host>:3000/d/apex-claude-code-usage` (or `/grafana/d/...` behind Caddy).
Anonymous *view* is on by default (`GRAFANA_ANON_VIEW=true`) so the whole
team can see it; the admin login is needed only to edit.

## Controlling which models members can use

Two keys in `clients/claude-code/managed-settings.json`:

```json
"availableModels": ["sonnet", "haiku"],
"enforceAvailableModels": true
```

- `availableModels` — allowlist applied to `/model`, `--model`, and
  `ANTHROPIC_MODEL`. Aliases (`sonnet`, `opus`, `haiku`, `fable`) or full IDs.
- `enforceAvailableModels: true` — also constrains the "Default" option, so a
  user can't fall back to a default that's outside the list.
- Optional pinning of what an alias means: `"env": {"ANTHROPIC_DEFAULT_SONNET_MODEL": "<model-id>"}`.

Edit the list, re-run the installer on each machine. Members can still
*choose* among the allowed models; there is no single-model hard lock.

**Enterprise-only alternative:** the admin console
(claude.ai/admin-settings/claude-code) can disable models server-side, org-wide
or per role, and that also covers cloud sessions. On a **Teams** plan that
control doesn't exist, so the managed-settings allowlist is the tool.

## Case-by-case access to Opus / Fable (time-boxed grants)

A grant is a drop-in file in `managed-settings.d/` that widens
`availableModels` for a fixed number of hours, then removes itself. The
baseline file is never edited. Grants take effect at the user's next
`claude` start and apply to **every user on that machine** (see caveat).

**Linux / WSL** — `install-managed-settings.sh` installs
`/usr/local/sbin/claude-model-grant` and a cron sweeper (`/etc/cron.d/claude-model-grants`,
every 5 min, reboot-safe) that expires grants:

```bash
# on the machine
sudo claude-model-grant grant  opus 4          # 4 hours (default)
sudo claude-model-grant grant  opus,fable 8
sudo claude-model-grant list
sudo claude-model-grant revoke opus            # or --all

# from your desk, over ssh (same subcommands)
clients/claude-code/grant-model.sh alice@ws-01 grant opus 4
clients/claude-code/grant-model.sh alice@ws-01 list
```

**Windows** — `Grant-Model.ps1` (elevated PowerShell on the PC) does the
same; expiry is a one-shot Scheduled Task running as SYSTEM that revokes
and unregisters itself:

```powershell
.\Grant-Model.ps1 -Models opus -Hours 4
.\Grant-Model.ps1 -Models opus,fable -Hours 8
.\Grant-Model.ps1 -List
.\Grant-Model.ps1 -Revoke -Models opus      # or -Revoke -All
```

Suggested flow: member asks in chat/ticket with a one-line reason → you run
the grant → it expires on its own. Audit is the dashboard panel
**"Opus / Fable tokens per hour, by user"** — every premium token is
attributed to an email, so short grants plus visibility replace approval
bureaucracy.

Caveats:
- **Per-machine, not per-user.** On the shared workstation a grant unlocks
  the model for everyone logged in during the window. Keep windows short and
  rely on the audit panel. Untested idea for true per-user grants there:
  `chown alice: && chmod 600` the drop-in so only alice's `claude` can read
  it — test whether Claude Code skips unreadable drop-ins or errors before
  relying on it.
- **Session boundaries.** A running session doesn't gain or lose the model
  mid-way; it applies at the next start.
- **Plan tier.** `availableModels` can only unlock models the seat can reach;
  if Fable isn't on your Teams tier, listing it does nothing.
- Log of expiries: `/var/log/claude-model-grants.log` (Linux).

## Migrating existing users

People already using Claude Code are barely affected by the telemetry, and
*are* affected by the model allowlist. Roll out in that order: measure first,
restrict second.

### What changes for an existing user

| | Effect |
|---|---|
| Their `~/.claude/settings.json`, permissions, hooks, MCP servers, `CLAUDE.md`, memory, history, custom agents | **Untouched.** Managed settings merge on top and win only for the keys they set. No reinstall, no re-login. |
| Telemetry | Invisible. No latency, no prompts. Fails silently if the collector is unreachable. **No backfill** — usage before install day isn't in the dashboard. |
| Running sessions | Unchanged until the next `claude` start. Nobody is interrupted. |
| Model allowlist | Opus/Fable vanish from `/model` at the next start. Anyone with `"model": "opus"` in their settings, `ANTHROPIC_MODEL=opus`, or a `--model opus` habit gets forced to an allowed model. |
| Privacy | `user_email` now leaves the machine for your server — announce it, don't let it be discovered. |

**Unverified edge cases — test in phase 1, then record the answer here:**
- A disallowed model configured in user settings / env: quiet fallback, or startup error?
- `--resume` of a session that ran on Opus.
- Custom subagents with `model: opus` in their frontmatter — does the allowlist reach them?

**Out of scope, say so explicitly:** machines you don't manage (personal
laptops) and Claude Code *cloud* sessions launched from the web — managed
settings don't reach them.

### Phases

**0 · Inventory (a day).** Who uses Claude Code, on which machines (shared
workstation / Windows PC / WSL / laptop). Don't rely on self-report for
which models — phase 2 measures it.

**1 · Server + canary (a day).** `make init && make up && make status`; run
the installer on *your own* machine only; confirm `/status` shows managed
settings and your sessions appear on the dashboard within a minute. Run the
edge-case tests above here.

**2 · Monitor-only rollout (1–2 weeks).** Telemetry on everywhere, **no
allowlist**:

```bash
sudo ./clients/claude-code/install-managed-settings.sh --monitor-only <server-ip> <team>
```
```powershell
.\clients\claude-code\Install-ManagedSettings.ps1 -Collector <server-ip> -Team <team> -MonitorOnly
```

Announce the same day: what's collected (tokens, cost estimate, model,
email — *not* prompts or code), where it lives, who can see it, why. Then
let the **Tokens by model** and **Opus / Fable by user** panels build a
baseline. That baseline is what tells you the right allowlist and how many
grants to expect.

**3 · Model policy (announce, enforce a week later).** Set `availableModels`
in `managed-settings.json` from the evidence. Announce the policy and the
request → grant flow with a date. For the few people the baseline shows as
legitimate heavy Opus/Fable users, either give a standing long grant on day
one (`claude-model-grant grant opus 720` = 30 days) or tell them the request
path personally. On the date, re-run the installers **without** the flag —
they merge, so it's a 30-second update per machine:

```bash
sudo ./clients/claude-code/install-managed-settings.sh <server-ip> <team>
```

Re-running **with** `--monitor-only` later removes the allowlist again, so
switching modes is always a flag, never a hand edit.

**4 · Steady state.** Grants via `make grant …`, expiring on their own; a
weekly glance at the dashboard; the audit panel for anything odd.

## What about Claude chat and Cowork on the Windows PCs?

Honest answer: **token usage there can't be captured this way.** OpenTelemetry
export is a Claude *Code* feature. Chat (claude.ai / Desktop) and Cowork have
no client-side telemetry, hooks, or export. The only per-user numbers for
those surfaces are on the admin side:

- Teams admin **spend report CSV** (per user, per model, daily) and the
  analytics dashboard — Admin/Owner role only. The docs don't say whether
  that CSV splits usage by surface (chat vs Code vs Cowork).
- Enterprise plans additionally get an Analytics API across all surfaces;
  Teams does not.

So for chat/Cowork you need the overseas admin — either a periodic CSV export,
or granting a local team lead the Admin role (there's no analytics-only role).
The model allowlist above *does* apply to Cowork, since Cowork reads the
device's managed settings.

What this stack **does** cover on the Windows PCs: Claude Code in the
terminal, in VS Code / JetBrains, and local Claude Code sessions launched
from the Desktop app.

## What you get

| Metric (Prometheus name) | Labels | Meaning |
|---|---|---|
| `claude_code_token_usage` | `user_email`, `model`, `type` | tokens; `type` ∈ input / output / cacheRead / cacheCreation |
| `claude_code_cost_usage` | `user_email`, `model` | estimated USD at API list price |
| `claude_code_session_count` | `user_email` | sessions started |
| `claude_code_lines_of_code_count` | `user_email`, `type` | lines added / removed |
| `claude_code_commit_count`, `_pull_request_count` | `user_email` | git activity via Claude |
| `claude_code_active_time_total` | `user_email` | seconds of active use |

All carry `session_id`, `organization_id`, `terminal_type`, and the
`host_name` / `team` resource attributes the installer sets — so you can
split the dashboard by machine (shared workstation vs. each Windows PC).

## Caveats — read before showing anyone the dashboard

- **Cost is an estimate, not a bill.** Teams is a subscription: usage counts
  against plan limits; `cost_usage` is computed at API list price. Use it to
  compare people and spot outliers, not to reconcile anything.
- **Counters are per session.** Each session is a fresh series; the dashboard
  sums `increase()` across series. Sessions shorter than ~30 s may not show.
- **Offline clients drop data.** If this box is unreachable, that session's
  telemetry is lost — no client-side buffering. Laptops off-VPN won't report.
- **This is per-person monitoring.** `user_email` is on every series. Tell
  the team what's collected and why before switching it on.
- **Per-prompt detail is not captured.** Claude Code can also emit
  per-request *events* (OTLP logs) with prompt-level token counts. We set
  `OTEL_LOGS_EXPORTER=none`; to enable, add Loki to the stack, a `logs`
  pipeline to `observability/otel-collector.yml`, and flip the env var.
- **RAM.** The three containers are capped at 384 + 512 + 512 MB in compose;
  real use is well under that. The stack is standalone, so if a host gets
  tight it can move to any other Docker box — only the `OTEL_EXPORTER_OTLP_ENDPOINT`
  on the clients changes (re-run the installers).

## Troubleshooting

| Symptom | Check |
|---|---|
| Dashboard empty | `make status`, then `make logs svc=otel-collector` — anything arriving? If not, it's client-side. |
| A client sends nothing | Managed file present at the OS-specific path? Inside `claude`, `/status` shows the env. TCP check: `bash -c '</dev/tcp/<box-ip>/4317'` or `Test-NetConnection <box-ip> -Port 4317`. |
| Collector receives, Prometheus empty | `make status` shows the `claude-code` target; `make restart svc=prometheus` if needed. |
| Series but wrong names | Uncomment the `debug` exporter in `otel-collector.yml`, add it to the metrics pipeline, read raw names in the collector log. |
| `/model` still shows everything | Managed file not being read (wrong path — `ProgramData` on Windows is the usual mistake), or the user is in a cloud session. |
| Grant never expires (Linux/WSL) | cron not running — WSL is off by default: `sudo service cron start` (+ `systemctl enable cron` or `/etc/wsl.conf` `[boot] command`). The installer warns about this. |
| `.ps1` "cannot be loaded" on Windows | Execution policy. `powershell -ExecutionPolicy Bypass -File <script> …` (this invocation only). |
| Grant not visible | `/model` inside a NEW session; `claude-model-grant list` shows it active; drop-in dir is `managed-settings.d` next to the base file. |
| User missing | No new session since install, or they use Claude Code on a machine without the managed file. |

## Removing it

Server: `make down` (data kept under `DATA_ROOT`; delete it to purge). Clients: delete the managed file (a
`.bak` of any previous file sits beside it); the next `claude` start is
back to user settings.
