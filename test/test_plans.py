"""Shared plan routing must preserve user configuration and existing notes."""

import json
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "lib/plans.py"


class PlansTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.vault = self.root / "shared vault"
        self.project = self.root / "code" / "Example"
        self.project.mkdir(parents=True)
        self.home.mkdir()

    def run_cli(self, action, payload=None, *extra):
        command = [sys.executable, str(SCRIPT), action, "--vault", str(self.vault)]
        if action == "install":
            command += ["--home", str(self.home), "--agents", "claude", "codex"]
        else:
            command += ["--agent", "codex"]
        result = subprocess.run(
            command + list(extra),
            input=json.dumps(payload or {}),
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout or "{}")

    def stop(
        self,
        body="<proposed_plan>\n# Better routing\n\n1. Route plans.\n</proposed_plan>",
    ):
        return {
            "hook_event_name": "Stop",
            "cwd": str(self.project),
            "session_id": "session-1",
            "turn_id": "turn-1",
            "last_assistant_message": body,
        }

    def test_install_keeps_custom_settings_and_other_hooks_and_is_idempotent(self):
        claude = self.home / ".claude"
        codex = self.home / ".codex"
        claude.mkdir()
        codex.mkdir()
        custom = {
            "env": {"KEEP": "yes"},
            "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "echo custom"}]}]
            },
        }
        (claude / "settings.json").write_text(json.dumps(custom))
        (codex / "config.toml").write_text(
            'model = "kept"\n[sandbox_workspace_write]\nwritable_roots = [\n  "/kept",\n]\n[features]\nhooks = true\n'
        )
        self.run_cli("install")
        settings = json.loads((claude / "settings.json").read_text())
        self.assertEqual(settings["env"], custom["env"])
        self.assertEqual(settings["hooks"]["Stop"][0], custom["hooks"]["Stop"][0])
        self.assertIn(str(self.vault), settings["permissions"]["additionalDirectories"])
        config = tomllib.loads((codex / "config.toml").read_text())
        self.assertEqual(config["model"], "kept")
        self.assertEqual(
            config["sandbox_workspace_write"]["writable_roots"],
            ["/kept", str(self.vault)],
        )
        self.assertIn(str(self.vault), (codex / "AGENTS.md").read_text())
        before = [
            (path, path.read_bytes())
            for path in [
                claude / "settings.json",
                codex / "hooks.json",
                codex / "AGENTS.md",
                codex / "config.toml",
            ]
        ]
        self.run_cli("install")
        self.assertTrue(all(path.read_bytes() == text for path, text in before))

    def test_native_claude_plans_move_without_losing_content(self):
        native = self.home / ".claude/plans"
        native.mkdir(parents=True)
        (native / "old.md").write_text("Existing native plan.\n")
        self.run_cli("install")
        self.assertTrue(native.is_symlink())
        self.assertEqual((native / "old.md").read_text(), "Existing native plan.\n")
        self.assertTrue(native.resolve().is_relative_to(self.vault))

    def test_codex_proposed_plan_saved_once_and_linked_without_repo_files(self):
        self.run_cli("install")
        self.run_cli("hook", self.stop())
        self.run_cli("hook", self.stop())
        plans = list((self.vault / "Example").glob("*-plan.md"))
        self.assertEqual(len(plans), 1)
        self.assertIn("# Better routing", plans[0].read_text())
        self.assertIn('agent: "codex"', plans[0].read_text())
        self.assertIn("[[", (self.vault / "Example/_Plans.md").read_text())
        self.assertIn("Example/_Plans", (self.vault / "Plans Home.md").read_text())
        self.assertEqual(list(self.project.iterdir()), [])

    def test_regular_answer_not_saved_as_plan(self):
        self.run_cli("install")
        self.run_cli("hook", self.stop("Work completed. Two tests passed."))
        self.assertFalse(list(self.vault.glob("Example/*-plan.md")))

    def test_claude_exit_plan_mode_captures_approved_markdown(self):
        self.run_cli("install")
        payload = {
            "hook_event_name": "PostToolUse",
            "cwd": str(self.project),
            "session_id": "claude-session",
            "tool_name": "ExitPlanMode",
            "tool_response": {"plan": "# Approved plan\n\n1. Build it."},
        }
        self.run_cli("hook", payload, "--agent", "claude")
        plans = list((self.vault / "Example").glob("*-plan.md"))
        self.assertEqual(len(plans), 1)
        self.assertIn('status: "approved"', plans[0].read_text())

    def test_existing_notes_and_user_indexes_are_preserved(self):
        folder = self.vault / "OldProject"
        folder.mkdir(parents=True)
        note = folder / "2026-09-01-existing-spec.md"
        note.write_text("---\nproject: OldProject\n---\n# Handwritten knowledge\n")
        index = folder / "_Plans.md"
        index.write_text("My custom index.\n")
        before = note.read_bytes()
        self.run_cli("install")
        self.assertEqual(note.read_bytes(), before)
        self.assertEqual(index.read_text(), "My custom index.\n")
        self.assertTrue((folder / "_ATS Plans.md").exists())
        self.assertTrue((self.vault / "Plans.base").exists())

    def test_hooks_index_non_utf8_evidence_without_changing_it(self):
        self.run_cli("install")
        folder = self.vault / "Example"
        note = folder / "evidence" / "TextMeshPro.md"
        note.parent.mkdir(parents=True)
        original = b"# Imported documentation\n".ljust(1442, b" ") + b"\x93quoted\x94\n"
        note.write_bytes(original)
        for event in ("SessionStart", "UserPromptSubmit"):
            with self.subTest(event=event):
                result = self.run_cli(
                    "hook", {"hook_event_name": event, "cwd": str(self.project)}
                )
                self.assertIn(
                    str(folder), result["hookSpecificOutput"]["additionalContext"]
                )
        result = self.run_cli("hook", self.stop())
        self.assertIn("Plan saved", result["systemMessage"])
        self.assertIn("evidence/TextMeshPro", (folder / "_Plans.md").read_text())
        self.assertEqual(note.read_bytes(), original)

    def test_non_utf8_user_index_is_preserved(self):
        folder = self.vault / "Example"
        folder.mkdir(parents=True)
        index = folder / "_Plans.md"
        original = b"# My index\n\x93Keep this\x94\n"
        index.write_bytes(original)
        self.run_cli("install")
        result = self.run_cli(
            "hook", {"hook_event_name": "UserPromptSubmit", "cwd": str(self.project)}
        )
        self.assertIn(
            "_ATS Plans.md", result["hookSpecificOutput"]["additionalContext"]
        )
        self.assertEqual(index.read_bytes(), original)

    def test_unity_cache_is_skipped_but_normal_library_notes_are_indexed(self):
        self.run_cli("install")
        folder = self.vault / "Example"
        unity = folder / "evidence" / "UnityProject"
        settings = unity / "ProjectSettings"
        settings.mkdir(parents=True)
        (settings / "ProjectVersion.txt").write_text("m_EditorVersion: 6000.3.0f1\n")
        cache = unity / "Library" / "PackageCache"
        cache.mkdir(parents=True)
        artifact = cache / "TextMeshPro.md"
        original = b"# Cached documentation\n\x93quote\x94\n"
        artifact.write_bytes(original)
        library = folder / "Library"
        library.mkdir()
        (library / "user-spec.md").write_text("# User knowledge\n")
        result = self.run_cli(
            "hook", {"hook_event_name": "UserPromptSubmit", "cwd": str(self.project)}
        )
        self.assertIn("hookSpecificOutput", result)
        index = (folder / "_Plans.md").read_text()
        self.assertIn("Library/user-spec", index)
        self.assertNotIn("PackageCache", index)
        self.assertEqual(artifact.read_bytes(), original)

    def test_project_names_cannot_traverse_vault_or_collide(self):
        self.run_cli("install")
        self.run_cli("hook", self.stop())
        other = self.root / "other" / "Example"
        other.mkdir(parents=True)
        payload = self.stop()
        payload["cwd"] = str(other)
        self.run_cli("hook", payload)
        folders = [
            p
            for p in self.vault.iterdir()
            if p.is_dir() and p.name.startswith("Example")
        ]
        self.assertEqual(len(folders), 2)
        self.assertTrue(all(list(p.glob("*-plan.md")) for p in folders))

    def test_symlink_project_folder_does_not_write_outside_vault(self):
        self.run_cli("install")
        outside = self.root / "outside"
        outside.mkdir()
        (self.vault / "Example").symlink_to(outside, target_is_directory=True)
        self.run_cli("hook", self.stop())
        self.assertEqual(list(outside.iterdir()), [])

    def test_context_supplies_canonical_project_directory(self):
        self.run_cli("install")
        data = self.run_cli(
            "hook", {"hook_event_name": "SessionStart", "cwd": str(self.project)}
        )
        context = data["hookSpecificOutput"]["additionalContext"]
        self.assertIn(str(self.vault / "Example"), context)
        self.assertIn("<proposed_plan>", context)

    def test_rejected_claude_plan_is_not_marked_approved(self):
        self.run_cli("install")
        event = {
            "hook_event_name": "PostToolUse",
            "cwd": str(self.project),
            "tool_name": "ExitPlanMode",
            "tool_response": {"plan": "# Rejected", "approved": False},
        }
        self.run_cli("hook", event, "--agent", "claude")
        self.assertFalse(list(self.vault.glob("Example/*-plan.md")))

    def test_migration_conflict_preserves_both_directories(self):
        native = self.home / ".claude/plans"
        target = self.vault / "Inbox/Claude"
        native.mkdir(parents=True)
        target.mkdir(parents=True)
        (native / "old.md").write_text("Native content")
        (target / "other.md").write_text("Vault content")
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "install",
                "--vault",
                str(self.vault),
                "--home",
                str(self.home),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((native / "old.md").read_text(), "Native content")
        self.assertEqual((target / "other.md").read_text(), "Vault content")
        self.assertFalse((self.home / ".codex/config.toml").exists())

    def test_parallel_capture_deduplicates_without_partial_notes(self):
        self.run_cli("install")
        command = [
            sys.executable,
            str(SCRIPT),
            "hook",
            "--vault",
            str(self.vault),
            "--agent",
            "codex",
        ]
        processes = [
            subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(2)
        ]
        for process in processes:
            process.stdin.write(json.dumps(self.stop()))
            process.stdin.close()
            process.stdin = None
        for process in processes:
            out, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, error)
            self.assertIn("Plan saved", json.loads(out)["systemMessage"])
        notes = list((self.vault / "Example").glob("*-plan.md"))
        self.assertEqual(len(notes), 1)
        self.assertTrue(notes[0].read_text().endswith("1. Route plans.\n"))

    def test_repository_named_inbox_does_not_mix_with_native_drafts(self):
        self.run_cli("install")
        project = self.root / "code" / "Inbox"
        project.mkdir()
        payload = self.stop()
        payload["cwd"] = str(project)
        self.run_cli("hook", payload)
        self.assertFalse(list((self.vault / "Inbox").glob("*-plan.md")))
        self.assertTrue(list((self.vault / "Inbox-project").glob("*-plan.md")))

    def test_linked_worktree_uses_original_repository_folder(self):
        def git(*arguments):
            subprocess.run(["git", "-C", str(self.project), *arguments],
                           capture_output=True, check=True)

        git("init", "-q")
        git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c",
            "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "initial")
        worktree = self.root / "feature-worktree"
        git("worktree", "add", "-qb", "feature/check", str(worktree))
        self.run_cli("install")
        payload = self.stop()
        payload["cwd"] = str(worktree)
        self.run_cli("hook", payload)
        self.assertTrue(list((self.vault / "Example").glob("*-plan.md")))
        self.assertFalse((self.vault / "feature-worktree").exists())

    def test_obsidian_table_customization_survives_sync(self):
        self.run_cli("install")
        base = self.vault / "Plans.base"
        customized = base.read_text().replace("name: Knowledge", "name: My sorted plans")
        base.write_text(customized)
        self.run_cli("install")
        self.assertEqual(base.read_text(), customized)


if __name__ == "__main__":
    unittest.main()
