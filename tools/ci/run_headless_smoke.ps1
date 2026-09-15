<#
.SYNOPSIS
  NSOC headless battle smoke test + state hash (refactor doc section 7, stage 0).

.DESCRIPTION
  Runs one PVE campaign battle through the real Main.tscn assembly path and prints
  a state hash per turn. Used to (1) prove the game still runs after a change and
  (2) prove the same seed + same input reproduces the same result (desync check).

  Three layers of protection (all required):
    1. --import warmup: a fresh copy has no .godot/global_script_class_cache.cfg, so
       every class_name fails to resolve. Import once first (also a parse check).
    2. In-script watchdog: Godot force-quits after N seconds.
    3. Process-level timeout: if the harness script fails to parse, Godot spins
       forever with no script attached, so only an external Kill can stop it.

  NOTE: this file must stay pure ASCII. Windows PowerShell 5.1 reads BOM-less files
  as GBK; non-ASCII text here breaks parsing. Chinese docs live in docs/ instead.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -TempCopy -Verify
  Warm up in a temp copy, run twice, compare hashes (recommended after core edits).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1
  In-place run (fastest when .godot already exists).
#>
[CmdletBinding()]
param(
    [string]$Godot = "",
    [string]$Scene = "res://tests/HeadlessBattle.tscn",
    [int]$Turns = 3,
    [string]$Chapter = "res://data/chapters/smoke_test.json",
    [int]$Seed = 20260101,
    [int]$TimeoutSec = 300,
    [int]$WatchdogSec = 240,
    [switch]$Verify,
    [switch]$TempCopy,
    [switch]$FreshCopy,
    [switch]$SkipImport
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

# Run Godot with a process-level timeout. Returns { TimedOut, ExitCode, Text }.
function Invoke-Godot {
    param([string]$GodotBin, [string[]]$Arguments, [int]$TimeoutSec)
    $tag = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $stdout = Join-Path $env:TEMP "nsoc_godot_$tag.out"
    $stderr = Join-Path $env:TEMP "nsoc_godot_$tag.err"
    $p = Start-Process -FilePath $GodotBin -ArgumentList $Arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $exited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) {
        try { $p.Kill() } catch { }
        Start-Sleep -Milliseconds 800
    }
    $text = ""
    if (Test-Path $stdout) { $text += (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $stderr) { $text += "`n" + (Get-Content $stderr -Raw -ErrorAction SilentlyContinue) }
    Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
    $code = if ($exited) { $p.ExitCode } else { -1 }
    return [pscustomobject]@{ TimedOut = (-not $exited); ExitCode = $code; Text = $text }
}

function Get-SmokeResult {
    param([string]$Text)
    # NOTE: plain hashtable, not [ordered]@{} — OrderedDictionary treats an integer
    # key as a positional index and throws ArgumentOutOfRangeException on PS 5.1.
    $turns = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)^TURN_HASH\s+(\d+)\s+([0-9a-f]{64})\s*$')) {
        $turns[[int]$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $state = [regex]::Match($Text, '(?m)^STATE_HASH\s+([0-9a-f]{64})\s*$').Groups[1].Value
    # Accepts smoke (SMOKE_RESULT) / authority (AUTHORITY_RESULT) / multi-board (TESTBATTLE_RESULT)
    # / rules-on-data (ROD_RESULT).
    $res = [regex]::Match($Text, '(?m)^(?:SMOKE|AUTHORITY|TESTBATTLE|ROD)_RESULT\s+(\S+)\s*(.*)$')
    return [pscustomobject]@{
        TurnHashes = $turns
        StateHash  = $state
        Passed     = ($res.Groups[1].Value -eq "PASS")
        Reason     = $res.Groups[2].Value.Trim()
    }
}

$godotBin = Find-Godot -Explicit $Godot
Write-Host "Godot: $godotBin"

$projectPath = $projectSrc
$tempRoot = $null
if ($TempCopy) {
    $tempRoot = Join-Path $env:TEMP "nsoc_smoke_run"
    $projectPath = Join-Path $tempRoot "nsoc"
    if ($FreshCopy -and (Test-Path $tempRoot)) { Remove-Item $tempRoot -Recurse -Force }
    if (-not (Test-Path $projectPath)) {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        Copy-Item $projectSrc -Destination $projectPath -Recurse -Force
        Write-Host "Temp copy created: $projectPath" -ForegroundColor DarkGray
    }
    else {
        Copy-Item (Join-Path $projectSrc "*") -Destination $projectPath -Recurse -Force
        Write-Host "Temp copy synced: $projectPath" -ForegroundColor DarkGray
    }
}

try {
    # -- Step 1: import warmup (doubles as a GDScript parse check) ----------
    if (-not $SkipImport) {
        Write-Host "==> Import warmup (class_name cache + parse check)" -ForegroundColor Cyan
        $imp = Invoke-Godot -GodotBin $godotBin -TimeoutSec $TimeoutSec `
            -Arguments @("--headless", "--path", $projectPath, "--import")
        if ($imp.TimedOut) {
            Write-Host "[FAIL] import did not exit within $TimeoutSec s" -ForegroundColor Red
            exit 1
        }
        $parseErr = [regex]::Matches($imp.Text, 'Parse Error')
        Write-Host "    import exit=$($imp.ExitCode)  parse_errors=$($parseErr.Count)" -ForegroundColor DarkGray
        if ($parseErr.Count -gt 0) {
            Write-Host "[FAIL] GDScript parse errors detected:" -ForegroundColor Red
            ($imp.Text -split "`n" | Where-Object { $_ -match 'Parse Error' } | Select-Object -First 20) |
                ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor Red }
            exit 1
        }
    }

    # -- Step 2/3: smoke run + determinism check ---------------------------
    $smokeArgs = @(
        "--headless", "--path", $projectPath, $Scene, "--",
        "--turns=$Turns", "--chapter=$Chapter", "--seed=$Seed", "--watchdog=$WatchdogSec"
    )

    function Invoke-Smoke {
        Write-Host "==> Run scene: $Scene (turns=$Turns seed=$Seed)" -ForegroundColor Cyan
        $r = Invoke-Godot -GodotBin $godotBin -Arguments $smokeArgs -TimeoutSec $TimeoutSec
        return [pscustomobject]@{
            Raw = $r.Text; TimedOut = $r.TimedOut; ExitCode = $r.ExitCode
            Parsed = (Get-SmokeResult -Text $r.Text)
        }
    }

    $first = Invoke-Smoke
    if ($first.TimedOut -or -not $first.Parsed.Passed) {
        ($first.Raw -split "`n" |
            Where-Object { $_ -notmatch 'certificate store|CategoryInfo|FullyQualifiedErrorId|^\s*\+|at: get_system' } |
            Select-Object -Last 30) | ForEach-Object { Write-Host $_ }
        $why = if ($first.TimedOut) { "process timed out" } else { $first.Parsed.Reason }
        Write-Host "[FAIL] smoke test failed: $why" -ForegroundColor Red
        exit 1
    }
    Write-Host "[PASS] smoke ok, STATE_HASH=$($first.Parsed.StateHash)" -ForegroundColor Green
    # Echo per-case lines (authority test) so failures/successes are visible in CI logs.
    ($first.Raw -split "`n" | Where-Object { $_ -match 'AUTHORITY_CASE|AUTHORITY_RESULT|ROD_CASE|ROD_RESULT|SMOKE_SUMMARY' }) |
        ForEach-Object { Write-Host "    $($_.Trim())" -ForegroundColor DarkGray }
    foreach ($k in ($first.Parsed.TurnHashes.Keys | Sort-Object)) {
        Write-Host ("    turn {0}: {1}" -f $k, $first.Parsed.TurnHashes[$k]) -ForegroundColor DarkGray
    }

    if (-not $Verify) { exit 0 }

    $second = Invoke-Smoke
    if ($second.TimedOut -or -not $second.Parsed.Passed) {
        Write-Host "[FAIL] second smoke run failed: $($second.Parsed.Reason)" -ForegroundColor Red
        exit 1
    }

    $diff = @()
    foreach ($k in ($first.Parsed.TurnHashes.Keys | Sort-Object)) {
        $a = $first.Parsed.TurnHashes[$k]
        $b = if ($second.Parsed.TurnHashes.Contains($k)) { $second.Parsed.TurnHashes[$k] } else { "<missing>" }
        if ($a -ne $b) { $diff += "turn $k : $a != $b" }
    }
    if ($first.Parsed.StateHash -ne $second.Parsed.StateHash) {
        $diff += "final STATE_HASH : $($first.Parsed.StateHash) != $($second.Parsed.StateHash)"
    }
    if ($diff.Count -gt 0) {
        Write-Host "[FAIL] two runs differ (desync / non-determinism):" -ForegroundColor Red
        $diff | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "[PASS] determinism check: per-turn hashes identical across two runs" -ForegroundColor Green
    exit 0
}
finally {
    if ($tempRoot -and (Test-Path $tempRoot)) {
        Write-Host "Temp copy kept at: $tempRoot (reused next run; -FreshCopy to rebuild)" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Pitfall log (keep this):
# 1. A fresh copy has no .godot/global_script_class_cache.cfg, so every class_name
#    fails with "Could not find type ... in the current scope". Run --import first.
# 2. Game.turn.run() is a `-> void` coroutine: `var s = Game.turn.run()` is a hard
#    Parse Error ("Cannot get return value of call to run()"). Must use await.
# 3. If the harness script fails to parse, the scene root has no script, Godot spins
#    forever and never exits; the in-script watchdog lives in that same broken file,
#    so the outer WaitForExit + Kill is mandatory.
# 4. This file must stay ASCII: Windows PowerShell 5.1 reads BOM-less files as GBK.
# ---------------------------------------------------------------------------
