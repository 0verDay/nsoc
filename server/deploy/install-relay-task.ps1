<#
    Registers the NSOC relay as a Windows Scheduled Task that starts at boot
    and restarts if it dies.  Run this ON THE SERVER, in an ELEVATED PowerShell.

    Usage (from the folder that holds nsoc-server.exe):
        powershell -ExecutionPolicy Bypass -File .\install-relay-task.ps1
        powershell -ExecutionPolicy Bypass -File .\install-relay-task.ps1 -DeployDir C:\nsoc

    ASCII only -- Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI and would
    garble any non-ASCII text.
#>
param(
    [string]$DeployDir = $PSScriptRoot,
    [string]$TaskName  = "NSOC Relay"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DeployDir)) { $DeployDir = (Get-Location).Path }

$exe = Join-Path $DeployDir "nsoc-server.exe"
$cmd = Join-Path $DeployDir "run-relay.cmd"

foreach ($f in @($exe, $cmd)) {
    if (-not (Test-Path $f)) { throw "missing file: $f" }
}

Write-Host "Deploy dir : $DeployDir"
Write-Host "Task name  : $TaskName"

# Idempotent: drop any previous registration first.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing task..."
    Stop-ScheduledTask     -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute $cmd -WorkingDirectory $DeployDir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
# ExecutionTimeLimit Zero = never kill the task (default would stop it after 3 days).
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -RestartCount 999 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "NSOC multiplayer relay (WebSocket + room service)" | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-List

Write-Host ""
Write-Host "Installed. Useful commands:"
Write-Host "  health   : curl.exe http://127.0.0.1:8080/health"
Write-Host "  log      : Get-Content '$DeployDir\relay.log' -Tail 30"
Write-Host "  stop     : Stop-ScheduledTask  -TaskName '$TaskName'"
Write-Host "  start    : Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "  uninstall: Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"
