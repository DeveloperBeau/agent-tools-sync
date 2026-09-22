#!/usr/bin/env bash
# run_tests.sh — runs every test_*.sh in its own subshell (so one file's
# TESTS_RUN/TESTS_FAILED counters can't leak into another) and aggregates
# pass/fail across the whole suite. Exit 0 iff everything passed.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

total_run=0 total_failed=0 any_suite_failed=0

for f in "$HERE"/test_*.sh; do
  name="$(basename "$f")"
  out="$(bash "$f" 2>&1)"
  status=$?
  run_count="$(printf '%s\n' "$out" | grep -oE '^[0-9]+ run' | grep -oE '^[0-9]+')"
  failed_count="$(printf '%s\n' "$out" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+')"
  run_count="${run_count:-0}"
  failed_count="${failed_count:-0}"
  total_run=$((total_run + run_count))
  total_failed=$((total_failed + failed_count))
  if [ "$status" -eq 0 ]; then
    printf '✔ %-24s %s tests\n' "$name" "$run_count"
  else
    any_suite_failed=1
    printf '✘ %-24s %s/%s failed\n' "$name" "$failed_count" "$run_count"
    printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/    /'
  fi
done

printf '\n%d total, %d failed\n' "$total_run" "$total_failed"
exit "$any_suite_failed"
