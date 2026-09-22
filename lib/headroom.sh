#!/usr/bin/env bash
# headroom.sh — install/update headroom, wire its on-demand MCP server into
# Claude Code, run its persistent proxy on its own port. Headroom is not
# agent-facing: caveman (:8787) is the only proxy either agent's base URL
# points at, chained to headroom (:8788) as the final hop before the real
# provider — see caveman.sh's compat-mount setup. This used to also own
# Codex's OPENAI_BASE_URL directly; that shadowed caveman's native Codex
# integration entirely (Codex traffic never touched caveman), so it's gone —
# headroom_rc_has_leaked_base_url()/headroom_fix_rc_file() below clean up the
# stale env block a past run of this script left in shell rc files.
#
# Pure decision functions (headroom_*) take plain text and return a verdict;
# they do no I/O and are what test/test_headroom.sh exercises directly.
# The install_headroom()/headroom_ensure_proxy() functions below them are the
# thin, side-effecting orchestration layer built on top.

# headroom_profile_exists STATUS_TEXT — 0 if `install status` returned a real
# profile block, 1 if it returned the "no such profile" error.
headroom_profile_exists() {
  case "$1" in
    *"No deployment profile named"*) return 1 ;;
    *"Profile:"*)                    return 0 ;;
    *)                                return 1 ;;
  esac
}

# headroom_profile_port STATUS_TEXT — echoes the profile's configured port,
# or nothing if the profile doesn't exist / text is malformed.
headroom_profile_port() {
  headroom_profile_exists "$1" || return 0
  printf '%s\n' "$1" | tr -d '\r' | awk -F': *' '/^Port:/{print $2; exit}'
}

# headroom_is_healthy STATUS_TEXT — 0 if the profile is running AND healthy.
# Anchored to the whole field value (not `.*running`) so a line like
# "Status:     stopped (was running before)" can't false-match on the
# trailing word.
headroom_is_healthy() {
  printf '%s\n' "$1" | grep -qE '^Status:[[:space:]]+running[[:space:]]*$' || return 1
  printf '%s\n' "$1" | grep -qiE '^Healthy:[[:space:]]+yes[[:space:]]*$'
}

# headroom_profile_running STATUS_TEXT — 0 if the profile exists and its
# Status field is "running", regardless of Healthy. Used by the kill path:
# a wedged-but-alive (running, unhealthy) process still needs stopping.
headroom_profile_running() {
  headroom_profile_exists "$1" || return 1
  printf '%s\n' "$1" | grep -qE '^Status:[[:space:]]+running[[:space:]]*$'
}

# headroom_deployment_action STATUS_TEXT DESIRED_PORT — decides what the
# proxy needs: reapply (missing profile, or port doesn't match — apply alone
# does not rewrite an existing profile's stored port, so it must be removed
# and recreated), start (right port, not yet healthy), or healthy (nothing
# to do).
headroom_deployment_action() {
  local status_text="$1" desired_port="$2"
  if ! headroom_profile_exists "$status_text"; then
    echo "reapply"; return
  fi
  if [ "$(headroom_profile_port "$status_text")" != "$desired_port" ]; then
    echo "reapply"; return
  fi
  if headroom_is_healthy "$status_text"; then
    echo "healthy"
  else
    echo "start"
  fi
}

# headroom_rc_has_leaked_base_url RC_TEXT — 0 if a stale "headroom persistent
# env" block (written by the retired `headroom init codex` routing step)
# still exports ANTHROPIC_BASE_URL or OPENAI_BASE_URL. Either one, left in a
# shell rc file, points an agent straight at headroom and skips caveman
# entirely — caveman is now the only proxy either agent's base URL should
# name.
headroom_rc_has_leaked_base_url() {
  awk '
    /^# >>> headroom persistent env >>>/ { inblock=1 }
    /^# <<< headroom persistent env <<</ { inblock=0 }
    inblock && /^export (ANTHROPIC|OPENAI)_BASE_URL=/ { found=1 }
    END { exit !found }
  ' <<<"$1"
}

# headroom_mcp_registered MCP_LIST_TEXT — 0 if `claude mcp list` already
# shows a headroom entry.
headroom_mcp_registered() {
  printf '%s' "$1" | grep -qi 'headroom'
}

install_headroom() {
  if ! have headroom; then
    if have uv; then run uv tool install --python 3.13 "headroom-ai[all]"
    elif have pipx; then run pipx install "headroom-ai[all]"
    else run pip3 install --user "headroom-ai[all]"
    fi
  else
    ok "installed ($(headroom --version 2>/dev/null))"
  fi
}

# headroom_fix_rc_file RC_PATH — strips leaked ANTHROPIC_BASE_URL /
# OPENAI_BASE_URL lines from headroom's block in RC_PATH, in place, leaving
# everything else in the block (and the file) untouched. No-op if the file
# doesn't exist or doesn't have the leak.
headroom_fix_rc_file() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  headroom_rc_has_leaked_base_url "$(cat "$rc")" || return 0
  local tmp
  tmp="$(mktemp)"
  awk '
    /^# >>> headroom persistent env >>>/ { inblock=1 }
    /^# <<< headroom persistent env <<</ { inblock=0 }
    inblock && /^export (ANTHROPIC|OPENAI)_BASE_URL=/ { next }
    { print }
  ' "$rc" > "$tmp" && mv "$tmp" "$rc"
  warn "removed shell-wide agent routing that pointed straight at headroom in $rc (caveman is the only proxy either agent's base URL should name)"
}

# headroom_fix_codex_config CONFIG_PATH — strips the retired "Headroom init
# provider" block (root openai_base_url + model_providers.headroom) from
# Codex's config.toml. Inert now that caveman owns Codex routing —
# model_provider = "caveman" always wins — but stale unused config is still
# worth cleaning up.
headroom_fix_codex_config() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  grep -q '^# --- Headroom init provider ---$' "$cfg" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp)"
  awk '
    /^# --- Headroom init provider ---$/ { inblock=1; next }
    /^# --- end Headroom init provider ---$/ { inblock=0; next }
    inblock { next }
    { print }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  warn "removed the retired Headroom Codex provider block from $cfg (caveman owns Codex routing)"
}

headroom_ensure_claude_mcp() {
  local mcp_text
  mcp_text="$(claude mcp list 2>/dev/null)"
  if headroom_mcp_registered "$mcp_text"; then
    skip "MCP already registered with Claude Code"
  elif run headroom mcp install --agent claude; then
    ok "MCP registered with Claude Code"
  else
    warn "MCP registration failed"
  fi
}

# headroom_ensure_proxy PORT — profile named "default", runtime=python
# (persistent-docker was tried and never reports healthy in this
# environment — see plans/agent-tools-sync notes; python runtime works).
headroom_ensure_proxy() {
  local port="$1" status
  status="$(headroom install status --profile default 2>&1)"
  case "$(headroom_deployment_action "$status" "$port")" in
    reapply)
      run headroom install remove --profile default >/dev/null 2>&1
      if run headroom install apply --profile default --port "$port" \
             --scope user --preset persistent-service --runtime python \
        && run headroom install start --profile default; then
        ok "proxy installed and started on :$port"
      else
        warn "proxy install failed — check 'headroom install status --profile default'"
      fi
      ;;
    start)
      if run headroom install start --profile default; then
        ok "proxy started on :$port"
      else
        warn "proxy failed to start"
      fi
      ;;
    healthy)
      ok "proxy already running on :$port"
      ;;
  esac
}

# headroom_stop_proxy — stops the persistent deployment if it's running.
# No-op (skip) if headroom isn't installed or the profile isn't running.
headroom_stop_proxy() {
  have headroom || { skip "headroom not installed"; return; }
  local status
  status="$(headroom install status --profile default 2>&1)"
  if headroom_profile_running "$status"; then
    if run headroom install stop --profile default; then
      ok "proxy stopped"
    else
      warn "proxy stop failed — check 'headroom install status --profile default'"
    fi
  else
    skip "proxy not running"
  fi
}

setup_headroom() {
  section "headroom"
  install_headroom
  have headroom || { warn "headroom not on PATH after install — skipping rest"; return; }

  # Bounded: this hits the network, and headroom has been observed to hang
  # here for 5+ minutes with nothing but Ctrl-C to escape.
  if run with_timeout 30 headroom update >/dev/null 2>&1; then
    ok "checked for updates"
  else
    warn "update check failed or timed out"
  fi
  headroom_fix_rc_file "$HOME/.zshrc"
  headroom_fix_rc_file "$HOME/.bashrc"
  headroom_fix_codex_config "$HOME/.codex/config.toml"
  headroom_ensure_claude_mcp
  headroom_ensure_proxy "$HEADROOM_PORT"
}
