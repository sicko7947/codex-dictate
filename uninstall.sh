#!/usr/bin/env bash
#
# codex-dictate — uninstaller. Reverts what setup.sh installed.
# Does NOT touch ~/.codex/auth.json or reinstall any local Whisper model.
#
set -euo pipefail

UNIT_DIR="$HOME/.config/systemd/user"
BIN="$HOME/.local/bin/codex-dictate-proxy"

c_g(){ printf '\033[32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[33m%s\033[0m\n' "$*"; }

echo "Stopping and removing the proxy service..."
systemctl --user disable --now codex-dictate-proxy.service 2>/dev/null || true
rm -f "$UNIT_DIR/codex-dictate-proxy.service"
rm -f "$UNIT_DIR/voxtype.service.d/10-codex-proxy.conf"
rm -f "$UNIT_DIR/voxtype.service.d/20-no-eager.conf"
rmdir "$UNIT_DIR/voxtype.service.d" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user restart voxtype.service 2>/dev/null || true
rm -f "$BIN"
c_g "Removed proxy binary, service, and drop-ins."

echo
c_y "Your ~/.config/voxtype/config.toml still has mode = \"remote\"."
c_y "To go back to a local model, set mode = \"local\" (and re-download a model"
c_y "with 'voxtype setup model'), then: systemctl --user restart voxtype.service"
c_y "Or restore a backup: ls ~/.config/voxtype/config.toml.bak-*"
