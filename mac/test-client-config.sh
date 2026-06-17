#!/usr/bin/env bash
# Lightweight static checks for the single-file macOS client.
set -euo pipefail

cd "$(dirname "$0")/.."

src="mac/codex-dictate.swift"
agents="mac/install-agents.sh"
readme="mac/README.md"
build="mac/build.sh"

grep -q 'CODEX_DICTATE_INPUT_DEVICE' "$src"
grep -q 'CODEX_DICTATE_FALLBACK_INPUT_DEVICE' "$src"
grep -q 'CODEX_DICTATE_SILENCE_RMS_DB' "$src"
grep -q 'CODEX_DICTATE_MAX_RECORDING_SECONDS' "$src"
grep -q 'chooseAudio' "$src"
grep -q 'wavMetrics' "$src"
grep -q 'already recording; stopping' "$src"
grep -q 'max recording duration reached' "$src"
grep -q 'sox did not terminate; killing' "$src"
grep -q 'AXIsProcessTrusted' "$src"
grep -q 'transcribed chars=' "$src"
grep -q 'left transcript on clipboard' "$src"
grep -q -- '-t", "coreaudio"' "$src"
grep -q 'CODEX_DICTATE_FALLBACK_INPUT_DEVICE' "$agents"
grep -q 'CODEX_DICTATE_INPUT_DEVICE' "$agents"
grep -q 'CODEX_DICTATE_FALLBACK_INPUT_DEVICE' "$readme"
grep -q 'CODEX_DICTATE_INPUT_DEVICE' "$readme"
grep -q 'CODEX_DICTATE_CODESIGN_IDENTITY' "$build"
grep -q -- '--identifier io.codexdictate.client' "$build"
grep -q 'CODEX_DICTATE_CODESIGN_IDENTITY' "$readme"
