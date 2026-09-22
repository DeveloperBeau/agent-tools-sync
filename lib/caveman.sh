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
  if ! have caveman; then
    run npm install -g @caveman-ai/cli
  else
    ok "installed ($(caveman_version_string "$(caveman --version 2>/dev/null)"))"
    run npm update -g @caveman-ai/cli >/dev/null
  fi
}

caveman_ensure_agent() {
  local status_text="$1" agent="$2" label="$3"
  if caveman_agent_installed "$status_text" "$agent"; then
    skip "$label integration already installed"
  elif caveman_route_patched "$agent"; then
    skip "$label integration reports degraded — expected, its route is patched to chain through headroom"
  elif run caveman enable "$agent"; then
    ok "$label integration installed"
  else
    warn "$label integration failed"
  fi
}

# caveman_start_proxy — starts caveman-proxy directly if it isn't already
# running. Caveman has no CLI verb for this either (it normally lazy-starts
# on the next `claude`/`codex` session); ats start needs it back now.
CAVEMAN_PROXY_BIN="$HOME/.caveman/bin/caveman-proxy"
caveman_start_proxy() {
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy already running on :8787"
    return
  fi
  if [ ! -x "$CAVEMAN_PROXY_BIN" ]; then
    skip "caveman-proxy binary not found at $CAVEMAN_PROXY_BIN — it will self-start on the next claude/codex session"
    return
  fi
  nohup "$CAVEMAN_PROXY_BIN" >/dev/null 2>&1 &
  sleep 1
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy started on :8787"
  else
    warn "proxy failed to start — try $CAVEMAN_PROXY_BIN directly"
  fi
}

# caveman_stop_proxy — kills the caveman-proxy process if one is running.
# No CLI subcommand owns this (caveman itself has no `stop`/`disable` verb
# for the proxy), so this matches setup_caveman's own pgrep pattern above.
caveman_stop_proxy() {
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    if run pkill -f caveman-proxy; then
      ok "proxy stopped"
    else
      warn "proxy stop failed"
    fi
  else
    skip "proxy not running"
  fi
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
  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    run pkill -f caveman-proxy
    sleep 1
    caveman_start_proxy
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

# caveman_patch_codex_route — same idea for Codex's model_providers.caveman
# table, scoped to caveman's own owned block so nothing else in config.toml
# is touched.
caveman_patch_codex_route() {
  [ -f "$CAVEMAN_CODEX_CONFIG" ] || return 0
  if ! grep -q 'base_url = "http://127.0.0.1:8787/chatgpt"' "$CAVEMAN_CODEX_CONFIG" 2>/dev/null; then
    skip "Codex already routed through compat/headroom"
    return
  fi
  local tmp
  tmp="$(mktemp)"
  awk '
    /^# >>> caveman:native-tables/ { inblock=1 }
    /^# <<< caveman:native-tables/ { inblock=0 }
    inblock && /^base_url = "http:\/\/127\.0\.0\.1:8787\/chatgpt"/ {
      print "base_url = \"http://127.0.0.1:8787/compat/headroom\""
      next
    }
    { print }
  ' "$CAVEMAN_CODEX_CONFIG" > "$tmp" && mv "$tmp" "$CAVEMAN_CODEX_CONFIG"
  ok "Codex now chains caveman -> headroom"
}

setup_caveman() {
  section "caveman"
  install_caveman
  have caveman || { warn "caveman not on PATH after install — skipping rest"; return; }

  local status_text
  status_text="$(caveman status 2>/dev/null)"
  caveman_ensure_agent "$status_text" claude "Claude Code"
  caveman_ensure_agent "$status_text" codex "Codex"

  caveman_ensure_ssrf_allowlist "$HOME/.zshrc"
  caveman_ensure_ssrf_allowlist "$HOME/.bashrc"
  export CAVE_SSRF_ALLOWLIST="${CAVE_SSRF_ALLOWLIST:-127.0.0.1:8788}"

  caveman_ensure_stack_config
  caveman_patch_claude_route
  caveman_patch_codex_route

  if pgrep -f caveman-proxy >/dev/null 2>&1; then
    ok "proxy already running on :8787"
  else
    skip "proxy not running — it starts itself on the next Claude Code / Codex session"
  fi
}
