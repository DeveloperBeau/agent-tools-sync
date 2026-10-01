#!/usr/bin/env bash
# Shared Markdown plans vault; no Obsidian community plugin or daemon required.

setup_obsidian() {
  section "obsidian plans"
  local agents=() vault
  have claude && agents+=(claude)
  have codex && agents+=(codex)
  if [ "${#agents[@]}" -eq 0 ]; then
    skip "Claude Code and Codex not installed"
    return 0
  fi
  if ! have python3 || ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    warn "shared plans integration needs Python 3.11 or newer; continuing"
    return 0
  fi
  vault="${ATS_PLANS_VAULT:-$HOME/Developer/Personal/plans}"
  if run python3 "$SCRIPT_DIR/lib/plans.py" install --home "$HOME" --vault "$vault" --agents "${agents[@]}"; then
    ok "shared plans vault and agent hooks ready"
  else
    warn "shared plans setup failed; inspect the error before retrying"
  fi
}
