#!/usr/bin/env bash
# Serena runs within agent-owned stdio sessions, not the ATS proxy chain.

serena_prepare() {
  local tools managed=no config
  SERENA_RUNTIME=""
  if have uv; then
    tools="$(with_timeout 30 uv tool list)" || { warn "Serena tool inspection failed"; return 1; }
    if printf '%s\n' "$tools" | grep -qE '^serena-agent([[:space:]]|$)'; then managed=yes; fi
  fi
  if [ "$managed" = no ] && have serena; then
    SERENA_RUNTIME="$(command -v serena)"
    skip "existing Serena installation preserved"
  else
    have uv || { warn "uv required to install serena-agent"; return 1; }
    if [ "$managed" = yes ]; then
      run with_timeout 300 uv tool upgrade serena-agent || { warn "Serena upgrade failed"; return 1; }
    else
      run with_timeout 300 uv tool install --python 3.13 serena-agent || { warn "Serena installation failed"; return 1; }
    fi
    tools="$(uv tool dir --bin)" || { warn "Serena executable directory unavailable"; return 1; }
    SERENA_RUNTIME="$tools/serena"
  fi
  case "$SERENA_RUNTIME" in /*) ;; *) warn "Serena executable must have an absolute path"; return 1 ;; esac
  [ -x "$SERENA_RUNTIME" ] || { warn "Serena executable missing: $SERENA_RUNTIME"; return 1; }
  config="$(python3 - <<'PY'
import os, pathlib
home = os.environ.get("SERENA_HOME", "").strip()
print((pathlib.Path(home) if home else pathlib.Path.home() / ".serena") / "serena_config.yml")
PY
  )" || { warn "Serena config path check failed"; return 1; }
  # init overwrites backend selection; existing configuration must be preserved.
  if [ -e "$config" ] || [ -L "$config" ]; then
    skip "Serena configuration preserved"
  elif ! run with_timeout 60 "$SERENA_RUNTIME" init; then
    warn "Serena initialization failed"
    return 1
  fi
}

setup_serena() {
  section "serena"
  local available failed=0
  mcp_setup_available; available=$?
  [ "$available" -ne 1 ] || return 0
  [ "$available" -eq 0 ] || return 1
  serena_prepare || return 1
  mcp_ensure claude serena stdio "$SERENA_RUNTIME" start-mcp-server \
    --context claude-code --project-from-cwd --open-web-dashboard False || failed=1
  mcp_ensure codex serena stdio "$SERENA_RUNTIME" start-mcp-server \
    --context codex --project-from-cwd --open-web-dashboard False || failed=1
  return "$failed"
}
