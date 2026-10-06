#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=harness.sh
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/mcp.sh"
source "$HERE/../lib/grepai.sh"

# Fixture: temp HOME with stub brew, ollama and claude first on PATH. Real
# git runs against a sandboxed global config in the temp HOME.
# OLLAMA_FAIL_PULL: model whose pull fails. OLLAMA_LIST: `ollama list` output.
# BREW_OUTDATED / BREW_FAIL as in test_search_tools.sh. ANSWER: terminal reply.
grepai_fixture() {
  HOME="$(mktemp -d)"; export HOME
  trap 'rm -rf "$HOME"' EXIT
  unset CAVEMAN_HOME
  GIT_CONFIG_GLOBAL="$HOME/.gitconfig"; export GIT_CONFIG_GLOBAL
  STUB="$HOME/stub"; mkdir -p "$STUB"
  LOG="$HOME/calls"; export LOG BREW_OUTDATED BREW_FAIL OLLAMA_FAIL_PULL OLLAMA_LIST
  STATE="$HOME/.caveman/ats-grepai.env"
  cat >"$STUB/brew" <<'STUB'
#!/usr/bin/env bash
printf 'brew %s\n' "$*" >>"$LOG"
case "$1" in
  outdated) case " ${BREW_OUTDATED:-} " in *" $2 "*) echo "$2" ;; esac ;;
  install|upgrade) [ "${BREW_FAIL:-0}" -eq 0 ] ;;
esac
STUB
  cat >"$STUB/ollama" <<'STUB'
#!/usr/bin/env bash
printf 'ollama %s\n' "$*" >>"$LOG"
case "$1" in
  list) printf '%s\n' "${OLLAMA_LIST:-}" ;;
  pull) [ "$2" != "${OLLAMA_FAIL_PULL:-}" ] ;;
esac
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB/grepai"
  cat >"$STUB/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$LOG"
STUB
  chmod +x "$STUB"/*
  PATH="$STUB:/usr/bin:/bin"; export PATH
  ATS_TTY=/nonexistent; export ATS_TTY
  if [ -n "${ANSWER+x}" ]; then printf '%s\n' "$ANSWER" >"$HOME/tty"; ATS_TTY="$HOME/tty"; fi
}

state() { sed -n "s/^$1=//p" "$STATE"; }
pulls() { grep -c '^ollama pull' "$LOG"; }

# --- first-launch prompt -----------------------------------------------------
chooses_qwen() (
  ANSWER=1; grepai_fixture
  setup_grepai >"$HOME/out" 2>"$HOME/err" 3<&- || return 1
  grep -qx "ollama pull qwen3-embedding:8b" "$LOG" && ! grep -q 'pull nomic' "$LOG" \
    && [ "$(state GREPAI_MODEL)" = qwen3-embedding:8b ] \
    && [ "$(state GREPAI_DIMENSIONS)" = 4096 ] && [ "$(state GREPAI_ASKED)" = yes ]
)
check "grepai: choosing qwen3 pulls it and records 4096 dimensions" chooses_qwen

chooses_nomic() (
  ANSWER=2; grepai_fixture
  setup_grepai >"$HOME/out" 2>"$HOME/err" 3<&- || return 1
  grep -qx "ollama pull nomic-embed-text" "$LOG" && ! grep -q 'qwen3' "$LOG" \
    && [ "$(state GREPAI_MODEL)" = nomic-embed-text ] \
    && [ "$(state GREPAI_DIMENSIONS)" = 768 ] && [ "$(state GREPAI_ASKED)" = yes ]
)
check "grepai: choosing nomic pulls it and records 768 dimensions" chooses_nomic

empty_answer_is_recommended() (
  ANSWER=""; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&- || return 1
  [ "$(state GREPAI_MODEL)" = qwen3-embedding:8b ]
)
check "grepai: empty answer takes the recommended model" empty_answer_is_recommended

prompt_text_and_reprompt() (
  grepai_fixture
  printf 'x\n2\n' >"$HOME/answers"
  setup_grepai >/dev/null 2>"$HOME/err" 3<"$HOME/answers" || return 1
  err="$(cat "$HOME/err")"
  [[ "$err" == *"Which Ollama embedding model should grepai use?"* ]] || return 1
  [[ "$err" == *"1) qwen3-embedding:8b (recommended)"* ]] || return 1
  [[ "$err" == *"About a 4.7 GB download, needs roughly 8 GB of"* ]] || return 1
  [[ "$err" == *"2) nomic-embed-text"* ]] || return 1
  [[ "$err" == *"About a 274 MB download, runs on any Mac, lower search quality."* ]] || return 1
  [[ "$err" == *"Enter 1 or 2."* ]] || return 1
  [ "$(state GREPAI_MODEL)" = nomic-embed-text ]
)
check "grepai: prompt text, reprompt on bad input, fd 3 honoured" prompt_text_and_reprompt

remembered_choice_not_asked() (
  ANSWER=1; grepai_fixture
  mkdir -p "$HOME/.caveman"
  printf 'GREPAI_MODEL=nomic-embed-text\nGREPAI_DIMENSIONS=768\nGREPAI_ASKED=yes\n' >"$STATE"
  setup_grepai >/dev/null 2>"$HOME/err" 3<&- || return 1
  [ ! -s "$HOME/err" ] && grep -qx "ollama pull nomic-embed-text" "$LOG" && [ "$(pulls)" -eq 1 ] \
    && [ "$(state GREPAI_MODEL)" = nomic-embed-text ]
)
check "grepai: remembered choice is not asked again, only that model is updated" remembered_choice_not_asked

non_interactive_defaults() (
  grepai_fixture
  out="$(setup_grepai 2>&1 3<&-)" || return 1
  [[ "$out" == *"defaulting to nomic-embed-text"* ]] \
    && [ "$(state GREPAI_MODEL)" = nomic-embed-text ] && [ "$(state GREPAI_ASKED)" = no ] \
    && ! grep -q qwen3 "$LOG"
)
check "grepai: no terminal defaults to nomic without hanging" non_interactive_defaults

default_then_asked_later() (
  ANSWER=1; grepai_fixture
  mkdir -p "$HOME/.caveman"
  printf 'GREPAI_MODEL=nomic-embed-text\nGREPAI_DIMENSIONS=768\nGREPAI_ASKED=no\n' >"$STATE"
  setup_grepai >/dev/null 2>&1 3<&- || return 1
  [ "$(state GREPAI_MODEL)" = qwen3-embedding:8b ]
)
check "grepai: a non-interactive default is replaced when a terminal appears" default_then_asked_later

qwen_failure_falls_back() (
  ANSWER=1; OLLAMA_FAIL_PULL=qwen3-embedding:8b; grepai_fixture
  out="$(setup_grepai 2>/dev/null 3<&-)" || return 1
  [[ "$out" == *"falling back to nomic-embed-text"* ]] \
    && grep -qx "ollama pull nomic-embed-text" "$LOG" \
    && [ "$(state GREPAI_MODEL)" = nomic-embed-text ] && [ "$(state GREPAI_DIMENSIONS)" = 768 ] \
    && [ "$(state GREPAI_ASKED)" = yes ]
)
check "grepai: qwen3 pull failure falls back to nomic and records it" qwen_failure_falls_back

failed_update_keeps_downloaded_model() (
  grepai_fixture
  OLLAMA_FAIL_PULL=qwen3-embedding:8b
  OLLAMA_LIST="qwen3-embedding:8b   abc   4.7 GB   now"
  mkdir -p "$HOME/.caveman"
  printf 'GREPAI_MODEL=qwen3-embedding:8b\nGREPAI_DIMENSIONS=4096\nGREPAI_ASKED=yes\n' >"$STATE"
  setup_grepai >/dev/null 2>&1 3<&-
  [ "$(state GREPAI_MODEL)" = qwen3-embedding:8b ] && ! grep -q 'pull nomic' "$LOG"
)
check "grepai: offline update of an installed model does not downgrade it" failed_update_keeps_downloaded_model

both_pulls_fail() (
  ANSWER=1; grepai_fixture
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/ollama"
  setup_grepai >/dev/null 2>&1 3<&-; status=$?
  [ "$status" -ne 0 ] && [ ! -e "$STATE" ]
)
check "grepai: nothing recorded when no model can be pulled" both_pulls_fail

# --- brew --------------------------------------------------------------------
brew_installs_and_starts_service() (
  ANSWER=2; grepai_fixture
  rm "$STUB/grepai" "$STUB/ollama"
  setup_grepai >/dev/null 2>&1 3<&-
  grep -qx "brew install yoanbernabeu/tap/grepai" "$LOG" && grep -qx "brew install ollama" "$LOG"
)
check "grepai: installs grepai and ollama when missing" brew_installs_and_starts_service

starts_ollama_service() (
  ANSWER=2; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  grep -qx "brew services start ollama" "$LOG"
)
check "grepai: starts ollama with brew services" starts_ollama_service

upgrades_outdated() (
  ANSWER=2; BREW_OUTDATED="yoanbernabeu/tap/grepai ollama"; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  grep -qx "brew upgrade yoanbernabeu/tap/grepai" "$LOG" && grep -qx "brew upgrade ollama" "$LOG"
)
check "grepai: upgrades outdated grepai and ollama" upgrades_outdated

current_is_skipped() (
  ANSWER=2; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  ! grep -qE '^brew (install|upgrade)' "$LOG"
)
check "grepai: current grepai and ollama are skipped" current_is_skipped

brew_failure_continues() (
  ANSWER=2; BREW_OUTDATED="ollama yoanbernabeu/tap/grepai"; BREW_FAIL=1; grepai_fixture
  out="$(setup_grepai 2>&1 3<&-)"; status=$?
  [ "$status" -ne 0 ] && [[ "$out" == *"ollama upgrade failed"* ]] \
    && grep -qx "ollama pull nomic-embed-text" "$LOG" && grep -q 'mcp add' "$LOG" \
    && grep -qx '.grepai/' "$HOME/.config/git/ignore"
)
check "grepai: brew failure warns and the remaining steps still run" brew_failure_continues

# --- git excludes --------------------------------------------------------------
creates_excludes() (
  ANSWER=2; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  [ "$(cat "$HOME/.config/git/ignore")" = ".grepai/" ] \
    && [ "$(git config --global core.excludesFile)" = "$HOME/.config/git/ignore" ]
)
check "grepai: creates ~/.config/git/ignore and sets core.excludesFile when unset" creates_excludes

existing_excludes_with_entry() (
  ANSWER=2; grepai_fixture
  printf 'node_modules/\n.grepai/\n' >"$HOME/myignore"
  git config --global core.excludesFile "$HOME/myignore"
  setup_grepai >/dev/null 2>&1 3<&-
  [ "$(cat "$HOME/myignore")" = $'node_modules/\n.grepai/' ] && [ ! -e "$HOME/.config/git/ignore" ]
)
check "grepai: excludes file already holding .grepai/ is left untouched" existing_excludes_with_entry

existing_excludes_appended() (
  ANSWER=2; grepai_fixture
  printf 'node_modules/\n' >"$HOME/myignore"
  git config --global core.excludesFile "$HOME/myignore"
  setup_grepai >/dev/null 2>&1 3<&-
  [ "$(cat "$HOME/myignore")" = $'node_modules/\n.grepai/' ] \
    && [ "$(git config --global core.excludesFile)" = "$HOME/myignore" ]
)
check "grepai: configured excludes file gets the entry appended, config kept" existing_excludes_appended

excludes_idempotent() (
  ANSWER=2; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  setup_grepai >/dev/null 2>&1 3<&-
  [ "$(grep -c '^\.grepai/$' "$HOME/.config/git/ignore")" -eq 1 ]
)
check "grepai: rerun adds .grepai/ only once" excludes_idempotent

# --- MCP -------------------------------------------------------------------------
registers_mcp() (
  ANSWER=2; grepai_fixture
  setup_grepai >/dev/null 2>&1 3<&-
  grep -qx "claude mcp add --scope user grepai -- grepai mcp-serve" "$LOG"
)
check "grepai: registers the MCP server at user scope" registers_mcp

mcp_already_registered() (
  ANSWER=2; grepai_fixture
  printf '{"mcpServers":{"grepai":{"command":"grepai"}}}\n' >"$HOME/.claude.json"
  out="$(setup_grepai 2>&1 3<&-)"
  ! grep -q 'mcp add' "$LOG" && [[ "$out" == *"grepai MCP already registered"* ]]
)
check "grepai: already registered MCP server is preserved" mcp_already_registered

no_claude() (
  ANSWER=2; grepai_fixture
  rm "$STUB/claude"
  setup_grepai >/dev/null 2>&1 3<&-
  ! grep -q '^claude' "$LOG"
)
check "grepai: no claude, no MCP registration" no_claude

no_brew() (
  grepai_fixture; rm "$STUB/brew"
  out="$(setup_grepai 2>&1 3<&-)"; status=$?
  [ "$status" -ne 0 ] && [[ "$out" == *"brew required"* ]] && [ ! -s "$LOG" ]
)
check "grepai: missing brew warns and changes nothing" no_brew

report
