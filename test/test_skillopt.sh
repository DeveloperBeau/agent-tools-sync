#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/skillopt.sh"

skillopt_fixture() {
  SKILLOPT_TEST_ROOT="$(mktemp -d)"
  export SKILLOPT_TEST_ROOT
  trap 'rm -rf "$SKILLOPT_TEST_ROOT"' EXIT
  export HOME="$SKILLOPT_TEST_ROOT/home"
  unset SKILLOPT_SLEEP_REPO CLAUDE_CONFIG_DIR
  mkdir -p "$HOME" "$SKILLOPT_TEST_ROOT/bin" "$SKILLOPT_TEST_ROOT/upstream"
  export SKILLOPT_TEST_GIT="$(command -v git)"
  local source="$SKILLOPT_TEST_ROOT/upstream"
  "$SKILLOPT_TEST_GIT" -C "$source" init -q -b main
  "$SKILLOPT_TEST_GIT" -C "$source" config user.email tests@example.invalid
  "$SKILLOPT_TEST_GIT" -C "$source" config user.name Tests
  mkdir -p "$source/plugins/codex/skills/skillopt-sleep" "$source/plugins/claude-code/.claude-plugin"
  printf 'export SKILLOPT_SLEEP_REPO=/path/to/SkillOpt\n' >"$source/plugins/codex/skills/skillopt-sleep/SKILL.md"
  touch "$source/pyproject.toml" "$source/plugins/run-sleep.sh"
  printf '{"name":"skillopt-sleep"}\n' >"$source/plugins/claude-code/.claude-plugin/marketplace.json"
  "$SKILLOPT_TEST_GIT" -C "$source" add .
  "$SKILLOPT_TEST_GIT" -C "$source" commit -qm initial
  cat >"$SKILLOPT_TEST_ROOT/bin/git" <<'GIT'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$SKILLOPT_TEST_ROOT/calls"
if [ "$1" = clone ]; then
  [ "${SKILLOPT_TEST_CLONE_FAIL:-0}" = 0 ] || exit 1
  "$SKILLOPT_TEST_GIT" clone --quiet --branch main "$SKILLOPT_TEST_ROOT/upstream" "${@: -1}" || exit
  "$SKILLOPT_TEST_GIT" -C "${@: -1}" remote set-url origin https://github.com/microsoft/SkillOpt.git
elif [ "${3:-}" = fetch ]; then
  [ "${SKILLOPT_TEST_FETCH_FAIL:-0}" = 0 ] || exit 1
  "$SKILLOPT_TEST_GIT" -C "$2" fetch --quiet "$SKILLOPT_TEST_ROOT/upstream" main:refs/remotes/origin/main
else
  exec "$SKILLOPT_TEST_GIT" "$@"
fi
GIT
  cat >"$SKILLOPT_TEST_ROOT/bin/uv" <<'UV'
#!/usr/bin/env bash
printf 'uv %s\n' "$*" >>"$SKILLOPT_TEST_ROOT/calls"
if [ "$*" = 'tool dir' ]; then
  printf '%s/uv tools\n' "$SKILLOPT_TEST_ROOT"
else
  [ "${SKILLOPT_TEST_UV_FAIL:-0}" = 0 ] || exit 1
  mkdir -p "$SKILLOPT_TEST_ROOT/uv tools/skillopt/bin"
  printf '#!/bin/sh\nexit 0\n' >"$SKILLOPT_TEST_ROOT/uv tools/skillopt/bin/python"
  chmod +x "$SKILLOPT_TEST_ROOT/uv tools/skillopt/bin/python"
fi
UV
  cat >"$SKILLOPT_TEST_ROOT/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"$SKILLOPT_TEST_ROOT/calls"
[ "${SKILLOPT_TEST_CLAUDE_FAIL:-0}" = 0 ] || exit 1
mkdir -p "$HOME/.claude/plugins"
if [ "$1 $2 $3" = 'plugin marketplace add' ]; then
  python3 - "$4" <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(os.environ["HOME"]) / ".claude/plugins/known_marketplaces.json"
path.write_text(json.dumps({"skillopt-sleep": {"source": {"source": "directory", "path": sys.argv[1]}}}))
PY
elif [ "$1 $2" = 'plugin install' ]; then
  printf '{"plugins":{"skillopt-sleep@skillopt-sleep":[{"scope":"user"}]}}\n' >"$HOME/.claude/plugins/installed_plugins.json"
fi
CLAUDE
  chmod +x "$SKILLOPT_TEST_ROOT/bin/"*
  export PATH="$SKILLOPT_TEST_ROOT/bin:$PATH"
  with_timeout() { shift; "$@"; }
  have() {
    case "$1" in
      claude) [ "${SKILLOPT_TEST_CLAUDE:-1}" = 1 ] ;;
      codex) [ "${SKILLOPT_TEST_CODEX:-1}" = 1 ] ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
}

skillopt_initial_and_rerun() (
  skillopt_fixture
  setup_skillopt >/dev/null || return 1
  local skill="$HOME/.agents/skills/skillopt-sleep/SKILL.md"
  [ -s "$skill" ] || return 1
  grep -q 'claude plugin install skillopt-sleep@skillopt-sleep --scope user' "$SKILLOPT_TEST_ROOT/calls" || return 1
  setup_skillopt >/dev/null || return 1
  grep -q 'claude plugin marketplace update skillopt-sleep' "$SKILLOPT_TEST_ROOT/calls" || return 1
  grep -q 'claude plugin update skillopt-sleep@skillopt-sleep --scope user' "$SKILLOPT_TEST_ROOT/calls" || return 1
  [ "$(find "$(dirname "$skill")" -name 'SKILL.md.backup-*' | wc -l | tr -d ' ')" = 0 ] || return 1
  [ "$(grep -c '^git clone ' "$SKILLOPT_TEST_ROOT/calls")" = 1 ]
)
check 'SkillOpt installs both agents and refreshes idempotently' skillopt_initial_and_rerun

skillopt_optional_agents() (
  skillopt_fixture
  SKILLOPT_TEST_CLAUDE="$1" SKILLOPT_TEST_CODEX="$2"
  setup_skillopt >/dev/null || return 1
  if [ "$1" = 1 ]; then
    grep -q '^claude plugin install ' "$SKILLOPT_TEST_ROOT/calls" || return 1
  elif [ -f "$SKILLOPT_TEST_ROOT/calls" ]; then
    ! grep -q '^claude ' "$SKILLOPT_TEST_ROOT/calls" || return 1
  fi
  if [ "$2" = 1 ]; then
    [ -f "$HOME/.agents/skills/skillopt-sleep/SKILL.md" ] || return 1
  else
    [ ! -e "$HOME/.agents" ] || return 1
  fi
  if [ "$1$2" = 00 ]; then [ ! -e "$SKILLOPT_TEST_ROOT/calls" ]; fi
)
check 'SkillOpt supports Claude-only machines' skillopt_optional_agents 1 0
check 'SkillOpt supports Codex-only machines' skillopt_optional_agents 0 1
check 'SkillOpt skips machines with neither agent' skillopt_optional_agents 0 0

skillopt_paths_and_preservation() (
  skillopt_fixture
  export SKILLOPT_SLEEP_REPO="$HOME/quoted ' repository"
  mkdir -p "$HOME/.agents/skills/skillopt-sleep" "$HOME/.codex/prompts"
  printf 'old skill\n' >"$HOME/.agents/skills/skillopt-sleep/SKILL.md"
  printf 'unrelated prompt\n' >"$HOME/.codex/prompts/sleep.md"
  setup_skillopt >/dev/null || return 1
  local expected="$(cd -P "$SKILLOPT_SLEEP_REPO" && pwd)"
  unset SKILLOPT_SLEEP_REPO SKILLOPT_SLEEP_PYTHON
  source "$HOME/.agents/skills/skillopt-sleep/SKILL.md"
  [ "$SKILLOPT_SLEEP_REPO" = "$expected" ] || return 1
  [ -x "$SKILLOPT_SLEEP_PYTHON" ] || return 1
  [ "$(cat "$HOME/.codex/prompts/sleep.md")" = 'unrelated prompt' ] || return 1
  [ "$(cat "$HOME/.agents/skills/skillopt-sleep/"SKILL.md.backup-*)" = 'old skill' ] || return 1
  [ ! -e "$HOME/.skillopt-sleep" ] || return 1
  ! grep -Eq '(^skillopt-sleep | schedule| adopt| harvest| dry-run)' "$SKILLOPT_TEST_ROOT/calls"
)
check 'SkillOpt quotes paths, backs up replaced skills, and leaves prompts/config untouched' skillopt_paths_and_preservation

skillopt_nonfatal_failure() (
  skillopt_fixture
  export "$1=1"
  setup_skillopt >"$HOME/output" || return 1
  grep -q 'failed\|unavailable' "$HOME/output" || return 1
  if [ "$1" != SKILLOPT_TEST_CLAUDE_FAIL ]; then
    [ ! -e "$HOME/.agents" ] || return 1
    ! grep -q '^claude ' "$SKILLOPT_TEST_ROOT/calls"
  else
    [ -f "$HOME/.agents/skills/skillopt-sleep/SKILL.md" ] || return 1
    ! grep -q '^claude plugin install ' "$SKILLOPT_TEST_ROOT/calls"
  fi
)
check 'SkillOpt clone failure stays nonfatal' skillopt_nonfatal_failure SKILLOPT_TEST_CLONE_FAIL
check 'SkillOpt engine failure stays nonfatal' skillopt_nonfatal_failure SKILLOPT_TEST_UV_FAIL
check 'SkillOpt respects marketplace add failures while still installing Codex' skillopt_nonfatal_failure SKILLOPT_TEST_CLAUDE_FAIL

skillopt_local_checkout_preserved() (
  skillopt_fixture
  setup_skillopt >/dev/null || return 1
  local repo="$HOME/.local/share/skillopt" before
  case "$1" in
    dirty) printf changed >"$repo/pyproject.toml" ;;
    unrelated) git -C "$repo" remote set-url origin https://example.invalid/unrelated.git ;;
    diverged)
      printf local >"$repo/pyproject.toml"
      git -C "$repo" -c user.name=Tests -c user.email=tests@example.invalid commit -qam local ;;
  esac
  before="$(git -C "$repo" rev-parse HEAD):$(cat "$repo/pyproject.toml")"
  : >"$SKILLOPT_TEST_ROOT/calls"
  setup_skillopt >"$HOME/output" || return 1
  [ "$(git -C "$repo" rev-parse HEAD):$(cat "$repo/pyproject.toml")" = "$before" ] || return 1
  grep -q preserved "$HOME/output" || return 1
  ! grep -Eq '^uv |^claude ' "$SKILLOPT_TEST_ROOT/calls"
)
check 'SkillOpt preserves dirty checkouts' skillopt_local_checkout_preserved dirty
check 'SkillOpt preserves unrelated checkouts' skillopt_local_checkout_preserved unrelated
check 'SkillOpt preserves local commits' skillopt_local_checkout_preserved diverged

skillopt_fast_forwards() (
  skillopt_fixture
  setup_skillopt >/dev/null || return 1
  printf upstream >"$SKILLOPT_TEST_ROOT/upstream/pyproject.toml"
  "$SKILLOPT_TEST_GIT" -C "$SKILLOPT_TEST_ROOT/upstream" commit -qam update
  setup_skillopt >/dev/null || return 1
  [ "$(cat "$HOME/.local/share/skillopt/pyproject.toml")" = upstream ]
)
check 'SkillOpt fast-forwards upstream updates' skillopt_fast_forwards

skillopt_conflicting_marketplace() (
  skillopt_fixture
  mkdir -p "$HOME/.claude/plugins"
  printf '{"skillopt-sleep":{"source":{"source":"directory","path":"/unrelated"}}}\n' >"$HOME/.claude/plugins/known_marketplaces.json"
  setup_skillopt >"$HOME/output" || return 1
  grep -q 'another source' "$HOME/output" || return 1
  ! grep -q '^claude ' "$SKILLOPT_TEST_ROOT/calls"
)
check 'SkillOpt refuses conflicting marketplace sources' skillopt_conflicting_marketplace

report
