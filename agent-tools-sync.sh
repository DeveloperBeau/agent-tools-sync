#!/usr/bin/env bash
# agent-tools-sync — install / update / wire up the local agent-efficiency
# toolkit (headroom, rtk, caveman, ponytail, optional Ship) for both agents.
#
# Safe to re-run any time: every step checks current state first and only
# acts when something is actually missing or out of date.
#
# Portable: this whole directory is meant to be copied to another machine
# as-is. Symlink (or copy) THIS file onto PATH, e.g.:
#   ln -s /path/to/agent-tools-sync/agent-tools-sync.sh ~/.local/bin/agent-tools-sync
# lib/*.sh is found relative to this file's real location, not $PWD.

set -uo pipefail

# Portable symlink resolution (no reliance on GNU `readlink -f`, which BSD/
# macOS readlink doesn't support) — walk the link chain by hand.
_src="${BASH_SOURCE[0]}"
while [ -h "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
if [ "${1:-}" != kill ] && [ "${1:-}" != start ] && [ "${1:-}" != watchdog ]; then
  if ats_check_update "$SCRIPT_DIR"; then
    :
  elif [ "$?" -eq 2 ]; then
    exec "$SCRIPT_DIR/agent-tools-sync.sh" "$@"
  fi
fi
# shellcheck source=lib/headroom.sh
source "$SCRIPT_DIR/lib/headroom.sh"
# shellcheck source=lib/rtk.sh
source "$SCRIPT_DIR/lib/rtk.sh"
# shellcheck source=lib/xcsift.sh
source "$SCRIPT_DIR/lib/xcsift.sh"
# shellcheck source=lib/search-tools.sh
source "$SCRIPT_DIR/lib/search-tools.sh"
# shellcheck source=lib/grepai.sh
source "$SCRIPT_DIR/lib/grepai.sh"
# shellcheck source=lib/caveman.sh
source "$SCRIPT_DIR/lib/caveman.sh"
# shellcheck source=lib/ponytail.sh
source "$SCRIPT_DIR/lib/ponytail.sh"
# shellcheck source=lib/evolver.sh
source "$SCRIPT_DIR/lib/evolver.sh"
# shellcheck source=lib/claude-mem.sh
source "$SCRIPT_DIR/lib/claude-mem.sh"
# shellcheck source=lib/ship.sh
source "$SCRIPT_DIR/lib/ship.sh"
# shellcheck source=lib/skillopt.sh
source "$SCRIPT_DIR/lib/skillopt.sh"
# shellcheck source=lib/mcp.sh
source "$SCRIPT_DIR/lib/mcp.sh"
# shellcheck source=lib/context7.sh
source "$SCRIPT_DIR/lib/context7.sh"
# shellcheck source=lib/serena.sh
source "$SCRIPT_DIR/lib/serena.sh"
# shellcheck source=lib/obsidian.sh
source "$SCRIPT_DIR/lib/obsidian.sh"

# caveman owns :8787 as the only proxy either agent's base URL points at.
# headroom gets its own port and sits downstream of caveman in the chain
# (agent -> caveman -> headroom -> provider) — see lib/caveman.sh.
HEADROOM_PORT="${HEADROOM_PORT:-8788}"

# cmd_kill — stops all persistent background servers (caveman :8787,
# headroom :$HEADROOM_PORT, claude-mem's worker daemon) and confirms neither
# fixed-port proxy is still listening.
cmd_kill() {
  section "kill"
  proxy_suspend || return 1
  proxy_control_run cmd_kill_services
}

cmd_kill_services() {
  local failed=0
  caveman_stop_proxy || failed=1
  headroom_stop_proxy || failed=1
  claude_mem_stop_worker || failed=1

  sleep 1  # give the sockets a moment to actually release
  local alive=0 port
  for port in 8787 "$HEADROOM_PORT"; do
    if port_listening "$port"; then
      warn "port $port still listening"; alive=1
    elif [ "$?" != 1 ]; then
      warn "cannot inspect port $port"; alive=1
    fi
  done
  if [ "$alive" -eq 0 ]; then ok "no agent-tools servers listening on 8787 or $HEADROOM_PORT"; fi
  [ "$alive" -eq 0 ] && [ "$failed" -eq 0 ]
}

# cmd_start — brings all background servers back up without the full
# rtk/caveman-agent/ponytail sync. The counterpart to cmd_kill.
cmd_start() {
  section "start"
  bash "$SCRIPT_DIR/proxy-chain.sh" start || return 1
  claude_mem_start_worker
}

# stop_unused_proxies — stops each proxy that the current mode does not use.
stop_unused_proxies() {
  local failed=0
  ats_uses headroom || headroom_stop_proxy || failed=1
  ats_uses caveman || caveman_stop_proxy || failed=1
  [ "$failed" -eq 0 ]
}

usage() {
  echo "usage: agent-tools-sync [--no-headroom] [--no-caveman] | kill | start | watchdog capture|fire" >&2
  return 1
}

main() {
  case "${1:-}" in
    kill) cmd_kill; return ;;
    start) cmd_start; return ;;
    watchdog)
      case "${2:-}" in
        capture|fire) [ "$#" -eq 2 ] || return 1; python3 "$SCRIPT_DIR/lib/proxy_watchdog.py" "$2"; return ;;
        *) echo "usage: ats watchdog [capture|fire]" >&2; return 1 ;;
      esac ;;
  esac

  local no_headroom=false no_caveman=false mode=full arg
  for arg in "$@"; do
    case "$arg" in
      --no-headroom) no_headroom=true ;;
      --no-caveman) no_caveman=true ;;
      *) usage; return ;;
    esac
  done
  case "$no_headroom:$no_caveman" in
    true:true) mode=direct ;;
    true:false) mode=no-headroom ;;
    false:true) mode=no-caveman ;;
  esac

  proxy_resume || return 1
  ats_set_mode "$mode" || return 1
  ats_uses headroom && setup_headroom
  setup_rtk
  setup_xcsift
  setup_search_tools
  setup_grepai
  if ats_uses caveman; then
    setup_caveman
  elif ! python3 "$CAVEMAN_PROXY_INSTALLER" >/dev/null; then
    # The wrapper update makes Caveman's native hooks honor the mode.
    warn "Caveman wrapper refresh failed; its hooks may restart the proxy"
  fi
  setup_ponytail
  setup_evolver
  setup_claude_mem
  setup_ship
  setup_skillopt
  setup_context7
  setup_serena
  setup_obsidian
  section "proxy mode: $mode"
  caveman_route_agents "$mode" || warn "agent routing incomplete; check the messages above"
  proxy_control_run stop_unused_proxies || return 1
  bash "$SCRIPT_DIR/proxy-chain.sh" start || return 1
  section "done"
  case "$mode" in
    full)
      echo "  caveman    → both agents' base URL, proxy on :8787, chains to headroom"
      echo "  headroom   → downstream compression hop on :$HEADROOM_PORT, on-demand MCP in Claude Code" ;;
    no-headroom) echo "  caveman    → both agents' base URL on :8787, native routes; headroom stopped" ;;
    no-caveman) echo "  headroom   → both agents' base URL on :$HEADROOM_PORT; caveman proxy stopped" ;;
    direct) echo "  proxies    → none; both agents call their provider directly" ;;
  esac
  [ "$mode" = full ] || echo "  Run plain 'ats' to restore the full caveman → headroom chain."
  echo "  rtk        → shell-output hook in both Claude Code and Codex"
  echo "  xcsift     → compact xcodebuild/swift build output in Claude Code"
  echo "  search     → ripgrep, fd, sd and ast-grep for fast code search and rewriting"
  echo "  grepai     → semantic code search MCP in Claude Code, local Ollama embeddings"
  echo "  ponytail   → plugin in both Claude Code and Codex"
  echo "  evolver    → session hooks in both Claude Code and Codex"
  echo "  claude-mem → cross-session memory plugin in both, worker daemon on its own port"
  echo "  ship       → optional private plugin in both agents"
  echo "  skillopt   → skill optimization CLI, Claude plugin, and Codex skill"
  echo "  context7   → remote documentation MCP for installed agents"
  echo "  serena     → project code navigation MCP for installed agents"
  if obsidian_enabled; then
    echo "  plans      → shared Obsidian vault, automatic Claude and Codex plan capture"
  fi
  echo "  Run 'claude' or 'codex' as usual. Restart open sessions after a mode change."
}

main "$@"
