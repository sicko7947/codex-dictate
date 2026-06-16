# voxtype-codex-dictation

> 中文说明：[README.zh.md](README.zh.md)

Use **[Voxtype](https://voxtype.io)** for system-wide push-to-talk dictation on Linux,
but send the audio to **ChatGPT's transcription backend** (the same one the Codex
desktop app uses) instead of running a local Whisper model.

You speak → Voxtype records → a tiny local proxy adds your ChatGPT login → ChatGPT
transcribes → the text is typed at your cursor. No local GPU model, no OpenAI API
key, no extra subscription — it reuses the ChatGPT login you already have via Codex.

```
┌──────────┐   WAV (push-to-talk)   ┌─────────────────────┐   HTTPS + ChatGPT token   ┌────────────────────────┐
│ Voxtype  │ ─────────────────────► │ voxtype-codex-proxy │ ────────────────────────► │ chatgpt.com            │
│ (daemon) │   127.0.0.1:8377       │ (local Go binary)   │   browser UA + Bearer     │ /backend-api/transcribe │
└──────────┘ ◄───────────────────── └─────────────────────┘ ◄──────────────────────── └────────────────────────┘
        types text          {"text": "..."}            adds auth from ~/.codex/auth.json
```

---

## Why the proxy exists (the short version)

Voxtype's built-in "remote" mode can POST audio to any OpenAI-compatible
`/v1/audio/transcriptions` endpoint — but it **can't add custom HTTP headers**.
Talking to ChatGPT's backend needs two things Voxtype won't send:

1. **Your ChatGPT auth** — a `Authorization: Bearer <token>` from `~/.codex/auth.json`.
2. **A real browser `User-Agent`** — Cloudflare in front of `chatgpt.com` returns
   **403** to anything that looks like a bot (a bare `Mozilla/5.0` is *not* enough).

So this repo ships a ~10 MB static Go binary that listens on `127.0.0.1:8377`,
speaks the OpenAI multipart format Voxtype expects, and re-issues each request to
ChatGPT with the right token + UA. It reads `~/.codex/auth.json` **fresh on every
request**, so when Codex refreshes your token, the proxy picks it up automatically.

It also gently **normalizes loudness** (quiet/Bluetooth-mic recordings get boosted
to a steady level), which measurably improves accuracy.

---

## Requirements

| Need | Why | Install |
|------|-----|---------|
| **Linux + systemd + Wayland** | Voxtype targets Wayland/Hyprland | — |
| **[Voxtype](https://voxtype.io)** | the dictation daemon | Omarchy: `omarchy-voxtype-install` · else see voxtype.io |
| **Codex login (ChatGPT)** | provides `~/.codex/auth.json` | [Codex desktop app] or `codex login` |
| **Go** | builds the proxy | `sudo pacman -S go` · or https://go.dev/dl |
| **ffmpeg** *(optional)* | enables the install smoke-test | `sudo pacman -S ffmpeg` |
| **jq** *(optional)* | validates your auth file | `sudo pacman -S jq` |

> You need an account that Codex/ChatGPT signs in (a ChatGPT Plus/Pro login works).
> This does **not** use a paid OpenAI API key.

---

## Install (the whole thing)

```bash
git clone <this-repo-url> voxtype-codex-dictation
cd voxtype-codex-dictation
./setup.sh
```

`setup.sh` is idempotent and conservative — it:

1. checks Voxtype, Go, and your Codex login are present,
2. builds the proxy to `~/.local/bin/voxtype-codex-proxy`,
3. installs the Voxtype config preset (**backs up** any existing one),
4. installs the `voxtype-codex-proxy` systemd **user** service + two drop-ins for
   `voxtype.service`,
5. enables/starts everything, and
6. runs a real transcribe round-trip to confirm auth + Cloudflare + the backend
   all work.

Then just dictate (see keybindings below).

---

## Using it (Hyprland keybindings)

| Key | Action |
|-----|--------|
| **SUPER + CTRL + X** | Toggle dictation — press to start, press again to stop & transcribe |
| **F9 (hold)** | Push-to-talk — hold to record, release to transcribe |

- **On [Omarchy](https://omarchy.org)** these binds already ship by default — nothing to do.
- **Otherwise**, add them yourself: copy `config/hypr/voxtype.conf` to `~/.config/hypr/`,
  add `source = ~/.config/hypr/voxtype.conf` to your `hyprland.conf`, then `hyprctl reload`.

Speak a sentence, release, and the transcript is typed wherever your cursor is.

---

## What got installed (every file)

| Path | What |
|------|------|
| `~/.local/bin/voxtype-codex-proxy` | the Go proxy binary |
| `~/.config/voxtype/config.toml` | Voxtype set to `mode = "remote"` → the proxy |
| `~/.config/systemd/user/voxtype-codex-proxy.service` | runs the proxy, autostarts with your session |
| `~/.config/systemd/user/voxtype.service.d/10-codex-proxy.conf` | starts the proxy before Voxtype |
| `~/.config/systemd/user/voxtype.service.d/20-no-eager.conf` | drops `--eager-processing` (see below) |

Nothing here contains a secret. Your ChatGPT token stays in `~/.codex/auth.json`
and is read at runtime only.

### The `--eager-processing` fix
Voxtype's `--eager-processing` transcribes audio **in chunks while you're still
talking** (a latency trick for local Whisper). Over a remote backend each chunk
becomes a **separate, context-free** HTTP request, so words get mangled at the
chunk seams. The `20-no-eager.conf` drop-in removes that flag, so each utterance
is sent as **one** request with full context. This is the single biggest accuracy
win in this repo.

---

## Configuration knobs

**Proxy** (env vars in `voxtype-codex-proxy.service`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `VOXTYPE_PROXY_PORT` | `8377` | listen port (also update `remote_endpoint`) |
| `VOXTYPE_PROXY_HOST` | `127.0.0.1` | listen address (keep it local!) |
| `VOXTYPE_PROXY_NO_NORMALIZE` | unset | set to `1` to disable loudness normalization |
| `VOXTYPE_PROXY_DEBUG_DIR` | unset | set to a dir (e.g. `/tmp`) to dump the exact audio sent, for debugging |

**Voxtype** (`~/.config/voxtype/config.toml`): everything standard.

### Switching backends (ChatGPT ↔ local model)
Default is **remote** (ChatGPT). To switch to a local, offline Whisper model and
back, use the bundled script — it edits the `mode` line and restarts the services:

```bash
./switch-mode.sh            # show current mode, then toggle remote ↔ local
./switch-mode.sh remote     # force ChatGPT remote
./switch-mode.sh local      # force local model (download one: voxtype setup model)
./switch-mode.sh status     # just print the current mode
```

**Mic tip:** a wired/USB mic beats a Bluetooth headset for dictation by a wide
margin — Bluetooth mics fall back to a narrowband, compressed profile. If accuracy
is poor, check your input device first (`pactl list short sources`).

---

## Troubleshooting

```bash
# Is the proxy up?
systemctl --user status voxtype-codex-proxy.service
curl http://127.0.0.1:8377/            # -> {"status":"ok", ...}

# Live logs
journalctl --user -u voxtype-codex-proxy.service -f

# See exactly what audio Voxtype is sending (then inspect with ffprobe/your ears)
systemctl --user set-environment VOXTYPE_PROXY_DEBUG_DIR=/tmp   # or edit the unit
```

| Symptom | Likely cause / fix |
|---------|--------------------|
| **HTTP 403** on transcribe | ChatGPT token missing/expired, or Cloudflare. Make sure Codex is signed in (`codex login`); open the Codex app once to refresh. |
| **HTTP 502** | proxy couldn't reach ChatGPT or read `~/.codex/auth.json`. Check the logs. |
| **Garbled text at sentence seams** | `--eager-processing` still on — confirm `20-no-eager.conf` is installed and `systemctl --user daemon-reload && systemctl --user restart voxtype.service`. |
| **Quiet / missed words** | Bluetooth mic, or input gain low. Use a wired mic; check `pactl`. |
| **Nothing types** | needs `wtype` (Wayland) or `ydotool`. Install one. |

---

## Token & refresh

The proxy never stores or refreshes anything itself — it just reads
`~/.codex/auth.json` on each request. Keep **Codex (desktop or CLI) installed and
signed in**; it refreshes the token in the background. If you sign out of Codex,
dictation will start returning 403/502 until you sign back in.

---

## Uninstall

```bash
./uninstall.sh
```

Removes the proxy binary, its service, and the drop-ins, and restarts Voxtype.
It leaves `~/.codex/auth.json` alone and does **not** re-download a local model
(your `config.toml` still says `mode = "remote"` — flip it to `"local"` if you want
local transcription back; a backup of your original config is at
`~/.config/voxtype/config.toml.bak-*`).

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
