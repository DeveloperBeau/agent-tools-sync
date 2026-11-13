#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/caveman.sh"
# Load only command definitions, without executing setup or update checks.
eval "$(sed -n '/^cmd_kill()/,$p' "$HERE/../agent-tools-sync.sh" | sed '$d')"

kill_intent() (
  order=""
  proxy_suspend() { order="${order}Q"; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { order="${order}C"; }
  claude_mem_stop_worker() { order="${order}M"; }
  port_listening() { return 1; }
  sleep() { :; }
  cmd_kill >/dev/null || return 1
  [ "$order" = QCM ]
)
check 'kill records persistent stop before signals and also stops memory worker' kill_intent

failed_stop() (
  proxy_suspend() { :; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { return 1; }
  claude_mem_stop_worker() { :; }
  port_listening() { return 1; }
  sleep() { :; }
  ! cmd_kill >/dev/null
)
check 'kill propagates component failure even after port closes' failed_stop

stop_wait() (
  process_alive=1 signals="" waits=0
  lsof() { printf '123\n'; }
  ps() { [ "$process_alive" = 1 ] && printf '/private/caveman-proxy.bin\n'; }
  kill() {
    case "$1" in
      -TERM) signals="${signals}T" ;;
      -KILL) signals="${signals}K"; process_alive=0 ;;
      -0) [ "$process_alive" = 1 ] ;;
    esac
  }
  sleep() { waits=$((waits + 1)); }
  pgrep() { [ "$process_alive" = 1 ]; }
  pkill() { signals="${signals}P"; }
  caveman_stop_proxy >/dev/null || return 1
  [ "$process_alive" = 0 ] && [ "$signals" = TK ] && [ "$waits" -gt 0 ]
)
check 'Caveman stop waits for original listener and escalates scoped PID' stop_wait

unknown_listener() (
  signals=""
  lsof() { printf '123\n'; }
  ps() { printf '/usr/bin/unrelated-server\n'; }
  kill() { signals=sent; }
  pgrep() { return 1; }
  if caveman_stop_proxy >/dev/null; then return 1; fi
  [ -z "$signals" ]
)
check 'Caveman stop refuses unrelated listener without signaling it' unknown_listener

inspection_failure() (
  proxy_suspend() { :; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { :; }
  claude_mem_stop_worker() { :; }
  port_listening() { return 2; }
  sleep() { :; }
  ! cmd_kill >/dev/null
)
check 'kill cannot claim cleared ports when inspection failed' inspection_failure

common_probe_error() (
  lsof() { printf 'lsof: Cannot get process list\n' >&2; return 1; }
  port_listening 8787
  [ "$?" = 2 ]
)
check 'listener inspection distinguishes errors from empty port' common_probe_error

full_sync_start() (
  local order="" result="$1" expected="$2"
  shift 2
  CAVEMAN_HOME="$(mktemp -d)"
  trap 'rm -rf "$CAVEMAN_HOME"' EXIT
  SCRIPT_DIR=/fixture
  caveman_route_agents() { order="${order}[$1]"; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { order="${order}c"; }
  python3() { order="${order}W"; }
  proxy_resume() { order="${order}R"; }
  setup_rtk() { :; }
  setup_caveman() { order="${order}C"; }
  setup_ponytail() { :; }
  setup_evolver() { :; }
  setup_claude_mem() { :; }
  setup_ship() { :; }
  setup_skillopt() { :; }
  setup_context7() { order="${order}7"; }
  setup_serena() { order="${order}N"; }
  setup_obsidian() { order="${order}O"; }
  obsidian_enabled() { return 1; }
  bash() { [ "$*" = '/fixture/proxy-chain.sh start' ] || return 99; order="${order}S"; return "$result"; }
  main "$@" >/dev/null
  status=$?
  [ "$status" = "$result" ] && [ "$order" = "$expected" ] || { echo "$order"; return 1; }
)
check 'full sync starts the proxy after setup' full_sync_start 0 "RC7NO[full]S"
check 'full sync propagates proxy startup failure' full_sync_start 1 "RC7NO[full]S"
check 'no-wrap skips Caveman setup and stops it' full_sync_start 0 "R7NO[direct]cS" --no-wrap
check_fail 'older --no-caveman flag is rejected' full_sync_start 0 "" --no-caveman
check_fail 'older --no-headroom flag is rejected' full_sync_start 0 "" --no-headroom
check_fail 'unknown flag is rejected' full_sync_start 0 "" --bogus

control_lock_check() (
  HOME="$(mktemp -d)"
  trap 'rm -rf "$HOME"' EXIT
  control_probe() {
    python3 - "$CAVEMAN_HOME/ats-control.lock" <<'PY'
import fcntl, os, sys
try:
    os.fstat(9)
except OSError:
    pass
else:
    raise SystemExit("service child inherited control descriptor")
with open(sys.argv[1], "a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(0)
    raise SystemExit("shutdown did not retain control lock")
PY
  }
  proxy_control_run control_probe || return 1
  python3 - "$CAVEMAN_HOME/ats-control.lock" <<'PY'
import fcntl, sys
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
)
check 'shutdown retains the control lock throughout child work, then releases it' control_lock_check
report
