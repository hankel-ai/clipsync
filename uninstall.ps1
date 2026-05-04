<#
    uninstall.ps1 - remove clipsync from REMOTE (no admin required).
    Stops the running script, deletes installed files and the startup shortcut.
    Leaves AutoHotkey portable in place (you may use it for other things).
#>

[CmdletBinding()]
param(
    [switch]$RemoveAhk,           # also delete %LOCALAPPDATA%\AHK
    [switch]$RemoveStaging,       # also delete %LOCALAPPDATA%\clipsync\incoming
    [switch]$RemoveSshConfig      # strip 'Host clipsync-local' block from ssh config
)

$ErrorActionPreference = 'SilentlyContinue'
function Info($m) { Write-Host "[clipsync] $m" -ForegroundColor Cyan }

$clipsyncDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
$ahkDir       = Join-Path $env:LOCALAPPDATA 'AHK'
$startupDir   = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'clipsync.lnk'
$sshConf      = Join-Path $env:USERPROFILE '.ssh\config'

# Stop running AHK instances of clipsync
Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
    Where-Object { $_.CommandLine -match 'clipsync\.ahk' } |
    ForEach-Object {
        Info "Stopping AHK pid $($_.ProcessId)"
        Stop-Process -Id $_.ProcessId -Force
    }

if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Info "Removed startup shortcut."
}

if (Test-Path $clipsyncDir) {
    if ($RemoveStaging) {
        Remove-Item $clipsyncDir -Recurse -Force
        Info "Removed $clipsyncDir (script + staging)."
    } else {
        Remove-Item (Join-Path $clipsyncDir 'clipsync.ahk') -Force
        Info "Removed clipsync.ahk; staging dirs left at $clipsyncDir\incoming."
    }
}

if ($RemoveAhk -and (Test-Path $ahkDir)) {
    Remove-Item $ahkDir -Recurse -Force
    Info "Removed AutoHotkey at $ahkDir."
}

if ($RemoveSshConfig -and (Test-Path $sshConf)) {
    $text = Get-Content -Raw $sshConf
    # Strip the 'Host clipsync-local' block (until next 'Host ' line or EOF).
    $stripped = [regex]::Replace($text,
        '(?ims)^\s*Host\s+clipsync-local\b.*?(?=^\s*Host\s+\S|\Z)',
        '')
    Set-Content -Path $sshConf -Value $stripped -Encoding UTF8 -NoNewline
    Info "Removed 'clipsync-local' block from $sshConf."
}

Info "Done."
