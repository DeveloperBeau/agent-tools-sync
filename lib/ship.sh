#!/usr/bin/env bash
# Ship is private. Keep install/update failures nonfatal for machines without access.

# ship_developer_dir — the Developer dir of the plain /Applications/Xcode.app.
# `xcode-select` can point at an older, versioned Xcode whose compiler cannot
# read the newer SDK, which fails the Ship build. A set DEVELOPER_DIR wins.
ship_developer_dir() {
  [ -z "${DEVELOPER_DIR:-}" ] || { printf '%s\n' "$DEVELOPER_DIR"; return; }
  [ ! -d /Applications/Xcode.app/Contents/Developer ] || printf '%s\n' /Applications/Xcode.app/Contents/Developer
}

# Run a command with `swift build -c release` rewritten to the ship product.
# The release installer builds every Swift executable, and ShipTestHelper is one
# of them. A build that already names a product is left unchanged.
ship_with_product() {
  local real dir status
  real="$(command -v swift 2>/dev/null || true)"
  if [ -z "$real" ]; then
    "$@"
    return
  fi
  dir="$(mktemp -d "${TMPDIR:-/tmp}/ats-ship-swift.XXXXXX")" || { "$@"; return; }
  cat >"$dir/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1-}" = build ] && [ "${2-}" = -c ] && [ "${3-}" = release ]; then
  product=0
  for arg in "$@"; do
    [ "$arg" = --product ] && product=1
  done
  if [ "$product" -eq 0 ]; then
    shift 3
    exec "$SHIP_REAL_SWIFT" build -c release --product ship "$@"
  fi
fi
exec "$SHIP_REAL_SWIFT" "$@"
EOF
  chmod 755 "$dir/swift"
  local developer_dir
  developer_dir="$(ship_developer_dir)"
  (
    [ -z "$developer_dir" ] || export DEVELOPER_DIR="$developer_dir"
    SHIP_REAL_SWIFT="$real" PATH="$dir:$PATH" "$@"
  )
  status=$?
  rm -rf "$dir"
  return "$status"
}

setup_ship() {
  section "ship"

  local updater installer
  updater="$(command -v ship-update 2>/dev/null)"
  if [ -z "$updater" ] && [ -x "$HOME/.local/bin/ship-update" ]; then
    updater="$HOME/.local/bin/ship-update"
  fi
  if [ -n "$updater" ]; then
    if ship_with_product run "$updater"; then
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
  elif ship_with_product run bash "$installer"; then
    ok "installed"
  else
    warn "install failed; continuing"
  fi
  rm -f "$installer"
  return 0
}
