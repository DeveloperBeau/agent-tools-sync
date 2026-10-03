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
# server like caveman-proxy/headroom, so cmd_kill/cmd_start manage it too.
# Use the installed runtime's native lifecycle commands; npx may resolve a
# stale marketplace copy instead of the plugin actually loaded by the host.

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

claude_mem_worker_script() {
  local script root
  script="$(python3 - "$HOME/.claude/plugins/installed_plugins.json" <<'PY'
import json
import sys
from pathlib import Path
try:
    registry = json.loads(Path(sys.argv[1]).read_text())
    entries = registry.get("plugins", {}).get("claude-mem@thedotmack", [])
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("installPath"), str):
            continue
        script = Path(entry["installPath"]) / "scripts/worker-service.cjs"
        if script.is_file():
            print(script)
            raise SystemExit(0)
except (OSError, ValueError, TypeError, AttributeError):
    pass
raise SystemExit(1)
PY
)" && { printf '%s\n' "$script"; return 0; }
  root="$(claude_mem_codex_root)"
  [ -n "$root" ] && [ -f "$root/scripts/worker-service.cjs" ] || return 1
  printf '%s/scripts/worker-service.cjs\n' "$root"
}

claude_mem_worker_cli() {
  local script runtime
  script="$(claude_mem_worker_script)" || return 1
  if have bun; then runtime=bun
  elif [ -x "$HOME/.bun/bin/bun" ]; then runtime="$HOME/.bun/bin/bun"
  else return 1
  fi
  with_timeout 60 "$runtime" "$script" "$1"
}

claude_mem_stop_worker() {
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    if ! claude_mem_worker_cli stop >/dev/null 2>&1; then
      warn "worker stop failed"
      return 1
    fi
    local attempt
    for attempt in {1..5}; do
      if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
        :
      elif [ "$?" = 1 ]; then
        ok "worker stopped"
        return 0
      else
        warn "cannot verify worker shutdown"
        return 1
      fi
      sleep 1
    done
    warn "worker stop failed: process still running"
    return 1
  elif [ "$?" = 1 ]; then
    skip "worker not running"
  else
    warn "cannot inspect memory worker"
    return 1
  fi
}

claude_mem_start_worker() {
  if pgrep -f "$CLAUDE_MEM_WORKER_PATTERN" >/dev/null 2>&1; then
    ok "worker already running"
    return
  elif [ "$?" != 1 ]; then
    warn "cannot inspect memory worker"
    return 1
  fi
  if ! claude_mem_worker_script >/dev/null; then
    skip "claude-mem runtime not installed"
    return 0
  fi
  local result
  if ! result="$(claude_mem_worker_cli start 2>/dev/null)"; then
    warn "worker failed to start; check $HOME/.claude-mem/logs"
    return 1
  fi
  # Native start reports failures in JSON even when its exit code is zero.
  if printf '%s\n' "$result" | python3 -c '
import json, sys
status = None
for line in sys.stdin:
    try:
        item = json.loads(line)
        if isinstance(item, dict) and "status" in item:
            status = item["status"]
    except ValueError:
        pass
raise SystemExit(0 if status == "ready" else 1)
'; then
    ok "worker started"
  else
    warn "worker failed to start; check $HOME/.claude-mem/logs"
    return 1
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
