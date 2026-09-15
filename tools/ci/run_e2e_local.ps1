<#
.SYNOPSIS
  NSOC local end-to-end run: Go relay + Godot authority process + client probe.

.DESCRIPTION
  Proves the server-authoritative chain works locally, without any manual steps:
    1. builds the Go relay and starts it with NSOC_AUTHORITY_KEY=devkey
    2. starts the client probe (two relay connections: p1 creates a room, p2 joins)
    3. reads the room id the probe wrote, then starts the authority process for that room
    4. the probe sends client/hello + intent/end_turn and asserts it receives auth/* back

  Output: prints the probe's E2E_RESULT line and the authority log tail.
  Exit code 0 = PASS.

  NOTE: keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less files as GBK).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_e2e_local.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [int]$TimeoutSec = 90,
    [string]$Godot = "",
    [string]$AuthorityKey = "devkey"
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$projectSrc = Join-Path $repo "dev_gd\nsoc"

function Find-Godot {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    foreach ($c in @(
            "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe",
            "C:\D\GodotEngine\Godot_v4.7.2-stable_win64.exe")) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command godot -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Godot executable not found. Pass -Godot <path> (needs Godot 4.7.x)."
}

$godotBin = Find-Godot -Explicit $Godot
$tempRoot = Join-Path $env:TEMP "nsoc_e2e"
$projCopy = Join-Path $tempRoot "nsoc"
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
if (-not (Test-Path $projCopy)) {
    Copy-Item $projectSrc -Destination $projCopy -Recurse -Force
} else {
    Copy-Item (Join-Path $projectSrc "*") -Destination $projCopy -Recurse -Force
}

# Go toolchain env (no admin rights: keep caches under TEMP)
$env:GOCACHE = Join-Path $env:TEMP "gocache"
$env:GOPATH = Join-Path $env:TEMP "gopath"
$env:GOMODCACHE = Join-Path $env:TEMP "gopath\pkg\mod"
$env:GOTMPDIR = Join-Path $env:TEMP "gotmp"
$env:GOPROXY = "https://goproxy.cn,direct"
$env:GOSUMDB = "sum.golang.google.cn"
New-Item -ItemType Directory -Force -Path $env:GOCACHE, $env:GOPATH, $env:GOTMPDIR | Out-Null

$relayExe = Join-Path $tempRoot "nsoc-server.exe"
Write-Host "==> build relay" -ForegroundColor Cyan
Push-Location (Join-Path $repo "server")
& go build -o $relayExe .
$buildCode = $LASTEXITCODE
Pop-Location
if ($buildCode -ne 0) { throw "go build failed ($buildCode)" }

Write-Host "==> import warmup" -ForegroundColor Cyan
# Godot prints harmless noise on stderr (cert store / user://) -> send it to a file, not the console
& $godotBin --headless --path $projCopy --import > (Join-Path $tempRoot "import.log") 2>&1

$roomFile = Join-Path $tempRoot "room.txt"
Remove-Item $roomFile -Force -ErrorAction SilentlyContinue
$relayOut = Join-Path $tempRoot "relay.log"
$authOut = Join-Path $tempRoot "authority.log"
$probeOut = Join-Path $tempRoot "probe.log"
Remove-Item $relayOut, $authOut, $probeOut -Force -ErrorAction SilentlyContinue

$env:NSOC_AUTHORITY_KEY = $AuthorityKey
$env:PORT = "$Port"

Write-Host "==> start relay on :$Port" -ForegroundColor Cyan
$relay = Start-Process -FilePath $relayExe -PassThru -NoNewWindow `
    -RedirectStandardOutput $relayOut -RedirectStandardError ($relayOut + ".err")
Start-Sleep -Milliseconds 800

Write-Host "==> start client probe" -ForegroundColor Cyan
$probe = Start-Process -FilePath $godotBin -PassThru -NoNewWindow -RedirectStandardOutput $probeOut `
    -RedirectStandardError ($probeOut + ".err") -ArgumentList @(
        "--headless", "--path", $projCopy, "res://tests/E2ERelayProbe.tscn", "--",
        "--host=127.0.0.1", "--port=$Port", "--roomfile=$roomFile", "--timeout=45")

$deadline = (Get-Date).AddSeconds(40)
while (-not (Test-Path $roomFile) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }

$room = ""
if (Test-Path $roomFile) { $room = (Get-Content $roomFile -Raw).Trim() }
if ($room -eq "") {
    Write-Host "[FAIL] probe did not create a room (see $probeOut)" -ForegroundColor Red
} else {
    Write-Host "==> room $room : start authority process" -ForegroundColor Cyan
    $auth = Start-Process -FilePath $godotBin -PassThru -NoNewWindow -RedirectStandardOutput $authOut `
        -RedirectStandardError ($authOut + ".err") -ArgumentList @(
            "--headless", "--path", $projCopy, "res://server/AuthorityMain.tscn", "--",
            "--room=$room", "--host=127.0.0.1", "--port=$Port")
    $null = $probe.WaitForExit($TimeoutSec * 1000)
    Start-Sleep -Milliseconds 500
    try { if (-not $auth.HasExited) { $auth.Kill() } } catch { }
}

# Always stop children, whichever branch we took (a Godot scene whose script failed to
# parse spins forever with no script attached: it never exits on its own).
try { if (-not $probe.HasExited) { $probe.Kill() } } catch { }
try { if (-not $relay.HasExited) { $relay.Kill() } } catch { }
Start-Sleep -Milliseconds 500

# Read logs defensively (files may still be flushing).
function Read-Log {
    param([string]$Path, [int]$Tail = 0)
    if (-not (Test-Path $Path)) { return @() }
    try {
        $lines = [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)
    } catch { return @() }
    if ($Tail -gt 0 -and $lines.Count -gt $Tail) {
        return $lines[($lines.Count - $Tail)..($lines.Count - 1)]
    }
    return $lines
}

Write-Host "==> probe output" -ForegroundColor Cyan
Read-Log -Path $probeOut | Where-Object { $_ -match 'E2E_|ERROR|Parse' } | ForEach-Object { Write-Host "    $_" }
Write-Host "==> authority log (tail)" -ForegroundColor Cyan
Read-Log -Path $authOut -Tail 6 | ForEach-Object { Write-Host "    $_" }

$probeLines = Read-Log -Path $probeOut
$passed = $false
foreach ($line in $probeLines) { if ($line -match '^E2E_RESULT PASS') { $passed = $true } }
if ($passed) {
    Write-Host "[PASS] server-authoritative chain works locally" -ForegroundColor Green
    exit 0
}
Write-Host "[FAIL] see $probeOut / $authOut / $relayOut" -ForegroundColor Red
exit 1
