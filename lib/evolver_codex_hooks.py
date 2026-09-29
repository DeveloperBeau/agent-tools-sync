#!/usr/bin/env python3
"""Keep Evolver's Codex hooks in hooks.json alongside other user hooks."""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile


HOOKS = {
    "SessionStart": ("startup|resume", "session-start"),
    "UserPromptSubmit": ("", "prompt-recall"),
}


def write_atomic(path, content):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        file.write(content)
        temporary = Path(file.name)
    if path.exists():
        os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def remove_managed_toml_hooks(content):
    lines = content.splitlines(keepends=True)
    result = []
    index = 0
    while index < len(lines):
        match = re.fullmatch(r"\[\[hooks\.(SessionStart|UserPromptSubmit)\]\]\s*", lines[index])
        if not match:
            result.append(lines[index])
            index += 1
            continue
        event = match.group(1)
        end = index + 1
        while end < len(lines):
            line = lines[end]
            if line.startswith("[") and not line.startswith(f"[[hooks.{event}.hooks]]"):
                break
            end += 1
        block = lines[index:end]
        if 'statusMessage = "evolver-managed-hook"' not in "".join(block):
            result.extend(block)
        index = end
    return "".join(result)


def main(directory):
    hooks_path = directory / "hooks.json"
    config_path = directory / "config.toml"
    data = json.loads(hooks_path.read_text()) if hooks_path.exists() else {"hooks": {}}
    events = data.setdefault("hooks", {})
    executable = shutil.which("evolver") or "evolver"
    for event, (matcher, action) in HOOKS.items():
        command = f"{shlex.quote(executable)} inject {action} --hook-stdin"
        if event == "SessionStart":
            # ponytail: Codex sandbox blocks ps; skip this hook until Evolver supports sandbox process identity.
            command = f"if /bin/ps -o lstart= -p $$ >/dev/null 2>&1; then {command}; fi"
        entries = events.setdefault(event, [])
        existing = next(
            (hook for entry in entries for hook in entry.get("hooks", [])
             if hook.get("statusMessage") == "evolver-managed-hook"
             and f"inject {action} --hook-stdin" in hook.get("command", "")),
            None,
        )
        if existing is not None:
            existing["command"] = command
            continue
        hook = {"type": "command", "command": command, "statusMessage": "evolver-managed-hook"}
        if event == "UserPromptSubmit":
            hook["timeout"] = 5
        entries.append({"matcher": matcher, "hooks": [hook]})
    encoded = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if not hooks_path.exists() or hooks_path.read_text() != encoded:
        write_atomic(hooks_path, encoded)

    if config_path.exists():
        original = config_path.read_text()
        cleaned = remove_managed_toml_hooks(original)
        if cleaned != original:
            backup = config_path.with_name("config.toml.ats-backup")
            if not backup.exists():
                shutil.copy2(config_path, backup)
            write_atomic(config_path, cleaned)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
