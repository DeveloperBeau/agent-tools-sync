#!/usr/bin/env bash
# Start the existing chain without installing, updating, or restarting either proxy.
set -uo pipefail
CHAIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAIN_DIR/lib/common.sh"
source "$CHAIN_DIR/lib/caveman.sh"

chain_env() {
  cat <<'ENV'
export CAVE_SSRF_ALLOWLIST="${CAVE_SSRF_ALLOWLIST:+$CAVE_SSRF_ALLOWLIST,}127.0.0.1:8788"
export ANTHROPIC_BASE_URL="http://127.0.0.1:8787/compat/headroom"
export OPENAI_BASE_URL="http://127.0.0.1:8787/compat/headroom/v1"
ENV
}

chain_ready() {
  local url="$1" kind="$2"
  # Caveman has no /health endpoint; its structured 404 identifies the listener.
  curl --noproxy '*' -sS --max-time 2 "$url" 2>/dev/null |
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    good=(d.get("service")=="headroom-proxy" and d.get("ready") is True) if sys.argv[1]=="headroom" else d.get("error",{}).get("code")=="cave_route_not_found"
    sys.exit(0 if good else 1)
except (ValueError, AttributeError):
    sys.exit(1)' "$kind"
}

chain_wait() {
  local url="$1" kind="$2" attempt
  for attempt in {1..15}; do
    chain_ready "$url" "$kind" && return 0
    sleep 1
  done
  warn "$kind did not become ready; leaving existing processes untouched" >&2
  return 1
}

chain_start() {
  local allowlist
  proxy_resume || return 1
  # This launcher deliberately uses the already-installed, fixed-port mount.
  # Do not run setup_headroom: it may replace the diagnostic fork or deployment.
  caveman_yaml_has_headroom_stack "$(cat "$CAVEMAN_CONFIG_FILE" 2>/dev/null)" || {
    warn "expected compress-mode compat.headroom upstream http://127.0.0.1:8788 in $CAVEMAN_CONFIG_FILE" >&2
    return 1
  }
  if ! chain_ready http://127.0.0.1:8788/health headroom; then
    if port_listening 8788; then
      :
    elif [ "$?" = 1 ]; then
      headroom install start --profile default || return 1
    else
      warn "cannot inspect port 8788"; return 1
    fi
    chain_wait http://127.0.0.1:8788/health headroom || return 1
  fi
  ok "Headroom ready on :8788 (existing deployment preserved)"

  allowlist="${CAVE_SSRF_ALLOWLIST:-}"
  case ",$allowlist," in
    *,127.0.0.1:8788,*) ;;
    *) allowlist="${allowlist:+$allowlist,}127.0.0.1:8788" ;;
  esac
  export CAVE_SSRF_ALLOWLIST="$allowlist"
  if ! chain_ready http://127.0.0.1:8787/ caveman; then
    if port_listening 8787; then
      :
    elif [ "$?" = 1 ]; then
      caveman_start_proxy || return 1
    else
      warn "cannot inspect port 8787"; return 1
    fi
    chain_wait http://127.0.0.1:8787/ caveman || return 1
  fi
  ok "Caveman ready on :8787; agent routes already configured via compat/headroom"
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
