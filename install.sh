#!/usr/bin/env bash
# Bootstrap ATS on macOS. Run from a terminal so Homebrew and the agent
# selection prompts can use the controlling terminal.
set -euo pipefail

REPO_URL="https://github.com/DeveloperBeau/agent-tools-sync.git"
CHECKOUT="$HOME/.local/share/agent-tools-sync"
BIN="$HOME/.local/bin/agent-tools-sync"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

ask_agent() {
  local answer
  while :; do
    printf 'Install %s? [y/N] ' "$1" >&2
    IFS= read -r answer <&3 || die "could not read terminal"
    case "$answer" in
      y|Y|[Yy][Ee][Ss]) return 0 ;;
      ''|n|N|[Nn][Oo]) return 1 ;;
      *) printf 'Enter y or n.\n' >&2 ;;
    esac
  done
}

find_brew() {
  if command -v brew >/dev/null 2>&1; then command -v brew
  elif [ -x /opt/homebrew/bin/brew ]; then printf '%s\n' /opt/homebrew/bin/brew
  elif [ -x /usr/local/bin/brew ]; then printf '%s\n' /usr/local/bin/brew
  fi
  return 0
}

ensure_brew() {
  local brew_bin installer
  brew_bin="$(find_brew)"
  if [ -z "$brew_bin" ]; then
    printf 'Installing Homebrew...\n'
    installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    /bin/bash -c "$installer"
    brew_bin="$(find_brew)"
    [ -n "$brew_bin" ] || die "Homebrew installed but brew was not found"
  fi
  eval "$("$brew_bin" shellenv)"
}

ensure_command() {
  local command_name="$1" package="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    brew install "$package"
  fi
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name unavailable after installing $package"
}

install_agent() {
  local command_name="$1" cask="$2" label="$3"
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%s already installed.\n' "$label"
  elif ask_agent "$label"; then
    brew install --cask "$cask"
    command -v "$command_name" >/dev/null 2>&1 || die "$label unavailable after installation"
  fi
}

main() {
  [ "$(uname -s)" = Darwin ] || die "macOS required"
  [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root"
  exec 3</dev/tty || die "interactive terminal required"

  ensure_brew
  ensure_command git git
  if ! command -v node >/dev/null 2>&1 ||
     ! command -v npm >/dev/null 2>&1 ||
     ! command -v npx >/dev/null 2>&1; then
    brew install node
  fi
  command -v npm >/dev/null 2>&1 || die "npm unavailable after installing Node.js"
  command -v npx >/dev/null 2>&1 || die "npx unavailable after installing Node.js"
  ensure_command python3 python
  ensure_command uv uv
  ensure_command bun bun

  install_agent claude claude-code "Claude Code"
  install_agent codex codex "Codex"

  mkdir -p "$HOME/.local/bin" "$HOME/.local/share"
  if [ ! -e "$CHECKOUT" ]; then
    git clone "$REPO_URL" "$CHECKOUT"
  else
    [ -d "$CHECKOUT/.git" ] || die "$CHECKOUT exists but is not a Git checkout"
    case "$(git -C "$CHECKOUT" remote get-url origin)" in
      "$REPO_URL"|git@github.com:DeveloperBeau/agent-tools-sync.git) ;;
      *) die "$CHECKOUT has unexpected Git origin" ;;
    esac
  fi
  if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$CHECKOUT/agent-tools-sync.sh" ]; then
    :
  elif [ -e "$BIN" ] || [ -L "$BIN" ]; then
    die "$BIN already exists; remove it manually before installing ATS"
  else
    ln -s "$CHECKOUT/agent-tools-sync.sh" "$BIN"
  fi
  if ! grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.zprofile" 2>/dev/null; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.zprofile"
  fi
  export PATH="$HOME/.local/bin:$PATH"
  "$BIN"
  printf '\nInstalled ATS. Open a new terminal, then run agent-tools-sync anytime.\n'
}

main "$@"
