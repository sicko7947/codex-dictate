#!/usr/bin/env bash
# Install proxy + client as per-user launchd LaunchAgents so they start at login
# and restart if they crash. Run AFTER ./mac/build.sh. macOS only.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
mkdir -p "$LA_DIR" "$LOG_DIR"

PROXY="$BIN_DIR/codex-dictate-proxy"
CLIENT="$BIN_DIR/codex-dictate"
[ -x "$PROXY" ]  || { echo "missing $PROXY — run ./mac/build.sh first"; exit 1; }
[ -x "$CLIENT" ] || { echo "missing $CLIENT — run ./mac/build.sh first"; exit 1; }

xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

EXPLICIT_INPUT_DEVICE="${CODEX_DICTATE_INPUT_DEVICE:-}"
FALLBACK_INPUT_DEVICE="${CODEX_DICTATE_FALLBACK_INPUT_DEVICE:-}"
if [ -z "$FALLBACK_INPUT_DEVICE" ] && system_profiler SPAudioDataType 2>/dev/null | grep -q '^        MacBook Pro Microphone:'; then
  FALLBACK_INPUT_DEVICE="MacBook Pro Microphone"
fi

write_plist() { # label  program  include_client_env
  local label="$1" prog="$2" include_client_env="${3:-0}" plist="$LA_DIR/$1.plist"
  local escaped_explicit_input_device="" escaped_fallback_input_device=""
  if [ "$include_client_env" = "1" ] && [ -n "$EXPLICIT_INPUT_DEVICE" ]; then
    escaped_explicit_input_device="$(printf '%s' "$EXPLICIT_INPUT_DEVICE" | xml_escape)"
  fi
  if [ "$include_client_env" = "1" ] && [ -n "$FALLBACK_INPUT_DEVICE" ]; then
    escaped_fallback_input_device="$(printf '%s' "$FALLBACK_INPUT_DEVICE" | xml_escape)"
  fi
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$prog</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/$label.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/$label.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
EOF
  if [ -n "$escaped_explicit_input_device" ]; then
    cat >> "$plist" <<EOF
    <key>CODEX_DICTATE_INPUT_DEVICE</key><string>$escaped_explicit_input_device</string>
EOF
  fi
  if [ -n "$escaped_fallback_input_device" ]; then
    cat >> "$plist" <<EOF
    <key>CODEX_DICTATE_FALLBACK_INPUT_DEVICE</key><string>$escaped_fallback_input_device</string>
EOF
  fi
  cat >> "$plist" <<EOF
  </dict>
</dict>
</plist>
EOF
  echo "wrote $plist"
}

write_plist "io.codexdictate.proxy" "$PROXY"
write_plist "io.codexdictate.client" "$CLIENT" 1

for label in io.codexdictate.proxy io.codexdictate.client; do
  launchctl unload "$LA_DIR/$label.plist" 2>/dev/null || true
  launchctl load  "$LA_DIR/$label.plist"
done

echo
echo "Loaded. Logs: $LOG_DIR/io.codexdictate.*.log"
echo "First time only: approve Microphone / Input Monitoring / Accessibility in"
echo "System Settings -> Privacy & Security for 'codex-dictate', then:"
echo "  launchctl kickstart -k gui/\$(id -u)/io.codexdictate.client"
