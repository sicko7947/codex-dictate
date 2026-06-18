# codex-dictate

> System-wide **push-to-talk dictation** on **Linux and macOS**, transcribed by
> **ChatGPT's backend** (the same one the Codex desktop app uses) — no local GPU
> model, no OpenAI API key, no extra subscription.
>
> 中文说明：[README.zh.md](README.zh.md)

You speak → your OS records → a tiny local proxy adds your ChatGPT login → ChatGPT
transcribes → the text lands at your cursor. It reuses the ChatGPT login you
already have via Codex (`~/.codex/auth.json`).

```
            WAV (push-to-talk)        ┌─────────────────────┐   HTTPS + ChatGPT token   ┌─────────────────────────┐
 capture ─────────────────────────►  │ codex-dictate-proxy │ ────────────────────────► │ chatgpt.com             │
 client    127.0.0.1:8377            │ (local Go binary)   │   browser UA + Bearer     │ /backend-api/transcribe │
        ◄─────────────────────────   └─────────────────────┘ ◄──────────────────────── └─────────────────────────┘
   text at cursor          {"text": "..."}            adds auth from ~/.codex/auth.json
```

The **proxy is shared across platforms**; only the *capture client* (hotkey + mic
+ paste) differs:

| Platform | Capture client | Hotkey | Status |
|----------|----------------|--------|--------|
| **Linux** (Wayland/Hyprland + systemd) | [Voxtype](https://voxtype.io) daemon | SUPER+CTRL+X toggle · **F9 hold** | ✅ supported |
| **macOS** (12+) | bundled `codex-dictate` Swift binary | **fn hold** | ✅ supported |
| **Windows** | — | — | ❌ not supported |

- **Linux** → keep reading below, or jump to [Linux install](#linux-install).
- **macOS** → see **[mac/README.md](mac/README.md)** for the full walkthrough; a
  short version is in [macOS quick start](#macos-quick-start) below.

---

## Why the proxy exists (the short version)

The capture clients can POST audio to any OpenAI-compatible
`/v1/audio/transcriptions` endpoint — but they **can't add custom HTTP headers**.
Talking to ChatGPT's backend needs two things they won't send:

1. **Your ChatGPT auth** — a `Authorization: Bearer <token>` from `~/.codex/auth.json`.
2. **A real browser `User-Agent`** — Cloudflare in front of `chatgpt.com` returns
   **403** to anything that looks like a bot (a bare `Mozilla/5.0` is *not* enough).

So this repo ships a ~10 MB static Go binary that listens on `127.0.0.1:8377`,
speaks the OpenAI multipart format the clients expect, and re-issues each request
to ChatGPT with the right token + UA. It reads `~/.codex/auth.json` **fresh on
every request**, so when Codex refreshes your token, the proxy picks it up
automatically.

It also gently **normalizes loudness** (quiet/Bluetooth-mic recordings get boosted
to a steady level), which measurably improves accuracy. This logic is identical on
both platforms — the proxy is `proxy/main.go`, built the same way everywhere.

---

## Prerequisites (both platforms)

| Need | Why | Install |
|------|-----|---------|
| **Codex login (ChatGPT)** | provides `~/.codex/auth.json` | Codex desktop app, or `codex login` |
| **Go** | builds the proxy | https://go.dev/dl · `brew install go` · `pacman -S go` |

> You need an account that Codex/ChatGPT signs in (a ChatGPT Plus/Pro login works).
> This does **not** use a paid OpenAI API key.

Then follow your platform below.

---

# macOS quick start

Full details + permissions in **[mac/README.md](mac/README.md)**. Short version:

```bash
brew install go sox           # sox records the mic; go builds the proxy
xcode-select --install        # provides swiftc (skip if already installed)

git clone <this-repo-url> codex-dictate
cd codex-dictate
./mac/build.sh                # builds proxy + codex-dictate into ~/.local/bin
./mac/install-agents.sh       # run both as login agents (optional)
```

First run prompts for **Microphone**, **Input Monitoring**, and **Accessibility** —
approve all three, then restart the client. Now **hold fn**, speak, release: the
transcript pastes at your cursor.

Verify the login-agent install:

```bash
curl -sS http://127.0.0.1:8377/
launchctl print gui/$(id -u)/io.codexdictate.client | grep 'state = running'
tail -40 ~/Library/Logs/io.codexdictate.client.log
```

The macOS setup is robust for normal daily use, but it is not a 100% guaranteed
input method. Rebuilding an ad-hoc signed binary can make macOS stale the
Accessibility/Input Monitoring grants; if the pill says `Not pasted`, the usual
meaning is that transcription succeeded but macOS blocked Cmd+V, so the transcript
was left on the clipboard. Re-add `~/.local/bin/codex-dictate` under Accessibility
and Input Monitoring, then restart the client agent.

What the macOS client does, mirroring the Linux flow:

- watches the **physical fn key** (a global `NSEvent` monitor on keyCode 63),
- records 16 kHz mono WAV with **`sox`** while held,
- POSTs it to the same proxy on release,
- **pastes** the result (clipboard + Cmd+V, original clipboard restored).
- shows a compact bottom-center status pill while listening/transcribing.

No Xcode project, no `.app` bundle, no Hammerspoon/Karabiner — one Swift file
(`mac/codex-dictate.swift`) compiled to a single binary.

---

# Linux install

Linux uses the [Voxtype](https://voxtype.io) daemon as the capture client.

### Linux requirements

| Need | Why | Install |
|------|-----|---------|
| **Linux + systemd + Wayland** | Voxtype targets Wayland/Hyprland | — |
| **[Voxtype](https://voxtype.io)** | the dictation daemon | Omarchy: `omarchy-voxtype-install` · else see voxtype.io |
| **wtype** *(Wayland)* or **ydotool** | types the transcript at the cursor | `pacman -S wtype` |
| **ffmpeg** *(optional)* | enables the install smoke-test | `pacman -S ffmpeg` |
| **jq** *(optional)* | validates your auth file | `pacman -S jq` |

### Install (the whole thing)

```bash
git clone <this-repo-url> codex-dictate
cd codex-dictate
./setup.sh
```

`setup.sh` is idempotent and conservative — it:

1. checks Voxtype, Go, and your Codex login are present,
2. builds the proxy to `~/.local/bin/codex-dictate-proxy`,
3. installs the Voxtype config preset (**backs up** any existing one),
4. installs the `codex-dictate-proxy` systemd **user** service + two drop-ins for
   `voxtype.service`,
5. enables/starts everything, and
6. runs a real transcribe round-trip to confirm auth + Cloudflare + the backend
   all work.

Then just dictate (see keybindings below).

### Using it (Hyprland keybindings)

| Key | Action |
|-----|--------|
| **SUPER + CTRL + X** | Toggle dictation — press to start, press again to stop & transcribe |
| **F9 (hold)** | Push-to-talk — hold to record, release to transcribe |

- **On [Omarchy](https://omarchy.org)** these binds already ship by default — nothing to do.
- **Otherwise**, add them yourself: copy `config/hypr/voxtype.conf` to `~/.config/hypr/`,
  add `source = ~/.config/hypr/voxtype.conf` to your `hyprland.conf`, then `hyprctl reload`.

Speak a sentence, release, and the transcript is typed wherever your cursor is.

### What got installed (every file)

| Path | What |
|------|------|
| `~/.local/bin/codex-dictate-proxy` | the Go proxy binary |
| `~/.config/voxtype/config.toml` | Voxtype set to `mode = "remote"` → the proxy |
| `~/.config/systemd/user/codex-dictate-proxy.service` | runs the proxy, autostarts with your session |
| `~/.config/systemd/user/voxtype.service.d/10-codex-proxy.conf` | starts the proxy before Voxtype |
| `~/.config/systemd/user/voxtype.service.d/20-no-eager.conf` | drops `--eager-processing` (see below) |

Nothing here contains a secret. Your ChatGPT token stays in `~/.codex/auth.json`
and is read at runtime only.

#### The `--eager-processing` fix
Voxtype's `--eager-processing` transcribes audio **in chunks while you're still
talking** (a latency trick for local Whisper). Over a remote backend each chunk
becomes a **separate, context-free** HTTP request, so words get mangled at the
chunk seams. The `20-no-eager.conf` drop-in removes that flag, so each utterance
is sent as **one** request with full context. This is the single biggest accuracy
win in this repo.

### Switching backends (ChatGPT ↔ local model)
Default is **remote** (ChatGPT). To switch to a local, offline Whisper model and
back, use the bundled script — it edits the `mode` line and restarts the services:

```bash
./switch-mode.sh            # show current mode, then toggle remote ↔ local
./switch-mode.sh remote     # force ChatGPT remote
./switch-mode.sh local      # force local model (download one: voxtype setup model)
./switch-mode.sh status     # just print the current mode
```

### Uninstall (Linux)

```bash
./uninstall.sh
```

Removes the proxy binary, its service, and the drop-ins, and restarts Voxtype.
It leaves `~/.codex/auth.json` alone and does **not** re-download a local model
(your `config.toml` still says `mode = "remote"` — flip it to `"local"` if you want
local transcription back; a backup of your original config is at
`~/.config/voxtype/config.toml.bak-*`).

---

## Configuration knobs

**Proxy** (env vars — set in the systemd unit on Linux, or the launch agent plist
on macOS):

| Variable | Default | Meaning |
|----------|---------|---------|
| `CODEX_DICTATE_PROXY_PORT` | `8377` | listen port (also update the client endpoint) |
| `CODEX_DICTATE_PROXY_HOST` | `127.0.0.1` | listen address (keep it local!) |
| `CODEX_DICTATE_PROXY_TIMEOUT` | `180` | upstream timeout (seconds) |
| `CODEX_DICTATE_BROWSER_UA` | macOS Chrome UA | browser user-agent sent to ChatGPT |
| `CODEX_DICTATE_PROXY_NO_NORMALIZE` | unset | set to `1` to disable loudness normalization |
| `CODEX_DICTATE_PROXY_DEBUG_DIR` | unset | set to a dir (e.g. `/tmp`) to dump the exact audio sent, for debugging |

**macOS client** (`codex-dictate`) env vars: `CODEX_DICTATE_KEYCODE` (default `63` = fn),
`CODEX_DICTATE_LANG` (default `auto`), `CODEX_DICTATE_PROXY_URL`, `CODEX_DICTATE_SOX`,
`CODEX_DICTATE_TRANSCRIBE_TIMEOUT`. See
[mac/README.md](mac/README.md).

**Mic tip:** a wired/USB mic beats a Bluetooth headset for dictation by a wide
margin — Bluetooth mics fall back to a narrowband, compressed profile. If accuracy
is poor, check your input device first (Linux: `pactl list short sources`; macOS:
System Settings → Sound → Input).

---

## Troubleshooting

**Is the proxy up?** (both platforms)

```bash
curl http://127.0.0.1:8377/            # -> {"status":"ok", ...}
```

**Linux logs / debug:**

```bash
systemctl --user status codex-dictate-proxy.service
journalctl --user -u codex-dictate-proxy.service -f
systemctl --user set-environment CODEX_DICTATE_PROXY_DEBUG_DIR=/tmp   # dump sent audio
```

**macOS logs:** `~/Library/Logs/io.codexdictate.*.log` (when run as launch agents).

| Symptom | Likely cause / fix |
|---------|--------------------|
| **HTTP 403** on transcribe | ChatGPT token missing/expired, or Cloudflare. Make sure Codex is signed in (`codex login`); open the Codex app once to refresh. |
| **HTTP 502** | proxy couldn't reach ChatGPT or read `~/.codex/auth.json`. Check the logs. |
| **(macOS) fn does nothing** | grant **Input Monitoring**; if you remapped fn in System Settings → Keyboard, set "Press 🌐 to" → **Do Nothing**, or use a different `CODEX_DICTATE_KEYCODE`. |
| **(macOS) nothing pastes** | grant **Accessibility** (needed to synthesize Cmd+V); restart the client. |
| **(macOS) no audio** | grant **Microphone**; check `sox` is installed (`brew install sox`). |
| **(Linux) garbled text at sentence seams** | `--eager-processing` still on — confirm `20-no-eager.conf` is installed and `systemctl --user daemon-reload && systemctl --user restart voxtype.service`. |
| **(Linux) nothing types** | needs `wtype` (Wayland) or `ydotool`. Install one. |
| **Quiet / missed words** | Bluetooth mic, or input gain low. Use a wired mic. |

---

## Token & refresh

The proxy never stores or refreshes anything itself — it just reads
`~/.codex/auth.json` on each request. Keep **Codex (desktop or CLI) installed and
signed in**; it refreshes the token in the background. If you sign out of Codex,
dictation will start returning 403/502 until you sign back in.

---

## ⚠️ Disclaimer

This routes audio to ChatGPT's **internal** transcription endpoint using your
personal ChatGPT session token and a browser User-Agent. It is an unofficial
integration for **personal use**: it may break at any time if OpenAI changes the
endpoint, and using it could conflict with OpenAI's Terms of Service. No
affiliation with OpenAI or Voxtype. Provided **as-is, no warranty** — you are
responsible for how you use your own account. Don't expose the proxy beyond
`127.0.0.1`.

## License

MIT — see [LICENSE](LICENSE).
