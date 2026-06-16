#!/usr/bin/env bash
#
# voxtype-codex-dictation — switch transcription backend.
#
# Flips ~/.config/voxtype/config.toml between:
#   remote  -> ChatGPT (Codex) backend, via the local proxy  (no local model)
#   local   -> a local Whisper GPU/CPU model                  (no network)
#
#   ./switch-mode.sh            # show current mode, then toggle
#   ./switch-mode.sh remote     # force ChatGPT remote mode
#   ./switch-mode.sh local      # force local-model mode
#   ./switch-mode.sh status     # just print the current mode
#
set -euo pipefail

CFG="$HOME/.config/voxtype/config.toml"
STAMP="$(date +%Y%m%d-%H%M%S)"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[31m%s\033[0m\n' "$*"; }
die(){ c_r "ERROR: $*"; exit 1; }

[ -f "$CFG" ] || die "$CFG not found. Run ./setup.sh first."

# Read the mode line inside [whisper] (the first 'mode = "..."' under it).
current_mode(){
  awk '
    /^\[whisper\]/ {inw=1; next}
    /^\[/          {inw=0}
    inw && /^[[:space:]]*mode[[:space:]]*=/ {
      gsub(/.*=[[:space:]]*"?/,""); gsub(/".*/,""); print; exit
    }
  ' "$CFG"
}

set_mode(){ # $1 = remote|local
  local want="$1"
  cp -a "$CFG" "$CFG.bak-$STAMP"
  # Replace ONLY the mode line within the [whisper] block.
  awk -v want="$want" '
    /^\[whisper\]/ {inw=1; print; next}
    /^\[/          {inw=0}
    inw && /^[[:space:]]*mode[[:space:]]*=/ && !done {
      sub(/mode[[:space:]]*=[[:space:]]*"[^"]*"/, "mode = \"" want "\""); done=1
    }
    {print}
  ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
}

restart_services(){
  if [ "$1" = "remote" ]; then
    systemctl --user start voxtype-codex-proxy.service 2>/dev/null || true
  fi
  systemctl --user restart voxtype.service 2>/dev/null \
    || c_y "  (couldn't restart voxtype.service automatically — restart it yourself)"
}

cur="$(current_mode)"
[ -n "$cur" ] || die "couldn't find a 'mode =' line under [whisper] in $CFG."

target="${1:-toggle}"
case "$target" in
  status) echo "current voxtype mode: $cur"; exit 0 ;;
  toggle) [ "$cur" = "remote" ] && target="local" || target="remote" ;;
  remote|local) ;;
  *) die "usage: ./switch-mode.sh [remote|local|status]" ;;
esac

if [ "$cur" = "$target" ]; then
  c_g "Already in '$target' mode. Nothing to do."
  exit 0
fi

echo "switching: $cur -> $target"
set_mode "$target"
restart_services "$target"
c_g "Now in '$target' mode."

if [ "$target" = "local" ]; then
  c_y "Local mode uses the 'model' set under [whisper] (e.g. large-v3)."
  c_y "If you deleted your models, download one:  voxtype setup model"
  c_y "The ChatGPT proxy keeps running but is now idle (harmless)."
else
  c_y "Remote mode sends audio to ChatGPT via the proxy on 127.0.0.1:8377."
  c_y "Make sure Codex (ChatGPT) is signed in so ~/.codex/auth.json is fresh."
fi
