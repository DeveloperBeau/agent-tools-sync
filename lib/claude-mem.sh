#!/usr/bin/env bash
# claude-mem.sh — install/wire claude-mem (persistent cross-session memory,
# github.com/thedotmack/claude-mem) into both Claude Code and Codex, and
# manage its worker daemon alongside caveman/headroom's proxies.
#
# Claude Code uses the same marketplace-add + plugin-install pattern as
# ponytail.sh. Codex has no plugin marketplace support in claude-mem — it
# ships its own installer (`npx claude-mem install --ide codex-cli`) instead.
#
# The worker daemon (worker-service.cjs, Bun-managed) is a real background
# server like caveman-proxy/headroom, so cmd_kill/cmd_start in
# agent-tools-sync.sh manage it too. Its own `npx claude-mem start/stop/
# status` CLI is unreliable on a machine with a stale marketplace-path copy
# (a real, pre-existing claude-mem bug — `npx claude-mem doctor` reports
# "Marketplace runtime node_modules missing" even when the actual running
# daemon is healthy), so this manages the process directly instead, the same
# way caveman.sh does.

CLAUDE_MEM_REPO="thedotmack/claude-mem"
CLAUDE_MEM_WORKER_PATTERN="claude-mem.*worker-service"

# claude_mem_claude_installed PLUGIN_LIST_TEXT — 0 if `claude plugin list`
# already shows claude-mem@thedotmack.
claude_mem_claude_installed() {
  printf '%s' "$1" | grep -q 'claude-mem@thedotmack'
}

# claude_mem_codex_root — echoes the installed Codex plugin version directory.
claude_mem_codex_root() {
  local root
  for root in \
    "$HOME/.codex/plugins/cache/thedotmack/claude-mem"/* \
    "$HOME/.codex/plugins/cache/claude-mem-local/claude-mem"/*; do
    [ -f "$root/package.json" ] && { printf '%s\n' "$root"; return; }
  done
}

claude_mem_codex_installed() {
  [ -n "$(claude_mem_codex_root)" ]
}

# worker-service.cjs imports zod/v3. Codex copies local plugins without their
# node_modules tree, leaving every lifecycle hook to exit 1 unless dependencies
# are restored in the cache directory.
claude_mem_runtime_ready() {
  [ -f "$1/node_modules/zod/v3/index.js" ]
}

claude_mem_ensure_claude() {
  local list_text
  list_text="$(claude plugin list 2>/dev/null)"
  if claude_mem_claude_installed "$list_text"; then
    run claude plugin marketplace update thedotmack >/dev/null 2>&1
    run claude plugin update claude-mem@thedotmack >/dev/null 2>&1
    ok "Claude Code plugin present, refreshed"
    return
  fi
  local add_out
  add_out="$(claude plugin marketplace add "$CLAUDE_MEM_REPO" 2>&1)"
  if [ $? -ne 0 ] && ! already_added_error "$add_out"; then
    warn "Claude Code marketplace add failed: $add_out"
    return
  fi
  if run claude plugin install claude-mem@thedotmack; then
    ok "Claude Code plugin installed"
  else
    warn "Claude Code plugin install failed"
  fi
}

claude_mem_ensure_codex() {
  local root
  root="$(claude_mem_codex_root)"
  if [ -n "$root" ] && claude_mem_runtime_ready "$root"; then
    ok "Codex integration already installed, runtime ready"
    return
  fi
  if [ -n "$root" ]; then
    if run npm install --omit=dev --prefix "$root" && claude_mem_runtime_ready "$root"; then
      ok "Codex integration runtime dependencies repaired"
    else
      warn "Codex integration dependency repair failed"
    fi
    return
  fi
  # --provider claude: the installer refuses to guess a provider on a
  # non-interactive stdin ("A provider must be explicit when stdin is not
  # interactive") despite the README implying CI shells auto-skip that
  # prompt. claude matches the Anthropic-based setup already in use.
  if run npx claude-mem install --ide codex-cli --provider claude; then
    ok "Codex integration installed"
  else
    warn "Codex integration install failed"
  fi
}

# claude_mem_stop_worker — kills the worker daemon if one is running.
claude_mem_stop_worker() {
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    if run pkill -f "$CLAUDE_MEM_WORKER_PATTERN"; then
      ok "worker stopped"
    else
      warn "worker stop failed"
    fi
  else
    skip "worker not running"
  fi
}

# claude_mem_start_worker — starts the worker daemon directly if it isn't
# already running (`npx claude-mem start` is unreliable — see header note).
claude_mem_start_worker() {
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    ok "worker already running"
    return
  fi
  if ! claude_mem_claude_installed "$(claude plugin list 2>/dev/null)"; then
    skip "claude-mem not installed"
    return
  fi
  nohup npx claude-mem start >/dev/null 2>&1 &
  sleep 2
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    ok "worker started"
  else
    warn "worker failed to start — try 'npx claude-mem doctor'"
  fi
}

setup_claude_mem() {
  section "claude-mem"
  have claude && claude_mem_ensure_claude
  have codex && claude_mem_ensure_codex
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    ok "worker already running"
  else
    skip "worker not running — it starts itself on the next Claude Code session"
  fi
}
