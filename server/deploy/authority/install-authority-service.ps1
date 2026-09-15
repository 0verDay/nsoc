<#
    Registers the NSOC authority process as a Windows service managed by NSSM,
    on the SAME machine as the relay.  Run ON THE SERVER, in an ELEVATED PowerShell.

    After this, no client-side window has to stay open: the authority comes up at
    boot and restarts itself if it dies.

    Usage (defaults match run-authority.cmd):
        powershell -ExecutionPolicy Bypass -File .\install-authority-service.ps1
        powershell -ExecutionPolicy Bypass -File .\install-authority-service.ps1 `
            -AuthorityKey <key> -Nssm "C:\ntk\nssm.exe"

    ASCII only -- Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI.
#>
param(
    [string]$DeployDir    = "C:\nsoc\authority",
    [string]$ServiceName  = "nsoc-authority",
    [string]$GodotExe     = "",
    [string]$Nssm         = "",
    [string]$AuthorityKey = "6f1c167ff4703318ff444885e49b0aa3d681daac7e736aae1e29e20c2c4852f4",
    [string]$RelayHost    = "127.0.0.1",
    [int]$RelayPort       = 8080,
    [string]$RelayService = "nsoc-server"
)

$ErrorActionPreference = "Stop"

# ---- resolve nssm.exe -------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Nssm)) {
    $candidates = @(
        (Join-Path $DeployDir "nssm.exe"),
        "C:\Users\Administrator\Desktop\nsoc_server\server\nssm.exe",
        "C:\ntk\nssm.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { $Nssm = $c; break } }
    if ([string]::IsNullOrWhiteSpace($Nssm)) {
        $cmd = Get-Command nssm -ErrorAction SilentlyContinue
        if ($cmd) { $Nssm = $cmd.Source }
    }
}
if ([string]::IsNullOrWhiteSpace($Nssm) -or -not (Test-Path $Nssm)) {
    throw "nssm.exe not found. Pass -Nssm <path> (e.g. the copy you already use for nsoc-server)."
}

# ---- resolve the Godot console build ---------------------------------------
if ([string]::IsNullOrWhiteSpace($GodotExe)) {
    $GodotExe = Join-Path $DeployDir "Godot\Godot_v4.7.2-stable_win64_console.exe"
}
$GodotMain = Join-Path (Split-Path $GodotExe -Parent) "Godot_v4.7.2-stable_win64.exe"
$Project   = Join-Path $DeployDir "nsoc"

if (-not (Test-Path $GodotExe))  { throw "missing Godot console exe: $GodotExe" }
if (-not (Test-Path $GodotMain)) { throw "missing Godot main exe (the console build launches it): $GodotMain" }
if (-not (Test-Path $Project))   { throw "missing project dir: $Project" }
if (-not (Test-Path (Join-Path $Project ".godot"))) {
    throw "project has no .godot import cache ($Project\.godot). Copy the folder WITH it, or run once: `"$GodotExe`" --headless --path `"$Project`" --import"
}
if ([string]::IsNullOrWhiteSpace($AuthorityKey)) {
    throw "AuthorityKey is empty. It must match the relay's NSOC_AUTHORITY_KEY; without it every registration is rejected."
}

Write-Host "nssm        : $Nssm"
Write-Host "godot       : $GodotExe"
Write-Host "project     : $Project"
Write-Host "service     : $ServiceName"
Write-Host "relay       : $RelayHost`:$RelayPort"
Write-Host "key length  : $($AuthorityKey.Length)"
Write-Host ""

# ---- drop a previous registration (idempotent) ------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing service $ServiceName ..."
    if ($existing.Status -ne "Stopped") { Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    & $Nssm remove $ServiceName confirm | Out-Null
    Start-Sleep -Seconds 1
}

# ---- install ----------------------------------------------------------------
& $Nssm install $ServiceName $GodotExe | Out-Null
& $Nssm set $ServiceName AppDirectory $Project | Out-Null
& $Nssm set $ServiceName AppParameters "--headless --path `"$Project`" res://server/AuthorityMain.tscn" | Out-Null
& $Nssm set $ServiceName AppEnvironmentExtra "NSOC_AUTHORITY_KEY=$AuthorityKey" "NSOC_RELAY_HOST=$RelayHost" "NSOC_RELAY_PORT=$RelayPort" | Out-Null
& $Nssm set $ServiceName DisplayName "NSOC Authority (Godot headless)" | Out-Null
& $Nssm set $ServiceName Description "Server-authoritative referee: runs the game rules for every v2 match." | Out-Null

# logs (the authority prints to stdout/stderr; rotate at 10 MB)
& $Nssm set $ServiceName AppStdout (Join-Path $DeployDir "authority.out.log") | Out-Null
& $Nssm set $ServiceName AppStderr (Join-Path $DeployDir "authority.log") | Out-Null
& $Nssm set $ServiceName AppRotateFiles 1 | Out-Null
& $Nssm set $ServiceName AppRotateOnline 1 | Out-Null
& $Nssm set $ServiceName AppRotateBytes 10485760 | Out-Null

# boot + crash behaviour
& $Nssm set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $Nssm set $ServiceName AppExit Default Restart | Out-Null
& $Nssm set $ServiceName AppRestartDelay 5000 | Out-Null

# start after the relay (the authority retries anyway, this just avoids noise)
if (Get-Service -Name $RelayService -ErrorAction SilentlyContinue) {
    & $Nssm set $ServiceName DependOnService $RelayService | Out-Null
    Write-Host "depends on  : $RelayService"
}

Write-Host ""
Write-Host "Starting $ServiceName ..."
Start-Service $ServiceName
Start-Sleep -Seconds 12

Get-Service -Name $ServiceName | Select-Object Name, Status, StartType | Format-List

$log = Join-Path $DeployDir "authority.log"
if (Test-Path $log) {
    Write-Host "--- authority.log (tail) ---"
    Get-Content $log -Tail 8
}

Write-Host ""
Write-Host "Useful commands:"
Write-Host "  status : Get-Service $ServiceName"
Write-Host "  log    : Get-Content '$log' -Tail 30"
Write-Host "  stop   : Stop-Service $ServiceName"
Write-Host "  start  : Start-Service $ServiceName"
Write-Host "  remove : & '$Nssm' remove $ServiceName confirm"
Write-Host ""
Write-Host "Expect this line in the log:  [authority] ready, waiting for room assignment"
