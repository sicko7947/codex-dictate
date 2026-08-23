#!/usr/bin/env bash
set -euo pipefail

cfg="${1:-config/voxtype/config.toml}"
svc="${2:-config/systemd/codex-dictate-proxy.service}"
min=900

toml_int() {
  awk -F= -v key="$1" '
    $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      gsub(/[[:space:]]/, "", $2)
      print $2
      exit
    }
  ' "$cfg"
}

want_at_least() {
  local key="$1" value
  value="$(toml_int "$key")"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < min )); then
    echo "$cfg: $key=$value, want >= $min" >&2
    exit 1
  fi
}

want_at_least max_duration_secs
want_at_least remote_timeout_secs

grep -Eq '^[[:space:]]*device[[:space:]]*=[[:space:]]*"default"[[:space:]]*$' "$cfg" || {
  echo "$cfg: audio.device must remain dynamic (default)" >&2
  exit 1
}

selector="$(dirname "$cfg")/voxtype-select-input"
[[ -f "$selector" ]] || {
  echo "$selector: missing dynamic input selector" >&2
  exit 1
}
bash -n "$selector"

grep -Eq "(CODEX_DICTATE_PROXY_TIMEOUT|VOXTYPE_PROXY_TIMEOUT)=$min" "$svc" || {
  echo "$svc: missing proxy timeout env set to $min" >&2
  exit 1
}
