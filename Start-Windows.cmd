@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0CodexProxy.ps1" %*
exit /b %errorlevel%
