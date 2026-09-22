#!/usr/bin/env bash
# test_rtk.sh — unit + fuzz tests for lib/rtk.sh's pure decision functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/rtk.sh"

REAL_SETTINGS='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}'
REAL_AGENTS_MD=$'read this file\n@/Users/beau/.codex/RTK.md\nmore stuff'

# --- claude_hook_installed --------------------------------------------------
check "claude_hook: real settings.json line"        rtk_claude_hook_installed "$REAL_SETTINGS"
check_fail "claude_hook: settings.json without it"  rtk_claude_hook_installed '{"hooks":{}}'
check_fail "claude_hook: empty text"                rtk_claude_hook_installed ""
# False positive guard: a similarly-worded but different command must not count.
check_fail "claude_hook: near-miss command string" \
  rtk_claude_hook_installed '{"command":"rtk hook claude-experimental"}'
check_fail "claude_hook: mentions the phrase only in prose" \
  rtk_claude_hook_installed 'note: someone should add rtk hook claude support here'

# --- codex_installed ---------------------------------------------------------
check "codex_installed: file exists + real @-import"        rtk_codex_installed "yes" "$REAL_AGENTS_MD"
check_fail "codex_installed: file missing"                  rtk_codex_installed "no" "$REAL_AGENTS_MD"
check_fail "codex_installed: file exists, AGENTS.md empty"  rtk_codex_installed "yes" ""
# False positive guard: prose mentioning the filename without an @-import
# (e.g. a leftover note, or an unrelated "NOTES-RTK.md") must not count.
check_fail "codex_installed: prose mention without @-import" \
  rtk_codex_installed "yes" "see RTK.md for details"
check_fail "codex_installed: unrelated filename containing the substring" \
  rtk_codex_installed "yes" "@/tmp/NOTES-RTK.md is unrelated scratch"
check_fail "codex_installed: backup file with the same prefix" \
  rtk_codex_installed "yes" "@/Users/beau/.codex/RTK.md.bak leftover"
# Fuzz: exists flag garbled to anything other than the literal "yes" must be
# treated as "no", never silently coerced to true.
for garbage in "YES" "1" "true" " yes" ""; do
  check_fail "codex_installed: exists flag must be exact-match 'yes' (got '$garbage')" \
    rtk_codex_installed "$garbage" "$REAL_AGENTS_MD"
done

report
