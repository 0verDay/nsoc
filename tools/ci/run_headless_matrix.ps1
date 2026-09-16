<#
.SYNOPSIS
  NSOC headless verification matrix (all local PVE scenes) with a sandbox-friendly runner.

.DESCRIPTION
  Same scenes as tools\ci\run_headless_smoke.ps1, but this runner:
    - launches Godot from the repo copy directly (no temp copy, no $env:TEMP writes),
    - enforces a per-scene timeout and kills stragglers,
    - prints the RESULT line, the STATE_HASH and any FAIL cases for each scene.

  Use it when run_headless_smoke.ps1's temp-copy path is unavailable (confined
  sandboxes forbid writing outside the workspace) or when you just want the whole
  matrix in one go.

  Baselines (docs/NEXT.md group C):
    campaign 1 board  turns=3  -> STATE_HASH 652a3ef286eca42605d10065f817b3cf955ffcfab238417348729a3398331df8
    multi-board PVE   turns=2  -> STATE_HASH 0576fcc90d28747719b68bcb9cb40d79fbc25d08f780a7dda19fb1828995e0ce

  NOTE: the PVP / authority / server-session scenes were deleted together with the
  multiplayer + authority layer (see docs/archive/multiplayer-removal.md).
  ASCII only (Windows PowerShell 5.1 reads BOM-less files as GBK).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_matrix.ps1
#>
[CmdletBinding()]
param(
    [string]$Godot  = "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe",
    [string]$OutDir = "",
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Continue"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$proj = Join-Path $repo "dev_gd\nsoc"
# Default log location is OUTSIDE the repo: the project direction is "engine exports only,
# no build artifacts in the working tree". Pass -OutDir to keep logs somewhere else.
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $env:TEMP "nsoc_matrix" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not (Test-Path $Godot)) { throw "Godot not found: $Godot" }

function Invoke-Scene {
    param([string]$Name, [string]$Scene, [string[]]$Extra)
    $out = Join-Path $OutDir "$Name.log"
    $err = Join-Path $OutDir "$Name.err"
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    $args = @("--headless", "--path", $proj, $Scene, "--") + $Extra
    $p = Start-Process -FilePath $Godot -PassThru -NoNewWindow `
        -RedirectStandardOutput $out -RedirectStandardError $err -ArgumentList $args
    $exited = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { try { $p.Kill() } catch { } }
    $text = @()
    foreach ($f in @($out, $err)) {
        if (Test-Path $f) { $text += (Get-Content $f -ErrorAction SilentlyContinue) }
    }
    $result = ($text | Where-Object { $_ -match '^(?:SMOKE|TESTBATTLE|ROD|RULES|SPARRING|BOARD|CELLVIEW|HSETUP|HCOMBAT|SCENE|CHASH)_RESULT' } | Select-Object -Last 1)
    $hash   = ($text | Where-Object { $_ -match '^STATE_HASH\s+[0-9a-f]{64}' } | Select-Object -Last 1)
    $parse  = ($text | Where-Object { $_ -match 'Parse Error' }).Count
    $fails  = $text | Where-Object { $_ -match '_CASE FAIL' }
    [pscustomobject]@{
        Name = $Name; TimedOut = (-not $exited); Result = "$result".Trim()
        Hash = "$hash".Trim(); ParseErrors = $parse; FailCases = $fails
    }
}

$scenes = @(
    # -- golden paths + high-value suites (docs/NEXT.md group C) -----------------
    @{ Name = "campaign";      Scene = "res://tests/HeadlessBattle.tscn";     Extra = @("--turns=3", "--chapter=res://data/chapters/smoke_test.json", "--seed=20260101", "--watchdog=240") },
    @{ Name = "multiboard";    Scene = "res://tests/HeadlessTestBattle.tscn"; Extra = @("--turns=2", "--watchdog=240") },
    @{ Name = "rules-on-data"; Scene = "res://tests/RulesOnDataTest.tscn";    Extra = @() },
    # -- the rest of the local PVE matrix (.github/workflows/ci.yml) -------------
    @{ Name = "scene-load";    Scene = "res://tests/SceneLoadTest.tscn";       Extra = @() },
    @{ Name = "rules";         Scene = "res://tests/RulesTest.tscn";           Extra = @() },
    # Entry contract after the multiplayer removal: reachable, but no create/join.
    @{ Name = "sparring-entry"; Scene = "res://tests/SparringPanelTest.tscn";  Extra = @() },
    @{ Name = "headless-board"; Scene = "res://tests/HeadlessBoardTest.tscn";  Extra = @() },
    @{ Name = "cell-view";     Scene = "res://tests/CellViewTest.tscn";        Extra = @() },
    @{ Name = "headless-setup"; Scene = "res://tests/HeadlessSetupTest.tscn";  Extra = @() },
    @{ Name = "headless-combat"; Scene = "res://tests/HeadlessCombatTest.tscn"; Extra = @() },
    # Needs tools/ci/build_release.ps1 to have run (it prints SKIP and passes otherwise).
    @{ Name = "content-hash";  Scene = "res://tests/ContentHashTest.tscn";     Extra = @() }
)

$allOk = $true
foreach ($s in $scenes) {
    Write-Host "==> $($s.Name)  $($s.Scene)" -ForegroundColor Cyan
    $r = Invoke-Scene -Name $s.Name -Scene $s.Scene -Extra $s.Extra
    Write-Host "    $($r.Result)"
    if ($r.Hash) { Write-Host "    $($r.Hash)" -ForegroundColor DarkGray }
    if ($r.TimedOut) { Write-Host "    [FAIL] timed out after $TimeoutSec s" -ForegroundColor Red; $allOk = $false }
    if ($r.ParseErrors -gt 0) { Write-Host "    [FAIL] $($r.ParseErrors) parse error(s)" -ForegroundColor Red; $allOk = $false }
    if ($r.Result -notmatch 'PASS|SKIP') { Write-Host "    [FAIL] result is not PASS" -ForegroundColor Red; $allOk = $false }
    if ($r.FailCases) { $r.FailCases | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }; $allOk = $false }
    if ($r.Result -match 'passed=(\d+) failed=(\d+)' -and $Matches[2] -ne "0") {
        Write-Host "    [FAIL] failed=$($Matches[2])" -ForegroundColor Red; $allOk = $false
    }
}

Write-Host ""
if ($allOk) { Write-Host "MATRIX_RESULT PASS (logs in $OutDir)" -ForegroundColor Green; exit 0 }
Write-Host "MATRIX_RESULT FAIL (logs in $OutDir)" -ForegroundColor Red; exit 1
