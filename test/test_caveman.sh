#!/usr/bin/env bash
# test_caveman.sh — unit + fuzz tests for lib/caveman.sh's pure decision
# functions.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"   # functions below call ok()/warn()/run(), defined here
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

# --- route_agents (real temp files, one per proxy mode) ----------------------
route_dir="$(mktemp -d)"
printf '{\n  "env": {\n    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787/compat/headroom",\n    "KEEP": "1"\n  }\n}\n' > "$route_dir/settings.json"
printf 'model_provider = "caveman"\n\n[model_providers.caveman]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n\n[model_providers.headroom]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n\n[model_providers.other]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n' > "$route_dir/config.toml"
route() {
  CAVEMAN_CLAUDE_SETTINGS="$route_dir/settings.json" CAVEMAN_CODEX_CONFIG="$route_dir/config.toml" \
    caveman_route_agents "$1" >/dev/null
}
claude_url() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["env"].get("ANTHROPIC_BASE_URL","<unset>"))' "$route_dir/settings.json"; }
route full
assert_eq "route full: Claude uses Caveman's native route" "http://127.0.0.1:8787/w/claude" "$(claude_url)"
assert_contains "route full: first-party flag set with the route" "$(cat "$route_dir/settings.json")" '"_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1"'
assert_contains "route full: Codex uses Caveman's native route" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.caveman]\nbase_url = "http://127.0.0.1:8787/chatgpt"'
assert_contains "route full: saved headroom chats follow too" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.headroom]\nbase_url = "http://127.0.0.1:8787/chatgpt"'
route direct
assert_eq "route direct: Claude has no base URL override" "<unset>" "$(claude_url)"
assert_contains "route direct: Codex calls the ChatGPT backend" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.caveman]\nbase_url = "https://chatgpt.com/backend-api/codex"'
assert_contains "route direct: unrelated settings survive" "$(cat "$route_dir/settings.json")" '"KEEP": "1"'
route full
assert_eq "route full: Claude returns to Caveman" "http://127.0.0.1:8787/w/claude" "$(claude_url)"
assert_contains "route: other providers are never touched" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.other]\nbase_url = "http://127.0.0.1:8787/compat/headroom"'
printf '{"env":{"ANTHROPIC_BASE_URL":"https://custom.example"}}\n' > "$route_dir/settings.json"
check_fail "route: a custom Claude base URL is preserved and reported" route direct
assert_eq "route: custom Claude base URL unchanged" "https://custom.example" "$(claude_url)"
rm -rf "$route_dir"

# A route flag Caveman wrote with the base URL goes with it.
flag_dir="$(mktemp -d)"
printf '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8787/w/claude","_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL":"1","KEEP":"1"}}\n' > "$flag_dir/settings.json"
CAVEMAN_CLAUDE_SETTINGS="$flag_dir/settings.json" CAVEMAN_CODEX_CONFIG="$flag_dir/none.toml" caveman_route_agents direct >/dev/null
flag_after="$(cat "$flag_dir/settings.json")"
assert_contains "direct: base URL removed, other env kept" "$flag_after" '"KEEP": "1"'
check_fail "direct: first-party flag removed with the route" grep -q ASSUME_FIRST_PARTY "$flag_dir/settings.json"
rm -rf "$flag_dir"

report
