#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/headroom.sh"
source "$HERE/../lib/rtk.sh"
source "$HERE/../lib/evolver.sh"
source "$HERE/../lib/caveman.sh"

check_agent_selection() (
  local selected="$1" called=""
  have() { [ "$1" != claude ] && { [ "$1" != codex ] || [ "$selected" = codex ]; }; }
  install_rtk() { :; }
  install_evolver() { :; }
  install_caveman() { :; }
  caveman() { printf 'same-version\n'; }
  pgrep() { return 1; }
  caveman_ensure_ssrf_allowlist() { :; }
  caveman_ensure_stack_config() { :; }
  rtk_ensure_claude() { called="$called rtk-claude"; }
  rtk_ensure_codex() { called="$called rtk-codex"; }
  evolver_ensure_claude() { called="$called evolver-claude"; }
  evolver_ensure_codex() { called="$called evolver-codex"; }
  caveman_ensure_agent() { called="$called caveman-$2"; }
  caveman_patch_claude_route() { called="$called route-claude"; }
  caveman_patch_codex_route() { called="$called route-codex"; }
  setup_rtk >/dev/null || return
  setup_evolver >/dev/null || return
  setup_caveman >/dev/null || return
  headroom_ensure_claude_mcp >/dev/null || return
  [ "$called" = "$2" ]
)

check "no agents: no integrations configured" check_agent_selection none ""
check "Codex only: only Codex integrations configured" check_agent_selection codex \
  " rtk-codex evolver-codex caveman-codex route-codex"
report
