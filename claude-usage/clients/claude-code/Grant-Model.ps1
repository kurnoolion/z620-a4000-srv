<#
.SYNOPSIS
  Time-boxed model grants for Claude Code on a Windows PC (run as Administrator).

.DESCRIPTION
  Writes C:\Program Files\ClaudeCode\managed-settings.d\50-grant-<model>.json
  whose availableModels = baseline (from managed-settings.json) + all active
  grants, and registers a one-shot Scheduled Task (runs as SYSTEM) that deletes
  the grant at expiry. Takes effect at the user's next Claude Code start.

.EXAMPLE
  PS> .\Grant-Model.ps1 -Models opus,fable -Hours 4
  PS> .\Grant-Model.ps1 -Revoke -Models opus
  PS> .\Grant-Model.ps1 -Revoke -All
  PS> .\Grant-Model.ps1 -List
#>
[CmdletBinding(DefaultParameterSetName = "Grant")]
param(
  [Parameter(ParameterSetName = "Grant")] [Parameter(ParameterSetName = "Revoke")] [string[]] $Models,
  [Parameter(ParameterSetName = "Grant")] [double] $Hours = 4,
  [Parameter(ParameterSetName = "Revoke", Mandatory = $true)] [switch] $Revoke,
  [Parameter(ParameterSetName = "Revoke")] [switch] $All,
  [Parameter(ParameterSetName = "List",   Mandatory = $true)] [switch] $List
)
$ErrorActionPreference = "Stop"
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Run from an elevated (Administrator) PowerShell." }

$baseDir = "C:\Program Files\ClaudeCode"
$base    = Join-Path $baseDir "managed-settings.json"
$drop    = Join-Path $baseDir "managed-settings.d"
$prefix  = "50-grant-"
if (-not (Test-Path $base)) { throw "$base not found - run Install-ManagedSettings.ps1 first." }
New-Item -ItemType Directory -Force -Path $drop | Out-Null

function Get-Baseline { @((Get-Content $base -Raw | ConvertFrom-Json).availableModels) }
function Get-GrantFiles { Get-ChildItem -Path $drop -Filter "$prefix*.json" -ErrorAction SilentlyContinue | Sort-Object Name }
function Get-ModelOf($f) { $f.BaseName.Substring($prefix.Length) }
function Get-TaskName($m) { "ClaudeCode-GrantExpire-$m" }

function Rewrite-All {
  $models = @(Get-Baseline)
  foreach ($f in Get-GrantFiles) { $m = Get-ModelOf $f; if ($models -notcontains $m) { $models += $m } }
  foreach ($f in Get-GrantFiles) {
    @{ availableModels = $models; enforceAvailableModels = $true } |
      ConvertTo-Json -Depth 5 | Set-Content -Path $f.FullName -Encoding UTF8
  }
  return $models
}

function Remove-Grant($m) {
  $p = Join-Path $drop "$prefix$m.json"
  if (Test-Path $p) { Remove-Item $p -Force }
  Unregister-ScheduledTask -TaskName (Get-TaskName $m) -Confirm:$false -ErrorAction SilentlyContinue
}

switch ($PSCmdlet.ParameterSetName) {
  "Grant" {
    if (-not $Models) { throw "-Models is required, e.g. -Models opus,fable" }
    $expiry = (Get-Date).AddHours($Hours)
    foreach ($m in $Models) {
      Set-Content -Path (Join-Path $drop "$prefix$m.json") -Value "{}" -Encoding UTF8
      # One-shot expiry task: deletes the grant file, rewrites remaining grants
      # via this script, then unregisters itself.
      $self = $MyInvocation.MyCommand.Path
      $cmd  = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$self' -Revoke -Models $m`""
      $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $cmd
      $trigger = New-ScheduledTaskTrigger -Once -At $expiry
      $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
      Unregister-ScheduledTask -TaskName (Get-TaskName $m) -Confirm:$false -ErrorAction SilentlyContinue
      Register-ScheduledTask -TaskName (Get-TaskName $m) -Action $action -Trigger $trigger -Principal $principal | Out-Null
    }
    $final = Rewrite-All
    Write-Host ("granted {0} until {1:yyyy-MM-dd HH:mm} ({2}h)" -f ($Models -join ", "), $expiry, $Hours)
    Write-Host "availableModels now: $($final -join ', ')"
    Write-Host "takes effect at each user's next Claude Code start"
  }
  "Revoke" {
    $targets = if ($All) { Get-GrantFiles | ForEach-Object { Get-ModelOf $_ } } else { $Models }
    if (-not $targets) { Write-Host "nothing to revoke"; break }
    foreach ($m in $targets) { Remove-Grant $m }
    $final = Rewrite-All
    Write-Host "revoked $($targets -join ', ')"
    Write-Host "availableModels now: $($final -join ', ')"
  }
  "List" {
    Write-Host "baseline: $((Get-Baseline) -join ', ')"
    $files = Get-GrantFiles
    if (-not $files) { Write-Host "no active grants"; break }
    foreach ($f in $files) {
      $m = Get-ModelOf $f
      $t = Get-ScheduledTask -TaskName (Get-TaskName $m) -ErrorAction SilentlyContinue
      $when = if ($t) { $t.Triggers[0].StartBoundary } else { "no expiry (manual revoke only)" }
      Write-Host ("  {0,-12} expires {1}" -f $m, $when)
    }
  }
}
