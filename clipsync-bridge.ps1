<#
    clipsync-bridge.ps1 - TCP listener that exposes the LOCAL machine's
    interactive-session clipboard over loopback, with a system tray icon.

    Runs on LOCAL in the user's interactive logon session (auto-started from
    the Startup folder via install-local.ps1). REMOTE talks to it through
    its existing SSH connection: `ssh local "curl.exe -s http://127.0.0.1:8765/..."`.

    Endpoints:
      GET  /ping     -> "pong"
      GET  /kind     -> "text" | "files" | "image" | "empty"
      GET  /text     -> clipboard text (UTF-8 body)
      POST /text     -> set clipboard from request body (UTF-8)
      GET  /files    -> file paths (in the shared staging dir), one per line
      POST /files    -> set clipboard FileDropList from newline-separated paths
      GET  /image    -> saves clipboard image as PNG under the shared dir, returns path
      POST /image    -> loads a PNG (in the shared dir) onto the clipboard, deletes it

    No auth: bound to 127.0.0.1 only, reachable only via this user's loopback.

    Shared staging dir (-ShareDir, default C:\clipsync-share):
      File and image payloads transit this directory rather than the bridge
      user's profile. This lets clipsync run over a *separate* low-privilege SSH
      account: scp runs as that account and reads/writes the share, while the
      bridge (running as the interactive desktop user) also reads/writes the
      share. GET /files copies the desktop clipboard's files into the share so
      the SSH account can scp them; the desktop user's private profile stays
      unreadable to the SSH account. See setup-ssh-account.ps1.

    PowerShell 5.1 is STA by default; we assert STA on startup and bail
    otherwise (clipboard APIs require single-threaded apartment).
#>

[CmdletBinding()]
param(
    [string]$Bind = '127.0.0.1',
    [int]$Port = 8765,
    [string]$ShareDir = 'C:\clipsync-share',
    # Second listener for REMOTEs that cannot ssh+curl the loopback bridge.
    # iOS Shortcuts has no scp, and its SSH action does not reliably close
    # stdin, so the ssh+curl transport the other REMOTEs use is unavailable.
    # Token-authenticated because this listener is NOT loopback-only.
    # -IosPort 0 disables it entirely.
    [string]$IosBind = '0.0.0.0',
    [int]$IosPort = 8787,
    [int]$IosMaxBytes = 67108864,
    [string]$IosTokenFile = ''
)

$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Error "Bridge requires STA. Launch with: powershell -Sta -NoProfile -File <this script>"
    exit 2
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# WIC decoders (PresentationCore). GDI+ cannot read HEIC/HEIF/AVIF/WebP even
# when the Store codec extensions are installed; WIC can. Used as a fallback.
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:logDir  = Join-Path $env:LOCALAPPDATA 'clipsync'
if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
$script:logFile = Join-Path $script:logDir 'clipsync-bridge.log'
$script:bridgePath = $MyInvocation.MyCommand.Path

# Shared staging dir (readable/writable by both the bridge's desktop user and
# the low-privilege SSH account). File/image payloads transit here.
#   <share>\outgoing\ : files/images the bridge copies out for REMOTE to scp down
#   <share>\incoming\ : files/images REMOTE scp's up for the bridge to consume
$script:shareDir     = $ShareDir
$script:shareOutgoing = Join-Path $script:shareDir 'outgoing'
$script:shareIncoming = Join-Path $script:shareDir 'incoming'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Log($msg) {
    try {
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
        Add-Content -Path $script:logFile -Value $line -Encoding UTF8
    } catch { }
}

function Read-Line($stream) {
    $sb = New-Object Text.StringBuilder
    while ($true) {
        $b = $stream.ReadByte()
        if ($b -lt 0) { return $null }
        if ($b -eq 10) { break }
        if ($b -eq 13) { continue }
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

function Copy-ToStandaloneBitmap($img) {
    # Image.FromFile locks the file and Image.FromStream keeps a reference to
    # the stream; a Bitmap copy owns neither.
    try { return (New-Object Drawing.Bitmap $img) } finally { $img.Dispose() }
}

function Get-DecodedImage([string]$path) {
    $why = @()

    # Tier 1 - GDI+. Handles PNG, JPEG, GIF, BMP, TIFF.
    # Copied into a standalone Bitmap so the caller never holds a lock on the
    # staged file and can rewrite or delete it freely.
    try {
        return (Copy-ToStandaloneBitmap ([Drawing.Image]::FromFile($path)))
    } catch {
        # GDI+ reports every unsupported format as "Out of memory", so this is
        # the normal path for a HEIC or WebP, not an error condition.
        $why += "GDI+: $($_.Exception.Message)"
    }

    # Tier 2 - WIC. Adds whatever Store codec extensions are installed (WebP,
    # RAW, and HEIF *if* the HEVC Video Extension is also present).
    $fs = $null
    $ms = $null
    try {
        $fs = [IO.File]::OpenRead($path)
        $ms = New-Object IO.MemoryStream
        $dec = [Windows.Media.Imaging.BitmapDecoder]::Create(
            $fs,
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($dec.Frames[0]))
        $enc.Save($ms)
        $ms.Position = 0
        return (Copy-ToStandaloneBitmap ([Drawing.Image]::FromStream($ms)))
    } catch {
        $why += "WIC: $($_.Exception.Message)"
    } finally {
        if ($ms) { $ms.Dispose() }
        if ($fs) { $fs.Dispose() }
    }

    # Tier 3 - ffmpeg. Decodes HEIC/AVIF without any paid Store extension.
    if ($script:ffmpegPath) {
        $tmp = "$path.decoded.png"
        try {
            # $ErrorActionPreference is 'Stop' for this script, and a native exe
            # writing to stderr THROWS under Stop before $LASTEXITCODE is set.
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $script:ffmpegPath -y -v error -i $path -frames:v 1 $tmp 2>&1 | Out-Null
            } finally {
                $ErrorActionPreference = $prevEap
            }
            if (Test-Path -LiteralPath $tmp) {
                return (Copy-ToStandaloneBitmap ([Drawing.Image]::FromFile($tmp)))
            }
            $why += "ffmpeg: produced no output"
        } catch {
            $why += "ffmpeg: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        $why += 'ffmpeg: not on PATH'
    }

    throw ($why -join ' | ')
}

function Set-ClipboardImageBytes([byte[]]$bytes) {
    # Stage into the share like every other image payload, decode, then delete.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $png = Join-Path $script:shareIncoming "ios_$stamp.png"
    $k = 1
    while (Test-Path -LiteralPath $png) {
        $png = Join-Path $script:shareIncoming "ios_$stamp-$k.png"
        $k++
    }
    [IO.File]::WriteAllBytes($png, $bytes)
    $img = $null
    try {
        $img = Get-DecodedImage $png
        [Windows.Forms.Clipboard]::SetImage($img)
        # The file is kept, not deleted: the response is its path, so that
        # whatever reads it (Claude Code, an editor) can open it later. If the
        # upload was not already PNG - an iPhone HEIC, a WebP - overwrite the
        # staged bytes with the decoded PNG so the .png name is truthful and
        # the file is readable by things that cannot decode HEIC.
        if (-not (Test-PngBytes $bytes)) {
            $img.Save($png, [Drawing.Imaging.ImageFormat]::Png)
        }
        return $png
    } catch {
        # Keep the payload rather than deleting evidence of a format we cannot read.
        $kept = [IO.Path]::ChangeExtension($png, '.bin')
        Move-Item -LiteralPath $png -Destination $kept -Force -ErrorAction SilentlyContinue
        $n = [Math]::Min(15, $bytes.Length - 1)
        $hex = (($bytes[0..$n]) | ForEach-Object { $_.ToString('x2') }) -join ' '
        Log "IOS image decode FAILED $($bytes.Length)B magic=[$hex] kept=$kept : $($_.Exception.Message)"
        throw "ERROR: could not decode image ($($bytes.Length) bytes, magic $hex) - kept at $kept"
    } finally {
        if ($img) { $img.Dispose() }
    }
}

function ConvertFrom-Rtf([string]$rtf) {
    # RichTextBox is the only RTF reader in the box. It needs STA, which the
    # bridge already asserts on startup.
    $rtb = New-Object Windows.Forms.RichTextBox
    try {
        $rtb.Rtf = $rtf
        return $rtb.Text
    } finally {
        $rtb.Dispose()
    }
}

function Set-ClipboardTextBytes([string]$text) {
    # iOS carries several clipboard representations at once. Copying from a
    # browser makes public.rtf the richest one, and that is what Shortcuts
    # hands over - so the body arrives as an RTF document, not the text.
    if ($text.TrimStart().StartsWith('{\rtf')) {
        try {
            $plain = ConvertFrom-Rtf $text
            Log "converted RTF body: $($text.Length) -> $($plain.Length) chars"
            $text = $plain
        } catch {
            Log "RTF conversion failed, keeping raw: $($_.Exception.Message)"
        }
    }
    [Windows.Forms.Clipboard]::SetText($text, [Windows.Forms.TextDataFormat]::UnicodeText)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $txt = Join-Path $script:shareIncoming "ios_$stamp.txt"
    $k = 1
    while (Test-Path -LiteralPath $txt) {
        $txt = Join-Path $script:shareIncoming "ios_$stamp-$k.txt"
        $k++
    }
    # UTF8Encoding($false): no BOM, so the file reads cleanly everywhere.
    [IO.File]::WriteAllText($txt, $text, (New-Object Text.UTF8Encoding $false))
    return $txt
}

function Test-PngBytes([byte[]]$b) {
    if ($b.Length -lt 8) { return $false }
    return ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47)
}

function Test-ImageBytes([byte[]]$b) {
    # Sniff by magic number. Shortcuts sends whatever the clipboard held as a
    # file body, so the bridge decides image-vs-text rather than the client.
    if ($b.Length -lt 12) { return $false }
    # PNG
    if ($b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { return $true }
    # JPEG
    if ($b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { return $true }
    # GIF
    if ($b[0] -eq 0x47 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x38) { return $true }
    # BMP
    if ($b[0] -eq 0x42 -and $b[1] -eq 0x4D) { return $true }
    # TIFF (II* / MM*)
    if (($b[0] -eq 0x49 -and $b[1] -eq 0x49 -and $b[2] -eq 0x2A) -or
        ($b[0] -eq 0x4D -and $b[1] -eq 0x4D -and $b[2] -eq 0x00)) { return $true }
    # WebP: 'RIFF' <4 byte size> 'WEBP'
    if ($b[0] -eq 0x52 -and $b[1] -eq 0x49 -and $b[2] -eq 0x46 -and $b[3] -eq 0x46 -and
        $b[8] -eq 0x57 -and $b[9] -eq 0x45 -and $b[10] -eq 0x42 -and $b[11] -eq 0x50) { return $true }
    # ISO-BMFF family: HEIC / HEIF / AVIF - 'ftyp' at offset 4
    if ($b[4] -eq 0x66 -and $b[5] -eq 0x74 -and $b[6] -eq 0x79 -and $b[7] -eq 0x70) { return $true }
    return $false
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

# ---------------------------------------------------------------------------
# Tray icon: green circle with two white sync arrows
# ---------------------------------------------------------------------------
function New-SyncIcon {
    $bmp = New-Object Drawing.Bitmap(16, 16)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([Drawing.Color]::Transparent)

    $green = [Drawing.Color]::FromArgb(34, 177, 76)
    $bg = New-Object Drawing.SolidBrush($green)
    $g.FillEllipse($bg, 0, 0, 15, 15)
    $bg.Dispose()

    $white = [Drawing.Color]::White
    $pen = New-Object Drawing.Pen($white, 1.5)
    $brush = New-Object Drawing.SolidBrush($white)

    # Up arrow (left)
    $g.DrawLine($pen, 5, 5, 5, 12)
    $g.FillPolygon($brush, @(
        (New-Object Drawing.PointF(5, 3)),
        (New-Object Drawing.PointF(3, 6)),
        (New-Object Drawing.PointF(7, 6))
    ))

    # Down arrow (right)
    $g.DrawLine($pen, 10, 4, 10, 11)
    $g.FillPolygon($brush, @(
        (New-Object Drawing.PointF(10, 13)),
        (New-Object Drawing.PointF(8, 10)),
        (New-Object Drawing.PointF(12, 10))
    ))

    $pen.Dispose()
    $brush.Dispose()
    $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---------------------------------------------------------------------------
# Request handler (called on the main STA thread via Forms.Timer)
# ---------------------------------------------------------------------------
function Handle-Connection($listener, [bool]$IsIos = $false) {
    $client = $null
    $stream = $null
    try {
        $client = $listener.AcceptTcpClient()
        $client.NoDelay = $true
        # The iOS listener carries whole images over a phone uplink, which can
        # be slow; the loopback listener never needs more than a moment.
        if ($IsIos) {
            $client.ReceiveTimeout = 120000
            $client.SendTimeout    = 120000
        } else {
            $client.ReceiveTimeout = 10000
            $client.SendTimeout    = 10000
        }
        $stream = $client.GetStream()

        $reqLine = Read-Line $stream
        if (-not $reqLine) { return }
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
        $parts = $reqLine -split ' '
        $method = $parts[0].ToUpper()
        $path = if ($parts.Length -ge 2) { $parts[1] } else { '/' }
        $key = "$method $path"

        # Reject before reading the body, so an unauthorised caller cannot make
        # us buffer megabytes. The loopback listener stays unauthenticated.
        if ($IsIos) {
            $tok = ''
            if ($headers.ContainsKey('x-token')) { $tok = $headers['x-token'] }
            if ($tok -ne $script:iosToken) {
                Log "IOS REJECT $key bad/missing token from $($client.Client.RemoteEndPoint)"
                Write-Response $stream '403 Forbidden' 'ERROR: bad or missing X-Token'
                return
            }
        }

        $cl = 0
        if ($headers.ContainsKey('content-length')) { $cl = [int]$headers['content-length'] }
        if ($IsIos -and $cl -gt $script:iosMaxBytes) {
            Log "IOS REJECT $key oversize $cl"
            Write-Response $stream '413 Payload Too Large' "ERROR: body $cl exceeds $($script:iosMaxBytes) bytes"
            return
        }
        # curl and some HTTP clients withhold a large body until they see this.
        if ($headers.ContainsKey('expect') -and $headers['expect'] -match '100-continue') {
            $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
            $stream.Write($cont, 0, $cont.Length)
            $stream.Flush()
        }

        $bodyBytes = Read-Body $stream $cl
        $bodyText = if ($bodyBytes.Length -gt 0) { [Text.Encoding]::UTF8.GetString($bodyBytes) } else { '' }
        Log "REQ $key  body=$($bodyBytes.Length)B ios=$IsIos"

        if ($IsIos) {
            # Read-Body returns short on a truncated upload; never treat a
            # partial image as a good one.
            if ($bodyBytes.Length -ne $cl) {
                Log "IOS short body $($bodyBytes.Length) of $cl"
                Write-Response $stream '400 Bad Request' "ERROR: short body $($bodyBytes.Length) of $cl"
                return
            }
            switch ($key) {
                'GET /ping' {
                    Write-Response $stream '200 OK' 'pong'
                }
                'POST /image' {
                    if ($bodyBytes.Length -eq 0) {
                        Write-Response $stream '400 Bad Request' 'ERROR: empty body'
                    } else {
                        try {
                            Write-Response $stream '200 OK' (Set-ClipboardImageBytes $bodyBytes)
                        } catch {
                            Write-Response $stream '400 Bad Request' "$($_.Exception.Message)"
                        }
                    }
                }
                'POST /text' {
                    if ($bodyText.Length -eq 0) {
                        [Windows.Forms.Clipboard]::Clear()
                        Write-Response $stream '200 OK' 'clipboard cleared'
                    } else {
                        Write-Response $stream '200 OK' (Set-ClipboardTextBytes $bodyText)
                    }
                }
                'POST /clip' {
                    # One endpoint for a client that cannot branch on type.
                    if ($bodyBytes.Length -eq 0) {
                        [Windows.Forms.Clipboard]::Clear()
                        Write-Response $stream '200 OK' 'clipboard cleared'
                    } elseif (Test-ImageBytes $bodyBytes) {
                        try {
                            Write-Response $stream '200 OK' (Set-ClipboardImageBytes $bodyBytes)
                        } catch {
                            Write-Response $stream '400 Bad Request' "$($_.Exception.Message)"
                        }
                    } else {
                        Write-Response $stream '200 OK' (Set-ClipboardTextBytes $bodyText)
                    }
                }
                default {
                    Write-Response $stream '404 Not Found' "no route $key"
                }
            }
            return
        }

        switch ($key) {
            'GET /ping' {
                Write-Response $stream '200 OK' 'pong'
            }
            'GET /kind' {
                $kind = if ([Windows.Forms.Clipboard]::ContainsFileDropList()) { 'files' }
                        elseif ([Windows.Forms.Clipboard]::ContainsImage())    { 'image' }
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
                # Copy the desktop clipboard's files into the shared staging dir
                # and return THOSE paths. The SSH account can't read the desktop
                # user's private profile, but it can read the share.
                $files = [Windows.Forms.Clipboard]::GetFileDropList()
                if (-not $files -or $files.Count -eq 0) {
                    Write-Response $stream '200 OK' ''
                } else {
                    $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                    $stage = Join-Path $script:shareOutgoing $ts
                    New-Item -ItemType Directory -Force -Path $stage | Out-Null
                    $arr = @()
                    foreach ($f in $files) {
                        $src = [string]$f
                        try {
                            $leaf = Split-Path -Leaf $src
                            $dst  = Join-Path $stage $leaf
                            if (Test-Path -LiteralPath $src -PathType Container) {
                                Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
                            } else {
                                Copy-Item -LiteralPath $src -Destination $dst -Force
                            }
                            $arr += $dst
                        } catch {
                            Log "GET /files copy failed for '$src': $($_.Exception.Message)"
                        }
                    }
                    Write-Response $stream '200 OK' ($arr -join "`n")
                }
            }
            'POST /files' {
                $paths = ($bodyText -split "`r?`n") | Where-Object { $_ -ne '' }
                if (-not $paths -or $paths.Count -eq 0) {
                    Write-Response $stream '400 Bad Request' 'no paths in body'
                } else {
                    $quoted = ($paths | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ','
                    $clipScript = "Set-Clipboard -Path $quoted"
                    $encBytes = [Text.Encoding]::Unicode.GetBytes($clipScript)
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
            'GET /image' {
                $img = [Windows.Forms.Clipboard]::GetImage()
                if ($null -eq $img) {
                    Write-Response $stream '404 Not Found' 'no image on clipboard'
                } else {
                    # Save under the shared dir so the SSH account can scp it down.
                    $outDir = $script:shareOutgoing
                    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
                    $pngPath = Join-Path $outDir ("img_{0}.png" -f [Environment]::TickCount)
                    $img.Save($pngPath, [Drawing.Imaging.ImageFormat]::Png)
                    $img.Dispose()
                    Write-Response $stream '200 OK' $pngPath
                }
            }
            'POST /image' {
                $path = $bodyText.Trim()
                if (-not $path -or -not (Test-Path -LiteralPath $path)) {
                    Write-Response $stream '400 Bad Request' "no png at '$path'"
                } else {
                    $img = [Drawing.Image]::FromFile($path)
                    try { [Windows.Forms.Clipboard]::SetImage($img) }
                    finally { $img.Dispose() }
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    Write-Response $stream '200 OK' 'ok'
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

# ---------------------------------------------------------------------------
# Startup: ensure shared staging dirs exist, prune old transfers (>7 days).
# We prune rather than wipe: the SSH account may be mid-transfer into
# <share>\incoming when the bridge (re)starts, and pruning by age is safe.
# ---------------------------------------------------------------------------
foreach ($d in @($script:shareOutgoing, $script:shareIncoming)) {
    if (-not (Test-Path $d)) {
        try { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        catch { Log "could not create share dir ${d}: $($_.Exception.Message)" }
    }
}
$cutoff = (Get-Date).AddDays(-7)
foreach ($d in @($script:shareOutgoing, $script:shareIncoming)) {
    if (Test-Path $d) {
        try {
            Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            Log "pruned share dir $d (>7d)"
        } catch { Log "share prune failed for ${d}: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# TCP listener
# ---------------------------------------------------------------------------
$ip = [Net.IPAddress]::Parse($Bind)
$script:listener = New-Object Net.Sockets.TcpListener($ip, $Port)
try {
    $script:listener.Start()
} catch {
    Log "FATAL bind ${Bind}:${Port} - $($_.Exception.Message)"
    throw
}
Log "listening on ${Bind}:${Port}  pid=$PID"

# ---------------------------------------------------------------------------
# iOS listener (token-authenticated, not loopback-only)
# ---------------------------------------------------------------------------
# Third-tier image decoder. Optional: absent just means HEIC/AVIF will fail
# with a clear message instead of being decoded.
$script:ffmpegPath = $null
try {
    $ff = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($ff) { $script:ffmpegPath = $ff.Source }
} catch { }
Log "ffmpeg decoder: $(if ($script:ffmpegPath) { $script:ffmpegPath } else { 'NOT FOUND' })"

$script:iosMaxBytes = $IosMaxBytes
$script:iosToken    = ''
$script:iosListener = $null
if ($IosPort -gt 0) {
    $tokenFile = $IosTokenFile
    if (-not $tokenFile) { $tokenFile = Join-Path $script:logDir 'ios-token.txt' }
    if (Test-Path -LiteralPath $tokenFile) {
        $script:iosToken = ([IO.File]::ReadAllText($tokenFile)).Trim()
    }
    if (-not $script:iosToken) {
        $rndBytes = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($rndBytes) } finally { $rng.Dispose() }
        $script:iosToken = ([BitConverter]::ToString($rndBytes) -replace '-', '').ToLower()
        # UTF8Encoding($false): PS 5.1's Set-Content -Encoding UTF8 writes a BOM.
        [IO.File]::WriteAllText($tokenFile, $script:iosToken, (New-Object Text.UTF8Encoding $false))
        Log "generated iOS token -> $tokenFile"
    }
    $iosIp = [Net.IPAddress]::Parse($IosBind)
    $script:iosListener = New-Object Net.Sockets.TcpListener($iosIp, $IosPort)
    try {
        $script:iosListener.Start()
        Log "iOS listener on ${IosBind}:${IosPort}  token=$($script:iosToken.Substring(0,4))...  file=$tokenFile"
    } catch {
        Log "iOS listener bind FAILED ${IosBind}:${IosPort} - $($_.Exception.Message)"
        $script:iosListener = $null
    }
}

# ---------------------------------------------------------------------------
# Hidden form (message-pump owner)
# ---------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = [Windows.Forms.FormWindowState]::Minimized
$form.Visible = $false
$form.Text = 'clipsync-bridge'

# ---------------------------------------------------------------------------
# System tray icon + context menu
# ---------------------------------------------------------------------------
$script:notifyIcon = New-Object Windows.Forms.NotifyIcon
$script:notifyIcon.Icon = New-SyncIcon
$script:notifyIcon.Text = "clipsync-bridge (${Bind}:${Port})"
$script:notifyIcon.Visible = $true

$menu = New-Object Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("Listening on ${Bind}:${Port}")
$statusItem.Enabled = $false
[void]$menu.Items.Add('-')

$logItem = $menu.Items.Add('Open Log')
$logItem.Add_Click({ Start-Process notepad.exe $script:logFile })
[void]$menu.Items.Add('-')

$script:startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'clipsync-bridge.lnk'
$startupItem = New-Object Windows.Forms.ToolStripMenuItem('Start with Windows')
$startupItem.CheckOnClick = $true
$startupItem.Checked = (Test-Path $script:startupLnk)
$startupItem.Add_CheckedChanged({
    if ($startupItem.Checked) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($script:startupLnk)
        $lnk.TargetPath = (Get-Command powershell.exe).Source
        $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Sta -File `"$script:bridgePath`" -Bind $Bind -Port $Port -ShareDir `"$script:shareDir`""
        $lnk.WorkingDirectory = $script:logDir
        $lnk.WindowStyle = 7
        $lnk.Description = 'clipsync clipboard bridge'
        $lnk.Save()
        Log "startup shortcut created"
    } else {
        Remove-Item $script:startupLnk -Force -ErrorAction SilentlyContinue
        Log "startup shortcut removed"
    }
})
[void]$menu.Items.Add($startupItem)
[void]$menu.Items.Add('-')

$restartItem = $menu.Items.Add('Restart')
$restartItem.Add_Click({
    Log "restart requested"
    $script:timer.Stop()
    $script:listener.Stop()
    if ($script:iosListener) { $script:iosListener.Stop() }
    Start-Sleep -Milliseconds 300
    Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden',
        '-ExecutionPolicy', 'Bypass', '-Sta',
        '-File', $script:bridgePath,
        '-Bind', $Bind, '-Port', $Port,
        '-ShareDir', $script:shareDir
    ) -WindowStyle Hidden
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    [Windows.Forms.Application]::Exit()
})
[void]$menu.Items.Add('-')

$exitItem = $menu.Items.Add('Exit')
$exitItem.Add_Click({
    Log "exit requested"
    $script:timer.Stop()
    $script:listener.Stop()
    if ($script:iosListener) { $script:iosListener.Stop() }
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    [Windows.Forms.Application]::Exit()
})

$script:notifyIcon.ContextMenuStrip = $menu

# ---------------------------------------------------------------------------
# Timer: poll for TCP connections every 50ms on the main STA thread
# ---------------------------------------------------------------------------
$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 50
$script:timer.Add_Tick({
    while ($script:listener.Pending()) {
        Handle-Connection $script:listener $false
    }
    if ($script:iosListener) {
        while ($script:iosListener.Pending()) {
            Handle-Connection $script:iosListener $true
        }
    }
})
$script:timer.Start()

# ---------------------------------------------------------------------------
# Clean shutdown on form close
# ---------------------------------------------------------------------------
$form.Add_FormClosing({
    $script:timer.Stop()
    $script:listener.Stop()
    if ($script:iosListener) { $script:iosListener.Stop() }
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
})

# ---------------------------------------------------------------------------
# Run (blocks until Application.Exit())
# ---------------------------------------------------------------------------
[Windows.Forms.Application]::Run($form)
