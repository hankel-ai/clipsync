<#
    clipsync-bridge.ps1 - tiny TCP listener that exposes the LOCAL machine's
    interactive-session clipboard over loopback.

    Runs on LOCAL in the user's interactive logon session (auto-started from
    the Startup folder via install-local.ps1). REMOTE talks to it through
    its existing SSH connection: `ssh local "curl -s http://127.0.0.1:8765/..."`.
    The SSH session itself can't see the clipboard, but it can dial localhost,
    and the listener (which IS in the interactive session) can.

    Endpoints:
      GET  /ping     -> "pong"
      GET  /kind     -> "text" | "files" | "empty"
      GET  /text     -> clipboard text (UTF-8 body)
      POST /text     -> set clipboard from request body (UTF-8)
      GET  /files    -> file paths, one per line
      POST /files    -> set clipboard FileDropList from newline-separated paths

    No auth: bound to 127.0.0.1 only, reachable only via this user's loopback.

    PowerShell 5.1 is STA by default; we assert STA on startup and bail
    otherwise (clipboard APIs require single-threaded apartment).
#>

[CmdletBinding()]
param(
    [string]$Bind = '127.0.0.1',
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "Bridge requires STA. Launch with: powershell -Sta -NoProfile -File <this script>"
    exit 2
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$logDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir 'clipsync-bridge.log'

function Log($msg) {
    try {
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Read-Line($stream) {
    $sb = New-Object Text.StringBuilder
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { return $null }
        if ($b -eq 10) { break }                       # LF
        if ($b -eq 13) { continue }                    # CR (skip)
        [void]$sb.Append([char]$b)
    }
    return $sb.ToString()
}

function Read-Body($stream, [int]$length) {
    if ($length -le 0) { return [byte[]]@() }
    $buf = New-Object byte[] $length
    $read = 0
    while ($read -lt $length) {
        $n = $stream.Read($buf, $read, $length - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    if ($read -lt $length) { $buf = $buf[0..($read-1)] }
    return $buf
}

function Write-Response($stream, [string]$status, [string]$body) {
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
    $head = "HTTP/1.0 $status`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
    $headBytes = [Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($headBytes, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $stream.Flush()
}

$pruneDays = 7
$stagingDir = Join-Path $env:LOCALAPPDATA 'clipsync\incoming'
if (Test-Path $stagingDir) {
    $cutoff = (Get-Date).AddDays(-$pruneDays)
    Get-ChildItem -Path $stagingDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force; Log "pruned $($_.FullName)" }
            catch { Log "prune failed: $($_.FullName) - $($_.Exception.Message)" }
        }
}

$ip = [Net.IPAddress]::Parse($Bind)
$listener = New-Object Net.Sockets.TcpListener($ip, $Port)
try {
    $listener.Start()
} catch {
    Log "FATAL bind ${Bind}:${Port} - $($_.Exception.Message)"
    throw
}
Log "listening on ${Bind}:${Port}  pid=$PID"

while ($true) {
    $client = $null
    $stream = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.NoDelay = $true
        $client.ReceiveTimeout = 10000
        $client.SendTimeout    = 10000
        $stream = $client.GetStream()

        # Buffer input via a bytestream-aware reader (handles binary bodies).
        $headerLines = @()
        $reqLine = Read-Line $stream
        if (-not $reqLine) { continue }
        $headerLines += $reqLine
        $headers = @{}
        while ($true) {
            $line = Read-Line $stream
            if ($null -eq $line -or $line -eq '') { break }
            $idx = $line.IndexOf(':')
            if ($idx -gt 0) {
                $k = $line.Substring(0, $idx).Trim().ToLower()
                $v = $line.Substring($idx + 1).Trim()
                $headers[$k] = $v
            }
        }
        $cl = 0
        if ($headers.ContainsKey('content-length')) { $cl = [int]$headers['content-length'] }
        $bodyBytes = Read-Body $stream $cl
        $bodyText = if ($bodyBytes.Length -gt 0) { [Text.Encoding]::UTF8.GetString($bodyBytes) } else { '' }

        $parts = $reqLine -split ' '
        $method = $parts[0].ToUpper()
        $path = if ($parts.Length -ge 2) { $parts[1] } else { '/' }
        $key = "$method $path"
        Log "REQ $key  body=$($bodyBytes.Length)B"

        switch ($key) {
            'GET /ping' {
                Write-Response $stream '200 OK' 'pong'
            }
            'GET /kind' {
                $kind = if ([Windows.Forms.Clipboard]::ContainsFileDropList()) { 'files' }
                        elseif ([Windows.Forms.Clipboard]::ContainsText())     { 'text'  }
                        else { 'empty' }
                Write-Response $stream '200 OK' $kind
            }
            'GET /text' {
                $text = [Windows.Forms.Clipboard]::GetText([Windows.Forms.TextDataFormat]::UnicodeText)
                if ($null -eq $text) { $text = '' }
                Write-Response $stream '200 OK' $text
            }
            'POST /text' {
                if ($bodyText.Length -eq 0) {
                    [Windows.Forms.Clipboard]::Clear()
                } else {
                    [Windows.Forms.Clipboard]::SetText($bodyText, [Windows.Forms.TextDataFormat]::UnicodeText)
                }
                Write-Response $stream '200 OK' 'ok'
            }
            'GET /files' {
                $files = [Windows.Forms.Clipboard]::GetFileDropList()
                $arr = @()
                if ($files) { foreach ($f in $files) { $arr += [string]$f } }
                Write-Response $stream '200 OK' ($arr -join "`n")
            }
            'POST /files' {
                $paths = ($bodyText -split "`r?`n") | Where-Object { $_ -ne '' }
                if (-not $paths -or $paths.Count -eq 0) {
                    Write-Response $stream '400 Bad Request' 'no paths in body'
                } else {
                    $quoted = ($paths | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ','
                    $script = "Set-Clipboard -Path $quoted"
                    $encBytes = [Text.Encoding]::Unicode.GetBytes($script)
                    $enc = [Convert]::ToBase64String($encBytes)
                    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                        '-NoProfile', '-Sta', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc
                    ) -Wait -PassThru -WindowStyle Hidden
                    if ($proc.ExitCode -eq 0) {
                        Write-Response $stream '200 OK' 'ok'
                    } else {
                        Write-Response $stream '500 Internal' "Set-Clipboard exit $($proc.ExitCode)"
                    }
                }
            }
            default {
                Write-Response $stream '404 Not Found' "no route for $key"
            }
        }
    } catch {
        Log "ERR $($_.Exception.Message)"
        try { Write-Response $stream '500 Internal' $_.Exception.Message } catch { }
    } finally {
        try { if ($stream) { $stream.Close() } } catch { }
        try { if ($client) { $client.Close() } } catch { }
    }
}
