#!/usr/bin/env bash
# common.sh — shared helpers. Sourced by every other lib/*.sh and by the
# orchestrator. No side effects at source time.

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_red=$'\033[31m'; c_blue=$'\033[34m'
ATS_VERSION=1.5.0

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

# already_added_error TEXT — 0 if TEXT looks like a "marketplace already
# exists" error rather than a real failure. Shared by every plugin-based
# install (ponytail, claude-mem) that adds a marketplace before installing.
already_added_error() {
  printf '%s' "$1" | grep -qi 'already added'
}

# Refresh this checkout before loading integrations. Return 2 after an update
# so the caller can restart with the newly fetched script and libraries.
ats_check_update() {
  local dir="$1" root upstream remote branch behind
  section "ats v$ATS_VERSION"
  have git || return 0
  dir="$(cd -P "$dir" && pwd)" || return 0
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ "$root" = "$dir" ] || return 0
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" || return 0
  remote="${upstream%%/*}"
  branch="${upstream#*/}"
  if ! with_timeout 15 env GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch --quiet "$remote" "$branch"; then
    warn "update check failed; continuing with local version"
    return 0
  fi
  behind="$(git -C "$dir" rev-list --count "HEAD..$upstream")" || return 0
  if [ "$behind" -eq 0 ]; then
    ok "already up to date"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$upstream"; then
    warn "local branch diverged; update manually"
    return 0
  fi
  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    warn "update available; commit local changes before updating"
    return 0
  fi
  if git -C "$dir" merge --ff-only --quiet "$upstream"; then
    ok "updated from $upstream"
    return 2
  fi
  warn "update failed; continuing with local version"
  return 0
}
