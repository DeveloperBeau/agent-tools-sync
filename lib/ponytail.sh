#!/usr/bin/env bash
# ponytail.sh — install/refresh the ponytail plugin in both Claude Code and
# Codex. Both hosts manage plugins via a marketplace-add + install/add pair;
# re-adding an already-added marketplace errors, so that error is tolerated.

PONYTAIL_REPO="DietrichGebert/ponytail"

# ponytail_claude_installed PLUGIN_LIST_TEXT — 0 if `claude plugin list`
# already shows ponytail@ponytail.
ponytail_claude_installed() {
  printf '%s' "$1" | grep -q 'ponytail@ponytail'
}

# ponytail_codex_installed CONFIG_TOML_TEXT — 0 only if the
# [plugins."ponytail@ponytail"] table exists AND sets enabled = true.
# (Codex's own `plugin list` doesn't reliably print the combined
# name@marketplace id per plugin — config.toml is the source of truth here.)
ponytail_codex_installed() {
  awk '
    /^\[plugins\."ponytail@ponytail"\]/ { insection=1; next }
    /^\[/ { insection=0 }
    insection && /enabled[ \t]*=[ \t]*true/ { found=1 }
    END { exit !found }
  ' <<<"$1"
}

# already_added_error TEXT — 0 if TEXT looks like a "marketplace already
# exists" error rather than a real failure.
already_added_error() {
  printf '%s' "$1" | grep -qi 'already added'
}

ponytail_ensure_claude() {
  local list_text
  list_text="$(claude plugin list 2>/dev/null)"
  if ponytail_claude_installed "$list_text"; then
    run claude plugin marketplace update ponytail >/dev/null 2>&1
    run claude plugin update ponytail@ponytail >/dev/null 2>&1
    ok "Claude Code plugin present, refreshed"
    return
  fi
  local add_out
  add_out="$(claude plugin marketplace add "$PONYTAIL_REPO" 2>&1)"
  if [ $? -ne 0 ] && ! already_added_error "$add_out"; then
    warn "Claude Code marketplace add failed: $add_out"
    return
  fi
  if run claude plugin install ponytail@ponytail; then
    ok "Claude Code plugin installed"
  else
    warn "Claude Code plugin install failed"
  fi
}

ponytail_ensure_codex() {
  local cfg_text
  cfg_text="$(cat "$HOME/.codex/config.toml" 2>/dev/null)"
  if ponytail_codex_installed "$cfg_text"; then
    run codex plugin marketplace upgrade >/dev/null 2>&1
    run codex plugin add ponytail@ponytail >/dev/null 2>&1
    ok "Codex plugin present, refreshed"
    return
  fi
  local add_out
  add_out="$(codex plugin marketplace add "$PONYTAIL_REPO" 2>&1)"
  if [ $? -ne 0 ] && ! already_added_error "$add_out"; then
    warn "Codex marketplace add failed: $add_out"
    return
  fi
  if run codex plugin add ponytail@ponytail; then
    ok "Codex plugin installed"
  else
    warn "Codex plugin install failed"
  fi
}

setup_ponytail() {
  section "ponytail"
  have claude && ponytail_ensure_claude
  have codex && ponytail_ensure_codex
}
