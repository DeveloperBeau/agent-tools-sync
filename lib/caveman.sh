#!/usr/bin/env bash
# caveman.sh — install/update caveman, enable its native Claude Code and
# Codex integrations (proxy + MCP + hooks, all managed by `caveman enable`),
# then chain caveman's proxy into headroom's so both compress every request:
# agent -> caveman (:8787) -> headroom (:8788) -> real provider. caveman has
# no override for its native /w/claude and /chatgpt wrap routes' upstream, so
# the chain instead goes through a `compat` mount in caveman.yaml, and
# ANTHROPIC_BASE_URL / Codex's model_providers.caveman.base_url get patched
# to point at that mount instead of the native routes. See
# https://github.com/JuliusBrussee/caveman/blob/main/docs/technical/proxy-and-providers.md#openai-compatible-providers

# caveman_agent_state STATUS_TEXT AGENT — echoes the word `caveman status`
# reports for AGENT's "native integrations" row (e.g. "installed",
# "available", "unavailable"), or nothing if AGENT isn't a row in the text
# at all. Exact first-field match, so "codex-app installed" can't be
# mistaken for the "codex" row, and free text mentioning the agent name
# elsewhere in the output can't produce a false positive either.
caveman_agent_state() {
  local status_text="$1" agent="$2"
  awk -v a="$agent" '$1==a{print $2; exit}' <<<"$status_text"
}

# caveman_agent_installed STATUS_TEXT AGENT — 0 only on an exact "installed".
caveman_agent_installed() {
  [ "$(caveman_agent_state "$1" "$2")" = "installed" ]
}

# caveman_version_string VERSION_JSON — pulls "version" out of
# `caveman --version`'s JSON without requiring a JSON parser on PATH.
caveman_version_string() {
  printf '%s' "$1" | grep -o '"version": *"[^"]*"' | cut -d'"' -f4
}

CAVEMAN_CONFIG_FILE="$HOME/.caveman/caveman.yaml"
CAVEMAN_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
CAVEMAN_CODEX_CONFIG="$HOME/.codex/config.toml"
CAVEMAN_CODEX_HOOKS="$HOME/.codex/hooks.json"
CAVEMAN_MANAGED_PROXY_BIN="$HOME/.caveman/bin/caveman-proxy"
CAVEMAN_PRIVATE_PROXY_BIN="$HOME/.caveman/ats-proxy/caveman-proxy"
CAVEMAN_PROXY_LOG="$HOME/.caveman/proxy.log"
CAVEMAN_PROXY_INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_caveman_proxy.py"
CAVEMAN_PROXY_BIN="${CAVEMAN_PROXY_BIN:-$CAVEMAN_MANAGED_PROXY_BIN}"

caveman_select_proxy() {
  case "$CAVEMAN_PROXY_BIN" in
    "$CAVEMAN_MANAGED_PROXY_BIN"|"$CAVEMAN_PRIVATE_PROXY_BIN") ;;
    *) export CAVEMAN_PROXY_BIN; return ;;
  esac
  if [ -x "$CAVEMAN_PRIVATE_PROXY_BIN" ]; then
    CAVEMAN_PROXY_BIN="$CAVEMAN_PRIVATE_PROXY_BIN"
  fi
  export CAVEMAN_PROXY_BIN
}
caveman_select_proxy

caveman_ensure_proxy_override() {
  local rc="$1" line
  [ -f "$rc" ] || return 0
  printf -v line 'export CAVEMAN_PROXY_BIN=%q' "$CAVEMAN_PROXY_BIN"
  grep -Fqx "$line" "$rc" && return 0
  printf '\n# ATS patched Caveman proxy (preserved across vendor updates).\n%s\n' "$line" >> "$rc"
}

# Only migrate the native hook command previously installed by Caveman.
# Custom executable paths remain the user's choice.
caveman_migrate_native_proxy() {
  [ "$CAVEMAN_PROXY_BIN" = "$CAVEMAN_PRIVATE_PROXY_BIN" ] || return 1
  local cfg
  case "$1" in
    claude) cfg="$CAVEMAN_CLAUDE_SETTINGS" ;;
    codex) cfg="$CAVEMAN_CODEX_HOOKS" ;;
    *) return 1 ;;
  esac
  python3 - "$cfg" "$CAVEMAN_MANAGED_PROXY_BIN" "$1" "$CAVEMAN_PRIVATE_PROXY_BIN" <<'PY'
import json, os, shlex, stat, sys, tempfile
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
    changed = False
    for entries in data.get("hooks", {}).values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                args = list(shlex.shlex(hook.get("command", ""), posix=True, punctuation_chars=True))
                if (len(args) == 5 and args[:4] == [sys.argv[2], "native-hook", sys.argv[3], "--adapter"]):
                    hook["command"] = shlex.join([sys.argv[4], *args[1:]])
                    changed = True
    if changed:
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
            temporary = Path(output.name)
            try:
                output.write(json.dumps(data, indent=2) + "\n")
                output.flush()
                os.fchmod(output.fileno(), stat.S_IMODE(path.stat().st_mode))
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        raise SystemExit(0)
except (OSError, ValueError, TypeError, AttributeError):
    pass
raise SystemExit(1)
PY
}

# caveman_yaml_has_headroom_stack YAML_TEXT — 0 if caveman.yaml already runs
# in compress mode with the compat.headroom mount pointed at headroom's port.
caveman_yaml_has_headroom_stack() {
  printf '%s\n' "$1" | grep -q '^mode: compress$' || return 1
  printf '%s\n' "$1" | grep -q '^  headroom:$' || return 1
  printf '%s\n' "$1" | grep -q 'base_url: http://127.0.0.1:8788$'
}

# caveman_route_patched AGENT — 0 if AGENT's caveman-owned route already
# points at the compat/headroom mount. `caveman enable` fingerprints the
# files it writes, so our own deliberate patch makes it report the agent as
# "degraded" forever after — this distinguishes that expected, harmless case
# from an agent that's actually missing or broken.
caveman_route_patched() {
  case "$1" in
    claude) [ -f "$CAVEMAN_CLAUDE_SETTINGS" ] && grep -q '"ANTHROPIC_BASE_URL": *"http://127.0.0.1:8787/compat/headroom"' "$CAVEMAN_CLAUDE_SETTINGS" 2>/dev/null ;;
    codex)  [ -f "$CAVEMAN_CODEX_CONFIG" ] && grep -q 'base_url = "http://127.0.0.1:8787/compat/headroom"' "$CAVEMAN_CODEX_CONFIG" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

install_caveman() {
  # --allow-scripts=pnpm: scoped to this command only (not written to global
  # npm config) so @caveman-ai/cli's pnpm dependency can run its own
  # postinstall. A persistent global allow-scripts entry instead breaks
  # unrelated project-scoped npm installs elsewhere — see claude-mem's
  # Codex plugin install, which hit exactly that.
  if ! have caveman; then
    run npm install -g @caveman-ai/cli --allow-scripts=pnpm
  else
    ok "installed ($(caveman_version_string "$(caveman --version 2>/dev/null)"))"
    run npm update -g @caveman-ai/cli --allow-scripts=pnpm >/dev/null
  fi
  if ! run python3 "$CAVEMAN_PROXY_INSTALLER"; then
    warn "patched Caveman build unavailable; keeping the existing proxy"
  fi
  caveman_select_proxy
  if [ "$CAVEMAN_PROXY_BIN" = "$CAVEMAN_PRIVATE_PROXY_BIN" ]; then
    caveman_ensure_proxy_override "$HOME/.zshrc"
    caveman_ensure_proxy_override "$HOME/.bashrc"
  fi
}

caveman_ensure_agent() {
  local status_text="$1" agent="$2" label="$3"
  if caveman_migrate_native_proxy "$agent"; then
    ok "$label native hooks now use the patched proxy"
    return
  elif caveman_agent_installed "$status_text" "$agent"; then
    skip "$label integration already installed"
    return
  elif caveman_route_patched "$agent"; then
    skip "$label integration active through headroom"
    return
  fi
  if run caveman enable "$agent"; then
    ok "$label integration installed"
  else
    warn "$label integration failed"
  fi
}

# caveman_start_proxy — starts caveman-proxy directly if it isn't already
# running. Caveman has no CLI verb for this either (it normally lazy-starts
# on the next `claude`/`codex` session); ats start needs it back now.
caveman_start_proxy() {
  caveman_select_proxy
  local pids status
  pids="$(listener_pids 8787)"; status=$?
  [ "$status" -ne 2 ] || { warn "cannot inspect port 8787"; return 1; }
  if [ -n "$pids" ]; then
    if caveman_listener_owned; then
      ok "proxy already listening on :8787"
      return 0
    fi
    warn "port 8787 belongs to another process; preserved"
    return 1
  fi
  if [ ! -x "$CAVEMAN_PROXY_BIN" ]; then
    warn "caveman-proxy binary not found at $CAVEMAN_PROXY_BIN"
    return 1
  fi
  mkdir -p "$(dirname "$CAVEMAN_PROXY_LOG")" || return 1
  (umask 077; touch "$CAVEMAN_PROXY_LOG") || return 1
  chmod 600 "$CAVEMAN_PROXY_LOG" || return 1
  nohup "$CAVEMAN_PROXY_BIN" >>"$CAVEMAN_PROXY_LOG" 2>&1 &
  local attempt
  for attempt in {1..10}; do
    if caveman_listener_owned; then
      ok "proxy listening on :8787"
      return 0
    fi
    sleep 1
  done
  warn "proxy failed to listen on :8787; see $CAVEMAN_PROXY_LOG"
  return 1
}

caveman_pid_owned() {
  local command
  command="$(ps -p "$1" -o comm= 2>/dev/null)" || return 1
  case "${command##*/}" in caveman-proxy|caveman-proxy.bin) return 0 ;; *) return 1 ;; esac
}

caveman_listener_owned() {
  local pids pid
  pids="$(listener_pids 8787)" || return 1
  [ -n "$pids" ] || return 1
  for pid in $pids; do
    caveman_pid_owned "$pid" || return 1
  done
}

# Stop only identified listeners; hook processes and other ports are separate.
caveman_stop_proxy() {
  local pids pid attempt alive status
  pids="$(listener_pids 8787)"; status=$?
  [ "$status" -ne 2 ] || { warn "cannot inspect port 8787; no process signaled"; return 1; }
  if [ -z "$pids" ]; then
    skip "proxy not running"
    return 0
  fi
  for pid in $pids; do
    caveman_pid_owned "$pid" || { warn "port 8787 belongs to another process; preserved"; return 1; }
  done
  for pid in $pids; do
    caveman_pid_owned "$pid" && run kill -TERM "$pid"
  done
  for attempt in {1..6}; do
    alive=0
    for pid in $pids; do caveman_pid_owned "$pid" && alive=1; done
    [ "$alive" = 0 ] && { ok "proxy stopped"; return 0; }
    sleep 1
  done
  for pid in $pids; do caveman_pid_owned "$pid" && run kill -KILL "$pid"; done
  for attempt in {1..3}; do
    alive=0
    for pid in $pids; do caveman_pid_owned "$pid" && alive=1; done
    [ "$alive" = 0 ] && { ok "proxy stopped"; return 0; }
    sleep 1
  done
  warn "proxy stop failed: original listener still running"
  return 1
}

# caveman_ensure_ssrf_allowlist RC_PATH — a loopback upstream (headroom on
# :8788) needs an explicit CAVE_SSRF_ALLOWLIST entry or caveman's proxy
# refuses to forward to it. Appends a guarded export block; no-op if it's
# already there.
caveman_ensure_ssrf_allowlist() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  if grep -q '^export CAVE_SSRF_ALLOWLIST=.*127\.0\.0\.1:8788' "$rc" 2>/dev/null; then
    skip "$rc already allows the headroom loopback upstream"
    return
  fi
  {
    printf '\n# >>> caveman ssrf allowlist >>>\n'
    printf 'export CAVE_SSRF_ALLOWLIST="127.0.0.1:8788"\n'
    printf '# <<< caveman ssrf allowlist <<<\n'
  } >> "$rc"
  ok "added CAVE_SSRF_ALLOWLIST for the headroom loopback upstream to $rc"
}

# caveman_ensure_stack_config — writes caveman.yaml's compress mode + the
# compat.headroom mount if it isn't already there, then restarts a running
# proxy so the new config actually takes effect this run (config is read at
# startup, not hot-reloaded).
# ponytail: full-file overwrite, no YAML merge — caveman.yaml is otherwise
# unused here. Upgrade to a merge if this ever needs to coexist with other
# hand-edited caveman.yaml settings.
caveman_ensure_stack_config() {
  local current
  current="$(cat "$CAVEMAN_CONFIG_FILE" 2>/dev/null)"
  if caveman_yaml_has_headroom_stack "$current"; then
    skip "caveman.yaml already chains to headroom"
    return
  fi
  cat > "$CAVEMAN_CONFIG_FILE" <<'YAML'
mode: compress
compat:
  headroom:
    base_url: http://127.0.0.1:8788
    wire_dialect: anthropic
YAML
  ok "caveman.yaml now chains to headroom (:8788) for compression"
  if port_listening 8787; then
    caveman_stop_proxy && caveman_start_proxy || return 1
  fi
}

# caveman_patch_claude_route — caveman enable claude always (re)writes
# ANTHROPIC_BASE_URL to its native /w/claude wrap route; repoint it at the
# compat/headroom mount so Claude Code's traffic chains through headroom too.
caveman_patch_claude_route() {
  [ -f "$CAVEMAN_CLAUDE_SETTINGS" ] || return 0
  if ! grep -q '"ANTHROPIC_BASE_URL": *"http://127.0.0.1:8787/w/claude"' "$CAVEMAN_CLAUDE_SETTINGS" 2>/dev/null; then
    skip "Claude Code already routed through compat/headroom"
    return
  fi
  if node -e '
    const fs = require("fs");
    const path = process.argv[1];
    const data = JSON.parse(fs.readFileSync(path, "utf8"));
    data.env = data.env || {};
    data.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:8787/compat/headroom";
    fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
  ' "$CAVEMAN_CLAUDE_SETTINGS"; then
    ok "Claude Code now chains caveman -> headroom"
  else
    warn "failed to patch $CAVEMAN_CLAUDE_SETTINGS"
  fi
}

# caveman_patch_codex_route — patch Caveman's known local routes and retain
# the headroom provider name used by saved Codex chats. Scope by table:
# Codex rewrites TOML without retaining Caveman's ownership comments.
caveman_patch_codex_route() {
  [ -f "$CAVEMAN_CODEX_CONFIG" ] || return 0
  local tmp
  tmp="$(mktemp)" || return 1
  if ! awk '
    /^[[:space:]]*\[/ {
      caveman=($0 ~ /^[[:space:]]*\[model_providers\.caveman\][[:space:]]*(#.*)?$/)
    }
    /^[[:space:]]*\[model_providers\.headroom\][[:space:]]*(#.*)?$/ { headroom=1 }
    caveman && /^base_url = "http:\/\/127\.0\.0\.1:8787\/(chatgpt|compat\/headroom)"/ { managed=1 }
    caveman && /^base_url = "http:\/\/127\.0\.0\.1:8787\/chatgpt"/ {
      print "base_url = \"http://127.0.0.1:8787/compat/headroom\""
      next
    }
    { print }
    END {
      if (managed && !headroom) {
        print "\n# Compatibility for saved Codex chats using the headroom provider."
        print "[model_providers.headroom]"
        print "name = \"Headroom (compatibility)\""
        print "base_url = \"http://127.0.0.1:8787/compat/headroom\""
        print "wire_api = \"responses\""
        print "requires_openai_auth = true"
      }
    }
  ' "$CAVEMAN_CODEX_CONFIG" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$CAVEMAN_CODEX_CONFIG"; then
    rm -f "$tmp"
    skip "Codex routing and saved-chat provider already configured"
  elif mv "$tmp" "$CAVEMAN_CODEX_CONFIG"; then
    ok "Codex now chains caveman -> headroom with saved-chat compatibility"
  else
    rm -f "$tmp"
    warn "failed to patch $CAVEMAN_CODEX_CONFIG"
    return 1
  fi
}

setup_caveman() {
  section "caveman"
  local previous_version="" current_version previous_proxy current_proxy
  previous_proxy="$(cksum "$CAVEMAN_PRIVATE_PROXY_BIN.bin" 2>/dev/null)"
  have caveman && previous_version="$(caveman --version 2>/dev/null)"
  install_caveman
  have caveman || { warn "caveman not on PATH after install — skipping rest"; return; }
  current_version="$(caveman --version 2>/dev/null)"
  current_proxy="$(cksum "$CAVEMAN_PRIVATE_PROXY_BIN.bin" 2>/dev/null)"
  if { { [ -n "$previous_version" ] && [ -n "$current_version" ] &&
         [ "$previous_version" != "$current_version" ]; } ||
       { [ -n "$current_proxy" ] && [ "$previous_proxy" != "$current_proxy" ]; }; } &&
     port_listening 8787; then
    caveman_stop_proxy && caveman_start_proxy || return 1
  fi

  local status_text
  status_text="$(caveman status 2>/dev/null)"
  have claude && caveman_ensure_agent "$status_text" claude "Claude Code"
  have codex && caveman_ensure_agent "$status_text" codex "Codex"

  caveman_ensure_ssrf_allowlist "$HOME/.zshrc"
  caveman_ensure_ssrf_allowlist "$HOME/.bashrc"
  export CAVE_SSRF_ALLOWLIST="${CAVE_SSRF_ALLOWLIST:-127.0.0.1:8788}"

  caveman_ensure_stack_config
  have claude && caveman_patch_claude_route
  have codex && caveman_patch_codex_route

  if caveman_listener_owned; then
    ok "proxy already running on :8787"
  else
    skip "proxy startup checked at end of ATS sync"
  fi
}
