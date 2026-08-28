<#
.SYNOPSIS
  Install Claude Code managed settings on a Windows PC (run as Administrator).

.DESCRIPTION
  Writes C:\Program Files\ClaudeCode\managed-settings.json so every Claude Code
  session on this PC (CLI, VS Code / JetBrains extensions, Desktop app local
  sessions) exports usage telemetry to the z620 collector and is limited to
  the model allowlist in managed-settings.json.

  NOTE: the path is "C:\Program Files\ClaudeCode" — Claude Code does NOT read
  the older C:\ProgramData\ClaudeCode location.

  Managed settings override the user's %USERPROFILE%\.claude\settings.json.
  Existing keys in an existing file are preserved; ours are merged on top.
  WSL on the same PC is separate: run install-managed-settings.sh inside WSL
  (or set "wslInheritsWindowsSettings" — see CLAUDE-CODE-TELEMETRY.md).

.PARAMETER MonitorOnly
  Telemetry only: do NOT install the model allowlist (and REMOVE one a previous
  run installed). For the baseline phase — see CLAUDE-CODE-TELEMETRY.md
  "Migrating existing users". Re-run without the switch to enforce.

.EXAMPLE
  PS> .\Install-ManagedSettings.ps1 -Collector 10.0.0.42 -Team modem-logs
  PS> .\Install-ManagedSettings.ps1 -Collector 10.0.0.42 -Team modem-logs -MonitorOnly
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)] [string] $Collector,
  [string] $Team = "apex",
  [switch] $MonitorOnly
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run this from an elevated (Administrator) PowerShell." }

$src    = Join-Path $PSScriptRoot "managed-settings.json"
$dstDir = "C:\Program Files\ClaudeCode"
$dst    = Join-Path $dstDir "managed-settings.json"

$new = Get-Content $src -Raw | ConvertFrom-Json
$new.env.OTEL_EXPORTER_OTLP_ENDPOINT = "http://$Collector`:4317"
$new.env.OTEL_RESOURCE_ATTRIBUTES    = "host.name=$($env:COMPUTERNAME.ToLower()),team=$Team"

# Merge onto any existing managed file.
$cur = [ordered]@{}
if (Test-Path $dst) {
  Copy-Item $dst "$dst.bak.$(Get-Date -Format yyyy-MM-dd-HHmmss)"
  Write-Host "existing $dst backed up"
  $curObj = Get-Content $dst -Raw | ConvertFrom-Json
  foreach ($p in $curObj.PSObject.Properties) { $cur[$p.Name] = $p.Value }
}
if (-not $cur.Contains("env")) { $cur["env"] = [ordered]@{} }
$envMerged = [ordered]@{}
if ($cur["env"] -is [System.Collections.IDictionary]) {
  foreach ($k in $cur["env"].Keys) { $envMerged[$k] = $cur["env"][$k] }
} else {
  foreach ($p in $cur["env"].PSObject.Properties) { $envMerged[$p.Name] = $p.Value }
}
foreach ($p in $new.env.PSObject.Properties) { $envMerged[$p.Name] = $p.Value }
$cur["env"] = $envMerged
$modelKeys = @("availableModels", "enforceAvailableModels")
foreach ($p in $new.PSObject.Properties) {
  if ($p.Name -eq "env") { continue }
  if ($MonitorOnly -and $modelKeys -contains $p.Name) { continue }
  $cur[$p.Name] = $p.Value
}
if ($MonitorOnly) { foreach ($k in $modelKeys) { $cur.Remove($k) } }
$mode = if ($MonitorOnly) { "MONITOR-ONLY (no model allowlist)" } else { "telemetry + model allowlist $($cur['availableModels'] -join ', ')" }
Write-Host "mode: $mode"

New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
($cur | ConvertTo-Json -Depth 10) | Set-Content -Path $dst -Encoding UTF8

Write-Host "installed $dst:"
Get-Content $dst
Write-Host ""
Write-Host "Reachability check:"
$ok = Test-NetConnection -ComputerName $Collector -Port 4317 -InformationLevel Quiet -WarningAction SilentlyContinue
if ($ok) { Write-Host "  OK  - ${Collector}:4317 accepts connections" }
else     { Write-Host "  FAIL - cannot reach ${Collector}:4317 (collector down, firewall, or name doesn't resolve from this PC)" }
Write-Host ""
Write-Host "Users pick this up on their NEXT Claude Code session. Verify inside claude with /status and /model."
