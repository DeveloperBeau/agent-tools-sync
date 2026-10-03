#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/caveman.sh"
source "$HERE/../lib/headroom.sh"
# Load only command definitions, without executing setup or update checks.
eval "$(sed -n '/^cmd_kill()/,$p' "$HERE/../agent-tools-sync.sh" | sed '$d')"

kill_intent() (
  order="" HEADROOM_PORT=8788
  proxy_suspend() { order="${order}Q"; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { order="${order}C"; }
  headroom_stop_proxy() { order="${order}H"; }
  claude_mem_stop_worker() { order="${order}M"; }
  port_listening() { return 1; }
  sleep() { :; }
  cmd_kill >/dev/null || return 1
  [ "$order" = QCHM ]
)
check 'kill records persistent stop before signals and also stops memory worker' kill_intent

failed_stop() (
  HEADROOM_PORT=8788
  proxy_suspend() { :; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { return 1; }
  headroom_stop_proxy() { :; }
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

manual_dispatch() (
  SCRIPT_DIR=/fixture
  python3() { [ "$*" = '/fixture/lib/proxy_watchdog.py fire' ]; }
  main watchdog fire >/dev/null
)
check 'ats watchdog fire dispatches directly to existing watchdog' manual_dispatch

inspection_failure() (
  HEADROOM_PORT=8788
  proxy_suspend() { :; }
  proxy_control_run() { "$@"; }
  caveman_stop_proxy() { :; }
  headroom_stop_proxy() { :; }
  claude_mem_stop_worker() { :; }
  port_listening() { return 2; }
  sleep() { :; }
  ! cmd_kill >/dev/null
)
check 'kill cannot claim cleared ports when inspection failed' inspection_failure

headroom_stop_check() (
  local mode="$1" polls=0
  HEADROOM_PORT=8788
  have() { return 0; }
  headroom_profile_exists() { return 0; }
  headroom() { return 0; }
  with_timeout() { shift; "$@"; }
  port_listening() {
    polls=$((polls + 1))
    [ "$mode" = inspection-error ] && return 2
    [ "$mode" = stuck ] && return 0
    [ "$polls" -lt 3 ]
  }
  sleep() { :; }
  if [ "$mode" = drained ]; then
    headroom_stop_proxy >/dev/null && [ "$polls" = 3 ]
  else
    ! headroom_stop_proxy >/dev/null
  fi
)
check 'Headroom stop waits for listener shutdown' headroom_stop_check drained
check 'Headroom stop fails when listener stays bound' headroom_stop_check stuck
check 'Headroom stop fails when listener inspection fails' headroom_stop_check inspection-error

headroom_status_failure() (
  have() { return 0; }
  headroom() { return 1; }
  with_timeout() { shift; "$@"; }
  ! headroom_stop_proxy >/dev/null
)
check 'Headroom status failure cannot imply deployment is stopped' headroom_status_failure

common_probe_error() (
  lsof() { printf 'lsof: Cannot get process list\n' >&2; return 1; }
  port_listening 8787
  [ "$?" = 2 ]
)
check 'listener inspection distinguishes errors from empty port' common_probe_error

full_sync_start() (
  local order="" result="$1"
  SCRIPT_DIR=/fixture
  proxy_resume() { order="${order}R"; }
  setup_headroom() { order="${order}H"; }
  setup_rtk() { :; }
  setup_caveman() { order="${order}C"; }
  setup_ponytail() { :; }
  setup_evolver() { :; }
  setup_claude_mem() { :; }
  setup_ship() { :; }
  setup_skillopt() { :; }
  setup_obsidian() { order="${order}O"; }
  obsidian_enabled() { return 1; }
  bash() { [ "$*" = '/fixture/proxy-chain.sh start' ] || return 99; order="${order}S"; return "$result"; }
  main >/dev/null
  status=$?
  [ "$status" = "$result" ] && [ "$order" = RHCOS ]
)
check 'full sync starts existing chain after setup' full_sync_start 0
check 'full sync propagates chain startup failure' full_sync_start 1

control_lock_check() (
  HOME="$(mktemp -d)"
  trap 'rm -rf "$HOME"' EXIT
  control_probe() {
    python3 - "$HOME/.headroom/watchdog-state.control.lock" <<'PY'
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
  python3 - "$HOME/.headroom/watchdog-state.control.lock" <<'PY'
import fcntl, sys
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY
)
check 'shutdown retains watchdog lock throughout child work, then releases it' control_lock_check
report
