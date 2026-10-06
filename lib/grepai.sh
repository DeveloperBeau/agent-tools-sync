#!/usr/bin/env bash
# grepai.sh — install/update grepai and Ollama, start Ollama, keep .grepai/
# out of every repo via the global git excludes, register the grepai MCP
# server in Claude Code, and pull the user's chosen embedding model.
# ATS never runs `grepai init` or indexes a repository.

GREPAI_QWEN=qwen3-embedding:8b
GREPAI_NOMIC=nomic-embed-text

# Chosen model, its dimensions, and whether the user actually picked it.
# Lives beside ATS's other state (the stop marker) in the caveman home.
grepai_state_file() { printf '%s/ats-grepai.env\n' "${CAVEMAN_HOME:-$HOME/.caveman}"; }

grepai_dimensions() { case "$1" in "$GREPAI_QWEN") echo 4096 ;; *) echo 768 ;; esac; }

grepai_state_get() {
  sed -n "s/^$1=//p" "$(grepai_state_file)" 2>/dev/null | head -n1
}

# grepai_state_set MODEL ASKED — ASKED is yes when the user chose (or a
# fallback was recorded), no when a non-interactive run defaulted.
grepai_state_set() {
  local file; file="$(grepai_state_file)"
  mkdir -p "$(dirname "$file")" || return 1
  printf 'GREPAI_MODEL=%s\nGREPAI_DIMENSIONS=%s\nGREPAI_ASKED=%s\n' \
    "$1" "$(grepai_dimensions "$1")" "$2" >"$file"
}

# grepai_prompt — prints qwen3 or nomic. Reads fd 3 when install.sh opened
# it, else the controlling terminal (ATS_TTY overrides, for tests). Returns 1
# when there is no terminal.
grepai_prompt() {
  local answer fd_ok=0 tty="${ATS_TTY:-/dev/tty}"
  { : <&3; } 2>/dev/null && fd_ok=1
  [ "$fd_ok" -eq 1 ] || { { : <"$tty"; } 2>/dev/null || return 1; }
  {
    printf '\nWhich Ollama embedding model should grepai use?\n'
    printf '  1) %s (recommended)\n' "$GREPAI_QWEN"
    printf '     Best search quality. About a 4.7 GB download, needs roughly 8 GB of\n'
    printf '     free memory while indexing, best on Apple silicon with 16 GB or more.\n'
    printf '  2) %s\n' "$GREPAI_NOMIC"
    printf '     About a 274 MB download, runs on any Mac, lower search quality.\n'
  } >&2
  while :; do
    printf 'Choice [1/2, default 1]: ' >&2
    if [ "$fd_ok" -eq 1 ]; then IFS= read -r answer <&3 || return 1
    else IFS= read -r answer <"$tty" || return 1; fi
    case "$answer" in
      ''|1) echo "$GREPAI_QWEN"; return 0 ;;
      2) echo "$GREPAI_NOMIC"; return 0 ;;
      *) printf 'Enter 1 or 2.\n' >&2 ;;
    esac
  done
}

# grepai_exclude — add .grepai/ to the global git excludes file, creating
# ~/.config/git/ignore and pointing core.excludesFile at it only when unset.
grepai_exclude() {
  have git || { warn "git required to update global excludes"; return 1; }
  local file
  file="$(git config --global core.excludesFile 2>/dev/null)"
  if [ -z "$file" ]; then
    file="$HOME/.config/git/ignore"
    git config --global core.excludesFile "$file" || { warn "could not set core.excludesFile"; return 1; }
  fi
  case "$file" in \~/*) file="$HOME/${file#??}" ;; esac
  if grep -qxF '.grepai/' "$file" 2>/dev/null; then
    skip ".grepai/ already in global git excludes"
    return 0
  fi
  if mkdir -p "$(dirname "$file")" && printf '.grepai/\n' >>"$file"; then
    ok ".grepai/ added to global git excludes ($file)"
  else
    warn "could not update $file"; return 1
  fi
}

# grepai_pull MODEL — pull, waiting briefly for a just-started server.
grepai_pull() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ollama list >/dev/null 2>&1 && break
    sleep 1
  done
  run ollama pull "$1"
}

grepai_model_present() { ollama list 2>/dev/null | grep -q "^$1[[:space:]:]"; }

grepai_setup_model() {
  local model asked
  model="$(grepai_state_get GREPAI_MODEL)"
  asked="$(grepai_state_get GREPAI_ASKED)"
  if [ -z "$model" ] || [ "$asked" != yes ]; then
    if model="$(grepai_prompt)"; then
      asked=yes
    else
      model="${model:-$GREPAI_NOMIC}"
      asked=no
      skip "no terminal to ask; defaulting to $model (rerun ats in a terminal to choose)"
    fi
  fi
  if ! grepai_pull "$model"; then
    if grepai_model_present "$model"; then
      warn "$model update failed; keeping the downloaded copy"
    elif [ "$model" != "$GREPAI_NOMIC" ]; then
      warn "$model pull failed; falling back to $GREPAI_NOMIC"
      model="$GREPAI_NOMIC"; asked=yes
      grepai_pull "$model" || { warn "$model pull failed"; return 1; }
    else
      warn "$model pull failed"; return 1
    fi
  fi
  grepai_state_set "$model" "$asked" || { warn "could not record model choice"; return 1; }
  ok "embedding model: $model ($(grepai_dimensions "$model") dimensions)"
}

setup_grepai() {
  section "grepai"
  have brew || { warn "brew required to install grepai"; return 1; }
  local failed=0
  brew_ensure grepai yoanbernabeu/tap/grepai || failed=1
  brew_ensure ollama ollama || failed=1
  if have ollama; then
    run brew services start ollama || { warn "could not start Ollama service"; failed=1; }
    grepai_setup_model || failed=1
  fi
  grepai_exclude || failed=1
  if have claude && have grepai; then
    mcp_ensure claude grepai stdio grepai mcp-serve || failed=1
  fi
  return "$failed"
}
