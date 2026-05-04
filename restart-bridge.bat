@echo off
echo Copying updated bridge script...
if not exist "%LOCALAPPDATA%\clipsync" mkdir "%LOCALAPPDATA%\clipsync"
copy /Y "%~dp0clipsync-bridge.ps1" "%LOCALAPPDATA%\clipsync\clipsync-bridge.ps1"
echo Stopping old bridge...
wmic process where "name='powershell.exe' and commandline like '%%clipsync-bridge%%'" call terminate >nul 2>&1
timeout /t 1 /nobreak >nul
echo Starting bridge...
start "" /MIN powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Sta -File "%LOCALAPPDATA%\clipsync\clipsync-bridge.ps1"
timeout /t 2 /nobreak >nul
echo Pinging bridge...
curl.exe -s http://127.0.0.1:8765/ping
echo.
pause
