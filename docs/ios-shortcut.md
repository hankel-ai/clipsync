# iOS Shortcut — "Send to PC"

Exact build instructions for the iPhone side of clipsync. Everything here is what the
Shortcuts app actually shows, so the shortcut can be recreated from scratch without
guesswork.

The shortcut sends whatever is on the iPhone clipboard to the bridge's iOS listener. The
bridge decides whether it is an image or text, puts it on the Windows clipboard, saves it,
and answers with the saved file's path.

---

## 1. Get the token

On LOCAL (the Windows machine), once:

```powershell
Get-Content "$env:LOCALAPPDATA\clipsync\ios-token.txt"
```

A 32-character hex string. The bridge generates it on first start if the file is absent.
Deleting the file makes the bridge mint a new one on its next start, which invalidates the
shortcut until you paste the new value in.

## 2. Pick the host

| Where you are | Host to use |
|---|---|
| Anywhere, over Tailscale | the LOCAL machine's tailnet IP, e.g. `100.71.83.150` |
| Home LAN only | the LOCAL machine's LAN IP |

The tailnet address works at home too, so there is no reason to maintain two versions of the
shortcut. Tailscale must be connected on the phone.

Port is **8787**. Plain HTTP, no TLS — the traffic rides inside the Tailscale tunnel.

## 3. Build the shortcut

Three actions. No `If`, no `Detect Images`, no type branching.

### Action 1 — Get Clipboard

Search: **Get Clipboard**. No parameters.

### Action 2 — Get Contents of URL

Search: **Get Contents of URL**. Tap **Show More** to reveal Method, Headers and Request
Body.

| Field | Value |
|---|---|
| URL | `http://100.71.83.150:8787/clip` |
| Method | `POST` |
| Headers | key `X-Token`, value = the 32-char token from step 1 |
| Request Body | **File** |
| (body content) | the **Clipboard** variable from Action 1 |

Request Body must be **File**, not Text or JSON or Form. File sends the clipboard's raw
bytes, which is what lets one endpoint handle both images and text.

### Action 3 — Show Result

Search: **Show Result**. Content: the **Contents of URL** variable from Action 2.

### Optional Action 4 — Copy to Clipboard

Content: **Contents of URL**. This puts the returned Windows path on the *phone's* clipboard
so it can be pasted straight into Claude Code as a file reference.

---

## What comes back

A successful response is the absolute Windows path and nothing else:

```
C:\clipsync-share\incoming\ios_20260916-193349.png
C:\clipsync-share\incoming\ios_20260916-192514.txt
```

Errors are the only prose responses and all begin `ERROR:`.

| Response | Meaning |
|---|---|
| `ERROR: bad or missing X-Token` | Header missing, misspelled, or the token was regenerated |
| `ERROR: empty body` | Clipboard was empty |
| `ERROR: short body N of M` | Upload was cut off; the partial file is discarded |
| `ERROR: could not decode image (N bytes, magic ...)` | No decoder handled it; payload kept as `ios_<stamp>.bin` for diagnosis |
| `ERROR: body N exceeds 67108864 bytes` | Over the 64MB cap |
| `clipboard cleared` | Empty body sent deliberately |

## What the bridge does with each kind

**Images** — PNG, JPEG, GIF, BMP, TIFF, WebP, and HEIC/HEIF/AVIF. iPhone photos are HEIC and
are transcoded to PNG on arrival, so the returned `.png` path is genuinely a PNG and opens
anywhere. The image is also placed on the Windows clipboard.

**Text** — set on the Windows clipboard and saved as `.txt`, UTF-8 without BOM.

**Rich text** — copying from Safari puts RTF on the iOS pasteboard, and Shortcuts hands over
that richest representation, so the body arrives as `{\rtf1\ansi...`. The bridge detects the
`{\rtf` prefix and converts to plain text, preserving bullets, arrows, em dashes, degree
signs and emoji. Nothing to configure on the phone.

## Other endpoints

`/clip` is the one the shortcut uses. If you ever build something that already knows the
type, `POST /image` and `POST /text` skip the sniffing, and `GET /ping` returns `pong` for a
health check. All of them require the same `X-Token` header.

## Troubleshooting

**Nothing happens / connection error** — check Tailscale is connected on the phone, then
verify the listener from LOCAL:

```powershell
Get-NetTCPConnection -LocalPort 8787 -State Listen
```

**Everything returns 403** — the token in the shortcut no longer matches
`%LOCALAPPDATA%\clipsync\ios-token.txt`.

**Bridge log** — `%LOCALAPPDATA%\clipsync\clipsync-bridge.log`. Every request logs as
`REQ POST /clip body=NB ios=True`, rejections as `IOS REJECT`, and decode failures record
the payload's magic bytes and where the file was kept.

## Why it is built this way

Not obvious from the outside, and the reason it is HTTP rather than SSH like the other
REMOTEs: iOS Shortcuts has no scp, and its **Run Script Over SSH** action does not reliably
close stdin, so a remote script that reads stdin to EOF hangs until the client gives up.
Measured about 1 success in 9 over a high-latency path, and every failure leaked an orphaned
`powershell.exe` on LOCAL. HTTP with `Content-Length` has neither problem. Full detail in
`CLAUDE.md`.
