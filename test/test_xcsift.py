#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
import xcsift  # noqa: E402

# rewrite: build commands get piped, anything else is left alone.
assert xcsift.rewrite("xcodebuild -scheme App build") == \
    "set -o pipefail && xcodebuild -scheme App build 2>&1 | xcsift -f toon -w"
assert xcsift.rewrite("cd App && swift test") == \
    "set -o pipefail && cd App && swift test 2>&1 | xcsift -f toon -w"
for untouched in ["swift package resolve", "xcodebuild build | tail", "xcodebuild build 2>&1",
                  "xcodebuild build | xcbeautify", "rm -rf x && xcodebuild build",
                  "xcodebuild build; rm x", "xcodebuild build &", "echo $(xcodebuild)", "git status"]:
    assert xcsift.rewrite(untouched) is None, untouched

script = Path(xcsift.__file__)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)

    def hook(command, path):
        payload = json.dumps({"tool_input": {"command": command, "description": "d"}})
        out = subprocess.run([sys.executable, script, "hook"], input=payload, capture_output=True,
                             text=True, check=True, env={**os.environ, "PATH": path}).stdout
        return json.loads(out)

    # Missing xcsift must not swallow build output.
    assert hook("xcodebuild build", str(root)) == {}
    (root / "xcsift").write_text("#!/bin/sh\n")
    (root / "xcsift").chmod(0o755)
    result = hook("xcodebuild build", str(root))["hookSpecificOutput"]
    assert "permissionDecision" not in result
    assert result["updatedInput"] == {"command": xcsift.rewrite("xcodebuild build"), "description": "d"}

    # install: preserves existing hooks and settings, idempotent.
    settings, rtk = root / "settings.json", root / "rtk/config.toml"
    settings.write_text(json.dumps({"model": "x", "hooks": {"PreToolUse": [
        {"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]}}))
    rtk.parent.mkdir()
    rtk.write_text('[tracking]\nenabled = true\n\n[hooks]\nexclude_commands = ["curl"]\ntransparent_prefixes = []\n')
    xcsift.install(settings, rtk)
    first = (settings.read_text(), rtk.read_text())
    xcsift.install(settings, rtk)
    assert (settings.read_text(), rtk.read_text()) == first
    data = json.loads(first[0])
    assert data["model"] == "x"
    commands = [h["command"] for e in data["hooks"]["PreToolUse"] for h in e["hooks"]]
    assert commands[0] == "rtk hook claude" and commands[1].endswith("xcsift.py hook"), commands
    config = tomllib.loads(first[1])
    assert config["hooks"]["exclude_commands"] == ["curl", "xcodebuild", "swift build", "swift test"]
    assert config["tracking"]["enabled"] and config["hooks"]["transparent_prefixes"] == []

    # A moved checkout updates the hook path instead of adding a second entry.
    data["hooks"]["PreToolUse"][1]["hooks"][0]["command"] = "python3 /old/lib/xcsift.py hook"
    settings.write_text(json.dumps(data))
    xcsift.install(settings, rtk)
    assert json.loads(settings.read_text()) == json.loads(first[0])

    # Missing files: both are created.
    xcsift.install(root / "new/settings.json", root / "new/rtk.toml")
    assert tomllib.loads((root / "new/rtk.toml").read_text())["hooks"]["exclude_commands"] == list(xcsift.RTK_EXCLUDES)
    assert "xcsift.py" in (root / "new/settings.json").read_text()
