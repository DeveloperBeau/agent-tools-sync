#!/usr/bin/env bash
# Start the existing chain without installing, updating, or restarting either proxy.
# Only the proxies that the persisted ATS mode uses are started.
set -uo pipefail
CHAIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CHAIN_DIR/lib/common.sh"
source "$CHAIN_DIR/lib/caveman.sh"

chain_env() {
  local mode claude
  mode="$(ats_mode)"
  case "$mode" in
    full)
      cat <<'ENV'
export CAVE_SSRF_ALLOWLIST="${CAVE_SSRF_ALLOWLIST:+$CAVE_SSRF_ALLOWLIST,}127.0.0.1:8788"
export ANTHROPIC_BASE_URL="http://127.0.0.1:8787/compat/headroom"
export OPENAI_BASE_URL="http://127.0.0.1:8787/compat/headroom/v1"
ENV
      return ;;
    no-caveman) printf 'export OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n' ;;
    *) printf 'unset OPENAI_BASE_URL\n' ;;
  esac
  claude="$(caveman_route_url "$mode" claude)"
  if [ -n "$claude" ]; then
    printf 'export ANTHROPIC_BASE_URL="%s"\n' "$claude"
  else
    printf 'unset ANTHROPIC_BASE_URL\n'
  fi
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

chain_start_headroom() {
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
}

chain_start_caveman() {
  local allowlist
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
  ok "Caveman ready on :8787"
}

chain_start() {
  local mode
  proxy_resume || return 1
  mode="$(ats_mode)"
  # This launcher deliberately uses the already-installed, fixed-port mount.
  # Do not run setup_headroom: it may replace the diagnostic fork or deployment.
  if [ "$mode" = full ] && ! caveman_yaml_has_headroom_stack "$(cat "$CAVEMAN_CONFIG_FILE" 2>/dev/null)"; then
    warn "expected compress-mode compat.headroom upstream http://127.0.0.1:8788 in $CAVEMAN_CONFIG_FILE" >&2
    return 1
  fi
  if ats_uses headroom; then
    chain_start_headroom || return 1
  fi
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
