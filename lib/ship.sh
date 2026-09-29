#!/usr/bin/env bash
# Ship is private. Keep install/update failures nonfatal for machines without access.

setup_ship() {
  section "ship"

  local updater installer
  updater="$(command -v ship-update 2>/dev/null)"
  if [ -z "$updater" ] && [ -x "$HOME/.local/bin/ship-update" ]; then
    updater="$HOME/.local/bin/ship-update"
  fi
  if [ -n "$updater" ]; then
    if run "$updater"; then
      ok "updated"
    else
      warn "update failed; continuing"
    fi
    return 0
  fi

  if ! have gh; then
    skip "not installed; GitHub CLI unavailable"
    return 0
  fi

  installer="$(mktemp)" || { warn "installer download unavailable"; return 0; }
  if ! with_timeout 30 gh api 'repos/DeveloperBeau/Ship/contents/install.sh?ref=release' \
      -H 'Accept: application/vnd.github.raw+json' >"$installer"; then
    warn "install unavailable; check private repository access"
  elif [ ! -s "$installer" ]; then
    warn "install unavailable; empty bootstrap"
  elif run bash "$installer"; then
    ok "installed"
  else
    warn "install failed; continuing"
  fi
  rm -f "$installer"
  return 0
}
