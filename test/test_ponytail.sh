#!/usr/bin/env bash
# test_ponytail.sh — unit + fuzz tests for lib/ponytail.sh's pure decision
# functions. ponytail_codex_installed is the exact seam the real "marketplace
# already added" failure came from (the old check grepped `codex plugin
# list`, which doesn't print the id the way we assumed).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/harness.sh"
source "$HERE/../lib/ponytail.sh"

REAL_CLAUDE_LIST=$'Installed plugins:\n\n  ❯ ponytail@ponytail\n    Version: 4.9.0\n    Scope: user\n    Status: ✔ enabled'
REAL_CODEX_TOML=$'[marketplaces.ponytail]\nsource_type = "git"\nsource = "https://github.com/dietrichgebert/ponytail.git"\n\n[plugins."ponytail@ponytail"]\nenabled = true\n'

# --- claude_installed --------------------------------------------------------
check "claude_installed: real plugin list"            ponytail_claude_installed "$REAL_CLAUDE_LIST"
check_fail "claude_installed: plugin absent"          ponytail_claude_installed 'Installed plugins:\n\n  ❯ axiom@axiom-marketplace'
check_fail "claude_installed: empty list"             ponytail_claude_installed ""

# --- codex_installed ----------------------------------------------------------
check "codex_installed: real config.toml, enabled=true"  ponytail_codex_installed "$REAL_CODEX_TOML"
check_fail "codex_installed: enabled=false"              ponytail_codex_installed \
  $'[plugins."ponytail@ponytail"]\nenabled = false\n'
check_fail "codex_installed: section entirely absent"    ponytail_codex_installed \
  $'[plugins."other@x"]\nenabled = true\n'
check_fail "codex_installed: empty config"               ponytail_codex_installed ""

# This is the direct regression test for the real bug's shape: a DIFFERENT
# plugin's section is enabled, ponytail's own section says false. A naive
# "does the file contain both the id string and enabled=true anywhere"
# check would false-positive here; the section-scoped state machine must not.
check_fail "codex_installed: another section enabled=true must not leak into ponytail's row" \
  ponytail_codex_installed $'[plugins."other@x"]\nenabled = true\n\n[plugins."ponytail@ponytail"]\nenabled = false\n'

# Order shouldn't matter: ponytail's own section enabled=true, appearing
# before an unrelated disabled section, must still read as installed.
check "codex_installed: ponytail enabled=true ahead of an unrelated disabled section" \
  ponytail_codex_installed $'[plugins."ponytail@ponytail"]\nenabled = true\n\n[plugins."other@x"]\nenabled = false\n'

# Reset guard: ponytail's own section disabled, followed by an unrelated
# section that IS enabled. This only passes if `insection` actually resets
# to 0 on leaving ponytail's table — a state machine that forgot to reset it
# would let the later, unrelated "enabled = true" leak through as a false
# positive (this is the exact shape that let a real mutant survive mutation
# testing — see test/mutate.sh).
check_fail "codex_installed: insection must reset — a later unrelated enabled=true must not leak back" \
  ponytail_codex_installed $'[plugins."ponytail@ponytail"]\nenabled = false\n\n[plugins."other@x"]\nenabled = true\n'

# Fuzz: malformed / truncated toml (no closing section, no trailing newline,
# random noise) must never crash and must never false-positive.
check_fail "codex_installed: truncated toml, no trailing newline" \
  ponytail_codex_installed '[plugins."ponytail@ponytail"'
check_fail "codex_installed: random fuzz text" \
  ponytail_codex_installed "$(head -c 300 /dev/urandom | base64)"
# Documented boundary (false negative): extra whitespace inside the section
# header (not what codex itself ever emits) is intentionally not matched.
check_fail "codex_installed: spaced-out section header is NOT matched (documented boundary)" \
  ponytail_codex_installed $'[ plugins."ponytail@ponytail" ]\nenabled = true\n'

# --- already_added_error ------------------------------------------------------
check "already_added_error: real codex error text" already_added_error \
  "Error: marketplace 'ponytail' is already added from a different source; remove it before adding this source"
check_fail "already_added_error: unrelated error"   already_added_error "Error: network unreachable"
check_fail "already_added_error: empty text"        already_added_error ""
check "already_added_error: case-insensitive"       already_added_error "ALREADY ADDED, skipping"

report
