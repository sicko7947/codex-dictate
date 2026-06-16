#!/usr/bin/env bash
# Build the macOS push-to-talk client + the shared Go proxy.
# Run this ON A MAC (needs the Swift toolchain from Command Line Tools + Go).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

echo "==> checking tools"
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
command -v go     >/dev/null || { echo "go not found. brew install go"; exit 1; }
command -v sox    >/dev/null || echo "WARNING: sox not found — brew install sox (needed at runtime)"

echo "==> building proxy -> $BIN_DIR/voxtype-codex-proxy"
( cd "$REPO_DIR/proxy" && CGO_ENABLED=0 go build -ldflags "-s -w" -o "$BIN_DIR/voxtype-codex-proxy" . )

echo "==> building client -> $BIN_DIR/voxtype-mac"
swiftc -O "$REPO_DIR/mac/voxtype-mac.swift" -o "$BIN_DIR/voxtype-mac"

echo
echo "Done. Next:"
echo "  1) make sure ~/.codex/auth.json exists (codex login / Codex desktop)"
echo "  2) start the proxy:   $BIN_DIR/voxtype-codex-proxy &"
echo "  3) start the client:  $BIN_DIR/voxtype-mac"
echo "     (first run prompts for Microphone, Input Monitoring, Accessibility —"
echo "      approve all three, then restart the client)"
echo
echo "Or install both as login agents:  ./mac/install-agents.sh"
