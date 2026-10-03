import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


class InstallTests(unittest.TestCase):
    def setUp(self):
        script = Path(__file__).resolve().parents[1] / "lib/install_caveman_proxy.py"
        self.assertTrue(script.exists(), "durable Caveman installer is missing")
        spec = importlib.util.spec_from_file_location("caveman_install", script)
        self.installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.installer)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        (self.source / "source.txt").write_text("old\n")
        subprocess.run(["git", "-C", str(self.source), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-qm", "fixture"], check=True)
        self.installer.PIN = subprocess.check_output(["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True).strip()
        self.installer.ROOT = self.root / "private"
        self.installer.PATCH = self.root / "change.patch"
        self.installer.PATCH.write_text("diff --git a/source.txt b/source.txt\n--- a/source.txt\n+++ b/source.txt\n@@ -1 +1 @@\n-old\n+patched\n")
        self.builds = 0
        self.real_run = self.installer.run

    def fake_build(self, command, **kwargs):
        if command[0] != "go":
            return self.real_run(command, **kwargs)
        self.builds += 1
        self.assertEqual((Path(kwargs["cwd"]) / "source.txt").read_text(), "patched\n")
        self.assertIn("-ldflags", command)
        self.assertEqual(command[command.index("-ldflags") + 1],
                         "-X main.version=ats-size-bypass-" + self.installer.digest(self.installer.PATCH)[:12])
        binary = Path(command[command.index("-o") + 1])
        binary.write_text('#!/bin/sh\nif [ "$1" = version ]; then\nprintf \'%s\\n\' \'{"capabilities":["run_state","native_hook_bridge_v1"]}\'\nelse\nprintf \'%s\\n\' "$CAVEMAN_PROXY_BIN" "$CAVE_SSRF_ALLOWLIST" "$@"\nif [ "$#" -eq 0 ]; then printf \'proxy diagnostic\\n\' >&2; fi\nfi\n')
        binary.chmod(0o755)
        return subprocess.CompletedProcess(command, 0, "", "")

    def test_pinned_build_wrapper_and_idempotence(self):
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
            self.installer.install(self.source)
        self.assertEqual(self.builds, 1)
        wrapper = self.installer.ROOT / "caveman-proxy"
        for previous, expected in [("", "127.0.0.1:8788"),
                                   ("example.test:8080", "example.test:8080,127.0.0.1:8788"),
                                   ("example.test:8080,127.0.0.1:8788", "example.test:8080,127.0.0.1:8788")]:
            result = subprocess.check_output([str(wrapper), "one argument", "two"], text=True,
                                             env={**os.environ, "CAVE_SSRF_ALLOWLIST": previous})
            self.assertEqual(result.splitlines(), [str(wrapper), expected, "one argument", "two"])
        self.assertEqual((self.source / "source.txt").read_text(), "old\n")
        receipt = json.loads((self.installer.ROOT / "build.json").read_text())
        self.assertEqual(receipt["commit"], self.installer.PIN)
        wrapper.chmod(0o600)
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
        self.assertTrue(wrapper.stat().st_mode & 0o100)

    def test_failed_build_keeps_previous_executable_and_receipt(self):
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
        before = {path.name: path.read_bytes() for path in self.installer.ROOT.iterdir() if path.is_file()}
        self.installer.PATCH.write_text(self.installer.PATCH.read_text() + "\n")
        def fail(command, **kwargs):
            if command[0] == "go":
                raise subprocess.CalledProcessError(1, command, stderr="build failed")
            return self.real_run(command, **kwargs)
        with patch.object(self.installer, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                self.installer.install(self.source)
        for name, content in before.items():
            self.assertEqual((self.installer.ROOT / name).read_bytes(), content)

    def test_wrapper_refresh_reuses_verified_binary_without_build_or_fetch(self):
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
        wrapper = self.installer.ROOT / "caveman-proxy"
        binary = self.installer.ROOT / "caveman-proxy.bin"
        receipt = self.installer.ROOT / "build.json"
        before = (binary.read_bytes(), receipt.read_bytes())
        wrapper.write_text("#!/bin/sh\nexit 99\n")
        with patch.object(self.installer, "run", side_effect=AssertionError("unnecessary fetch/build")):
            self.installer.install()
        self.assertEqual(wrapper.read_text(), self.installer.WRAPPER)
        self.assertEqual((binary.read_bytes(), receipt.read_bytes()), before)

    def test_native_autostart_persists_server_output_privately(self):
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
        wrapper = self.installer.ROOT / "caveman-proxy"
        result = subprocess.run([str(wrapper)], check=True, capture_output=True, text=True,
                                env={**os.environ, "CAVEMAN_HOME": str(self.root / ".caveman")})
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")
        log = self.root / ".caveman/proxy.log"
        self.assertIn(str(wrapper), log.read_text())
        self.assertIn("proxy diagnostic", log.read_text())
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        previous = log.read_text()
        result = subprocess.run([str(wrapper), "serve"], check=True, capture_output=True, text=True,
                                env={**os.environ, "CAVEMAN_HOME": str(self.root / ".caveman")})
        self.assertEqual(result.stdout, "")
        self.assertTrue(log.read_text().startswith(previous))
        self.assertTrue(log.read_text().endswith("serve\n"))

    def test_wrong_commit_is_rejected_before_build(self):
        self.installer.PIN = "f" * 40
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                self.installer.install(self.source)
        self.assertEqual(self.builds, 0)
        self.assertFalse((self.installer.ROOT / "caveman-proxy").exists())

    def test_explicit_stop_blocks_native_hooks_and_server_until_resumed(self):
        with patch.object(self.installer, "run", side_effect=self.fake_build):
            self.installer.install(self.source)
        wrapper = self.installer.ROOT / "caveman-proxy"
        home = self.root / "caveman home"
        home.mkdir()
        marker = home / "ats-stopped"
        marker.touch()
        env = {**os.environ, "CAVEMAN_HOME": str(home)}
        hook = subprocess.run([str(wrapper), "native-hook", "codex"], capture_output=True, text=True, env=env)
        self.assertEqual(hook.returncode, 0)
        self.assertEqual(hook.stdout, "")
        server = subprocess.run([str(wrapper), "serve"], capture_output=True, text=True, env=env)
        self.assertNotEqual(server.returncode, 0)
        marker.unlink()
        resumed = subprocess.run([str(wrapper), "native-hook", "codex"], capture_output=True, text=True, env=env)
        self.assertEqual(resumed.returncode, 0)
        self.assertIn("native-hook", resumed.stdout)


if __name__ == "__main__":
    unittest.main()
