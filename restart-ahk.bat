@echo off
echo Copying updated script...
if not exist "%LOCALAPPDATA%\clipsync" mkdir "%LOCALAPPDATA%\clipsync"
copy /Y "%~dp0clipsync.ahk" "%LOCALAPPDATA%\clipsync\clipsync.ahk"
echo Stopping old clipsync...
taskkill /F /IM AutoHotkey64.exe >nul 2>&1
timeout /t 1 /nobreak >nul
echo Starting clipsync...
start "" "%LOCALAPPDATA%\AHK\AutoHotkey64.exe" "%LOCALAPPDATA%\clipsync\clipsync.ahk"
echo Done.
pause
