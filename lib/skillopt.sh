#!/usr/bin/env bash
# SkillOpt's shared engine, Claude Code plugin, and official Codex skill.
# Installation does not harvest sessions, run optimization, schedule, or adopt.

skillopt_checkout() {
  local repo="$1" origin root changes upstream target migrate=no
  local fork=https://github.com/DeveloperBeau/SkillOpt.git
  if [ ! -e "$repo" ]; then
    mkdir -p "$(dirname "$repo")" || return 1
    run with_timeout 120 env GIT_TERMINAL_PROMPT=0 git clone --quiet --branch main --single-branch \
      "$fork" "$repo" || return 1
  else
    root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
      warn "SkillOpt path is not a checkout; preserved: $repo"; return 1;
    }
    [ "$root" = "$repo" ] || { warn "SkillOpt path belongs to another checkout; preserved"; return 1; }
    origin="$(git -C "$repo" remote get-url origin 2>/dev/null)" || return 1
    case "${origin%.git}" in
      https://github.com/microsoft/SkillOpt|git@github.com:microsoft/SkillOpt|ssh://git@github.com/microsoft/SkillOpt) migrate=yes ;;
      https://github.com/DeveloperBeau/SkillOpt|git@github.com:DeveloperBeau/SkillOpt|ssh://git@github.com/DeveloperBeau/SkillOpt) ;;
      *) warn "SkillOpt checkout has another origin; preserved: $repo"; return 1 ;;
    esac
    changes="$(git -C "$repo" status --porcelain)" || return 1
    if [ -n "$changes" ] || [ "$(git -C "$repo" branch --show-current)" != main ]; then
      warn "SkillOpt checkout has local changes or another branch; preserved: $repo"
      return 1
    fi
    target=origin/main
    if [ "$migrate" = yes ]; then
      upstream="$(git -C "$repo" remote get-url upstream 2>/dev/null)" || upstream=
      case "${upstream%.git}" in
        ''|https://github.com/microsoft/SkillOpt|git@github.com:microsoft/SkillOpt|ssh://git@github.com/microsoft/SkillOpt) ;;
        *) warn "SkillOpt upstream has another source; preserved: $repo"; return 1 ;;
      esac
      # Fetch without changing origin or its tracking ref until migration is safe.
      with_timeout 60 env GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet "$fork" main || return 1
      target=FETCH_HEAD
    else
      with_timeout 60 env GIT_TERMINAL_PROMPT=0 git -C "$repo" fetch --quiet origin main || return 1
    fi
    if ! git -C "$repo" merge-base --is-ancestor HEAD "$target"; then
      warn "SkillOpt checkout has local commits; preserved: $repo"
      return 1
    fi
    run git -C "$repo" merge --ff-only --quiet "$target" || return 1
    if [ "$migrate" = yes ]; then
      if [ -z "$upstream" ]; then
        run git -C "$repo" remote add upstream https://github.com/microsoft/SkillOpt.git || return 1
      fi
      run git -C "$repo" remote set-url origin "$fork" || return 1
      git -C "$repo" update-ref refs/remotes/origin/main HEAD || return 1
    fi
  fi
  [ -f "$repo/pyproject.toml" ] && [ -f "$repo/plugins/run-sleep.sh" ] &&
    [ -f "$repo/plugins/codex/skills/skillopt-sleep/SKILL.md" ] &&
    [ -f "$repo/plugins/claude-code/.claude-plugin/marketplace.json" ]
}

skillopt_ensure_claude() {
  local repo="$1" config_dir state installed
  config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  state="$(python3 - "$config_dir/plugins/known_marketplaces.json" "$repo/plugins/claude-code" <<'PY'
import json, pathlib, sys
path, expected = map(pathlib.Path, sys.argv[1:])
try:
    entry = json.loads(path.read_text()).get("skillopt-sleep") if path.exists() else None
    source = entry.get("source", {}) if entry else {}
    matches = source.get("source") == "directory" and pathlib.Path(source.get("path", "")).resolve() == expected.resolve()
    print("missing" if entry is None else "match" if matches else "conflict")
except (OSError, ValueError, TypeError, AttributeError):
    print("conflict")
PY
)" || { warn "Claude Code SkillOpt marketplace check failed"; return 0; }
  case "$state" in
    missing)
      if ! run with_timeout 120 claude plugin marketplace add "$repo/plugins/claude-code"; then
        warn "Claude Code SkillOpt marketplace add failed; continuing"
        return 0
      fi ;;
    match)
      if ! run with_timeout 120 claude plugin marketplace update skillopt-sleep; then
        warn "Claude Code SkillOpt marketplace update failed; continuing"
        return 0
      fi ;;
    *) warn "Claude Code SkillOpt marketplace has another source or invalid registry; preserved"; return 0 ;;
  esac
  installed="$(python3 - "$config_dir/plugins/installed_plugins.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    entries = json.loads(path.read_text()).get("plugins", {}).get("skillopt-sleep@skillopt-sleep", []) if path.exists() else []
    print("yes" if any(entry.get("scope") == "user" for entry in entries) else "no")
except (OSError, ValueError, TypeError, AttributeError):
    print("no")
PY
)"
  local action=install
  [ "$installed" = yes ] && action=update
  if run with_timeout 120 claude plugin "$action" skillopt-sleep@skillopt-sleep --scope user; then
    ok "Claude Code SkillOpt plugin ready"
  else
    warn "Claude Code SkillOpt plugin $action failed; continuing"
  fi
}

skillopt_ensure_codex() {
  local repo="$1" interpreter="$2"
  if python3 - "$repo" "$interpreter" "$HOME/.agents/skills/skillopt-sleep/SKILL.md" <<'PY'
import os, pathlib, shlex, shutil, sys, tempfile
repo, interpreter, target = sys.argv[1:]
target = pathlib.Path(target)
source = pathlib.Path(repo) / "plugins/codex/skills/skillopt-sleep/SKILL.md"
text = source.read_text()
marker = "export SKILLOPT_SLEEP_REPO=/path/to/SkillOpt"
if text.count(marker) != 1:
    raise SystemExit("SkillOpt's Codex skill changed; expected repository placeholder missing")
text = text.replace(marker, "export SKILLOPT_SLEEP_REPO=" + shlex.quote(repo) + "\nexport SKILLOPT_SLEEP_PYTHON=" + shlex.quote(interpreter))
target.parent.mkdir(parents=True, exist_ok=True)
if target.exists() and target.read_text() == text:
    raise SystemExit(0)
if target.exists() or target.is_symlink():
    fd, backup = tempfile.mkstemp(prefix="SKILL.md.backup-", dir=target.parent)
    os.close(fd)
    os.unlink(backup)
    shutil.copy2(target, backup, follow_symlinks=False)
    print("Preserved previous skill: " + backup)
fd, temporary = tempfile.mkstemp(prefix=".SKILL.md-", dir=target.parent)
try:
    with os.fdopen(fd, "w") as stream:
        stream.write(text)
    os.replace(temporary, target)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
  then
    ok "Codex SkillOpt skill ready"
  else
    warn "Codex SkillOpt skill install failed; continuing"
  fi
}

setup_skillopt() {
  section "skillopt"
  if ! have claude && ! have codex; then
    skip "Claude Code and Codex not installed"
    return 0
  fi
  if ! have git || ! have uv || ! have python3; then
    warn "SkillOpt needs git, uv, and python3; continuing"
    return 0
  fi
  local repo tools_dir
  repo="${SKILLOPT_SLEEP_REPO:-$HOME/.local/share/skillopt}"
  # Resolve without requiring the destination to exist, including spaces/symlinks.
  repo="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$repo")" || return 0
  if ! skillopt_checkout "$repo"; then
    warn "SkillOpt checkout unavailable; continuing"
    return 0
  fi
  if ! run with_timeout 300 uv tool install --force --python 3.13 --editable "$repo"; then
    warn "SkillOpt engine install failed; continuing"
    return 0
  fi
  tools_dir="$(uv tool dir)" || { warn "SkillOpt tool directory unavailable; continuing"; return 0; }
  if [ ! -x "$tools_dir/skillopt/bin/python" ]; then
    warn "SkillOpt installed interpreter unavailable; continuing"
    return 0
  fi
  if have claude; then skillopt_ensure_claude "$repo"; fi
  if have codex; then skillopt_ensure_codex "$repo" "$tools_dir/skillopt/bin/python"; fi
  return 0
}
