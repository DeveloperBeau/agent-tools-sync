#!/usr/bin/env bash
# mutate.sh — mutation testing for the pure decision functions in lib/*.sh.
#
# For each mutant: copy the whole repo to a scratch dir, apply one realistic
# code mutation (flip a comparison, loosen a regex, grab the wrong field),
# then rerun that module's test file against the mutated copy. A mutant
# should be KILLED (tests fail); one that SURVIVES (tests still pass) means
# a test isn't actually connected to that line of logic — a real gap, not
# a passing grade.
#
# "Interleaving proves an assertion is honest; mutation proves the test is
# connected." — this script is the mutation half of that pair.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

MUT_LIB=(); MUT_TEST=(); MUT_DESC=(); MUT_OLD=(); MUT_NEW=()
mutant() { MUT_LIB+=("$1"); MUT_TEST+=("$2"); MUT_DESC+=("$3"); MUT_OLD+=("$4"); MUT_NEW+=("$5"); }

# ---------------------------------------------------------------- headroom --
mutant lib/headroom.sh test/test_headroom.sh \
  "profile_exists: invert the 'Profile:' branch" \
  '*"Profile:"*)                    return 0 ;;' \
  '*"Profile:"*)                    return 1 ;;'

mutant lib/headroom.sh test/test_headroom.sh \
  "profile_port: wrong awk field (\$1 instead of \$2)" \
  "awk -F': *' '/^Port:/{print \$2; exit}'" \
  "awk -F': *' '/^Port:/{print \$1; exit}'"

mutant lib/headroom.sh test/test_headroom.sh \
  "is_healthy: revert to the open-ended (buggy) match" \
  "grep -qE '^Status:[[:space:]]+running[[:space:]]*\$'" \
  "grep -q '^Status:.*running'"

mutant lib/headroom.sh test/test_headroom.sh \
  "deployment_action: flip the port-mismatch comparison" \
  'if [ "$(headroom_profile_port "$status_text")" != "$desired_port" ]; then' \
  'if [ "$(headroom_profile_port "$status_text")" = "$desired_port" ]; then'

mutant lib/headroom.sh test/test_headroom.sh \
  "deployment_action: always report healthy instead of start" \
  'echo "start"' \
  'echo "healthy"'

mutant lib/headroom.sh test/test_headroom.sh \
  "codex_routed/mcp_registered: search for the wrong marker" \
  "grep -qi 'headroom'" \
  "grep -qi 'nonexistent-marker-xyz'"

mutant lib/headroom.sh test/test_headroom.sh \
  "rc_has_leaked_anthropic_url: never reset inblock, so any later export counts" \
  '/^# <<< headroom persistent env <<</ { inblock=0 }' \
  '/^# <<< headroom persistent env <<</ { inblock=inblock }'

mutant lib/headroom.sh test/test_headroom.sh \
  "fix_rc_file: stop actually skipping the leaked line (rewrite becomes a no-op)" \
  'inblock && /^export ANTHROPIC_BASE_URL=/ { next }' \
  'inblock && /^export ANTHROPIC_BASE_URL=/ { }'

# --------------------------------------------------------------------- rtk --
mutant lib/rtk.sh test/test_rtk.sh \
  "claude_hook_installed: loosen back to a bare substring match" \
  "grep -qE '\"rtk hook claude\"'" \
  "grep -q 'rtk hook claude'"

mutant lib/rtk.sh test/test_rtk.sh \
  "codex_installed: drop the file-exists guard" \
  '[ "$rtk_md_exists" = "yes" ] || return 1' \
  ': # guard removed'

mutant lib/rtk.sh test/test_rtk.sh \
  "codex_installed: loosen the @-import regex to a bare substring" \
  "grep -qE '@([^[:space:]]*/)?RTK\\.md([[:space:]]|\$)'" \
  "grep -q 'RTK.md'"

# ----------------------------------------------------------------- caveman --
mutant lib/caveman.sh test/test_caveman.sh \
  "agent_state: compare against the wrong awk field" \
  "awk -v a=\"\$agent\" '\$1==a{print \$2; exit}'" \
  "awk -v a=\"\$agent\" '\$2==a{print \$2; exit}'"

mutant lib/caveman.sh test/test_caveman.sh \
  "agent_installed: accept any non-empty state, not just 'installed'" \
  '[ "$(caveman_agent_state "$1" "$2")" = "installed" ]' \
  '[ -n "$(caveman_agent_state "$1" "$2")" ]'

mutant lib/caveman.sh test/test_caveman.sh \
  "version_string: grab the wrong JSON key" \
  "grep -o '\"version\": *\"[^\"]*\"'" \
  "grep -o '\"binary_release\": *\"[^\"]*\"'"

# ---------------------------------------------------------------- ponytail --
mutant lib/ponytail.sh test/test_ponytail.sh \
  "codex_installed: never reset insection on a new table header" \
  '/^\[/ { insection=0 }' \
  '/^\[/ { insection=insection }'

mutant lib/ponytail.sh test/test_ponytail.sh \
  "codex_installed: accept enabled=false too" \
  'insection && /enabled[ \t]*=[ \t]*true/ { found=1 }' \
  'insection && /enabled[ \t]*=[ \t]*(true|false)/ { found=1 }'

mutant lib/ponytail.sh test/test_ponytail.sh \
  "already_added_error: search for a phrase that never appears" \
  "grep -qi 'already added'" \
  "grep -qi 'zzz-never-matches-zzz'"

# ------------------------------------------------------------------ runner --
killed=0 survived=0 skipped=0

for i in "${!MUT_LIB[@]}"; do
  lib_rel="${MUT_LIB[$i]}" test_rel="${MUT_TEST[$i]}" desc="${MUT_DESC[$i]}"
  old="${MUT_OLD[$i]}" new="${MUT_NEW[$i]}"
  work="$(mktemp -d)"
  cp -R "$ROOT"/. "$work"/
  target="$work/$lib_rel"
  before="$(cat "$target")"
  MUT_OLD_TXT="$old" MUT_NEW_TXT="$new" perl -i -pe \
    'BEGIN { $o = $ENV{MUT_OLD_TXT}; $n = $ENV{MUT_NEW_TXT}; } s/\Q$o\E/$n/g;' \
    "$target"
  after="$(cat "$target")"

  if [ "$before" = "$after" ]; then
    skipped=$((skipped + 1))
    printf '  ?  SKIP (pattern not found — mutant text drifted from source)  %s\n' "$desc"
  elif bash "$work/$test_rel" >/tmp/mutant-out.$$ 2>&1; then
    survived=$((survived + 1))
    printf '  ✘ SURVIVED  %s\n' "$desc"
  else
    killed=$((killed + 1))
    printf '  ✔ killed    %s\n' "$desc"
  fi
  rm -f /tmp/mutant-out.$$
  rm -rf "$work"
done

printf '\n%d killed, %d survived, %d skipped (of %d mutants)\n' \
  "$killed" "$survived" "$skipped" "${#MUT_LIB[@]}"
[ "$survived" -eq 0 ] && [ "$skipped" -eq 0 ]
