@echo off
robocopy "%~dp0." "%USERPROFILE%\OneDrive\Programs\clipsync" /E /XD .git /PURGE /NFL /NDL /NJH /NJS
echo Deployed clipsync to Programs\clipsync
pause
