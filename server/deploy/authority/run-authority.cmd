@echo off
REM ============================================================
REM  NSOC authority process (Godot headless) -- Windows Server
REM
REM  Layout this file expects:
REM    C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe
REM    C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64.exe
REM    C:\nsoc\authority\nsoc\            (game project, .godot included)
REM
REM  Use this file to test the authority by hand before installing it
REM  as a service (install-authority-service.ps1 does the service).
REM
REM  ASCII only -- cmd.exe would garble non-ANSI comments.
REM ============================================================

REM --- Godot CONSOLE build. The plain .exe writes NOTHING when its output is
REM     redirected to a file, so a service built on it would have no logs.
set "GODOT=C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe"

REM --- game project. The .godot import cache must be present, otherwise every
REM     class_name fails to resolve. If it is missing, run once:
REM       "%GODOT%" --headless --path "%PROJECT%" --import
set "PROJECT=C:\nsoc\authority\nsoc"

REM --- authority shared secret. MUST be identical to the relay's
REM     NSOC_AUTHORITY_KEY (both live on this machine).
set "NSOC_AUTHORITY_KEY=6f1c167ff4703318ff444885e49b0aa3d681daac7e736aae1e29e20c2c4852f4"

REM --- relay endpoints: the relay runs on this same machine.
set "NSOC_RELAY_HOST=127.0.0.1"
set "NSOC_RELAY_PORT=8080"

cd /d "%PROJECT%"
"%GODOT%" --headless --path "%PROJECT%" res://server/AuthorityMain.tscn
echo authority exited with code %ERRORLEVEL%
pause
