#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile


script = Path(__file__).resolve().parents[1] / "lib/evolver_codex_hooks.py"
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    original = """[features]
hooks = true

[[hooks.SessionStart]]
matcher = "startup|resume"

[[hooks.SessionStart.hooks]]
type = "command"
command = "evolver inject session-start --hook-stdin"
statusMessage = "evolver-managed-hook"

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "evolver inject prompt-recall --hook-stdin"
timeout = 5
statusMessage = "evolver-managed-hook"

[desktop]
enabled = true
"""
    (root / "config.toml").write_text(original)
    (root / "hooks.json").write_text('{"hooks":{"Stop":[{"hooks":[{"command":"other"}]}]}}')
    subprocess.run(["python3", str(script), str(root)], check=True)
    config = (root / "config.toml").read_text()
    hooks = json.loads((root / "hooks.json").read_text())["hooks"]
    assert "evolver-managed-hook" not in config
    assert "[features]" in config and "[desktop]" in config
    assert hooks["Stop"][0]["hooks"][0]["command"] == "other"
    assert hooks["SessionStart"][0]["hooks"][0]["command"].startswith("if /bin/ps -o lstart=")
    assert hooks["UserPromptSubmit"][0]["hooks"][0]["command"].endswith("evolver inject prompt-recall --hook-stdin")
    assert (root / "config.toml.ats-backup").read_text() == original
    subprocess.run(["python3", str(script), str(root)], check=True)
    assert len(json.loads((root / "hooks.json").read_text())["hooks"]["SessionStart"]) == 1
