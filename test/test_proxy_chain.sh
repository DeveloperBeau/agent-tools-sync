#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../proxy-chain.sh"
CAVEMAN_HOME="$(mktemp -d)"
export CAVEMAN_HOME
trap 'rm -rf "$CAVEMAN_HOME"' EXIT

# mode_check MODE EXPECTED — cold start in MODE starts the proxy only when the mode uses it.
mode_check() (
  ats_set_mode "$1"
  order=""
  proxy_resume() { :; }
  chain_start_caveman() { order="${order}C"; }
  chain_start >/dev/null 2>&1 || return 1
  [ "$order" = "$2" ]
)
check "full starts Caveman" mode_check full C
check "direct starts no proxy" mode_check direct ""
check "older no-headroom value means full" bash -c '
  source "$1"; ats_set_mode no-headroom; [ "$(ats_mode)" = full ]' bash "$HERE/../proxy-chain.sh"
check "older no-caveman value means direct" bash -c '
  source "$1"; ats_set_mode no-caveman; [ "$(ats_mode)" = direct ]' bash "$HERE/../proxy-chain.sh"

startup_check() (
  scenario="$1" expected="$2" order="" cave=0
  ats_set_mode full
  proxy_resume() { :; }
  [ "$scenario" = healthy ] && cave=1
  chain_ready() { [ "$cave" = 1 ]; }
  port_listening() { return 1; }
  chain_wait() { order="${order}V"; [ "$scenario" != failure ] && cave=1; }
  caveman_start_proxy() { order="${order}C"; }
  status=0
  chain_start >/dev/null 2>&1 || status=$?
  case "$scenario" in
    failure) [ "$status" != 0 ] || return 1 ;;
    *) [ "$status" = 0 ] || return 1 ;;
  esac
  [ "$order" = "$expected" ]
)

check "Cold start launches Caveman and waits for readiness" startup_check cold CV
check "Healthy process is not restarted" startup_check healthy ""
check "Caveman that never becomes ready fails startup" startup_check failure CV

check "Caveman readiness requires its structured 404" bash -c '
  source "$1"
  curl() { printf "%s" "{\"error\":{\"code\":\"cave_route_not_found\"}}"; }
  chain_ready ignored || exit 1
  curl() { printf "%s" "{\"error\":{\"code\":\"other\"}}"; }
  ! chain_ready ignored
' bash "$HERE/../proxy-chain.sh"
check "Env output in full mode uses Caveman's native Claude route" bash -c '
  source "$1"
  ats_set_mode full
  eval "$(chain_env)"
  [ "$ANTHROPIC_BASE_URL" = http://127.0.0.1:8787/w/claude ] && [ -z "${OPENAI_BASE_URL+x}" ]
' bash "$HERE/../proxy-chain.sh"
check "Env output follows the persisted mode" bash -c '
  source "$1"
  ats_set_mode direct; eval "$(chain_env)"
  [ -z "${ANTHROPIC_BASE_URL+x}" ] && [ -z "${OPENAI_BASE_URL+x}" ] || exit 1
  ats_set_mode full
' bash "$HERE/../proxy-chain.sh"
report
