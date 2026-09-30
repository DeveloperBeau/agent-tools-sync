#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/headroom.sh"
source "$HERE/../lib/caveman.sh"

headroom_restart_check() (
  pinned="$1" expected="$2" order="" HEADROOM_PORT=8788
  have() { return 0; }
  headroom_has_route_health() { [ "$pinned" = true ]; }
  install_headroom() { pinned=true; }
  with_timeout() { return 0; }
  headroom_stop_proxy() { order="${order}S"; }
  headroom_fix_rc_file() { :; }
  headroom_fix_codex_config() { :; }
  headroom_fix_codex_hooks() { :; }
  headroom_remove_legacy_profile() { :; }
  headroom_ensure_claude_mcp() { :; }
  headroom_ensure_codex_mcp() { :; }
  headroom_ensure_proxy() { order="${order}E"; }
  setup_headroom >/dev/null
  [ "$order" = "$expected" ]
)

caveman_restart_check() (
  version=1 target_version="$1" expected="$2" running=1 order=""
  have() { return 0; }
  caveman() { [ "$1" = --version ] && printf '%s\n' "$version"; }
  install_caveman() { version="$target_version"; }
  pgrep() { [ "$running" -eq 1 ]; }
  caveman_stop_proxy() { order="${order}S"; running=0; }
  caveman_start_proxy() { order="${order}B"; running=1; }
  sleep() { :; }
  caveman_ensure_agent() { :; }
  caveman_ensure_ssrf_allowlist() { :; }
  caveman_ensure_stack_config() { :; }
  caveman_patch_claude_route() { :; }
  caveman_patch_codex_route() { :; }
  setup_caveman >/dev/null
  [ "$order" = "$expected" ]
)

check "Headroom pin change stops old proxy before ensuring new one" headroom_restart_check false SE
check "Headroom matching pin keeps running proxy" headroom_restart_check true E
check "Caveman update restarts running proxy" caveman_restart_check 2 SB
check "Caveman without update keeps running proxy" caveman_restart_check 1 ""
report
