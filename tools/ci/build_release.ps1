<#
.SYNOPSIS
  One command -> three release artifacts + version.json (refactor doc section 5.2 / 5.3, NEXT.md B5).

.DESCRIPTION
  Produces, under "<OutDir>\" (default: %TEMP%\nsoc_release\<BUILD_ID>):

    NSOC-Client-Android.apk     Android client            (Godot export, best effort)
    NSOC-Client-Windows.exe     Windows client            (Godot export, best effort)
    NSOC-Server-Windows.exe     headless authority server (Godot export, best effort)
    version.json                PROTOCOL_VERSION / CONTENT_HASH / BUILD_ID
    content_manifest.json       data path -> sha256 (the CONTENT_HASH input, shipped for hot-update)
    RELEASE.txt                 what was built, what was skipped and why

  Also refreshes `dev_gd\nsoc\data\content_hash_check.json`: a small sidecar that names one
  data file plus the sha256 the BUILD SIDE computed for it. tests/ContentHashTest.tscn
  recomputes that file with GDScript and compares, which pins the two sha256 implementations
  together (the accumulator stage alone cannot catch a per-file hashing difference, because
  both implementations just feed their own values into the same accumulation).

  CONTENT_HASH algorithm (MUST match NetProtocol.content_hash() in
  dev_gd/nsoc/scripts/core/net/protocol.gd):

      acc = "nsoc-content-v1"
      for each file (keys sorted):
          acc += "|" + key + ":" + sha256_hex_of(sha256_hex_of(file bytes))
      CONTENT_HASH = sha256_hex_of(utf8(acc))

  Note the DOUBLE hash, which is easy to get wrong (it was, until verified against the
  engine): the inner step hashes the ASCII hex digest, and the outer step hashes the
  assembled accumulator. Both use plain SHA-256 over UTF-8 bytes - Godot's
  `String.sha256_text()` does NOT append a NUL (measured against the engine).

  MANIFEST NOTE: `content_manifest.json` lists the raw-byte sha256 of each file (the useful,
  portable value). The CONTENT_HASH above is derived from the double-hash chain, so do not
  try to recompute it from the manifest by hand - read version.json instead.

  Export prerequisites (skipped gracefully when missing, reported in RELEASE.txt):
    - Godot 4.7.x export templates installed (the editor installs them under
      %APPDATA%\Godot\export_templates\<version>.stable\)
    - a headless-server preset in export_presets.cfg (only Android + Windows Desktop
      exist today; this script does NOT modify that file)

  The Windows client is exported as ONE self-contained exe: the preset has
  `binary_format/embed_pck=true`, so the .pck is baked into NSOC.exe (~127 MB) and the
  player only copies a single file. `NSOC.console.exe` (0.1 MB) is an optional wrapper
  that shows a console window with the game's log output - useful for acceptance runs.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\build_release.ps1

.EXAMPLE
  # version.json only - fast, no Godot needed (useful in CI / before a deploy)
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\build_release.ps1 -SkipExport
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$OutDir   = "",
    [string]$Godot    = "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe",
    [string]$BuildId  = "",
    [string]$Version  = "1.0.0",
    [switch]$SkipExport,
    [int]$ExportTimeoutSec = 900
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
$project = Join-Path $RepoRoot "dev_gd\nsoc"
$dataDir = Join-Path $project "data"
if (-not (Test-Path $dataDir)) { throw "missing data dir: $dataDir" }

if ([string]::IsNullOrWhiteSpace($BuildId)) {
    $BuildId = Get-Date -Format "yyyyMMdd-HHmmss"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    # Default OUTSIDE the repo: the project direction is "engine exports only, no build
    # artifacts in the working tree". Override with -OutDir (CI passes $RUNNER_TEMP).
    $OutDir = Join-Path $env:TEMP "nsoc_release\$BuildId"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

# ---- 1) content manifest + CONTENT_HASH -------------------------------------
# key = path relative to the project root, using forward slashes (res://-style without
# the scheme) so it is stable across machines. Value = sha256 of the raw file bytes.
Write-Host "==> [1/4] content manifest + CONTENT_HASH ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Cyan

function Get-ContentFiles {
    return Get-ChildItem $dataDir -Recurse -File | Sort-Object FullName
}

function Get-FileSha256Hex {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) |
        ForEach-Object { $_.ToString("x2") })
}

# 1a) refresh the verification sidecar BEFORE hashing, so the manifest covers it.
# It names the first data file (sorted) and the build-side sha256 of its raw bytes.
$firstFile = (Get-ContentFiles | Select-Object -First 1)
$checkPath = Join-Path $dataDir "content_hash_check.json"
if ($null -ne $firstFile) {
    $firstRel = ($firstFile.FullName.Substring($project.Length + 1)).Replace('\', '/')
    $checkObj = [ordered]@{
        version = 1
        note    = "Auto-generated by tools/ci/build_release.ps1; read by tests/ContentHashTest.tscn to pin the PowerShell and GDScript sha256 implementations together. Editing this by hand will fail that test."
        files   = @([ordered]@{ path = $firstRel; sha256 = (Get-FileSha256Hex $firstFile.FullName) })
    }
    Write-Utf8NoBom -Path $checkPath -Text (($checkObj | ConvertTo-Json -Depth 4) + "`n")
    Write-Host "    check file  : $firstRel"
}

# 1b) manifest over every file under data/ EXCEPT the derived manifest itself
# (including it would make CONTENT_HASH depend on its own hash -> never stable).
$files = (Get-ContentFiles | Where-Object { $_.Name -ne "content_manifest.json" })
$manifest = [ordered]@{
    version = 1
    note    = "CONTENT_HASH input; see NetProtocol.content_hash() and tools/ci/build_release.ps1"
    files   = [ordered]@{}
}
foreach ($f in $files) {
    $rel = $f.FullName.Substring($project.Length + 1).Replace('\', '/')
    $manifest.files[$rel] = (Get-FileSha256Hex $f.FullName)
}

$manifestPath = Join-Path $OutDir "content_manifest.json"
Write-Utf8NoBom -Path $manifestPath -Text (($manifest | ConvertTo-Json -Depth 4) + "`n")
# The project also carries a copy: the manifest is what a client/server ships alongside the
# data so content mismatches can be diagnosed (and it is what tests/ContentHashTest.tscn reads).
$projectManifestPath = Join-Path $dataDir "content_manifest.json"
Write-Utf8NoBom -Path $projectManifestPath -Text (($manifest | ConvertTo-Json -Depth 4) + "`n")
# 1c) CONTENT_HASH: replicate NetProtocol.content_hash() exactly.
#   inner = sha256(utf8(sha256_hex(file bytes)))    <- plain SHA-256 of the ASCII hex digest.
#          (verified against the engine: Godot's String.sha256_text() does NOT append a NUL)
#   out   = sha256(utf8("nsoc-content-v1|key:inner|..."))
function Get-InnerHash {
    param([string]$HexDigest)
    $b = [System.Text.Encoding]::UTF8.GetBytes($HexDigest)
    return -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($b) |
        ForEach-Object { $_.ToString("x2") })
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("nsoc-content-v1")
foreach ($rel in ($manifest.files.Keys | Sort-Object)) {
    [void]$sb.Append("|").Append($rel).Append(":").Append((Get-InnerHash $manifest.files[$rel]))
}
$accBytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
$contentHash = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($accBytes) |
    ForEach-Object { $_.ToString("x2") })
Write-Host "    files       : $($manifest.files.Count)"
Write-Host "    CONTENT_HASH: $contentHash"

# ---- 2) PROTOCOL_VERSION (read from the single source of truth) -------------
Write-Host "==> [2/4] read PROTOCOL_VERSION from NetProtocol" -ForegroundColor Cyan
$protocolFile = Join-Path $project "scripts\core\net\protocol.gd"
if (-not (Test-Path $protocolFile)) { throw "missing $protocolFile" }
$protocolVersion = $null
foreach ($line in Get-Content $protocolFile -Encoding UTF8) {
    if ($line -match '^\s*const\s+VERSION\s*:\s*int\s*=\s*(\d+)') {
        $protocolVersion = [int]$Matches[1]
        break
    }
}
if ($null -eq $protocolVersion) { throw "could not parse 'const VERSION: int = N' from $protocolFile" }
Write-Host "    PROTOCOL_VERSION: $protocolVersion"

# ---- 3) version.json --------------------------------------------------------
Write-Host "==> [3/4] version.json" -ForegroundColor Cyan
$versionJson = [ordered]@{
    BUILD_ID         = $BuildId
    VERSION          = $Version
    PROTOCOL_VERSION = $protocolVersion
    CONTENT_HASH     = $contentHash
    CONTENT_FILES    = $manifest.files.Count
    BUILT_AT         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    HOST             = $env:COMPUTERNAME
}
$versionPath = Join-Path $OutDir "version.json"
Write-Utf8NoBom -Path $versionPath -Text (($versionJson | ConvertTo-Json -Depth 3) + "`n")
# The project also carries a copy: the server/client read it at runtime as res://version.json
# (and tests/ContentHashTest.tscn compares CONTENT_HASH against it). Generated, not hand-written.
$projectVersionPath = Join-Path $project "version.json"
Write-Utf8NoBom -Path $projectVersionPath -Text (($versionJson | ConvertTo-Json -Depth 3) + "`n")
Get-Content $versionPath -Encoding UTF8 | ForEach-Object { "    $_" }
Write-Host "    also wrote : $projectVersionPath"

# ---- 4) exports (best effort; never fails the run) --------------------------
$exportResults = @()
if ($SkipExport) {
    Write-Host "==> [4/4] exports SKIPPED (-SkipExport)" -ForegroundColor Yellow
    $exportResults += "exports skipped (-SkipExport)"
} else {
    Write-Host "==> [4/4] exports (best effort)" -ForegroundColor Cyan
    $presets = Join-Path $project "export_presets.cfg"
    $presetText = if (Test-Path $presets) { Get-Content $presets -Raw -Encoding UTF8 } else { "" }
    $targets = @(
        @{ Preset = "Windows Desktop"; Out = "NSOC-Client-Windows.exe"; Must = $false },
        @{ Preset = "Android";         Out = "NSOC-Client-Android.apk"; Must = $false },
        @{ Preset = "NSOC-Server-Windows"; Out = "NSOC-Server-Windows.exe"; Must = $false }
    )
    if (-not (Test-Path $Godot)) {
        $exportResults += "SKIPPED all exports: Godot not found at $Godot"
    } else {
        foreach ($t in $targets) {
            if ($presetText -notmatch [regex]::Escape("name=`"$($t.Preset)`"")) {
                $exportResults += "SKIPPED $($t.Out): no preset named '$($t.Preset)' in export_presets.cfg"
                continue
            }
            $outPath = Join-Path $OutDir $t.Out
            # export_presets.cfg export_path wins for some targets; pass an absolute path anyway
            $args = @("--headless", "--path", $project, "--export-release", $t.Preset, $outPath)
            $p = Start-Process -FilePath $Godot -PassThru -NoNewWindow `
                -RedirectStandardOutput (Join-Path $OutDir "_export_$($t.Out).log") `
                -RedirectStandardError  (Join-Path $OutDir "_export_$($t.Out).err") `
                -ArgumentList $args
            $ok = $p.WaitForExit($ExportTimeoutSec * 1000)
            if (-not $ok) { try { $p.Kill() } catch { } }
            if ($ok -and (Test-Path $outPath)) {
                $mb = [math]::Round((Get-Item $outPath).Length / 1MB, 1)
                Write-Host "    OK      $($t.Out) ($mb MB)" -ForegroundColor Green
                $exportResults += "OK $($t.Out) ($mb MB)"
            } else {
                $reason = "exit=$($p.ExitCode)$(if (-not $ok) { ', timed out' })"
                Write-Host "    SKIPPED $($t.Out): $reason (see _export_$($t.Out).log)" -ForegroundColor Yellow
                $exportResults += "SKIPPED $($t.Out): $reason"
            }
        }
    }
}

# ---- report -----------------------------------------------------------------
$report = @()
$report += "NSOC release build"
$report += "  BUILD_ID         : $BuildId"
$report += "  VERSION          : $Version"
$report += "  PROTOCOL_VERSION : $protocolVersion"
$report += "  CONTENT_HASH     : $contentHash"
$report += "  CONTENT_FILES    : $($manifest.files.Count)"
$report += "  output dir       : $OutDir"
$report += ""
$report += "artifacts:"
foreach ($r in $exportResults) { $report += "  - $r" }
$report += ""
$report += "notes:"
$report += "  - version.json / content_manifest.json are always produced (no Godot needed)."
$report += "  - the project also carries version.json and data/content_manifest.json (runtime copies)."
$report += "  - CONTENT_HASH must equal NetProtocol.content_hash() over the same data files;"
$report += "    verify with: godot --headless --path dev_gd/nsoc res://tests/ContentHashTest.tscn"
$report += "  - the headless-server preset does not exist yet (NEXT.md B5); add it to"
$report += "    export_presets.cfg to get NSOC-Server-Windows.exe."
$reportPath = Join-Path $OutDir "RELEASE.txt"
Write-Utf8NoBom -Path $reportPath -Text (($report -join "`r`n") + "`r`n")

Write-Host ""
Write-Host "=== release ready: $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -File | Where-Object { $_.Name -notlike '_export_*' } |
    Sort-Object Name | ForEach-Object { "    {0,-30} {1,10:N1} KB" -f $_.Name, ($_.Length / 1KB) }
Write-Host ""
Write-Host "CONTENT_HASH = $contentHash"
