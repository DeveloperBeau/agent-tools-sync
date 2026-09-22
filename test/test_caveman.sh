#!/usr/bin/env bash
# test_caveman.sh — unit + fuzz tests for lib/caveman.sh's pure decision
# functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/caveman.sh"

REAL_STATUS=$'native integrations\nclaude     installed · newer_unknown · provider_proxy, session_start, mcp\ncodex      available · newer_unknown · local_runtime_available\nhermes     unavailable · unreported · local_runtime_available'
REAL_VERSION_JSON='{
  "version": "1.3.4",
  "binary_release": "bin-v1.1.7"
}'

# --- agent_state / agent_installed ------------------------------------------
assert_eq "agent_state: claude row"           "installed"  "$(caveman_agent_state "$REAL_STATUS" claude)"
assert_eq "agent_state: codex row"            "available"  "$(caveman_agent_state "$REAL_STATUS" codex)"
assert_eq "agent_state: agent absent"         ""           "$(caveman_agent_state "$REAL_STATUS" gemini)"
assert_eq "agent_state: empty status text"    ""           "$(caveman_agent_state "" claude)"

check "agent_installed: claude is installed"          caveman_agent_installed "$REAL_STATUS" claude
check_fail "agent_installed: codex only available"    caveman_agent_installed "$REAL_STATUS" codex
check_fail "agent_installed: agent not a row at all"  caveman_agent_installed "$REAL_STATUS" gemini

# False positive guard: a row for a *different* agent whose name merely
# starts with the same token, or a compound token, must not match as an
# exact "codex" row (awk's exact-field comparison is what protects this).
check_fail "agent_installed: compound token must not match bare agent name" \
  caveman_agent_installed $'codex-app  installed · x' codex
# False positive guard: the word "installed" appearing elsewhere in the
# text (not as $2 of the agent's own row) must not count.
check_fail "agent_installed: 'installed' mentioned elsewhere, not on the agent row" \
  caveman_agent_installed $'notes: codex integration used to be installed\ncodex      available · x' codex

# Fuzz: garbage / binary text must never crash and must never report
# "installed" (bias toward false-negative, which only costs a redundant
# `caveman enable`, over false-positive, which would silently skip setup).
FUZZ_TEXT="$(head -c 400 /dev/urandom | base64)"
check_fail "agent_installed: random fuzz text never reads as installed (claude)" \
  caveman_agent_installed "$FUZZ_TEXT" claude
check_fail "agent_installed: random fuzz text never reads as installed (codex)" \
  caveman_agent_installed "$FUZZ_TEXT" codex

# Multiple candidate lines: documents that the first match wins.
TWO_ROWS=$'claude     installed · a\nclaude     available · b'
assert_eq "agent_state: first matching row wins when duplicated" "installed" \
  "$(caveman_agent_state "$TWO_ROWS" claude)"

# --- version_string ----------------------------------------------------------
assert_eq "version_string: real caveman --version JSON" "1.3.4" \
  "$(caveman_version_string "$REAL_VERSION_JSON")"
assert_eq "version_string: missing version key -> empty, no crash" "" \
  "$(caveman_version_string '{"binary_release":"bin-v1.1.7"}')"
assert_eq "version_string: empty input -> empty" "" \
  "$(caveman_version_string "")"
# Documented boundary (false negative): a space before the colon is not the
# format caveman actually emits, so this intentionally does not match.
assert_eq "version_string: space-before-colon variant is NOT matched (documented boundary)" "" \
  "$(caveman_version_string '{"version" : "9.9.9"}')"
# Fuzz: malformed JSON must not crash the extractor.
assert_eq "version_string: malformed JSON -> empty, no crash" "" \
  "$(caveman_version_string '{not json at all')"

report
