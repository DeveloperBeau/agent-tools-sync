#!/usr/bin/env bash
# Start the Caveman proxy without installing, updating, or restarting it.
# Direct mode starts nothing.
set -uo pipefail
CHAIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAIN_DIR/lib/common.sh"
source "$CHAIN_DIR/lib/caveman.sh"

chain_env() {
  local claude
  printf 'unset OPENAI_BASE_URL\n'
  claude="$(caveman_route_url "$(ats_mode)" claude)"
  if [ -n "$claude" ]; then
    printf 'export ANTHROPIC_BASE_URL="%s"\n' "$claude"
  else
    printf 'unset ANTHROPIC_BASE_URL\n'
  fi
}

chain_ready() {
  # Caveman has no /health endpoint; its structured 404 identifies the listener.
  curl --noproxy '*' -sS --max-time 2 "$1" 2>/dev/null |
    python3 -c 'import json,sys
try:
    sys.exit(0 if json.load(sys.stdin).get("error",{}).get("code")=="cave_route_not_found" else 1)
except (ValueError, AttributeError):
    sys.exit(1)'
}

chain_wait() {
  local url="$1" attempt
  for attempt in {1..15}; do
    chain_ready "$url" && return 0
    sleep 1
  done
  warn "caveman did not become ready; leaving existing processes untouched" >&2
  return 1
}

chain_start_caveman() {
  if ! chain_ready http://127.0.0.1:8787/; then
    if port_listening 8787; then
      :
    elif [ "$?" = 1 ]; then
      caveman_start_proxy || return 1
    else
      warn "cannot inspect port 8787"; return 1
    fi
    chain_wait http://127.0.0.1:8787/ || return 1
  fi
  ok "Caveman ready on :8787"
}

chain_start() {
  local mode
  proxy_resume || return 1
  mode="$(ats_mode)"
  if ats_uses caveman; then
    chain_start_caveman || return 1
  fi
  [ "$mode" = direct ] && ok "direct mode: no proxies started"
  ok "proxy mode $mode; agent routes configured by ats"
}

chain_main() {
  case "${1:-start}" in
    start) chain_start ;;
    env) chain_env ;;
    *) echo "usage: bash proxy-chain.sh [start|env]" >&2; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  chain_main "$@"
fi
