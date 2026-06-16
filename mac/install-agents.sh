#!/usr/bin/env bash
# Install proxy + client as per-user launchd LaunchAgents so they start at login
# and restart if they crash. Run AFTER ./mac/build.sh. macOS only.
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
LA_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
mkdir -p "$LA_DIR" "$LOG_DIR"

PROXY="$BIN_DIR/voxtype-codex-proxy"
CLIENT="$BIN_DIR/voxtype-mac"
[ -x "$PROXY" ]  || { echo "missing $PROXY — run ./mac/build.sh first"; exit 1; }
[ -x "$CLIENT" ] || { echo "missing $CLIENT — run ./mac/build.sh first"; exit 1; }

write_plist() { # label  program
  local label="$1" prog="$2" plist="$LA_DIR/$1.plist"
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
  </dict>
</dict>
</plist>
EOF
  echo "wrote $plist"
}

write_plist "io.voxtype.codex-proxy" "$PROXY"
write_plist "io.voxtype.mac"          "$CLIENT"

for label in io.voxtype.codex-proxy io.voxtype.mac; do
  launchctl unload "$LA_DIR/$label.plist" 2>/dev/null || true
  launchctl load  "$LA_DIR/$label.plist"
done

echo
echo "Loaded. Logs: $LOG_DIR/io.voxtype.*.log"
echo "First time only: approve Microphone / Input Monitoring / Accessibility in"
echo "System Settings -> Privacy & Security for 'voxtype-mac', then:"
echo "  launchctl kickstart -k gui/\$(id -u)/io.voxtype.mac"
