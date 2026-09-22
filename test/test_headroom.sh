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

# --- codex_routed / mcp_registered -------------------------------------------
check "codex_routed: config mentioning headroom"     headroom_codex_routed 'model_providers.headroom'
check_fail "codex_routed: config with no mention"    headroom_codex_routed 'model_providers.openai'
check_fail "codex_routed: empty config"              headroom_codex_routed ''
check "mcp_registered: list mentioning headroom"     headroom_mcp_registered 'headroom: /path/to/mcp -  Connected'
check_fail "mcp_registered: list with no mention"    headroom_mcp_registered 'caveman: /path -  Connected'

# --- rc_has_leaked_anthropic_url --------------------------------------------
# Regression test for the real leak: `headroom init codex` wrote a shell rc
# block that also exported ANTHROPIC_BASE_URL, shadowing caveman's Claude
# Code routing for every new terminal.
LEAKY_BLOCK=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport ANTHROPIC_BASE_URL="http://127.0.0.1:8788"\nexport OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n# <<< headroom persistent env <<<\n'
CLEAN_BLOCK=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n# <<< headroom persistent env <<<\n'

check "rc_has_leaked_anthropic_url: real leaky block"        headroom_rc_has_leaked_anthropic_url "$LEAKY_BLOCK"
check_fail "rc_has_leaked_anthropic_url: cleaned-up block"   headroom_rc_has_leaked_anthropic_url "$CLEAN_BLOCK"
check_fail "rc_has_leaked_anthropic_url: no headroom block at all" \
  headroom_rc_has_leaked_anthropic_url 'export PATH=/usr/bin'
# False positive guard: an ANTHROPIC_BASE_URL export OUTSIDE the headroom
# block (e.g. hand-written by the user elsewhere in their rc file) is none
# of this function's business and must not be flagged.
check_fail "rc_has_leaked_anthropic_url: export outside the block is not our concern" \
  headroom_rc_has_leaked_anthropic_url $'export ANTHROPIC_BASE_URL="http://elsewhere"\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\n# <<< headroom persistent env <<<\n'
# Reset guard: an unrelated export AFTER the closing marker must not count
# either — this only passes if `inblock` actually resets to 0 at the closing
# marker (a state machine that forgot to reset would let it leak through;
# this is the after-the-block mirror of the ponytail insection bug above).
check_fail "rc_has_leaked_anthropic_url: inblock must reset — an export after the closing marker doesn't count" \
  headroom_rc_has_leaked_anthropic_url $'# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\n# <<< headroom persistent env <<<\n\nexport ANTHROPIC_BASE_URL="http://unrelated-user-line"\n'

# --- fix_rc_file (the actual file-editing side of the leak fix) ------------
# These operate on a real temp file, not just text in a variable, since
# fix_rc_file's job is specifically to rewrite a file on disk in place.
FIXTURE_LEAKY=$'export PATH=/usr/bin\n\n# >>> headroom persistent env >>>\nexport HEADROOM_PORT="8788"\nexport ANTHROPIC_BASE_URL="http://127.0.0.1:8788"\nexport OPENAI_BASE_URL="http://127.0.0.1:8788/v1"\n# <<< headroom persistent env <<<\n\nexport UNRELATED=1\n'

tmp_rc="$(mktemp)"
printf '%s' "$FIXTURE_LEAKY" > "$tmp_rc"
headroom_fix_rc_file "$tmp_rc" >/dev/null
fixed_text="$(cat "$tmp_rc")"
check_fail "fix_rc_file: leak is actually gone after fixing"      headroom_rc_has_leaked_anthropic_url "$fixed_text"
assert_contains "fix_rc_file: unrelated line before the block survives"   "$fixed_text" 'export PATH=/usr/bin'
assert_contains "fix_rc_file: OPENAI_BASE_URL line survives"              "$fixed_text" 'export OPENAI_BASE_URL="http://127.0.0.1:8788/v1"'
assert_contains "fix_rc_file: HEADROOM_PORT line survives"                "$fixed_text" 'export HEADROOM_PORT="8788"'
assert_contains "fix_rc_file: unrelated line after the block survives"    "$fixed_text" 'export UNRELATED=1'
assert_contains "fix_rc_file: block markers survive"                      "$fixed_text" '# >>> headroom persistent env >>>'
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

report
