#!/usr/bin/env bash
# agent-tools-sync — install / update / wire up the local agent-efficiency
# toolkit (headroom, rtk, caveman, ponytail) for both Claude Code and Codex.
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
# shellcheck source=lib/headroom.sh
source "$SCRIPT_DIR/lib/headroom.sh"
# shellcheck source=lib/rtk.sh
source "$SCRIPT_DIR/lib/rtk.sh"
# shellcheck source=lib/caveman.sh
source "$SCRIPT_DIR/lib/caveman.sh"
# shellcheck source=lib/ponytail.sh
source "$SCRIPT_DIR/lib/ponytail.sh"

# caveman owns :8787 as the only proxy either agent's base URL points at.
# headroom gets its own port and sits downstream of caveman in the chain
# (agent -> caveman -> headroom -> provider) — see lib/caveman.sh.
HEADROOM_PORT="${HEADROOM_PORT:-8788}"

# cmd_kill — stops both persistent background proxies (caveman :8787,
# headroom :$HEADROOM_PORT) and confirms neither port is still listening.
cmd_kill() {
  section "kill"
  caveman_stop_proxy
  headroom_stop_proxy

  sleep 1  # give the sockets a moment to actually release
  local alive=0
  port_listening 8787 && { warn "port 8787 still listening"; alive=1; }
  port_listening "$HEADROOM_PORT" && { warn "port $HEADROOM_PORT still listening"; alive=1; }
  [ "$alive" -eq 0 ] && ok "no agent-tools servers listening on 8787 or $HEADROOM_PORT"
}

# cmd_start — brings both proxies back up without the full rtk/caveman-agent
# /ponytail sync. The counterpart to cmd_kill.
cmd_start() {
  section "start"
  caveman_start_proxy
  headroom_ensure_proxy "$HEADROOM_PORT"
}

main() {
  case "${1:-}" in
    kill) cmd_kill; return ;;
    start) cmd_start; return ;;
    "") ;;
    *) echo "usage: agent-tools-sync [kill|start]" >&2; return 1 ;;
  esac

  setup_headroom
  setup_rtk
  setup_caveman
  setup_ponytail
  section "done"
  echo "  caveman  → both agents' base URL, proxy on :8787, chains to headroom"
  echo "  headroom → downstream compression hop on :$HEADROOM_PORT, on-demand MCP in Claude Code"
  echo "  rtk      → shell-output hook in both Claude Code and Codex"
  echo "  ponytail → plugin in both Claude Code and Codex"
  echo "  Just run 'claude' or 'codex' as usual — nothing else to launch."
}

main "$@"
