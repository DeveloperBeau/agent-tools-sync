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

report
