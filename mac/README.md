# codex-dictate — macOS (fn push-to-talk)

The Linux setup leans on **Voxtype** for the hotkey, mic recording, and typing at
the cursor. macOS has no Voxtype, so this folder ships a tiny native replacement
for exactly that layer and **reuses the same Go proxy** unchanged.

```
hold fn ─► sox records 16 kHz mono WAV
release ─► POST to local proxy 127.0.0.1:8377 ─► proxy adds ChatGPT token + UA
        ◄─ {"text": "..."} ◄─ chatgpt.com/backend-api/transcribe
paste text at cursor (clipboard + Cmd+V, original clipboard restored)
```

Only two dependencies beyond the repo: **`sox`** and your existing
**`~/.codex/auth.json`** (from `codex login` / the Codex desktop app). No Xcode
project, no app bundle, no Hammerspoon/Karabiner.

## Reliability expectation

This is the most robust shape for this repo's constraints: one Swift binary, no
app bundle, no Karabiner/Hammerspoon, no OpenAI API key, and login-agent startup.
It is still not a 100% guaranteed input method because macOS and ChatGPT both sit
outside the repo:

- macOS can revoke or stale **Input Monitoring** / **Accessibility** grants after
  rebuilding an ad-hoc signed binary.
- Bluetooth headset microphones can switch profiles or report as the system
  default input while producing weak audio.
- ChatGPT's web transcription endpoint can return temporary **403** / **429**
  responses even when the local client is healthy.

The client handles the common local failures defensively: it records the default
input plus a configured fallback input, caps stuck recordings, kills stuck `sox`
processes, shows a status pill, and leaves successful transcripts on the
clipboard when macOS blocks auto-paste.

## Install

```bash
brew install go sox           # go only needed to build the proxy
xcode-select --install        # provides swiftc (skip if already present)
test -f ~/.codex/auth.json    # if this fails, run: codex login

cd codex-dictate
./mac/build.sh                # builds proxy + client into ~/.local/bin
```

Then either run them by hand:

```bash
~/.local/bin/codex-dictate-proxy &     # the transcription proxy
~/.local/bin/codex-dictate               # the fn push-to-talk client
```

…or install both as login agents (auto-start + auto-restart):

```bash
./mac/install-agents.sh
```

Recommended daily setup is the login-agent path. It keeps both processes running
after login and restarts them if they crash.

## Verify install

Run these after `./mac/install-agents.sh`:

```bash
curl -sS http://127.0.0.1:8377/
launchctl print gui/$(id -u)/io.codexdictate.proxy | grep 'state = running'
launchctl print gui/$(id -u)/io.codexdictate.client | grep 'state = running'
tail -40 ~/Library/Logs/io.codexdictate.client.log
```

Expected:

- `curl` prints `{"status":"ok", ...}`.
- both launch agents are `running`;
- the client log contains `ready`;
- when you hold fn, the bottom-center status pill appears and the log shows
  `recording... inputs=default, MacBook Pro Microphone` when the fallback exists.

## Permissions (one time)

On first run macOS prompts for these — approve all, then restart the client:

| Permission | Why | Where |
|------------|-----|-------|
| **Microphone** | `sox` records the mic | prompt on first record |
| **Input Monitoring** | observe the fn key | Privacy & Security → Input Monitoring |
| **Accessibility** | synthesize Cmd+V to paste | Privacy & Security → Accessibility |

If you ran it from a terminal, the app needing permission is **your terminal**;
if via the launch agent, it's **`codex-dictate`**. After approving, restart:
`launchctl kickstart -k gui/$(id -u)/io.codexdictate.client`.

If `mac/build.sh` says `signing client ad-hoc`, macOS may treat a rebuilt binary
as a new privacy identity. If fn stops working or text stops pasting after a
rebuild, remove and re-add `~/.local/bin/codex-dictate` in **Input Monitoring**
and **Accessibility**, then run the restart command above.

## Use

Hold **fn** (the Globe key), speak, release. The transcript is pasted wherever
your cursor is.

## Tuning (env vars)

| Var | Default | Notes |
|-----|---------|-------|
| `CODEX_DICTATE_KEYCODE` | `63` (fn) | use another key's keyCode if you don't want fn |
| `CODEX_DICTATE_LANG` | `auto` | force a language, e.g. `en` / `zh` |
| `CODEX_DICTATE_PROXY_URL` | `http://127.0.0.1:8377/v1/audio/transcriptions` | |
| `CODEX_DICTATE_SOX` | auto-detected | full path to `sox` if not on PATH |
| `CODEX_DICTATE_INPUT_DEVICE` | unset | force one CoreAudio input device and disable auto selection |
| `CODEX_DICTATE_FALLBACK_INPUT_DEVICE` | set by installer when available | second input to record in auto mode, e.g. `MacBook Pro Microphone` |
| `CODEX_DICTATE_SILENCE_RMS_DB` | `-75` | default input below this RMS is treated as effectively silent |
| `CODEX_DICTATE_FALLBACK_MARGIN_DB` | `9` | fallback must beat default by this many dB before replacing a non-silent default |
| `CODEX_DICTATE_MAX_RECORDING_SECONDS` | `60` | safety stop if macOS misses the fn release event |
| `CODEX_DICTATE_TRANSCRIBE_TIMEOUT` | `180` | client-side timeout for longer utterance transcription |
| `CODEX_DICTATE_SHOW_UI` | `1` | show the small bottom-center recording/transcribing status pill; set `0` to disable |
| `CODEX_DICTATE_CODESIGN_IDENTITY` | first local identity, else ad-hoc | signing identity used by `mac/build.sh` for stable macOS privacy grants |

Set them in `~/Library/LaunchAgents/io.codexdictate.client.plist`
(`EnvironmentVariables`) when running as an agent.

## Notes / limits

- **fn key**: a global `NSEvent` monitor watches `flagsChanged` for keyCode 63 —
  the *physical* fn key — so arrow/F-keys (which also set the `.function` flag)
  don't trigger it. If you've remapped fn in System Settings ("Press 🌐 to…"),
  set it to **Do Nothing**, or pick a different `CODEX_DICTATE_KEYCODE`.
- **Paste vs. type**: this pastes (Cmd+V) instead of simulating each keystroke —
  faster and Unicode-safe. It briefly uses the clipboard and restores your prior
  contents ~0.4 s later.
- **Bluetooth inputs**: in auto mode the client records the system default input
  and the configured fallback input during the same push-to-talk window, then
  transcribes the recording with the stronger usable signal. This keeps Bluetooth
  earbud mics working when they are healthy, while falling back from silent or
  weak Bluetooth input without losing the utterance.
- **Status pill**: while recording or transcribing, the client shows a compact
  black-and-white pill near the bottom center of the screen. It is
  non-interactive, does not take focus, and can be disabled with
  `CODEX_DICTATE_SHOW_UI=0`.
- **Privacy grants after rebuilds**: `mac/build.sh` signs the client with the
  first local code-signing identity it can find, or with
  `CODEX_DICTATE_CODESIGN_IDENTITY` when set. If no identity exists, it falls
  back to ad-hoc signing; after rebuilding an ad-hoc binary, macOS may require
  re-adding `~/.local/bin/codex-dictate` under Input Monitoring and Accessibility.
- The proxy is byte-for-byte the same one Linux uses (`proxy/main.go`), including
  the loudness normalization and per-request token refresh.

## Troubleshooting

Start with the live logs:

```bash
tail -f ~/Library/Logs/io.codexdictate.client.log
tail -f ~/Library/Logs/io.codexdictate.proxy.log
```

| Symptom | Meaning / fix |
|---------|---------------|
| No pill when holding fn | The client is not seeing the key. Check `launchctl print gui/$(id -u)/io.codexdictate.client`; re-add `~/.local/bin/codex-dictate` under Input Monitoring; ensure fn/Globe is not remapped to another system action. |
| Pill shows, but no text appears | Check the client log. If it says `Accessibility not trusted; left transcript on clipboard`, transcription worked and macOS blocked Cmd+V. Re-add `~/.local/bin/codex-dictate` under Accessibility and restart the client. |
| Pill says `Not pasted` | The final output step failed or the transcript was empty. The most common case is Accessibility blocking paste; the transcript may already be on the clipboard. |
| Long hold seems stuck | The client has `CODEX_DICTATE_MAX_RECORDING_SECONDS` as a safety stop and will interrupt/terminate stuck `sox`; check logs for `max recording duration reached` or `sox did not stop`. |
| Wrong mic or weak Bluetooth audio | Leave auto mode on. The installer sets `CODEX_DICTATE_FALLBACK_INPUT_DEVICE=MacBook Pro Microphone` when available, so the client records both default and fallback and uses the stronger usable signal. |
| Proxy returns 403 | ChatGPT/Cloudflare rejected the web transcription request. Open Codex/ChatGPT so auth and browser session are fresh, then try again. |
| Proxy returns 429 | ChatGPT temporarily rate-limited transcription. Wait for the retry window shown in the proxy response. |
| Need to disable the UI | Set `CODEX_DICTATE_SHOW_UI=0` in the client LaunchAgent `EnvironmentVariables`, then restart the client. |

For a clean local sanity check after edits:

```bash
bash mac/test-client-config.sh
swiftc -parse mac/codex-dictate.swift
swiftc -typecheck mac/codex-dictate.swift
cd proxy && go test ./...
```
