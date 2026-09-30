#!/usr/bin/env bash
# test_headroom.sh — unit + fuzz tests for lib/headroom.sh's pure decision
# functions. These are the exact seams the real "port silently ignored on
# reapply" bug lived in, so this file is the most thorough of the four.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"   # fix_rc_file below calls warn(), defined here
source "$HERE/../lib/headroom.sh"

REAL_RUNNING=$'Profile:    default\nPreset:     persistent-service\nRuntime:    python\nSupervisor: service\nScope:      user\nPort:       8788\nStatus:     running\nHealthy:    yes\nHealth URL: http://127.0.0.1:8788/health\nBackend:    anthropic'
REAL_STOPPED=$'Profile:    default\nPreset:     persistent-service\nRuntime:    python\nSupervisor: service\nScope:      user\nPort:       8788\nStatus:     stopped\nHealthy:    no'
REAL_MISSING="Error: No deployment profile named 'default' is installed. Installed: init-user. Select one with --profile <name>."

# --- profile_exists ---------------------------------------------------------
check "profile_exists: real running profile"      headroom_profile_exists "$REAL_RUNNING"
check "profile_exists: real stopped profile"       headroom_profile_exists "$REAL_STOPPED"
check_fail "profile_exists: 'no profile' error"    headroom_profile_exists "$REAL_MISSING"
check_fail "profile_exists: empty text"            headroom_profile_exists ""
check_fail "profile_exists: garbage text"          headroom_profile_exists "$(head -c 200 /dev/urandom | base64)"

# --- profile_port ------------------------------------------------------------
assert_eq "profile_port: extracts port from running profile" "8788" "$(headroom_profile_port "$REAL_RUNNING")"
assert_eq "profile_port: extracts port from stopped profile" "8788" "$(headroom_profile_port "$REAL_STOPPED")"
assert_eq "profile_port: empty when profile missing" "" "$(headroom_profile_port "$REAL_MISSING")"
assert_eq "profile_port: tolerates CRLF line endings" "8788" \
  "$(headroom_profile_port "$(printf 'Profile:    default\r\nPort:       8788\r\n')")"

# --- is_healthy --------------------------------------------------------------
check "is_healthy: running + healthy"                headroom_is_healthy "$REAL_RUNNING"
check_fail "is_healthy: stopped + not healthy"       headroom_is_healthy "$REAL_STOPPED"
check_fail "is_healthy: empty text"                  headroom_is_healthy ""
# False positive guard: "running"/"yes" present but not attached to the
# Status:/Healthy: fields must not read as healthy.
check_fail "is_healthy: keywords present but out of field position" \
  headroom_is_healthy "the proxy is not running today, healthy: yes was a typo"
# Sharper false-positive guard: a stopped profile whose line still contains
# the word "running" elsewhere (an open-ended `.*running` regex would have
# matched this) must not be read as healthy. Healthy is pinned to "yes" so
# the verdict hinges purely on the Status regex, not on Healthy also being
# negative masking the bug (a weaker version of this test let the real
# open-ended-regex mutant survive mutation testing — see test/mutate.sh).
check_fail "is_healthy: 'stopped' line that also contains 'running', Healthy pinned to yes" \
  headroom_is_healthy $'Status:     stopped (was running before)\nHealthy:    yes'
# False negative guard: realistic noisy output (extra blank lines, trailing
# spaces) around the two fields must still be read correctly.
check "is_healthy: tolerates surrounding noise"      headroom_is_healthy $'\n\nsome banner\nStatus:     running   \nHealthy:    yes   \n\n'

# --- deployment_action (the function behind the actual port-reuse bug) ------
assert_eq "deployment_action: missing profile -> reapply" "reapply" \
  "$(headroom_deployment_action "$REAL_MISSING" 8788)"
assert_eq "deployment_action: right port, healthy -> healthy" "healthy" \
  "$(headroom_deployment_action "$REAL_RUNNING" 8788)"
assert_eq "deployment_action: right port, not healthy -> start" "start" \
  "$(headroom_deployment_action "$REAL_STOPPED" 8788)"
# This is the regression test for the actual bug: apply --port 8788 on a
# profile still configured for 8787 must trigger a reapply, not be treated
# as already satisfied.
assert_eq "deployment_action: port mismatch -> reapply (regression for the real bug)" "reapply" \
  "$(headroom_deployment_action "$REAL_RUNNING" 8787)"
assert_eq "deployment_action: garbage status text -> reapply, never a crash" "reapply" \
  "$(headroom_deployment_action "$(head -c 500 /dev/urandom | base64)" 8788)"
assert_eq "deployment_action: empty status text -> reapply" "reapply" \
  "$(headroom_deployment_action "" 8788)"

# --- profile_running (kill path: stop even if running-but-unhealthy) --------
check "profile_running: running + healthy"           headroom_profile_running "$REAL_RUNNING"
check_fail "profile_running: stopped"                 headroom_profile_running "$REAL_STOPPED"
check_fail "profile_running: missing profile"         headroom_profile_running "$REAL_MISSING"
check "profile_running: running but unhealthy still counts as running" \
  headroom_profile_running $'Profile:    default\nStatus:     running\nHealthy:    no'
check_fail "profile_running: 'stopped' line containing the word running" \
  headroom_profile_running $'Profile:    default\nStatus:     stopped (was running before)'

# --- mcp_registered -----------------------------------------------------
check "mcp_registered: list mentioning headroom"     headroom_mcp_registered 'headroom: /path/to/mcp -  Connected'
check_fail "mcp_registered: list with no mention"    headroom_mcp_registered 'caveman: /path -  Connected'

# --- legacy Codex init hook cleanup -----------------------------------------
# `headroom init codex` installs an on-demand init-user profile on the same
# port ATS owns with its default profile. That hook can stop/restart :8788
# underneath caveman, producing 502s while no upstream is listening.
tmp_hooks="$(mktemp)"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"/Users/test/.local/bin/headroom init hook ensure --profile init-user --marker headroom-init-codex","timeout":15},{"type":"command","command":"keep-session"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"headroom init hook ensure --profile init-user --marker headroom-init-codex"}]},{"hooks":[{"type":"command","command":"keep-pretool"}]}]}}' > "$tmp_hooks"
headroom_fix_codex_hooks "$tmp_hooks" >/dev/null
fixed_hooks="$(cat "$tmp_hooks")"
case "$fixed_hooks" in
  *"headroom init hook ensure"*)
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: fix_codex_hooks: legacy init-user hook should be gone\n' >&2 ;;
  *) TESTS_RUN=$((TESTS_RUN + 1)) ;;
esac
assert_contains "fix_codex_hooks: unrelated SessionStart hook survives" "$fixed_hooks" 'keep-session'
assert_contains "fix_codex_hooks: unrelated PreToolUse hook survives" "$fixed_hooks" 'keep-pretool'
before_hooks_second_pass="$fixed_hooks"
headroom_fix_codex_hooks "$tmp_hooks" >/dev/null
assert_eq "fix_codex_hooks: running twice is a no-op" "$before_hooks_second_pass" "$(cat "$tmp_hooks")"
rm -f "$tmp_hooks"

# --- rc_has_leaked_base_url --------------------------------------------
# Regression test for the real leak: the now-retired `headroom init codex`
# routing step wrote a shell rc block that exported ANTHROPIC_BASE_URL and
# OPENAI_BASE_URL, shadowing caveman's routing (both agents') for every new
# terminal. Caveman is the only proxy either agent's base URL should name.
LEAKY_BLOCK_ANTHROPIC=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport ANTHROPIC_BASE_URL="http://127.0.0.1:8788"\n# <<< headroom persistent env <<<\n'
LEAKY_BLOCK_OPENAI=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n# <<< headroom persistent env <<<\n'
CLEAN_BLOCK=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport HEADROOM_MODE="cache"\n# <<< headroom persistent env <<<\n'

check "rc_has_leaked_base_url: real leaky block, ANTHROPIC_BASE_URL"  headroom_rc_has_leaked_base_url "$LEAKY_BLOCK_ANTHROPIC"
check "rc_has_leaked_base_url: real leaky block, OPENAI_BASE_URL"     headroom_rc_has_leaked_base_url "$LEAKY_BLOCK_OPENAI"
check_fail "rc_has_leaked_base_url: cleaned-up block"                 headroom_rc_has_leaked_base_url "$CLEAN_BLOCK"
check_fail "rc_has_leaked_base_url: no headroom block at all" \
  headroom_rc_has_leaked_base_url 'export PATH=/usr/bin'
# False positive guard: a base-url export OUTSIDE the headroom block (e.g.
# hand-written by the user elsewhere in their rc file) is none of this
# function's business and must not be flagged.
check_fail "rc_has_leaked_base_url: export outside the block is not our concern" \
  headroom_rc_has_leaked_base_url $'export ANTHROPIC_BASE_URL="http://elsewhere"\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\n# <<< headroom persistent env <<<\n'
# Reset guard: an unrelated export AFTER the closing marker must not count
# either — this only passes if `inblock` actually resets to 0 at the closing
# marker (a state machine that forgot to reset would let it leak through;
# this is the after-the-block mirror of the ponytail insection bug above).
check_fail "rc_has_leaked_base_url: inblock must reset — an export after the closing marker doesn't count" \
  headroom_rc_has_leaked_base_url $'# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\n# <<< headroom persistent env <<<\n\nexport ANTHROPIC_BASE_URL="http://unrelated-user-line"\n'

# --- manifest_routes_agents (why the rc leak kept coming back) -------------
# fix_rc_file only cleans the symptom. The cause is the stored deployment
# manifest: applied with --providers auto/all it carries tool_envs, and every
# `install apply|start|restart` rewrites the shell block from it, so the leak
# returns on the next start. This is the probe that forces a manual reapply.
LEAKY_MANIFEST='{"provider_mode":"auto","targets":["claude","codex"],"tool_envs":{"claude":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8788"},"codex":{"OPENAI_BASE_URL":"http://127.0.0.1:8788/v1"}}}'
CLEAN_MANIFEST='{"provider_mode":"manual","targets":[],"tool_envs":{},"base_env":{"HEADROOM_PORT":"8788"},"health_url":"http://127.0.0.1:8788/readyz"}'

check "manifest_routes_agents: auto-providers manifest with tool_envs" \
  headroom_manifest_routes_agents "$LEAKY_MANIFEST"
check_fail "manifest_routes_agents: manual-providers manifest"        headroom_manifest_routes_agents "$CLEAN_MANIFEST"
check_fail "manifest_routes_agents: missing manifest reads as empty"  headroom_manifest_routes_agents ""
# A manifest that only mentions headroom's own URLs (health_url, base_env)
# must not be mistaken for agent routing.
check_fail "manifest_routes_agents: headroom's own urls are not agent routing" \
  headroom_manifest_routes_agents '{"health_url":"http://127.0.0.1:8788/readyz","image":"ghcr.io/x:latest"}'
# False positive guard: an unrelated key that merely ends in BASE_URL is not
# agent routing — only the two keys headroom writes into a shell rc file are.
check_fail "manifest_routes_agents: a lookalike key ending in BASE_URL" \
  headroom_manifest_routes_agents '{"extra_env":{"SOME_BASE_URL":"http://x","ANTHROPIC_TARGET_API_URL":"http://y"}}'
# False negative guard: the leak counts wherever it sits in the manifest —
# a hand-edited manifest can carry it in extra_env / base_env, not tool_envs.
check "manifest_routes_agents: leak in base_env, not tool_envs" \
  headroom_manifest_routes_agents '{"base_env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8788"},"tool_envs":{}}'
check "manifest_routes_agents: openai side alone still counts" \
  headroom_manifest_routes_agents '{"tool_envs":{"codex":{"OPENAI_BASE_URL":"http://127.0.0.1:8788/v1"}}}'
# Fuzz: random bytes are neither a manifest nor a reason to reapply, and must
# never crash the probe.
MANIFEST_FUZZ="$(head -c 400 /dev/urandom | base64)"
check_fail "manifest_routes_agents: random fuzz text never reads as leaking" \
  headroom_manifest_routes_agents "$MANIFEST_FUZZ"
check_fail "manifest_routes_agents: truncated json never reads as leaking" \
  headroom_manifest_routes_agents '{"provider_mode":"man'
# Fuzz, other direction: garbage *wrapped around* a real leak must still be
# caught — a manifest half-written by an interrupted apply is the real case.
check "manifest_routes_agents: leak survives surrounding garbage" \
  headroom_manifest_routes_agents "$MANIFEST_FUZZ"'{"tool_envs":{"claude":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:8788"}}'"$MANIFEST_FUZZ"

# --- effective_action (the seam that turns the probe into a reapply) --------
# The whole data flow: status text -> deployment_action -> effective_action.
# A leaky manifest must override every non-reapply verdict; a clean one must
# change nothing at all.
assert_eq "effective_action: healthy + leaky manifest -> reapply" \
  reapply "$(headroom_effective_action healthy "$LEAKY_MANIFEST")"
assert_eq "effective_action: start + leaky manifest -> reapply" \
  reapply "$(headroom_effective_action start "$LEAKY_MANIFEST")"
assert_eq "effective_action: reapply + leaky manifest stays reapply" \
  reapply "$(headroom_effective_action reapply "$LEAKY_MANIFEST")"
assert_eq "effective_action: healthy + clean manifest is left alone" \
  healthy "$(headroom_effective_action healthy "$CLEAN_MANIFEST")"
assert_eq "effective_action: start + clean manifest is left alone" \
  start "$(headroom_effective_action start "$CLEAN_MANIFEST")"
assert_eq "effective_action: missing manifest is left alone" \
  healthy "$(headroom_effective_action healthy "")"
assert_eq "effective_action: fuzz manifest is left alone" \
  healthy "$(headroom_effective_action healthy "$MANIFEST_FUZZ")"
# End to end over the real status text the port-reuse tests use: a healthy
# profile on the right port normally means "do nothing", and must not once
# the manifest is leaky.
assert_eq "effective_action: end to end, healthy status + leaky manifest -> reapply" \
  reapply "$(headroom_effective_action "$(headroom_deployment_action "$REAL_RUNNING" 8788)" "$LEAKY_MANIFEST")"
assert_eq "effective_action: end to end, healthy status + clean manifest -> healthy" \
  healthy "$(headroom_effective_action "$(headroom_deployment_action "$REAL_RUNNING" 8788)" "$CLEAN_MANIFEST")"

# --- fix_rc_file (the actual file-editing side of the leak fix) ------------
# These operate on a real temp file, not just text in a variable, since
# fix_rc_file's job is specifically to rewrite a file on disk in place.
FIXTURE_LEAKY=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport ANTHROPIC_BASE_URL="http://127.0.0.1:8788"\nexport OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n# <<< headroom persistent env <<<\n\nexport UNRELATED=1\n'

tmp_rc="$(mktemp)"
printf '%s' "$FIXTURE_LEAKY" > "$tmp_rc"
headroom_fix_rc_file "$tmp_rc" >/dev/null
fixed_text="$(cat "$tmp_rc")"
check_fail "fix_rc_file: leak is actually gone after fixing"      headroom_rc_has_leaked_base_url "$fixed_text"
assert_contains "fix_rc_file: unrelated line before the block survives"   "$fixed_text" 'export PATH=/usr/bin'
assert_contains "fix_rc_file: HEADROOM_PORT line survives"                "$fixed_text" 'export HEADROOM_PORT="8788"'
assert_contains "fix_rc_file: unrelated line after the block survives"    "$fixed_text" 'export UNRELATED=1'
assert_contains "fix_rc_file: block markers survive"                      "$fixed_text" '# >>> headroom persistent env >>>'
case "$fixed_text" in
  *OPENAI_BASE_URL*) TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: fix_rc_file: OPENAI_BASE_URL line should be gone too\n' >&2 ;;
  *) TESTS_RUN=$((TESTS_RUN + 1)) ;;
esac
rm -f "$tmp_rc"

# Idempotency: running it again on an already-clean file changes nothing.
tmp_rc2="$(mktemp)"
printf '%s' "$fixed_text" > "$tmp_rc2"
before_second_pass="$(cat "$tmp_rc2")"
headroom_fix_rc_file "$tmp_rc2" >/dev/null
assert_eq "fix_rc_file: running twice is a no-op the second time" "$before_second_pass" "$(cat "$tmp_rc2")"
rm -f "$tmp_rc2"

# Failure/edge cases: missing file and file with no headroom block at all
# must not error out or create anything.
check "fix_rc_file: missing file is a silent no-op" headroom_fix_rc_file "/tmp/agent-tools-sync-test-does-not-exist.$$"
tmp_rc3="$(mktemp)"
printf 'export PATH=/usr/bin\n' > "$tmp_rc3"
before_no_block="$(cat "$tmp_rc3")"
headroom_fix_rc_file "$tmp_rc3" >/dev/null
assert_eq "fix_rc_file: file without a headroom block is untouched" "$before_no_block" "$(cat "$tmp_rc3")"
rm -f "$tmp_rc3"

# --- fix_codex_config (retired Codex provider block cleanup) ----------------
CODEX_FIXTURE=$'model_provider = "caveman"\n\n# --- Headroom init provider ---\nopenai_base_url = "http://127.0.0.1:8788/v1"\n\n[model_providers.headroom]\nname = "Headroom init proxy"\nbase_url = "http://127.0.0.1:8788/v1"\n# --- end Headroom init provider ---\n\n[features]\nhooks = true\n'
tmp_codex="$(mktemp)"
printf '%s' "$CODEX_FIXTURE" > "$tmp_codex"
headroom_fix_codex_config "$tmp_codex" >/dev/null
fixed_codex="$(cat "$tmp_codex")"
case "$fixed_codex" in
  *"Headroom init provider"*|*"model_providers.headroom"*)
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: fix_codex_config: retired provider block should be gone\n' >&2 ;;
  *) TESTS_RUN=$((TESTS_RUN + 1)) ;;
esac
assert_contains "fix_codex_config: unrelated model_provider line survives" "$fixed_codex" 'model_provider = "caveman"'
assert_contains "fix_codex_config: unrelated features block survives" "$fixed_codex" 'hooks = true'
headroom_fix_codex_config "$tmp_codex" >/dev/null
assert_eq "fix_codex_config: running twice is a no-op the second time" "$fixed_codex" "$(cat "$tmp_codex")"
rm -f "$tmp_codex"

check "fix_codex_config: missing file is a silent no-op" headroom_fix_codex_config "/tmp/agent-tools-sync-test-does-not-exist.$$"
tmp_codex2="$(mktemp)"
printf 'model_provider = "caveman"\n' > "$tmp_codex2"
before_no_provider_block="$(cat "$tmp_codex2")"
headroom_fix_codex_config "$tmp_codex2" >/dev/null
assert_eq "fix_codex_config: file without the retired block is untouched" "$before_no_provider_block" "$(cat "$tmp_codex2")"
rm -f "$tmp_codex2"

# Setup must keep the pinned diagnostic build, never replace it via PyPI's
# `headroom update`, and restart an older live proxy after first install.
headroom_pin_setup_calls() (
  local installed=false calls="" HEADROOM_PORT=8788
  have() { return 0; }
  headroom_has_route_health() { [ "$installed" = true ]; }
  install_headroom() { calls="$calls install"; installed=true; }
  headroom_stop_proxy() { calls="$calls stop"; }
  headroom_ensure_proxy() { calls="$calls ensure"; }
  headroom() {
    if [ "$1" = --version ]; then echo 0.39.1
    elif [ "$1" = update ]; then calls="$calls update"
    fi
  }
  with_timeout() { shift; "$@"; }
  run() { "$@"; }
  headroom_fix_rc_file() { :; }
  headroom_fix_codex_config() { :; }
  headroom_fix_codex_hooks() { :; }
  headroom_remove_legacy_profile() { :; }
  headroom_ensure_claude_mcp() { :; }
  headroom_ensure_codex_mcp() { :; }
  setup_headroom >/dev/null
  printf '%s' "$calls"
)
assert_eq "setup_headroom: pinned fork install restarts old proxy without PyPI update" \
  " install stop ensure" "$(headroom_pin_setup_calls)"

report
