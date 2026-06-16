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

## Install

```bash
brew install go sox           # go only needed to build the proxy
xcode-select --install        # provides swiftc (skip if already present)

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
- The proxy is byte-for-byte the same one Linux uses (`proxy/main.go`), including
  the loudness normalization and per-request token refresh.
