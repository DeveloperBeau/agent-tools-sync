#!/usr/bin/env bash
# Inspect user registries without health checks that launch MCP servers.

mcp_user_config() {
  case "$1" in
    claude)
      if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s/.claude.json\n' "$CLAUDE_CONFIG_DIR"
      else
        printf '%s/.claude.json\n' "$HOME"
      fi ;;
    codex) printf '%s/config.toml\n' "${CODEX_HOME:-$HOME/.codex}" ;;
  esac
}

# Return 0 for an existing name, 1 for missing, 2 for unsafe/unreadable config.
mcp_registered() {
  python3 - "$1" "$(mcp_user_config "$1")" "$2" <<'PY'
import json, pathlib, sys

agent, filename, name = sys.argv[1:]
path = pathlib.Path(filename)
try:
    text = path.read_text(encoding="utf-8")
except FileNotFoundError:
    raise SystemExit(2 if path.is_symlink() else 1)
except (OSError, UnicodeError):
    raise SystemExit(2)
try:
    if agent == "claude":
        data = json.loads(text)
        key = "mcpServers"
    else:
        import tomllib
        data = tomllib.loads(text)
        key = "mcp_servers"
    if not isinstance(data, dict) or not isinstance(data.get(key, {}), dict):
        raise SystemExit(2)
    raise SystemExit(0 if name in data.get(key, {}) else 1)
except (ValueError, ImportError):
    raise SystemExit(2)
PY
}

# Native CLIs own writes and escaping. Existing names, including credentials,
# remain untouched even when they use a different endpoint or runtime.
mcp_ensure() {
  local agent="$1" name="$2" transport="$3" state
  shift 3
  have "$agent" || { skip "$agent not installed — no $name MCP registration"; return 0; }
  mcp_registered "$agent" "$name"; state=$?
  case "$state" in
    0) skip "$name MCP already registered with $agent; preserved"; return 0 ;;
    1) ;;
    *) warn "$agent user MCP registry unreadable or invalid (Codex needs Python 3.11+); preserved"; return 1 ;;
  esac
  local -a args
  if [ "$agent" = claude ]; then
    args=(claude mcp add --scope user)
    if [ "$transport" = http ]; then
      args+=(--transport http "$name" "$@")
    else
      args+=("$name" -- "$@")
    fi
  else
    args=(codex mcp add "$name")
    if [ "$transport" = http ]; then args+=(--url "$@"); else args+=(-- "$@"); fi
  fi
  if run with_timeout 30 "${args[@]}"; then
    ok "$name MCP registered with $agent"
  else
    warn "$name MCP registration failed for $agent"
    return 1
  fi
}

mcp_setup_available() {
  if ! have claude && ! have codex; then
    skip "no installed agents — MCP setup skipped"
    return 1
  fi
  have python3 || { warn "python3 required for safe MCP registry checks"; return 2; }
}
