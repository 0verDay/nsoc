@echo off
REM ============================================================
REM  NSOC relay launcher (Windows Server)
REM  Keep this file in the SAME folder as nsoc-server.exe.
REM  Edit the two settings below, then run / schedule this file.
REM  ASCII only -- cmd.exe would garble non-ANSI comments.
REM ============================================================

REM --- Listen port. The Tencent Cloud security group must allow it. ---
set "PORT=8080"

REM --- Authority shared secret. MUST be byte-identical on the relay AND on the
REM     authority process. Leave it EMPTY to disable authority registration:
REM     clients then silently fall back to v1 (no anti-cheat).
set "NSOC_AUTHORITY_KEY=6f1c167ff4703318ff444885e49b0aa3d681daac7e736aae1e29e20c2c4852f4"

cd /d "%~dp0"
REM The relay timestamps its own lines; no need to echo %date% here
REM (cmd's localised date would be written in the OEM codepage and garble).
"%~dp0nsoc-server.exe" >> "%~dp0relay.log" 2>&1
echo relay exited with code %ERRORLEVEL% >> "%~dp0relay.log"
