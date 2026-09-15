<#
.SYNOPSIS
  NSOC end-to-end run against a REMOTE relay (cloud acceptance, A1).

.DESCRIPTION
  Same chain as run_e2e_local.ps1 -- real relay, real authority process, real client
  probe -- but it does NOT start a local relay: it points both the authority and the
  client probe at an already-running (usually cloud) relay.

  Two machines:
      machine A : .\run_e2e_cloud.ps1 -StartAuthority      (keeps an authority standby)
      machine B : .\run_e2e_cloud.ps1                      (runs the probe, prints PASS/FAIL)
  One machine:
      .\run_e2e_cloud.ps1 -StartAuthority                  (starts authority, then probes)

  The probe asserts the server-authoritative chain end to end:
      room/create{authoritative:true} -> relay dispatches to a standby authority ->
      authority/start_match -> client/hello -> auth/hello -> auth/state ->
      intent/end_turn -> auth/event{phase_resolved,turn_started} on BOTH peers.

  Exit code 0 = PASS.  ASCII only (Windows PowerShell 5.1 reads BOM-less files as GBK).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_e2e_cloud.ps1 `
      -RelayHost 159.75.154.122 -AuthorityKey <key> -StartAuthority
#>
[CmdletBinding()]
param(
    [string]$RelayHost = "159.75.154.122",
    [int]$Port = 8080,
    [string]$AuthorityKey = $env:NSOC_AUTHORITY_KEY,
    [switch]$StartAuthority,
    [string]$Godot = "",
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$projectSrc = Join-Path $repo "dev_gd\nsoc"

if ([string]::IsNullOrWhiteSpace($AuthorityKey)) {
    throw "AuthorityKey is empty. Pass -AuthorityKey <key> or set `$env:NSOC_AUTHORITY_KEY."
}

function Find-Godot {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    foreach ($c in @(
            "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe",
            "C:\D\GodotEngine\Godot_v4.7.1-stable_win64_console.exe",
            "C:\D\GodotEngine\Godot_v4.7-stable_win64_console.exe")) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Godot executable not found. Pass -Godot <path> (needs Godot 4.7.x)."
}

$godotBin = Find-Godot -Explicit $Godot
$tempRoot = Join-Path $env:TEMP "nsoc_e2e_cloud"
$projCopy = Join-Path $tempRoot "nsoc"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
if (-not (Test-Path $projCopy)) {
    Copy-Item $projectSrc -Destination $projCopy -Recurse -Force
} else {
    Copy-Item (Join-Path $projectSrc "*") -Destination $projCopy -Recurse -Force
}

Write-Host "==> relay: ws://$RelayHost`:$Port" -ForegroundColor Cyan
try {
    $health = (Invoke-WebRequest -Uri "http://$RelayHost`:$Port/health" -UseBasicParsing -TimeoutSec 10).Content
    Write-Host "    /health -> $health" -ForegroundColor DarkGray
} catch {
    throw "relay not reachable at http://$RelayHost`:$Port/health : $($_.Exception.Message)"
}

Write-Host "==> import warmup" -ForegroundColor Cyan
$imp = Start-Process -FilePath $godotBin -PassThru -NoNewWindow -Wait `
    -RedirectStandardOutput (Join-Path $tempRoot "import.log") `
    -RedirectStandardError (Join-Path $tempRoot "import.err") `
    -ArgumentList @("--headless", "--path", $projCopy, "--import")
if ($imp.ExitCode -ne 0) { Write-Host "    import exit=$($imp.ExitCode) (usually harmless)" -ForegroundColor DarkGray }

$roomFile = Join-Path $tempRoot "room.txt"
$authOut = Join-Path $tempRoot "authority.log"
$probeOut = Join-Path $tempRoot "probe.log"
Remove-Item $roomFile, $authOut, $probeOut -Force -ErrorAction SilentlyContinue
Remove-Item ($authOut + ".err"), ($probeOut + ".err") -Force -ErrorAction SilentlyContinue

$env:NSOC_AUTHORITY_KEY = $AuthorityKey
$auth = $null
if ($StartAuthority) {
    Write-Host "==> start authority process (standby, remote relay)" -ForegroundColor Cyan
    $auth = Start-Process -FilePath $godotBin -PassThru -NoNewWindow -RedirectStandardOutput $authOut `
        -RedirectStandardError ($authOut + ".err") -ArgumentList @(
            "--headless", "--path", $projCopy, "res://server/AuthorityMain.tscn", "--",
            "--host=$RelayHost", "--port=$Port")
    Start-Sleep -Milliseconds 2500
} else {
    Write-Host "==> assuming an authority process is already standby (not started here)" -ForegroundColor Cyan
}

Write-Host "==> start client probe (authoritative room + lobby config)" -ForegroundColor Cyan
$probe = Start-Process -FilePath $godotBin -PassThru -NoNewWindow -RedirectStandardOutput $probeOut `
    -RedirectStandardError ($probeOut + ".err") -ArgumentList @(
        "--headless", "--path", $projCopy, "res://tests/E2ERelayProbe.tscn", "--",
        "--host=$RelayHost", "--port=$Port", "--roomfile=$roomFile", "--timeout=45")
$null = $probe.WaitForExit($TimeoutSec * 1000)
Start-Sleep -Milliseconds 500
try { if (-not $probe.HasExited) { $probe.Kill() } } catch { }
if ($auth) { try { if (-not $auth.HasExited) { $auth.Kill() } } catch { } }
Start-Sleep -Milliseconds 500

function Read-Log {
    param([string]$Path, [int]$Tail = 0)
    if (-not (Test-Path $Path)) { return @() }
    try { $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) }
    catch { return @() }
    if ($Tail -gt 0 -and $lines.Count -gt $Tail) { return $lines[($lines.Count - $Tail)..($lines.Count - 1)] }
    return $lines
}

Write-Host "==> probe output" -ForegroundColor Cyan
Read-Log -Path $probeOut | Where-Object { $_ -match 'E2E_|ERROR|Parse' } | ForEach-Object { Write-Host "    $_" }
if ($auth) {
    Write-Host "==> authority log (tail)" -ForegroundColor Cyan
    Read-Log -Path $authOut -Tail 8 | ForEach-Object { Write-Host "    $_" }
}

$passed = $false
foreach ($line in (Read-Log -Path $probeOut)) { if ($line -match '^E2E_RESULT PASS') { $passed = $true } }

if ($passed) {
    Write-Host "[PASS] server-authoritative chain works against $RelayHost`:$Port" -ForegroundColor Green
    exit 0
}
Write-Host "[FAIL] see $probeOut / $authOut" -ForegroundColor Red
exit 1
