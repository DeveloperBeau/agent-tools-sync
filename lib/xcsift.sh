#!/usr/bin/env bash
# xcsift.sh — install/update xcsift and pipe Claude Code's xcodebuild and
# swift build/test output through it (lib/xcsift.py). macOS + Xcode only.

XCSIFT_RTK_CONFIG="$HOME/Library/Application Support/rtk/config.toml"

setup_xcsift() {
  section "xcsift"
  have xcodebuild || { skip "no xcodebuild on PATH"; return 0; }
  have brew || { warn "brew required to install xcsift"; return 1; }
  if ! have xcsift; then
    run brew install xcsift || { warn "xcsift install failed"; return 1; }
  elif [ -n "$(brew outdated xcsift 2>/dev/null)" ]; then
    run brew upgrade xcsift || warn "xcsift upgrade failed"
  else
    skip "already up to date"
  fi
  have claude || return 0
  local out
  if out="$(python3 "$SCRIPT_DIR/lib/xcsift.py" install "$HOME/.claude/settings.json" "$XCSIFT_RTK_CONFIG" 2>&1)"; then
    if [ -n "$out" ]; then
      while IFS= read -r line; do ok "$line"; done <<<"$out"
    else
      skip "Claude Code hook already installed"
    fi
  else
    warn "Claude Code hook install failed: $out"
    return 1
  fi
}
