#!/usr/bin/env bash
# search-tools.sh — install/update the modern command-line search tools via
# Homebrew: ripgrep (rg), fd, sd and ast-grep (sg/ast-grep).

setup_search_tools() {
  section "search tools"
  have brew || { warn "brew required to install search tools"; return 1; }
  local failed=0 pair
  for pair in rg:ripgrep fd:fd sd:sd ast-grep:ast-grep; do
    brew_ensure "${pair%%:*}" "${pair#*:}" || failed=1
  done
  return "$failed"
}
