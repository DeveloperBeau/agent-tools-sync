#!/usr/bin/env bash
# rtk.sh — install/update rtk, wire its shell-output hook into Claude Code
# and its AGENTS.md/RTK.md routing into Codex.

RTK_INSTALL_URL="https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh"

# rtk_claude_hook_installed SETTINGS_JSON_TEXT — 0 if Claude Code's
# settings.json already runs the rtk hook. Matched as a quoted JSON string,
# not a bare substring, so "rtk hook claude-extra-thing" can't false-match.
rtk_claude_hook_installed() {
  printf '%s' "$1" | grep -qE '"rtk hook claude"'
}

# rtk_codex_installed RTK_MD_EXISTS AGENTS_MD_TEXT — 0 only if both the
# per-agent RTK.md file exists AND Codex's AGENTS.md actually @-imports it
# (the file alone, from a half-finished install, isn't enough; nor is prose
# that merely mentions "RTK.md" without an import directive). The filename
# component must be exactly RTK.md — preceded by "@" or "/" and followed by
# whitespace or end of string — so a differently-named file that merely
# ends in the same characters (e.g. "@/tmp/NOTES-RTK.md") can't false-match.
rtk_codex_installed() {
  local rtk_md_exists="$1" agents_md_text="$2"
  [ "$rtk_md_exists" = "yes" ] || return 1
  printf '%s' "$agents_md_text" | grep -qE '@([^[:space:]]*/)?RTK\.md([[:space:]]|$)'
}

install_rtk() {
  if ! have rtk; then
    if have brew; then run brew install rtk
    else run bash -c "curl -fsSL '$RTK_INSTALL_URL' | sh"
    fi
  else
    ok "installed ($(rtk --version 2>/dev/null))"
    if brew list rtk >/dev/null 2>&1; then
      run brew upgrade rtk || skip "already up to date"
    else
      run bash -c "curl -fsSL '$RTK_INSTALL_URL' | sh"
    fi
  fi
}

rtk_ensure_claude() {
  local settings_text
  settings_text="$(cat "$HOME/.claude/settings.json" 2>/dev/null)"
  if rtk_claude_hook_installed "$settings_text"; then
    skip "Claude Code hook already installed"
  elif run rtk init -g --auto-patch; then
    ok "Claude Code hook installed"
  else
    warn "Claude Code hook install failed"
  fi
}

rtk_ensure_codex() {
  local exists="no" agents_text
  [ -f "$HOME/.codex/RTK.md" ] && exists="yes"
  agents_text="$(cat "$HOME/.codex/AGENTS.md" 2>/dev/null)"
  if rtk_codex_installed "$exists" "$agents_text"; then
    skip "Codex integration already installed"
  elif run rtk init -g --codex --auto-patch; then
    ok "Codex integration installed"
  else
    warn "Codex integration install failed"
  fi
}

setup_rtk() {
  section "rtk"
  install_rtk
  have rtk || { warn "rtk not on PATH after install — skipping rest"; return; }
  rtk_ensure_claude
  rtk_ensure_codex
}
