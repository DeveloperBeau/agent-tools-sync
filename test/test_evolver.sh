#!/usr/bin/env bash
# test_evolver.sh — unit + fuzz tests for lib/evolver.sh's pure decision
# functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/evolver.sh"

REAL_CLAUDE_SETTINGS='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"node /Users/beau/.claude/hooks/evolver/evolver-session-start.js"}]}]}}'
# Codex's installer runs in "mcp-plugin" mode: hooks land in config.toml
# tagged evolver-managed-hook, not in hooks.json.
REAL_CODEX_HOOKS='[[hooks.SessionStart.hooks]]
type = "command"
command = "evolver inject session-start --hook-stdin"
statusMessage = "evolver-managed-hook"'

# --- claude_hook_installed --------------------------------------------------
check "claude_hook: real settings.json line"        evolver_claude_hook_installed "$REAL_CLAUDE_SETTINGS"
check_fail "claude_hook: settings.json without it"  evolver_claude_hook_installed '{"hooks":{}}'
check_fail "claude_hook: empty text"                evolver_claude_hook_installed ""
# False positive guard: a bare mention of "evolver" without the hooks path
# (e.g. an unrelated env var or a different tool's config) must not count.
check_fail "claude_hook: bare mention of evolver, no hooks path" \
  evolver_claude_hook_installed '{"env":{"SOME_EVOLVER_FLAG":"1"}}'
# Same guard in lowercase: the probe matches a path, not the word, so a
# settings.json that merely names evolver (an unrelated command, a comment)
# must not read as installed.
check_fail "claude_hook: lowercase mention of evolver, no hooks path" \
  evolver_claude_hook_installed '{"hooks":{"Stop":[{"hooks":[{"command":"echo evolver ran"}]}]}}'

check "codex hooks migrate without duplication" python3 "$HERE/test_evolver_codex.py"

report
