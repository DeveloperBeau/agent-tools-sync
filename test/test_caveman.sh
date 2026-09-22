#!/usr/bin/env bash
# test_caveman.sh — unit + fuzz tests for lib/caveman.sh's pure decision
# functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"   # ssrf/patch functions below call ok()/warn()/run(), defined here
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

# --- yaml_has_headroom_stack -------------------------------------------------
STACKED_YAML=$'mode: compress\ncompat:\n  headroom:\n    base_url: http://127.0.0.1:8788\n    wire_dialect: anthropic\n'
check "yaml_has_headroom_stack: real stacked config"        caveman_yaml_has_headroom_stack "$STACKED_YAML"
check_fail "yaml_has_headroom_stack: empty file"             caveman_yaml_has_headroom_stack ""
check_fail "yaml_has_headroom_stack: mode record, no compat" caveman_yaml_has_headroom_stack $'mode: record\n'
check_fail "yaml_has_headroom_stack: compat mount but wrong port" \
  caveman_yaml_has_headroom_stack $'mode: compress\ncompat:\n  headroom:\n    base_url: http://127.0.0.1:9999\n'
check_fail "yaml_has_headroom_stack: right compat mount but mode still record" \
  caveman_yaml_has_headroom_stack $'mode: record\ncompat:\n  headroom:\n    base_url: http://127.0.0.1:8788\n'

# --- route_patched ------------------------------------------------------------
tmp_settings_patched="$(mktemp)"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8787/compat/headroom"}}' > "$tmp_settings_patched"
CAVEMAN_CLAUDE_SETTINGS="$tmp_settings_patched" check "route_patched: claude, patched settings.json" \
  caveman_route_patched claude
rm -f "$tmp_settings_patched"

tmp_settings_native="$(mktemp)"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8787/w/claude"}}' > "$tmp_settings_native"
CAVEMAN_CLAUDE_SETTINGS="$tmp_settings_native" check_fail "route_patched: claude, still on native /w/claude route" \
  caveman_route_patched claude
rm -f "$tmp_settings_native"

check_fail "route_patched: unknown agent" caveman_route_patched gemini

# --- ensure_ssrf_allowlist (real temp file) ----------------------------------
tmp_rc="$(mktemp)"
printf 'export PATH=/usr/bin\n' > "$tmp_rc"
caveman_ensure_ssrf_allowlist "$tmp_rc" >/dev/null
after_first="$(cat "$tmp_rc")"
assert_contains "ensure_ssrf_allowlist: adds the allowlist export" "$after_first" 'CAVE_SSRF_ALLOWLIST="127.0.0.1:8788"'
assert_contains "ensure_ssrf_allowlist: unrelated line survives" "$after_first" 'export PATH=/usr/bin'
caveman_ensure_ssrf_allowlist "$tmp_rc" >/dev/null
assert_eq "ensure_ssrf_allowlist: running twice is a no-op the second time" "$after_first" "$(cat "$tmp_rc")"
rm -f "$tmp_rc"

# --- patch_codex_route (real temp file, scoped to caveman's own block) ------
CODEX_FIXTURE=$'model_provider = "caveman"\n\nopenai_base_url = "http://127.0.0.1:8788/v1"\n\n# >>> caveman:native-tables\n[model_providers.caveman]\nname = "Caveman"\nbase_url = "http://127.0.0.1:8787/chatgpt"\nwire_api = "responses"\n# <<< caveman:native-tables\n'
tmp_codex="$(mktemp)"
printf '%s' "$CODEX_FIXTURE" > "$tmp_codex"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
patched_codex="$(cat "$tmp_codex")"
assert_contains "patch_codex_route: base_url repointed at compat/headroom" "$patched_codex" 'base_url = "http://127.0.0.1:8787/compat/headroom"'
assert_contains "patch_codex_route: unrelated root base_url survives (dead but not this function's job)" \
  "$patched_codex" 'openai_base_url = "http://127.0.0.1:8788/v1"'
assert_contains "patch_codex_route: wire_api line survives" "$patched_codex" 'wire_api = "responses"'
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_eq "patch_codex_route: running twice is a no-op the second time" "$patched_codex" "$(cat "$tmp_codex")"
rm -f "$tmp_codex"

# --- patch_claude_route (real temp file, real node JSON patch) --------------
if have node; then
  CLAUDE_FIXTURE='{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8787/w/claude"},"other":"untouched"}'
  tmp_settings="$(mktemp)"
  printf '%s' "$CLAUDE_FIXTURE" > "$tmp_settings"
  CAVEMAN_CLAUDE_SETTINGS="$tmp_settings" caveman_patch_claude_route >/dev/null
  patched_settings="$(cat "$tmp_settings")"
  assert_contains "patch_claude_route: env repointed at compat/headroom" "$patched_settings" '"ANTHROPIC_BASE_URL": "http://127.0.0.1:8787/compat/headroom"'
  assert_contains "patch_claude_route: unrelated top-level key survives" "$patched_settings" '"other": "untouched"'
  CAVEMAN_CLAUDE_SETTINGS="$tmp_settings" caveman_patch_claude_route >/dev/null
  assert_eq "patch_claude_route: running twice is a no-op the second time" "$patched_settings" "$(cat "$tmp_settings")"
  rm -f "$tmp_settings"
fi

report
