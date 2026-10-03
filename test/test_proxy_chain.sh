#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../proxy-chain.sh"

startup_check() (
  scenario="$1" expected="$2" order="" hr=0 cave=0
  proxy_resume() { :; }
  [ "$scenario" = healthy ] && { hr=1; cave=1; }
  caveman_yaml_has_headroom_stack() { [ "$scenario" != invalid ]; }
  chain_ready() { if [ "$2" = headroom ]; then [ "$hr" = 1 ]; else [ "$cave" = 1 ]; fi; }
  port_listening() { return 1; }
  headroom() { [ "$*" = 'install start --profile default' ] || return 1; order="${order}H"; }
  chain_wait() {
    if [ "$2" = headroom ]; then
      order="${order}R"
      [ "$scenario" != failure ] || return 1
      hr=1
    else
      order="${order}V"
    fi
  }
  caveman_start_proxy() {
    [ "$hr" = 1 ] || return 1
    case ",$CAVE_SSRF_ALLOWLIST," in *,127.0.0.1:8788,*) ;; *) return 1 ;; esac
    order="${order}C"
  }
  CAVE_SSRF_ALLOWLIST=example.com:443
  status=0
  chain_start >/dev/null 2>&1 || status=$?
  case "$scenario" in
    failure|invalid) [ "$status" != 0 ] || return 1 ;;
    *) [ "$status" = 0 ] || return 1 ;;
  esac
  [ "$order" = "$expected" ]
)

check "Headroom must be ready before Caveman starts" startup_check cold HRCV
check "Healthy processes are not restarted" startup_check healthy ""
check "Failed Headroom blocks Caveman startup" startup_check failure HR
check "Invalid config fails before starting processes" startup_check invalid ""

check "Headroom readiness requires service identity and ready=true" bash -c '
  source "$1"
  curl() { printf "%s" "{\"service\":\"headroom-proxy\",\"ready\":true}"; }
  chain_ready ignored headroom || exit 1
  curl() { printf "%s" "{\"service\":\"other\",\"ready\":true}"; }
  ! chain_ready ignored headroom
' bash "$HERE/../proxy-chain.sh"
check "Env output is sourceable and routes both APIs through Caveman" bash -c '
  source "$1"
  eval "$(chain_env)"
  [ "$ANTHROPIC_BASE_URL" = http://127.0.0.1:8787/compat/headroom ] &&
  [ "$OPENAI_BASE_URL" = http://127.0.0.1:8787/compat/headroom/v1 ]
' bash "$HERE/../proxy-chain.sh"
report
