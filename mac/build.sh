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

echo "==> building proxy -> $BIN_DIR/codex-dictate-proxy"
( cd "$REPO_DIR/proxy" && CGO_ENABLED=0 go build -ldflags "-s -w" -o "$BIN_DIR/codex-dictate-proxy" . )

echo "==> building client -> $BIN_DIR/codex-dictate"
swiftc -O "$REPO_DIR/mac/codex-dictate.swift" -o "$BIN_DIR/codex-dictate"

SIGN_IDENTITY="${CODEX_DICTATE_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/"/ { print $2; exit }')"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> signing client with identity: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" --identifier io.codexdictate.client "$BIN_DIR/codex-dictate"
else
  echo "==> signing client ad-hoc (set CODEX_DICTATE_CODESIGN_IDENTITY for stable macOS privacy grants)"
  codesign --force --sign - --identifier io.codexdictate.client "$BIN_DIR/codex-dictate"
fi

echo
echo "Done. Next:"
echo "  1) make sure ~/.codex/auth.json exists (codex login / Codex desktop)"
echo "  2) start the proxy:   $BIN_DIR/codex-dictate-proxy &"
echo "  3) start the client:  $BIN_DIR/codex-dictate"
echo "     (first run prompts for Microphone, Input Monitoring, Accessibility —"
echo "      approve all three, then restart the client)"
echo
echo "Or install both as login agents:  ./mac/install-agents.sh"
