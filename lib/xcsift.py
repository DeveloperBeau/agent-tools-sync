#!/usr/bin/env python3
"""Claude Code PreToolUse hook that pipes Xcode build output through xcsift.

`xcsift.py hook` reads the hook payload on stdin. `xcsift.py install SETTINGS
RTK_CONFIG` registers the hook and hands the build commands from rtk's hook to
this one: both hooks run in parallel on the same command, so only one rewrite
can win.
"""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile


BUILD = re.compile(r"^(xcodebuild|swift\s+(build|test))\b")
FILTERS = ("xcsift", "xcbeautify", "xcpretty")
UNSAFE = re.compile(r"[|;<>`\n]|\$\(|(?<!&)&(?!&)")
RTK_EXCLUDES = ("xcodebuild", "swift build", "swift test")


def rewrite(command):
    """Return a rewritten command, or None if it should be left untouched."""
    if any(f in command for f in FILTERS) or UNSAFE.search(command):
        return None
    *prefix, build = [part.strip() for part in command.split("&&")]
    if not BUILD.match(build) or any(not p.startswith("cd ") for p in prefix):
        return None
    steps = prefix + [f"{build} 2>&1 | xcsift -f toon -w"]
    return "set -o pipefail && " + " && ".join(steps)


def hook():
    tool_input = json.load(sys.stdin).get("tool_input", {})
    # Without xcsift the pipe would swallow every line of build output.
    command = shutil.which("xcsift") and rewrite(tool_input.get("command", "").strip())
    if not command:
        print("{}")
        return
    # No permissionDecision: the rewrite must not bypass the user's permission mode.
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecisionReason": "Piping build output through xcsift",
        "updatedInput": {**tool_input, "command": command},
    }}))


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        file.write(content)
        temporary = Path(file.name)
    if path.exists():
        os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def ensure_settings(path, command):
    """Point the Bash PreToolUse entry at COMMAND. Return True if changed."""
    settings = json.loads(path.read_text()) if path.exists() else {}
    entries = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
    ours = [item for entry in entries for item in entry.get("hooks", [])
            if "xcsift.py" in item.get("command", "")]
    if ours and all(item["command"] == command for item in ours):
        return False
    for item in ours:
        item["command"] = command
    if not ours:
        entries.append({"matcher": "Bash", "hooks": [{"type": "command", "command": command, "timeout": 5}]})
    write_atomic(path, json.dumps(settings, indent=2) + "\n")
    return True


def ensure_rtk_excludes(path):
    """Add RTK_EXCLUDES to [hooks].exclude_commands. Return True if changed."""
    import tomllib

    text = path.read_text() if path.exists() else ""
    current = tomllib.loads(text).get("hooks", {}).get("exclude_commands", [])
    missing = [c for c in RTK_EXCLUDES if c not in current]
    if not missing:
        return False
    line = "exclude_commands = " + json.dumps(current + missing)
    pattern = re.compile(r"^exclude_commands\s*=\s*\[[^\]\n]*\]\s*$", re.M)
    if pattern.search(text):
        text = pattern.sub(lambda _: line, text, count=1)
    elif "exclude_commands" in text:
        raise SystemExit(f"{path}: multi-line exclude_commands, add {missing} by hand")
    elif re.search(r"^\[hooks\]\s*$", text, re.M):
        text = re.sub(r"^\[hooks\]\s*$", lambda m: m.group(0) + "\n" + line, text, count=1, flags=re.M)
    else:
        text = text.rstrip("\n") + ("\n\n" if text else "") + "[hooks]\n" + line + "\n"
    write_atomic(path, text)
    return True


def install(settings, rtk_config):
    command = "python3 " + shlex.quote(str(Path(__file__).resolve())) + " hook"
    if ensure_settings(Path(settings), command):
        print("Claude Code hook registered")
    if ensure_rtk_excludes(Path(rtk_config)):
        print("rtk hook now skips " + ", ".join(RTK_EXCLUDES))


if __name__ == "__main__":
    if sys.argv[1:2] == ["hook"]:
        hook()
    elif sys.argv[1:2] == ["install"] and len(sys.argv) == 4:
        install(*sys.argv[2:])
    else:
        raise SystemExit("usage: xcsift.py hook | install SETTINGS RTK_CONFIG")
