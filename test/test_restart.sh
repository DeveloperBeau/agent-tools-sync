#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/caveman.sh"

caveman_restart_check() (
  version=1 target_version="$1" expected="$2" running=1 order=""
  have() { return 0; }
  caveman() { [ "$1" = --version ] && printf '%s\n' "$version"; }
  install_caveman() { version="$target_version"; }
  pgrep() { [ "$running" -eq 1 ]; }
  port_listening() { [ "$running" -eq 1 ]; }
  caveman_listener_owned() { [ "$running" -eq 1 ]; }
  caveman_stop_proxy() { order="${order}S"; running=0; }
  caveman_start_proxy() { order="${order}B"; running=1; }
  sleep() { :; }
  caveman_ensure_agent() { :; }
  setup_caveman >/dev/null
  [ "$order" = "$expected" ]
)

check "Caveman update restarts running proxy" caveman_restart_check 2 SB
check "Caveman without update keeps running proxy" caveman_restart_check 1 ""
report
