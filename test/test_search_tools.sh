#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/search-tools.sh"

# Fixture: a stub brew on PATH. BREW_OUTDATED lists outdated formulae,
# BREW_FAIL=1 makes install/upgrade fail. INSTALLED lists present commands.
search_fixture() {
  HOME="$(mktemp -d)"; export HOME
  trap 'rm -rf "$HOME"' EXIT
  STUB="$HOME/stub"; mkdir -p "$STUB"
  LOG="$HOME/calls"; export LOG BREW_OUTDATED BREW_FAIL
  cat >"$STUB/brew" <<'BREW'
#!/usr/bin/env bash
printf 'brew %s\n' "$*" >>"$LOG"
case "$1" in
  outdated) case " ${BREW_OUTDATED:-} " in *" $2 "*) echo "$2" ;; esac ;;
  install|upgrade) [ "${BREW_FAIL:-0}" -eq 0 ] ;;
esac
BREW
  chmod +x "$STUB/brew"
  for c in ${INSTALLED:-}; do printf '#!/bin/sh\n' >"$STUB/$c"; chmod +x "$STUB/$c"; done
  PATH="$STUB:/usr/bin:/bin"; export PATH
}

installs_missing() (
  INSTALLED=""; search_fixture
  setup_search_tools >/dev/null || return 1
  for f in ripgrep fd sd ast-grep; do grep -qx "brew install $f" "$LOG" || return 1; done
  ! grep -q upgrade "$LOG"
)
check "search tools: installs all four when missing" installs_missing

skips_current() (
  INSTALLED="rg fd sd ast-grep"; search_fixture
  out="$(setup_search_tools)" || return 1
  ! grep -qE 'install|upgrade' "$LOG" && [[ "$out" == *"up to date"* ]]
)
check "search tools: up to date tools are skipped" skips_current

upgrades_outdated() (
  INSTALLED="rg fd sd ast-grep"; BREW_OUTDATED="fd"; search_fixture
  setup_search_tools >/dev/null || return 1
  grep -qx "brew upgrade fd" "$LOG" && [ "$(grep -c upgrade "$LOG")" -eq 1 ]
)
check "search tools: only the outdated tool is upgraded" upgrades_outdated

brew_failure_continues() (
  INSTALLED=""; BREW_FAIL=1; search_fixture
  out="$(setup_search_tools)"; status=$?
  [ "$status" -ne 0 ] && [ "$(grep -c '^brew install' "$LOG")" -eq 4 ] && [[ "$out" == *"ripgrep install failed"* ]]
)
check "search tools: brew failure warns, tries every tool, returns nonzero" brew_failure_continues

no_brew() (
  INSTALLED=""; search_fixture; rm "$STUB/brew"
  out="$(setup_search_tools)"; status=$?
  [ "$status" -ne 0 ] && [[ "$out" == *"brew required"* ]]
)
check "search tools: missing brew warns" no_brew

report
