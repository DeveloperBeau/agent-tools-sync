#!/usr/bin/env bash
# test_claude-mem.sh — unit + fuzz tests for lib/claude-mem.sh's pure
# decision functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"   # already_added_error lives here
source "$HERE/../lib/claude-mem.sh"

REAL_PLUGIN_LIST=$'  ❯ claude-mem@thedotmack\n  ❯ ponytail@ponytail'

# --- claude_installed ---------------------------------------------------------
check "claude_installed: real plugin list line"       claude_mem_claude_installed "$REAL_PLUGIN_LIST"
check_fail "claude_installed: list without it"         claude_mem_claude_installed '  ❯ ponytail@ponytail'
check_fail "claude_installed: empty text"              claude_mem_claude_installed ""
# False positive guard: a near-miss plugin id must not count.
check_fail "claude_installed: near-miss id" \
  claude_mem_claude_installed '  ❯ claude-mem-experimental@thedotmack'

# --- codex_installed/runtime_ready (real filesystem checks) -----------------
# Prefix assignment, not a subshell: check/check_fail write to TESTS_RUN/
# TESTS_FAILED in this shell, and a subshell would fork those away silently.
tmp_codex_home="$(mktemp -d)"
HOME="$tmp_codex_home" check_fail "codex_installed: neither plugin cache dir exists" \
  claude_mem_codex_installed
mkdir -p "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3"
printf '{}\n' > "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3/package.json"
HOME="$tmp_codex_home" check "codex_installed: thedotmack cache dir present" \
  claude_mem_codex_installed
check_fail "runtime_ready: missing zod/v3 is not healthy" \
  claude_mem_runtime_ready "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3"
mkdir -p "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3/node_modules/zod/v3"
printf 'export {};\n' > "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3/node_modules/zod/v3/index.js"
check "runtime_ready: zod/v3 dependency present" \
  claude_mem_runtime_ready "$tmp_codex_home/.codex/plugins/cache/thedotmack/claude-mem/13.25.3"
rm -rf "$tmp_codex_home"

tmp_codex_home2="$(mktemp -d)"
mkdir -p "$tmp_codex_home2/.codex/plugins/cache/claude-mem-local/claude-mem/13.25.3"
printf '{}\n' > "$tmp_codex_home2/.codex/plugins/cache/claude-mem-local/claude-mem/13.25.3/package.json"
HOME="$tmp_codex_home2" check "codex_installed: claude-mem-local cache dir present" \
  claude_mem_codex_installed
rm -rf "$tmp_codex_home2"

# --- already_added_error (shared with ponytail, re-exercised here) ---------
check "already_added_error: real error text" already_added_error \
  "Error: marketplace 'claude-mem' is already added from a different source"
check_fail "already_added_error: unrelated error" already_added_error "Error: network unreachable"

worker_script_fixture() (
  HOME="$(mktemp -d)"
  trap 'rm -rf "$HOME"' EXIT
  root="$HOME/installed memory"
  mkdir -p "$root/scripts" "$HOME/.claude/plugins"
  touch "$root/scripts/worker-service.cjs"
  python3 -c 'import json,sys; json.dump({"plugins":{"claude-mem@thedotmack":[{"installPath":sys.argv[1]}]}},open(sys.argv[2],"w"))' \
    "$root" "$HOME/.claude/plugins/installed_plugins.json"
  [ "$(claude_mem_worker_script)" = "$root/scripts/worker-service.cjs" ]
)
check 'worker script resolves installed Claude registry, including spaces' worker_script_fixture

worker_codex_fixture() (
  HOME="$(mktemp -d)"
  trap 'rm -rf "$HOME"' EXIT
  root="$HOME/.codex/plugins/cache/claude-mem-local/claude-mem/13.28.0"
  mkdir -p "$root/scripts" "$HOME/.claude/plugins"
  printf 'not JSON' > "$HOME/.claude/plugins/installed_plugins.json"
  touch "$root/package.json" "$root/scripts/worker-service.cjs"
  [ "$(claude_mem_worker_script)" = "$root/scripts/worker-service.cjs" ]
)
check 'worker script falls back to Codex runtime after malformed Claude registry' worker_codex_fixture

worker_start_fixture() (
  status="$1" code="$2" expected="$3"
  claude_mem_worker_script() { printf '/fixture/worker-service.cjs\n'; }
  pgrep() { return 1; }
  have() { [ "$1" = bun ]; }
  with_timeout() {
    [ "$1 $2 $3 $4" = '60 bun /fixture/worker-service.cjs start' ] || return 99
    printf '{"status":"%s"}\n' "$status"
    return "$code"
  }
  claude() { return 99; }
  npx() { return 99; }
  nohup() { return 99; }
  claude_mem_start_worker >/dev/null
  [ "$?" = "$expected" ]
)
check 'worker native start waits for ready result without npx or Claude CLI' worker_start_fixture ready 0 0
check 'worker start fails on error JSON even with exit zero' worker_start_fixture error 0 1
check 'worker start fails on native exit error' worker_start_fixture ready 1 1
check 'worker start fails on missing status' worker_start_fixture '' 0 1

worker_existing_fixture() (
  pgrep() { return 0; }
  claude_mem_worker_script() { return 99; }
  with_timeout() { return 99; }
  claude_mem_start_worker >/dev/null
)
check 'existing memory worker stays running without resetting provider backoff' worker_existing_fixture

worker_stop_fixture() (
  running=1 calls=0
  claude_mem_worker_script() { printf '/fixture/worker-service.cjs\n'; }
  have() { [ "$1" = bun ]; }
  pgrep() { [ "$running" = 1 ]; }
  pkill() { return 99; }
  with_timeout() {
    [ "$1 $2 $3 $4" = '60 bun /fixture/worker-service.cjs stop' ] || return 99
    calls=$((calls + 1)); running=0
  }
  claude_mem_stop_worker >/dev/null && [ "$calls" = 1 ] && [ "$running" = 0 ]
)
check 'memory stop uses native clean shutdown rather than broad pkill' worker_stop_fixture

worker_stop_failure_fixture() (
  pgrep() { return 0; }
  claude_mem_worker_script() { printf '/fixture/worker-service.cjs\n'; }
  have() { [ "$1" = bun ]; }
  with_timeout() { return 1; }
  ! claude_mem_stop_worker >/dev/null
)
check 'memory stop propagates native failure' worker_stop_failure_fixture

worker_inspection_failure() (
  pgrep() { return 2; }
  claude_mem_worker_script() { printf '/fixture/worker-service.cjs\n'; }
  claude_mem_worker_cli() { return 99; }
  ! claude_mem_start_worker >/dev/null && ! claude_mem_stop_worker >/dev/null
)
check 'memory lifecycle fails when process inspection is unavailable' worker_inspection_failure

report
