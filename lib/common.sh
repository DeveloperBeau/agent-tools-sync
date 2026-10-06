#!/usr/bin/env bash
# common.sh — shared helpers. Sourced by every other lib/*.sh and by the
# orchestrator. No side effects at source time.

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_red=$'\033[31m'; c_blue=$'\033[34m'
ATS_VERSION=1.10.0

section() { printf '\n%s== %s ==%s\n' "$c_bold$c_blue" "$1" "$c_reset"; }
ok()      { printf '  %s✔%s %s\n' "$c_green" "$c_reset" "$1"; }
skip()    { printf '  %s·%s %s\n' "$c_yellow" "$c_reset" "$1"; }
warn()    { printf '  %s!%s %s\n' "$c_red" "$c_reset" "$1"; }
run()     { printf '  %s→%s %s\n' "$c_blue" "$c_reset" "$*"; "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

# brew_ensure COMMAND FORMULA — install FORMULA when COMMAND is missing,
# upgrade it when brew reports it outdated, else skip. Failures warn and
# return 1 so the caller can continue.
brew_ensure() {
  local command_name="$1" formula="$2"
  if ! have "$command_name"; then
    run brew install "$formula" || { warn "$formula install failed"; return 1; }
  elif [ -n "$(brew outdated "$formula" 2>/dev/null)" ]; then
    run brew upgrade "$formula" || { warn "$formula upgrade failed"; return 1; }
  else
    skip "$formula already up to date"
  fi
}

# with_timeout SECONDS CMD... — runs CMD bounded by `timeout`/`gtimeout` when
# either is on PATH. Falls back to running unbounded on a machine without
# coreutils (this repo is meant to be portable). Use for any network call
# (update checks, install status probes) that could otherwise hang a whole
# run with only Ctrl-C to escape. --foreground keeps CMD in the terminal's
# process group; without it a TTY-touching CLI (claude) is stopped by
# SIGTTOU/SIGTTIN and hangs until the timeout kills it.
with_timeout() {
  local secs="$1"; shift
  if have timeout; then timeout --foreground "$secs" "$@"
  elif have gtimeout; then gtimeout --foreground "$secs" "$@"
  else "$@"
  fi
}

# listener_pids PORT — 0 with numeric PIDs, 1 if empty, 2 if inspection failed.
listener_pids() {
  local pids pid status
  have lsof || return 2
  pids="$(lsof -nP -tiTCP:"$1" -sTCP:LISTEN 2>&1)"; status=$?
  [ "$status" -le 1 ] || return 2
  [ -n "$pids" ] || { [ "$status" = 1 ] && return 1; return 2; }
  for pid in $pids; do
    case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  done
  [ "$status" = 0 ] || return 2
  printf '%s\n' "$pids"
}

port_listening() { listener_pids "$1" >/dev/null; }

proxy_stop_marker() { printf '%s/ats-stopped\n' "${CAVEMAN_HOME:-$HOME/.caveman}"; }
proxy_suspend() {
  local marker
  marker="$(proxy_stop_marker)"
  (umask 077; mkdir -p "$(dirname "$marker")" && touch "$marker")
}
proxy_resume() { rm -f "$(proxy_stop_marker)"; }

# The proxy mode persists between runs. It is full (both proxies) when the
# file is absent, else no-headroom, no-caveman or direct (no proxies).
ats_mode_file() { printf '%s/ats-mode\n' "${CAVEMAN_HOME:-$HOME/.caveman}"; }
ats_mode() {
  case "$(cat "$(ats_mode_file)" 2>/dev/null)" in
    no-headroom) echo no-headroom ;;
    no-caveman) echo no-caveman ;;
    direct) echo direct ;;
    *) echo full ;;
  esac
}
ats_set_mode() {
  local file
  file="$(ats_mode_file)"
  if [ "$1" = full ]; then rm -f "$file"; return; fi
  (umask 077; mkdir -p "$(dirname "$file")" && printf '%s\n' "$1" > "$file")
}
# ats_uses headroom|caveman — 0 if the current mode runs that proxy.
ats_uses() {
  case "$1:$(ats_mode)" in
    headroom:no-headroom|headroom:direct|caveman:no-caveman|caveman:direct) return 1 ;;
  esac
}

# flock belongs to the inherited open-file description. The shell retains it
# after Python exits, then closes it when this subshell returns.
proxy_control_run() (
  umask 077
  mkdir -p "$HOME/.headroom" || return 1
  exec 9>>"$HOME/.headroom/watchdog-state.control.lock" || return 1
  python3 -c 'import fcntl, signal; signal.alarm(180); fcntl.flock(9, fcntl.LOCK_EX)' || {
    warn "could not acquire watchdog control lock"
    return 1
  }
  # Keep the shell's saved descriptor open without passing it to service CLIs.
  "$@" 9>&-
)

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
