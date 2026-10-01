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

check "no agents: shared plans integration skipped" selected_agents none
check "Codex only: only Codex configured" selected_agents codex
check "both agents: shared vault path preserved" selected_agents both
report
