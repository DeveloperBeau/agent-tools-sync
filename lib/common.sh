#!/usr/bin/env bash
# common.sh — shared helpers. Sourced by every other lib/*.sh and by the
# orchestrator. No side effects at source time.

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_red=$'\033[31m'; c_blue=$'\033[34m'

section() { printf '\n%s== %s ==%s\n' "$c_bold$c_blue" "$1" "$c_reset"; }
ok()      { printf '  %s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
skip()    { printf '  %s·%s %s\n' "$c_yellow" "$c_reset" "$1"; }
warn()    { printf '  %s!%s %s\n' "$c_red" "$c_reset" "$1"; }
run()     { printf '  %s→%s %s\n' "$c_blue" "$c_reset" "$*"; "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

# with_timeout SECONDS CMD... — runs CMD bounded by `timeout`/`gtimeout` when
# either is on PATH. Falls back to running unbounded on a machine without
# coreutils (this repo is meant to be portable). Use for any network call
# (update checks, install status probes) that could otherwise hang a whole
# run with only Ctrl-C to escape.
with_timeout() {
  local secs="$1"; shift
  if have timeout; then timeout "$secs" "$@"
  elif have gtimeout; then gtimeout "$secs" "$@"
  else "$@"
  fi
}

# port_listening PORT — 0 if something is bound and listening on PORT.
# Isolated behind lsof so tests can stub the `lsof` binary on PATH.
port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}
