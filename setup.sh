#!/usr/bin/env bash
#
# codex-dictate — installer
#
# Wires Voxtype's "remote" transcription to the ChatGPT (Codex) backend through a
# tiny local Go proxy. Idempotent: safe to re-run. Backs up any file it replaces.
#
#   ./setup.sh            # install everything
#   ./setup.sh --help     # show options
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
VOX_CFG_DIR="$HOME/.config/voxtype"
PROXY_BIN="$BIN_DIR/codex-dictate-proxy"
STAMP="$(date +%Y%m%d-%H%M%S)"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }   # green
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }   # yellow
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }   # red
c_b(){ printf '\033[1m%s\033[0m\n'  "$*"; }   # bold
step(){ printf '\n'; c_b "==> $*"; }
die(){ c_r "ERROR: $*"; exit 1; }

backup(){ # backup $1 if it exists and differs from $2 (the new content source)
  local f="$1"
  [ -e "$f" ] || return 0
  cp -a "$f" "$f.bak-$STAMP"
  c_y "  backed up $f -> $f.bak-$STAMP"
}

[ "${1:-}" = "--help" ] && { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

c_b "codex-dictate installer"
echo "repo: $REPO_DIR"

# ---------------------------------------------------------------- preflight ---
step "Checking prerequisites"

command -v systemctl >/dev/null || die "systemd is required (systemctl not found)."
systemctl --user show-environment >/dev/null 2>&1 || die "systemd --user is not available in this session."

if ! command -v voxtype >/dev/null; then
  c_r "  'voxtype' is not installed or not on PATH."
  echo "    Install it first:"
  echo "      - Omarchy:  omarchy-voxtype-install   (or the Omarchy menu -> Install -> Voxtype)"
  echo "      - Otherwise: see https://voxtype.io"
  die "Install Voxtype, then re-run ./setup.sh"
fi
c_g "  voxtype: $(command -v voxtype)"

if ! command -v go >/dev/null; then
  c_r "  'go' (Go toolchain) is required to build the proxy."
  echo "    Arch:    sudo pacman -S go"
  echo "    Other:   https://go.dev/dl/"
  die "Install Go, then re-run ./setup.sh"
fi
c_g "  go: $(go version | awk '{print $3}')"

AUTH="$HOME/.codex/auth.json"
if [ ! -f "$AUTH" ]; then
  c_r "  ~/.codex/auth.json not found."
  echo "    This tool reuses your ChatGPT login from Codex. Install & sign in first:"
  echo "      - Codex Desktop, or the Codex CLI:  codex login"
  die "Sign in to Codex (ChatGPT), then re-run ./setup.sh"
fi
if command -v jq >/dev/null; then
  MODE="$(jq -r '.auth_mode // "unknown"' "$AUTH" 2>/dev/null || echo unknown)"
  HAS_TOK="$(jq -r 'if (.tokens.access_token // "") != "" then "yes" else "no" end' "$AUTH" 2>/dev/null || echo no)"
  [ "$HAS_TOK" = "yes" ] || die "~/.codex/auth.json has no access_token. Run 'codex login' (ChatGPT mode)."
  c_g "  codex auth: present (auth_mode=$MODE)"
  [ "$MODE" = "chatgpt" ] || c_y "  note: auth_mode=$MODE (expected 'chatgpt' from a ChatGPT login)."
else
  c_y "  jq not found — skipping auth.json validation (recommend: install jq)."
fi

command -v ffmpeg >/dev/null && HAVE_FFMPEG=1 || HAVE_FFMPEG=0

# ------------------------------------------------------------- build proxy ---
step "Building the Go proxy"
mkdir -p "$BIN_DIR"
( cd "$REPO_DIR/proxy" && CGO_ENABLED=0 go build -ldflags "-s -w" -o "$PROXY_BIN" . )
c_g "  built $PROXY_BIN ($(du -h "$PROXY_BIN" | cut -f1))"

# ----------------------------------------------------------- install config ---
step "Installing Voxtype config (remote/ChatGPT preset)"
mkdir -p "$VOX_CFG_DIR"
if [ -f "$VOX_CFG_DIR/config.toml" ]; then
  backup "$VOX_CFG_DIR/config.toml"
  c_y "  Your existing config was backed up. Installing the remote preset over it."
  c_y "  (If you had custom settings, merge them back from the .bak file.)"
fi
install -m 0644 "$REPO_DIR/config/voxtype/config.toml" "$VOX_CFG_DIR/config.toml"
# config.toml references the paste hook by absolute path (voxtype does not
# expand ~ or env vars there), so bake in the real $HOME.
sed -i "s|__HOME__|$HOME|g" "$VOX_CFG_DIR/config.toml"
c_g "  wrote $VOX_CFG_DIR/config.toml"

# Focus-aware paste hook: pastes the transcript into the focused window with the
# right key per app (Ctrl+Shift+V in terminals, Ctrl+V elsewhere). Avoids the
# keystroke-injection bug where non-ASCII text trips compositor keybinds.
install -m 0755 "$REPO_DIR/config/voxtype/voxtype-paste-focus" "$BIN_DIR/voxtype-paste-focus"
c_g "  wrote $BIN_DIR/voxtype-paste-focus"

# Select a safe dynamic default input immediately before each recording. This
# avoids Bluetooth SCO when a wired input is present without hard-coding one
# particular USB microphone.
install -m 0755 "$REPO_DIR/config/voxtype/voxtype-select-input" "$BIN_DIR/voxtype-select-input"
c_g "  wrote $BIN_DIR/voxtype-select-input"

# ---------------------------------------------------------- systemd units ---
step "Installing systemd user services"
mkdir -p "$UNIT_DIR/voxtype.service.d"

install -m 0644 "$REPO_DIR/config/systemd/codex-dictate-proxy.service" "$UNIT_DIR/codex-dictate-proxy.service"
c_g "  wrote codex-dictate-proxy.service"

# Ensure a voxtype.service exists (Omarchy ships one; otherwise create it).
if [ ! -f "$UNIT_DIR/voxtype.service" ] && ! systemctl --user cat voxtype.service >/dev/null 2>&1; then
  c_y "  voxtype.service not found — creating one via 'voxtype setup systemd'."
  voxtype setup systemd >/dev/null 2>&1 || c_y "  (could not auto-create; the drop-in still applies if you add one later)"
fi

# Older local installs used voxtype-codex-proxy.service and the same drop-in
# filename. Migrate those files before installing the canonical unit/drop-in;
# otherwise both proxies can be pulled in and race for 127.0.0.1:8377.
LEGACY_UNIT="$UNIT_DIR/voxtype-codex-proxy.service"
LEGACY_DROPIN="$UNIT_DIR/voxtype.service.d/10-codex-proxy.conf"
if [ -f "$LEGACY_UNIT" ]; then
  step "Migrating the legacy Voxtype proxy service"
  systemctl --user disable --now voxtype-codex-proxy.service 2>/dev/null || true
  mv "$LEGACY_UNIT" "$LEGACY_UNIT.legacy-$STAMP"
  c_y "  moved $LEGACY_UNIT -> $LEGACY_UNIT.legacy-$STAMP"
fi
if [ -f "$LEGACY_DROPIN" ] && grep -q "voxtype-codex-proxy.service" "$LEGACY_DROPIN"; then
  mv "$LEGACY_DROPIN" "$LEGACY_DROPIN.legacy-$STAMP"
  c_y "  moved legacy Voxtype drop-in -> $LEGACY_DROPIN.legacy-$STAMP"
fi

install -m 0644 "$REPO_DIR/config/systemd/voxtype.service.d/10-codex-proxy.conf" "$UNIT_DIR/voxtype.service.d/10-codex-proxy.conf"
install -m 0644 "$REPO_DIR/config/systemd/voxtype.service.d/20-no-eager.conf"   "$UNIT_DIR/voxtype.service.d/20-no-eager.conf"
install -m 0644 "$REPO_DIR/config/systemd/voxtype.service.d/30-restart.conf"    "$UNIT_DIR/voxtype.service.d/30-restart.conf"
c_g "  wrote voxtype.service.d/{10-codex-proxy,20-no-eager,30-restart}.conf"

step "Enabling and starting services"
systemctl --user daemon-reload
# A rebuild can replace an already-running binary; --now alone does not
# restart an active unit, so explicitly restart the canonical proxy here.
systemctl --user enable codex-dictate-proxy.service
systemctl --user restart codex-dictate-proxy.service
systemctl --user restart voxtype.service 2>/dev/null || c_y "  voxtype.service not started (start it once your session has it)."
sleep 1
c_g "  proxy:   $(systemctl --user is-active codex-dictate-proxy.service)"
c_g "  voxtype: $(systemctl --user is-active voxtype.service 2>/dev/null || echo n/a)"

# --------------------------------------------------------------- smoke test ---
step "Smoke test (auth + Cloudflare + transcribe round-trip)"
HEALTH="$(curl -fsS http://127.0.0.1:8377/ 2>/dev/null || true)"
[ -n "$HEALTH" ] && c_g "  proxy health: $HEALTH" || c_y "  proxy health check failed (is the service active?)"

if [ "$HAVE_FFMPEG" = "1" ]; then
  TMP="$(mktemp --suffix=.wav)"
  ffmpeg -hide_banner -loglevel error -f lavfi -i "sine=frequency=300:duration=1" \
    -ac 1 -ar 16000 -c:a pcm_s16le "$TMP" -y
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8377/v1/audio/transcriptions \
    -F "file=@$TMP;type=audio/wav;filename=audio.wav")"
  rm -f "$TMP"
  if [ "$CODE" = "200" ]; then
    c_g "  end-to-end transcribe: HTTP 200 (auth OK, empty text is expected for a test tone)"
  else
    c_r "  end-to-end transcribe: HTTP $CODE"
    echo "    403  -> Cloudflare/auth: make sure Codex (ChatGPT) is signed in and the token is fresh."
    echo "    502  -> proxy could not reach ChatGPT or read auth.json."
    echo "    Logs: journalctl --user -u codex-dictate-proxy.service -e"
  fi
else
  c_y "  ffmpeg not found — skipped audio round-trip (install ffmpeg for the full check)."
fi

# ------------------------------------------------------------------ summary ---
step "Done"
cat <<EOF
Dictation now goes to ChatGPT. Trigger it with your Hyprland keybinding:

  $(c_b 'SUPER + CTRL + X')   toggle dictation (press to start, press again to stop)
  $(c_b 'F9 (hold)')          push-to-talk

On Omarchy these binds exist by default. Otherwise add them:
  source config/hypr/voxtype.conf  -> see that file's header, then 'hyprctl reload'.

Useful commands:
  systemctl --user status codex-dictate-proxy.service
  journalctl --user -u codex-dictate-proxy.service -f
  ./uninstall.sh                 # revert everything

Switch between ChatGPT (remote) and a local model anytime:
  ./switch-mode.sh               # toggle remote <-> local (also: remote|local|status)
EOF
