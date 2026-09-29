#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/common.sh"
source "$HERE/../lib/ship.sh"

ship_fixture() {
  PATH=/usr/bin:/bin
  export PATH
  HOME="$(mktemp -d)"
  export HOME
  trap 'rm -r "$HOME"' EXIT
  SHIP_TEST_LOG="$HOME/calls"
  export SHIP_TEST_LOG
  cat >"$HOME/installer" <<'INSTALLER'
#!/usr/bin/env bash
printf 'installed\n' >>"$SHIP_TEST_LOG"
INSTALLER
  have() { [ "$1" = gh ] && [ "${SHIP_HAS_GH:-1}" -eq 1 ]; }
  with_timeout() {
    [ "${SHIP_FETCH_FAIL:-0}" -eq 0 ] || return 1
    cat "$HOME/installer"
  }
}

ship_updates_existing() (
  ship_fixture
  mkdir -p "$HOME/.local/bin"
  cat >"$HOME/.local/bin/ship-update" <<'UPDATER'
#!/usr/bin/env bash
printf 'updated\n' >>"$SHIP_TEST_LOG"
UPDATER
  chmod +x "$HOME/.local/bin/ship-update"
  setup_ship >/dev/null
  [ "$(cat "$SHIP_TEST_LOG")" = updated ]
)
check "Ship updates existing installation" ship_updates_existing

ship_update_failure_nonfatal() (
  ship_fixture
  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$HOME/.local/bin/ship-update"
  chmod +x "$HOME/.local/bin/ship-update"
  setup_ship >"$HOME/output"
  grep -q 'update failed; continuing' "$HOME/output"
)
check "Ship update failure does not stop sync" ship_update_failure_nonfatal

ship_installs_when_accessible() (
  ship_fixture
  setup_ship >/dev/null
  [ "$(cat "$SHIP_TEST_LOG")" = installed ]
)
check "Ship installs when repository accessible" ship_installs_when_accessible

ship_private_failure_nonfatal() (
  ship_fixture
  SHIP_FETCH_FAIL=1
  setup_ship >"$HOME/output"
  grep -q 'check private repository access' "$HOME/output"
  [ ! -e "$SHIP_TEST_LOG" ]
)
check "Private repository failure does not stop sync" ship_private_failure_nonfatal

ship_without_gh_nonfatal() (
  ship_fixture
  SHIP_HAS_GH=0
  setup_ship >"$HOME/output"
  grep -q 'GitHub CLI unavailable' "$HOME/output"
)
check "Ship skipped without GitHub CLI" ship_without_gh_nonfatal

report
