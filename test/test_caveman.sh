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
HEADROOM_COMPAT_FIELDS=$'[model_providers.headroom]\nname = "Headroom (compatibility)"\nbase_url = "http://127.0.0.1:8787/compat/headroom"\nwire_api = "responses"\nrequires_openai_auth = true'
assert_contains "patch_codex_route: saved headroom chats retain their provider through the proxy chain" \
  "$patched_codex" "$HEADROOM_COMPAT_FIELDS"
assert_contains "patch_codex_route: default provider stays caveman" "$patched_codex" 'model_provider = "caveman"'
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_eq "patch_codex_route: running twice is a no-op the second time" "$patched_codex" "$(cat "$tmp_codex")"

# ATS already removed the legacy provider on affected machines. Repair must
# run even when the current Caveman route no longer needs patching.
printf '%s' "${CODEX_FIXTURE/8787\/chatgpt/8787/compat/headroom}" > "$tmp_codex"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_contains "patch_codex_route: repairs an already-patched config missing headroom" \
  "$(cat "$tmp_codex")" "$HEADROOM_COMPAT_FIELDS"

# Codex rewrites TOML without retaining Caveman's ownership comments.
MARKERLESS_CODEX=$'model_provider = "caveman"\n\n[model_providers.caveman]\nname = "Caveman"\nbase_url = "http://127.0.0.1:8787/compat/headroom"\nwire_api = "responses"\nrequires_openai_auth = true\n\n[model_providers.other]\nbase_url = "http://127.0.0.1:8787/chatgpt"\n'
printf '%s' "$MARKERLESS_CODEX" > "$tmp_codex"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_contains "patch_codex_route: repairs markerless config rewritten by Codex" "$(cat "$tmp_codex")" "$HEADROOM_COMPAT_FIELDS"
printf '%s' "${MARKERLESS_CODEX/8787\/compat\/headroom/8787/chatgpt}" > "$tmp_codex"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_contains "patch_codex_route: markerless native Caveman route reaches the chain" \
  "$(cat "$tmp_codex")" $'[model_providers.caveman]\nname = "Caveman"\nbase_url = "http://127.0.0.1:8787/compat/headroom"'
assert_contains "patch_codex_route: sibling provider keeps its native URL" \
  "$(cat "$tmp_codex")" $'[model_providers.other]\nbase_url = "http://127.0.0.1:8787/chatgpt"'
printf '%s' "${MARKERLESS_CODEX/8787\/compat\/headroom/9999/custom}" > "$tmp_codex"
custom_codex="$(cat "$tmp_codex")"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_eq "patch_codex_route: custom Caveman upstream stays untouched" "$custom_codex" "$(cat "$tmp_codex")"

# Match setup_headroom -> setup_caveman, including future ATS reruns.
source "$HERE/../lib/headroom.sh"
printf '%s\n%s\n' "$CODEX_FIXTURE" $'# --- Headroom init provider ---\n[model_providers.headroom]\nname = "Headroom init proxy"\nbase_url = "http://127.0.0.1:8788/v1"\n# --- end Headroom init provider ---\n\n[features]\nhooks = true' > "$tmp_codex"
headroom_fix_codex_config "$tmp_codex" >/dev/null
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
patched_codex="$(cat "$tmp_codex")"
assert_contains "patch_codex_route: legacy cleanup retains saved-chat compatibility" "$patched_codex" "$HEADROOM_COMPAT_FIELDS"
assert_contains "patch_codex_route: unrelated table survives migration" "$patched_codex" $'[features]\nhooks = true'
headroom_fix_codex_config "$tmp_codex" >/dev/null
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_eq "patch_codex_route: compatibility survives repeated legacy cleanup" "$patched_codex" "$(cat "$tmp_codex")"

EXISTING_HEADROOM=$'[model_providers.headroom]\nname = "User provider"\nbase_url = "https://example.test/v1"'
printf '%s\n%s\n' "$CODEX_FIXTURE" "$EXISTING_HEADROOM" > "$tmp_codex"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_contains "patch_codex_route: existing user provider survives" "$(cat "$tmp_codex")" "$EXISTING_HEADROOM"
assert_eq "patch_codex_route: existing provider is not duplicated" 1 "$(grep -c '^\[model_providers.headroom\]$' "$tmp_codex")"

printf '%s\n' $'model_provider = "openai"\n\n[features]\nhooks = true' > "$tmp_codex"
unmanaged_codex="$(cat "$tmp_codex")"
CAVEMAN_CODEX_CONFIG="$tmp_codex" caveman_patch_codex_route >/dev/null
assert_eq "patch_codex_route: config without Caveman ownership stays untouched" "$unmanaged_codex" "$(cat "$tmp_codex")"
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

# --- durable private proxy selection / native lifecycle --------------------
caveman_private_lifecycle_check() (
  local root managed CAVEMAN_PRIVATE_PROXY_BIN CAVEMAN_PROXY_BIN CAVEMAN_MANAGED_PROXY_BIN
  local CAVEMAN_CODEX_HOOKS CAVEMAN_PROXY_LOG enabled="" probes=0
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' EXIT
  CAVEMAN_MANAGED_PROXY_BIN="$root/vendor/caveman-proxy"
  CAVEMAN_PRIVATE_PROXY_BIN="$root/private/caveman-proxy"
  CAVEMAN_PROXY_BIN="$CAVEMAN_MANAGED_PROXY_BIN"
  CAVEMAN_CODEX_HOOKS="$root/hooks.json"
  CAVEMAN_PROXY_LOG="$root/proxy.log"
  mkdir -p "$root/private" "$root/vendor"
  printf '#!/bin/sh\n' > "$CAVEMAN_PRIVATE_PROXY_BIN"
  chmod +x "$CAVEMAN_PRIVATE_PROXY_BIN"
  caveman_select_proxy || return
  [ "$CAVEMAN_PROXY_BIN" = "$CAVEMAN_PRIVATE_PROXY_BIN" ] || return 1
  CAVEMAN_PROXY_BIN=/user/custom-proxy
  caveman_select_proxy || return
  [ "$CAVEMAN_PROXY_BIN" = /user/custom-proxy ] || return 1
  CAVEMAN_PROXY_BIN="$CAVEMAN_PRIVATE_PROXY_BIN"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s native-hook codex --adapter /old/cli.js"},{"type":"command","command":"/user/custom-hook"}]}]}}' "$CAVEMAN_MANAGED_PROXY_BIN" > "$CAVEMAN_CODEX_HOOKS"
  caveman() { [ "$1" = enable ] && enabled="$2:$CAVEMAN_PROXY_BIN"; }
  caveman_ensure_agent $'codex installed' codex Codex >/dev/null
  [ -z "$enabled" ] || return 1
  python3 - "$CAVEMAN_CODEX_HOOKS" "$CAVEMAN_PRIVATE_PROXY_BIN" <<'PY' || return 1
import json, shlex, sys
with open(sys.argv[1]) as source:
    hooks = json.load(source)["hooks"]["SessionStart"][0]["hooks"]
assert shlex.split(hooks[0]["command"]) == [sys.argv[2], "native-hook", "codex", "--adapter", "/old/cli.js"]
assert hooks[1]["command"] == "/user/custom-hook"
PY
  local migrated
  migrated="$(cat "$CAVEMAN_CODEX_HOOKS")"
  caveman_ensure_agent $'codex installed' codex Codex >/dev/null
  [ "$migrated" = "$(cat "$CAVEMAN_CODEX_HOOKS")" ] || return 1
  [ -z "$enabled" ] || return 1
  enabled=""
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/user/custom-proxy native-hook codex"}]}]}}' > "$CAVEMAN_CODEX_HOOKS"
  caveman_ensure_agent $'codex installed' codex Codex >/dev/null
  [ -z "$enabled" ] || return 1
  lsof() { [ -f "$CAVEMAN_PROXY_LOG" ] && printf '123\n'; }
  ps() { printf '%s.bin\n' "$CAVEMAN_PRIVATE_PROXY_BIN"; }
  nohup() { printf 'caveman bypass diagnostic\n'; }
  sleep() { wait; }
  caveman_start_proxy >/dev/null
  grep -q 'caveman bypass diagnostic' "$CAVEMAN_PROXY_LOG"
)
check "private proxy: selected for native migration/start; user hooks preserved; output persisted" caveman_private_lifecycle_check

tmp_rc="$(mktemp)"
CAVEMAN_PROXY_BIN='/tmp/private proxy/caveman-proxy' caveman_ensure_proxy_override "$tmp_rc" >/dev/null
after_first="$(cat "$tmp_rc")"
CAVEMAN_PROXY_BIN='/tmp/private proxy/caveman-proxy' caveman_ensure_proxy_override "$tmp_rc" >/dev/null
assert_eq "private proxy: shell override is idempotent" "$after_first" "$(cat "$tmp_rc")"
assert_eq "private proxy: shell override preserves spaces" '/tmp/private proxy/caveman-proxy' \
  "$(bash -c 'source "$1"; printf "%s" "$CAVEMAN_PROXY_BIN"' bash "$tmp_rc")"
rm -f "$tmp_rc"
check "private proxy: pinned install, atomic failure fallback and wrapper delegation" python3 "$HERE/test_caveman_install.py"

# --- route_agents (real temp files, one per proxy mode) ----------------------
route_dir="$(mktemp -d)"
printf '{\n  "env": {\n    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787/compat/headroom",\n    "KEEP": "1"\n  }\n}\n' > "$route_dir/settings.json"
printf 'model_provider = "caveman"\n\n[model_providers.caveman]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n\n[model_providers.headroom]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n\n[model_providers.other]\nbase_url = "http://127.0.0.1:8787/compat/headroom"\n' > "$route_dir/config.toml"
route() {
  CAVEMAN_CLAUDE_SETTINGS="$route_dir/settings.json" CAVEMAN_CODEX_CONFIG="$route_dir/config.toml" \
    caveman_route_agents "$1" >/dev/null
}
claude_url() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["env"].get("ANTHROPIC_BASE_URL","<unset>"))' "$route_dir/settings.json"; }
route no-headroom
assert_eq "route no-headroom: Claude uses Caveman's native route" "http://127.0.0.1:8787/w/claude" "$(claude_url)"
assert_contains "route no-headroom: Codex uses Caveman's native route" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.caveman]\nbase_url = "http://127.0.0.1:8787/chatgpt"'
route no-caveman
assert_eq "route no-caveman: Claude goes straight to Headroom" "http://127.0.0.1:8788" "$(claude_url)"
assert_contains "route no-caveman: saved headroom chats follow too" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.headroom]\nbase_url = "http://127.0.0.1:8788"'
route direct
assert_eq "route direct: Claude has no base URL override" "<unset>" "$(claude_url)"
assert_contains "route direct: Codex calls the ChatGPT backend" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.caveman]\nbase_url = "https://chatgpt.com/backend-api/codex"'
assert_contains "route direct: unrelated settings survive" "$(cat "$route_dir/settings.json")" '"KEEP": "1"'
route full
assert_eq "route full: Claude returns to the chain" "http://127.0.0.1:8787/compat/headroom" "$(claude_url)"
assert_contains "route: other providers are never touched" "$(cat "$route_dir/config.toml")" \
  $'[model_providers.other]\nbase_url = "http://127.0.0.1:8787/compat/headroom"'
printf '{"env":{"ANTHROPIC_BASE_URL":"https://custom.example"}}\n' > "$route_dir/settings.json"
check_fail "route: a custom Claude base URL is preserved and reported" route direct
assert_eq "route: custom Claude base URL unchanged" "https://custom.example" "$(claude_url)"
rm -rf "$route_dir"

report
