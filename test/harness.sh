#!/usr/bin/env bash
# harness.sh — minimal dependency-free assertion helpers (no bats/shunit2:
# the whole toolkit, tests included, must copy to another machine and just
# work). Sourced by every test_*.sh and by run_tests.sh.

TESTS_RUN=0
TESTS_FAILED=0

# check DESC CMD [ARGS...] — expects CMD to exit 0 (a "success case" test).
check() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/tmp/agent-tools-sync-test-out.$$ 2>&1; then
    :
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL (expected success): %s\n' "$desc" >&2
    sed 's/^/      /' /tmp/agent-tools-sync-test-out.$$ >&2
  fi
  rm -f /tmp/agent-tools-sync-test-out.$$
}

# check_fail DESC CMD [ARGS...] — expects CMD to exit nonzero (a "failure
# case" / false-positive-rejection test).
check_fail() {
  local desc="$1"; shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@" >/dev/null 2>&1; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL (expected failure, got success): %s\n' "$desc" >&2
  fi
}

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$expected" != "$actual" ]; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf 'FAIL: %s\n      expected: %q\n      actual:   %q\n' "$desc" "$expected" "$actual" >&2
  fi
}

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  case "$haystack" in
    *"$needle"*) ;;
    *)
      TESTS_FAILED=$((TESTS_FAILED + 1))
      printf 'FAIL: %s\n      expected to find: %q\n' "$desc" "$needle" >&2
      ;;
  esac
}

report() {
  printf '\n%d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
