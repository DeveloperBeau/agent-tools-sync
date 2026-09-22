#!/usr/bin/env bash
# caveman.sh — install/update caveman, enable its native Claude Code and
# Codex integrations (proxy + MCP + hooks, all managed by `caveman enable`).

# caveman_agent_state STATUS_TEXT AGENT — echoes the word `caveman status`
# reports for AGENT's "native integrations" row (e.g. "installed",
# "available", "unavailable"), or nothing if AGENT isn't a row in the text
# at all. Exact first-field match, so "codex-app installed" can't be
# mistaken for the "codex" row, and free text mentioning the agent name
# elsewhere in the output can't produce a false positive either.
caveman_agent_state() {
  local status_text="$1" agent="$2"
  awk -v a="$agent" '$1==a{print $2; exit}' <<<"$status_text"
}

# caveman_agent_installed STATUS_TEXT AGENT — 0 only on an exact "installed".
caveman_agent_installed() {
  [ "$(caveman_agent_state "$1" "$2")" = "installed" ]
}

# caveman_version_string VERSION_JSON — pulls "version" out of
# `caveman --version`'s JSON without requiring a JSON parser on PATH.
caveman_version_string() {
  printf '%s' "$1" | grep -o '"version": *"[^"]*"' | cut -d'"' -f4
}

install_caveman() {
  if ! have caveman; then
    run npm install -g @caveman-ai/cli
  else
    ok "installed ($(caveman_version_string "$(caveman --version 2>/dev/null)"))"
    run npm update -g @caveman-ai/cli >/dev/null
  fi
}

caveman_ensure_agent() {
  local status_text="$1" agent="$2" label="$3"
  if caveman_agent_installed "$status_text" "$agent"; then
    skip "$label integration already installed"
  elif run caveman enable "$agent"; then
    ok "$label integration installed"
  else
    warn "$label integration failed"
  fi
}

# caveman_start_proxy — starts caveman-proxy directly if it isn't already
# running. Caveman has no CLI verb for this either (it normally lazy-starts
# on the next `claude`/`codex` session); ats start needs it back now.
CAVEMAN_PROXY_BIN="$HOME/.caveman/bin/caveman-proxy"
caveman_start_proxy() {
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy already running on :8787"
    return
  fi
  if [ ! -x "$CAVEMAN_PROXY_BIN" ]; then
    skip "caveman-proxy binary not found at $CAVEMAN_PROXY_BIN — it will self-start on the next claude/codex session"
    return
  fi
  nohup "$CAVEMAN_PROXY_BIN" >/dev/null 2>&1 &
  sleep 1
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy started on :8787"
  else
    warn "proxy failed to start — try $CAVEMAN_PROXY_BIN directly"
  fi
}

# caveman_stop_proxy — kills the caveman-proxy process if one is running.
# No CLI subcommand owns this (caveman itself has no `stop`/`disable` verb
# for the proxy), so this matches setup_caveman's own pgrep pattern above.
caveman_stop_proxy() {
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    if run pkill -f caveman-proxy; then
      ok "proxy stopped"
    else
      warn "proxy stop failed"
    fi
  else
    skip "proxy not running"
  fi
}

setup_caveman() {
  section "caveman"
  install_caveman
  have caveman || { warn "caveman not on PATH after install — skipping rest"; return; }

  local status_text
  status_text="$(caveman status 2>/dev/null)"
  caveman_ensure_agent "$status_text" claude "Claude Code"
  caveman_ensure_agent "$status_text" codex "Codex"

  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy already running on :8787"
  else
    skip "proxy not running — it starts itself on the next Claude Code / Codex session"
  fi
}
