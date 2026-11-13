#!/usr/bin/env bash
# caveman.sh — install/update caveman, enable its native Claude Code and
# Codex integrations (proxy + MCP + hooks, all managed by `caveman enable`),
# then point both agents at caveman's native routes:
# agent -> caveman (:8787) -> real provider. Remote Control needs
# api.anthropic.com, so it works only in the --no-wrap (direct) mode.

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

CAVEMAN_CONFIG_FILE="$HOME/.caveman/caveman.yaml"
CAVEMAN_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CAVEMAN_CODEX_CONFIG="$HOME/.codex/config.toml"
CAVEMAN_CODEX_HOOKS="$HOME/.codex/hooks.json"
CAVEMAN_MANAGED_PROXY_BIN="$HOME/.caveman/bin/caveman-proxy"
CAVEMAN_PROXY_LOG="$HOME/.caveman/proxy.log"
CAVEMAN_PROXY_BIN="${CAVEMAN_PROXY_BIN:-$CAVEMAN_MANAGED_PROXY_BIN}"
export CAVEMAN_PROXY_BIN


install_caveman() {
  # --allow-scripts=pnpm: scoped to this command only (not written to global
  # npm config) so @caveman-ai/cli's pnpm dependency can run its own
  # postinstall. A persistent global allow-scripts entry instead breaks
  # unrelated project-scoped npm installs elsewhere — see claude-mem's
  # Codex plugin install, which hit exactly that.
  if ! have caveman; then
    run npm install -g @caveman-ai/cli --allow-scripts=pnpm
  else
    ok "installed ($(caveman_version_string "$(caveman --version 2>/dev/null)"))"
    run npm update -g @caveman-ai/cli --allow-scripts=pnpm >/dev/null
  fi
}

caveman_ensure_agent() {
  local status_text="$1" agent="$2" label="$3"
  if caveman_agent_installed "$status_text" "$agent"; then
    skip "$label integration already installed"
    return
  fi
  if run caveman enable "$agent"; then
    ok "$label integration installed"
  else
    warn "$label integration failed"
  fi
}

# caveman_start_proxy — starts caveman-proxy directly if it isn't already
# running. Caveman has no CLI verb for this either (it normally lazy-starts
# on the next `claude`/`codex` session); ats start needs it back now.
caveman_start_proxy() {
  local pids status
  pids="$(listener_pids 8787)"; status=$?
  [ "$status" -ne 2 ] || { warn "cannot inspect port 8787"; return 1; }
  if [ -n "$pids" ]; then
    if caveman_listener_owned; then
      ok "proxy already listening on :8787"
      return 0
    fi
    warn "port 8787 belongs to another process; preserved"
    return 1
  fi
  if [ ! -x "$CAVEMAN_PROXY_BIN" ]; then
    warn "caveman-proxy binary not found at $CAVEMAN_PROXY_BIN"
    return 1
  fi
  mkdir -p "$(dirname "$CAVEMAN_PROXY_LOG")" || return 1
  (umask 077; touch "$CAVEMAN_PROXY_LOG") || return 1
  chmod 600 "$CAVEMAN_PROXY_LOG" || return 1
  nohup "$CAVEMAN_PROXY_BIN" >>"$CAVEMAN_PROXY_LOG" 2>&1 &
  local attempt
  for attempt in {1..10}; do
    if caveman_listener_owned; then
      ok "proxy listening on :8787"
      return 0
    fi
    sleep 1
  done
  warn "proxy failed to listen on :8787; see $CAVEMAN_PROXY_LOG"
  return 1
}

caveman_pid_owned() {
  local command
  command="$(ps -p "$1" -o comm= 2>/dev/null)" || return 1
  case "${command##*/}" in caveman-proxy|caveman-proxy.bin) return 0 ;; *) return 1 ;; esac
}

caveman_listener_owned() {
  local pids pid
  pids="$(listener_pids 8787)" || return 1
  [ -n "$pids" ] || return 1
  for pid in $pids; do
    caveman_pid_owned "$pid" || return 1
  done
}

# Stop only identified listeners; hook processes and other ports are separate.
caveman_stop_proxy() {
  local pids pid attempt alive status
  pids="$(listener_pids 8787)"; status=$?
  [ "$status" -ne 2 ] || { warn "cannot inspect port 8787; no process signaled"; return 1; }
  if [ -z "$pids" ]; then
    skip "proxy not running"
    return 0
  fi
  for pid in $pids; do
    caveman_pid_owned "$pid" || { warn "port 8787 belongs to another process; preserved"; return 1; }
  done
  for pid in $pids; do
    caveman_pid_owned "$pid" && run kill -TERM "$pid"
  done
  for attempt in {1..6}; do
    alive=0
    for pid in $pids; do caveman_pid_owned "$pid" && alive=1; done
    [ "$alive" = 0 ] && { ok "proxy stopped"; return 0; }
    sleep 1
  done
  for pid in $pids; do caveman_pid_owned "$pid" && run kill -KILL "$pid"; done
  for attempt in {1..3}; do
    alive=0
    for pid in $pids; do caveman_pid_owned "$pid" && alive=1; done
    [ "$alive" = 0 ] && { ok "proxy stopped"; return 0; }
    sleep 1
  done
  warn "proxy stop failed: original listener still running"
  return 1
}

# caveman_route_url MODE claude|codex — the base URL that the agent uses in
# MODE. An empty result for Claude means no override, so it calls Anthropic.
# Caveman's /chatgpt route forwards to the ChatGPT Codex backend, so direct
# Codex uses that backend itself.
caveman_route_url() {
  case "$1:$2" in
    full:claude) echo "http://127.0.0.1:8787/w/claude" ;;
    full:codex) echo "http://127.0.0.1:8787/chatgpt" ;;
    direct:claude) echo "" ;;
    direct:codex) echo "https://chatgpt.com/backend-api/codex" ;;
    *) return 1 ;;
  esac
}

# caveman_route_agents MODE — points Claude Code and Codex at the first hop of
# MODE. Only ATS-managed URLs change; a custom base URL stays. Running agents
# keep their old route until they restart.
caveman_route_agents() {
  local mode="$1" claude_url codex_url
  claude_url="$(caveman_route_url "$mode" claude)" || return 1
  codex_url="$(caveman_route_url "$mode" codex)" || return 1
  python3 - "$CAVEMAN_CLAUDE_SETTINGS" "$CAVEMAN_CODEX_CONFIG" "$claude_url" "$codex_url" <<'PY'
import json, re, sys
from pathlib import Path
claude, codex, claude_url, codex_url = sys.argv[1:]
# The compat/headroom and :8788 URLs are older ATS routes; they migrate here.
managed = {"http://127.0.0.1:8787/compat/headroom", "http://127.0.0.1:8787/w/claude",
           "http://127.0.0.1:8787/chatgpt", "http://127.0.0.1:8788",
           "https://chatgpt.com/backend-api/codex"}
status = 0
path = Path(claude)
if path.exists():
    data = json.loads(path.read_text())
    env = data.setdefault("env", {})
    current = env.get("ANTHROPIC_BASE_URL")
    if current is not None and current not in managed:
        print(f"  ! Claude Code base URL {current} is custom; preserved")
        status = 1
    elif current != (claude_url or None):
        if claude_url:
            env["ANTHROPIC_BASE_URL"] = claude_url
            # Caveman sets this flag with its route so Claude keeps first-party features.
            env.setdefault("_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL", "1")
        else:
            env.pop("ANTHROPIC_BASE_URL", None)
            # Caveman wrote this flag with the route; it means nothing alone.
            if env.get("_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL") == "1":
                env.pop("_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL")
        path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        print(f"  ✔ Claude Code now routes to {claude_url or 'Anthropic directly'}")
path = Path(codex)
if path.exists():
    text, table, lines = path.read_text(), None, []
    for line in text.splitlines(keepends=True):
        header = re.match(r"\s*\[([^\]]+)\]", line)
        if header:
            table = header.group(1).strip()
        value = re.match(r'base_url = "([^"]*)"', line)
        if table in ("model_providers.caveman", "model_providers.headroom") and value and value.group(1) in managed:
            line = f'base_url = "{codex_url}"\n'
        lines.append(line)
    if "".join(lines) != text:
        path.write_text("".join(lines))
        print(f"  ✔ Codex now routes to {codex_url}")
sys.exit(status)
PY
}

setup_caveman() {
  section "caveman"
  local previous_version="" current_version
  have caveman && previous_version="$(caveman --version 2>/dev/null)"
  install_caveman
  have caveman || { warn "caveman not on PATH after install — skipping rest"; return; }
  current_version="$(caveman --version 2>/dev/null)"
  if [ -n "$previous_version" ] && [ -n "$current_version" ] &&
     [ "$previous_version" != "$current_version" ] && port_listening 8787; then
    caveman_stop_proxy && caveman_start_proxy || return 1
  fi

  local status_text
  status_text="$(caveman status 2>/dev/null)"
  have claude && caveman_ensure_agent "$status_text" claude "Claude Code"
  have codex && caveman_ensure_agent "$status_text" codex "Codex"

  if caveman_listener_owned; then
    ok "proxy already running on :8787"
  else
    skip "proxy startup checked at end of ATS sync"
  fi
}
