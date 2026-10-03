"""Exercise MCP setup against isolated registries and external CLI doubles."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
CLI = r'''
import json, os, pathlib, sys
root = pathlib.Path(os.environ["ATS_TEST_ROOT"])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name, *args]) + "\n")
if os.environ.get("ATS_TEST_FAIL") == name + ":" + " ".join(args[:2]):
    sys.exit(1)
if name in ("claude", "codex"):
    if args[:2] != ["mcp", "add"]:
        sys.exit("Setup must not probe or launch MCP servers")
    if name == "claude":
        assert args[2:4] == ["--scope", "user"]
        args = args[4:]
        if args[:2] == ["--transport", "http"]:
            entry = {"type": "http", "url": args[3]}
            server = args[2]
        else:
            server = args[0]
            assert args[1] == "--"
            entry = {"type": "stdio", "command": args[2], "args": args[3:]}
        path = root / "claude.json"
        data = json.loads(path.read_text()) if path.exists() else {}
        data.setdefault("mcpServers", {})[server] = entry
        path.write_text(json.dumps(data))
    else:
        server = args[2]
        if args[3] == "--url":
            entry = "url = " + json.dumps(args[4])
        else:
            assert args[3] == "--"
            entry = "command = " + json.dumps(args[4]) + "\nargs = " + json.dumps(args[5:])
        with (root / "codex.toml").open("a") as stream:
            stream.write("\n[mcp_servers." + server + "]\n" + entry + "\n")
elif name == "uv":
    if args == ["tool", "list"]:
        if (root / "managed").exists():
            print("serena-agent v1.0.0\n- serena")
    elif args == ["tool", "dir", "--bin"]:
        print(root / "tools with spaces")
    elif args in (["tool", "install", "--python", "3.13", "serena-agent"],
                  ["tool", "upgrade", "serena-agent"]):
        (root / "managed").touch()
        target = root / "tools with spaces" / "serena"
        target.parent.mkdir(exist_ok=True)
        if not target.exists():
            target.symlink_to(root / "cli")
    else:
        sys.exit("Unexpected uv arguments: " + repr(args))
elif name == "serena":
    assert args == ["init"], "Setup must not start Serena's MCP server"
    target = pathlib.Path(os.environ["SERENA_HOME"]) / "serena_config.yml"
    target.parent.mkdir(exist_ok=True)
    target.write_text("language_backend: LSP\n")
'''


class MCPSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ats-mcp-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        cli = self.root / "cli"
        cli.write_text(f"#!{sys.executable}\n" + CLI)
        cli.chmod(0o755)
        for name in ("claude", "codex", "uv"):
            (self.bin / name).symlink_to(cli)
        self.env = dict(os.environ, ATS_TEST_ROOT=str(self.root),
                        SERENA_HOME=str(self.root / "serena-home"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        self.agents = "claude codex"
        self.missing = ""

    def setup(self, module, repetitions=1):
        script = r'''
set -uo pipefail
SCRIPT_DIR="$1"
source "$SCRIPT_DIR/lib/common.sh"
have() {
  case " $ATS_TEST_MISSING " in *" $1 "*) return 1 ;; esac
  case "$1" in
    claude|codex) case " $ATS_TEST_AGENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac ;;
    serena) [ -x "$ATS_TEST_ROOT/bin/serena" ] ;;
    *) command -v "$1" >/dev/null ;;
  esac
}
with_timeout() { shift; "$@"; }
source "$SCRIPT_DIR/lib/mcp.sh"
source "$SCRIPT_DIR/lib/$2.sh"
mcp_user_config() {
  case "$1" in
    claude) printf '%s/claude.json\n' "$ATS_TEST_ROOT" ;;
    codex) printf '%s/codex.toml\n' "$ATS_TEST_ROOT" ;;
  esac
}
for ((attempt=0; attempt<$3; attempt++)); do "setup_$2"; done
'''
        env = dict(self.env, ATS_TEST_AGENTS=self.agents, ATS_TEST_MISSING=self.missing)
        return subprocess.run(["bash", "-c", script, "ats-test", str(REPO), module,
                               str(repetitions)], env=env, text=True, capture_output=True,
                              timeout=15)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def assert_ready(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_context7_registers_remote_mcp_for_both_agents_once(self):
        self.assert_ready(self.setup("context7", repetitions=2))
        self.assertEqual(self.calls(), [
            ["claude", "mcp", "add", "--scope", "user", "--transport", "http", "context7",
             "https://mcp.context7.com/mcp"],
            ["codex", "mcp", "add", "context7", "--url", "https://mcp.context7.com/mcp"],
        ])

    def test_context7_only_registers_installed_agents(self):
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                self.agents = agent
                self.assert_ready(self.setup("context7"))
        self.assertEqual([call[0] for call in self.calls()], ["claude", "codex"])

    def test_no_agents_skips_dependency_checks_and_installation(self):
        self.agents = ""
        self.missing = "python3 uv"
        for module in ("context7", "serena"):
            self.assert_ready(self.setup(module))
        self.assertEqual(self.calls(), [])

    def test_existing_custom_registrations_preserved_byte_for_byte(self):
        claude = '{"mcpServers":{"context7":{"url":"https://custom.invalid","headers":{"key":"secret"}}}}\n'
        codex = '[mcp_servers.context7]\ncommand = "custom"\nargs = ["--private"]\n'
        (self.root / "claude.json").write_text(claude)
        (self.root / "codex.toml").write_text(codex)
        self.assert_ready(self.setup("context7"))
        self.assertEqual((self.root / "claude.json").read_text(), claude)
        self.assertEqual((self.root / "codex.toml").read_text(), codex)
        self.assertEqual(self.calls(), [])

    def test_invalid_registry_preserved_other_agent_still_registered(self):
        for bad_agent, path, value in (("claude", "claude.json", "{broken"),
                                       ("codex", "codex.toml", "[broken")):
            with self.subTest(agent=bad_agent):
                for filename in ("claude.json", "codex.toml", "calls.jsonl"):
                    (self.root / filename).unlink(missing_ok=True)
                (self.root / path).write_text(value)
                result = self.setup("context7")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.root / path).read_text(), value)
                self.assertEqual(len(self.calls()), 1)
                self.assertNotEqual(self.calls()[0][0], bad_agent)

    def test_invalid_registry_shape_cannot_trigger_registration(self):
        (self.root / "claude.json").write_text('{"mcpServers": []}')
        self.agents = "claude"
        self.assertNotEqual(self.setup("context7").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_missing_python_does_not_claim_registration(self):
        self.missing = "python3"
        result = self.setup("context7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python", result.stdout.lower())
        self.assertEqual(self.calls(), [])

    def test_registration_failure_still_attempts_other_agent(self):
        self.env["ATS_TEST_FAIL"] = "claude:mcp add"
        result = self.setup("context7")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed", result.stdout)
        self.assertFalse((self.root / "claude.json").exists())
        self.assertTrue((self.root / "codex.toml").exists())

    def test_serena_installs_initializes_and_uses_agent_contexts(self):
        self.assert_ready(self.setup("serena"))
        runtime = str(self.root / "tools with spaces" / "serena")
        self.assertEqual(self.calls(), [
            ["uv", "tool", "list"],
            ["uv", "tool", "install", "--python", "3.13", "serena-agent"],
            ["uv", "tool", "dir", "--bin"],
            ["serena", "init"],
            ["claude", "mcp", "add", "--scope", "user", "serena", "--", runtime,
             "start-mcp-server", "--context", "claude-code", "--project-from-cwd",
             "--open-web-dashboard", "False"],
            ["codex", "mcp", "add", "serena", "--", runtime,
             "start-mcp-server", "--context", "codex", "--project-from-cwd",
             "--open-web-dashboard", "False"],
        ])

    def test_serena_upgrade_preserves_backend_and_registration(self):
        self.assert_ready(self.setup("serena"))
        config = Path(self.env["SERENA_HOME"]) / "serena_config.yml"
        config.write_text("language_backend: JetBrains\n")
        (self.root / "calls.jsonl").unlink()
        claude = (self.root / "claude.json").read_bytes()
        codex = (self.root / "codex.toml").read_bytes()
        self.assert_ready(self.setup("serena"))
        self.assertEqual(self.calls(), [["uv", "tool", "list"],
                                        ["uv", "tool", "upgrade", "serena-agent"],
                                        ["uv", "tool", "dir", "--bin"]])
        self.assertEqual(config.read_text(), "language_backend: JetBrains\n")
        self.assertEqual((self.root / "claude.json").read_bytes(), claude)
        self.assertEqual((self.root / "codex.toml").read_bytes(), codex)

    def test_serena_missing_uv_fails_without_registrations(self):
        self.missing = "uv"
        self.assertNotEqual(self.setup("serena").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_serena_install_failure_prevents_init_and_registration(self):
        self.env["ATS_TEST_FAIL"] = "uv:tool install"
        self.assertNotEqual(self.setup("serena").returncode, 0)
        self.assertFalse(any(call[0] != "uv" for call in self.calls()))

    def test_serena_upgrade_failure_preserves_existing_setup(self):
        self.assert_ready(self.setup("serena"))
        paths = [self.root / "claude.json", self.root / "codex.toml",
                 Path(self.env["SERENA_HOME"]) / "serena_config.yml"]
        previous = [path.read_bytes() for path in paths]
        self.env["ATS_TEST_FAIL"] = "uv:tool upgrade"
        (self.root / "calls.jsonl").unlink()
        self.assertNotEqual(self.setup("serena").returncode, 0)
        self.assertEqual([path.read_bytes() for path in paths], previous)
        self.assertFalse(any(call[0] != "uv" for call in self.calls()))

    def test_serena_failed_tool_inspection_does_not_install(self):
        self.env["ATS_TEST_FAIL"] = "uv:tool list"
        self.assertNotEqual(self.setup("serena").returncode, 0)
        self.assertEqual(self.calls(), [["uv", "tool", "list"]])

    def test_serena_init_failure_prevents_registration(self):
        self.env["ATS_TEST_FAIL"] = "serena:init"
        self.assertNotEqual(self.setup("serena").returncode, 0)
        self.assertFalse(any(call[0] in ("claude", "codex") for call in self.calls()))

    def test_unmanaged_serena_preserved_and_used_without_uv(self):
        (self.bin / "serena").symlink_to(self.root / "cli")
        self.missing = "uv"
        self.agents = "codex"
        self.assert_ready(self.setup("serena"))
        self.assertFalse(any(call[0] == "uv" for call in self.calls()))
        self.assertEqual(self.calls()[-1][5], str(self.bin / "serena"))
        self.assertEqual([call[0] for call in self.calls()], ["serena", "codex"])


if __name__ == "__main__":
    unittest.main()
