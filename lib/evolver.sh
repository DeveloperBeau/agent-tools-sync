#!/usr/bin/env bash
# evolver.sh — install/update evolver (github.com/EvoMap/evolver), wire its
# session hooks into both Claude Code and Codex via `evolver setup-hooks`.
# No proxy/daemon component — it's a CLI invoked on demand by those hooks —
# so unlike headroom/caveman it has nothing for cmd_kill/cmd_start to manage.

# evolver_claude_hook_installed SETTINGS_JSON_TEXT — 0 if Claude Code's
# settings.json already references evolver's hook scripts.
evolver_claude_hook_installed() {
  printf '%s' "$1" | grep -q '\.claude/hooks/evolver/'
}

# Codex's Evolver installer writes hooks to config.toml. ATS keeps user hooks
# together in hooks.json to avoid Codex's dual-source warning.

install_evolver() {
  if ! have evolver; then
    if have npm; then run npm install -g @evomap/evolver
    elif have bun; then run bun install -g @evomap/evolver
    else warn "no npm or bun on PATH — cannot install evolver"; return 1
    fi
  else
    ok "installed"
    if command -v evolver | grep -q '/\.bun/'; then
      run bun install -g @evomap/evolver >/dev/null || warn "evolver update failed"
    else
      run npm update -g @evomap/evolver >/dev/null || warn "evolver update failed"
    fi
  fi
}

evolver_ensure_claude() {
  local settings_text
  settings_text="$(cat "$HOME/.claude/settings.json" 2>/dev/null)"
  if evolver_claude_hook_installed "$settings_text"; then
    skip "Claude Code hooks already installed"
  elif run evolver setup-hooks --runtime=claude-code --scope=user; then
    ok "Claude Code hooks installed"
  else
    warn "Claude Code hook install failed"
  fi
}

# --scope=user matters: codex's installer defaults to project scope, which
# drops a .codex/config.toml into whatever directory ats happened to run from.
evolver_ensure_codex() {
  if ! grep -q '^\[mcp_servers\.evolver\]' "$HOME/.codex/config.toml" 2>/dev/null; then
    if ! run evolver setup-hooks --runtime=codex --scope=user; then
      warn "Codex Evolver setup failed"
      return
    fi
  fi
  if run python3 "$SCRIPT_DIR/lib/evolver_codex_hooks.py" "$HOME/.codex"; then
    ok "Codex hooks registered in hooks.json"
  else
    warn "Codex hook registration failed"
  fi
}

setup_evolver() {
  section "evolver"
  install_evolver
  have evolver || { warn "evolver not on PATH after install — skipping rest"; return; }
  evolver_ensure_claude
  evolver_ensure_codex
}
