@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%video-compass.ps1"
  exit /b %errorlevel%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%video-compass.ps1"
exit /b %errorlevel%
