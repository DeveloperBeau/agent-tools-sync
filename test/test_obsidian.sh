#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/obsidian.sh"

selected_agents() (
  local selected="$1" called=""
  SCRIPT_DIR="/ats source"
  ATS_PLANS_VAULT="/shared plans"
  ATS_OBSIDIAN_PLANS=1
  have() {
    case "$1" in
      claude) [ "$selected" = both ] ;;
      codex) [ "$selected" = both ] || [ "$selected" = codex ] ;;
      python3) return 0 ;;
      *) return 1 ;;
    esac
  }
  python3() { [ "$1" = -c ] || called="$*"; }
  setup_obsidian >/dev/null
  case "$selected" in
    none) [ -z "$called" ] ;;
    codex) [[ "$called" == *"--agents codex" ]] ;;
    both) [[ "$called" == *"--vault /shared plans --agents claude codex" ]] ;;
  esac
)

skips_without_opt_in() (
  local setting="$1" called=""
  if [ "$setting" = unset ]; then
    unset ATS_OBSIDIAN_PLANS
  else
    ATS_OBSIDIAN_PLANS="$setting"
  fi
  have() { called="$called dependency"; return 0; }
  python3() { called="$called python"; }
  run() { called="$called installer"; }
  setup_obsidian >/dev/null || return
  [ -z "$called" ]
)

check "unset opt-in: no dependency checks or installation" skips_without_opt_in unset
check "disabled opt-in: no dependency checks or installation" skips_without_opt_in 0
check "invalid opt-in: no dependency checks or installation" skips_without_opt_in true
check "no agents: shared plans integration skipped" selected_agents none
check "Codex only: only Codex configured" selected_agents codex
check "both agents: shared vault path preserved" selected_agents both
report
