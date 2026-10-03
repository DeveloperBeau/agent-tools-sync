"""Route agent plans into one Markdown vault and maintain Obsidian indexes."""

import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

MARKER = "<!-- ats-plans: generated -->"
BASE_MARKER = "# ats-plans: generated"
RULE_START = "<!-- ats-plans: instructions -->"
RULE_END = "<!-- /ats-plans: instructions -->"
HOOK_MARKER = "--managed-hook"


def atomic_write(path, text, backup=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f"Refusing to replace symlink: {path}")
    if path.exists() and path.read_text() == text:
        return
    if backup and path.exists():
        previous = path.with_name(path.name + ".ats-plans-backup")
        if not previous.exists():
            shutil.copy2(path, previous)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        if path.exists():
            os.chmod(temporary, path.stat().st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def owned(path):
    if path.is_symlink():
        return False
    with path.open("rb") as stream:
        header = stream.read(1024)
    return MARKER.encode("ascii") in header or header.startswith(
        (BASE_MARKER + "\n").encode("ascii")
    )


def owned_name(folder, name, alternate):
    for basename in (name, alternate):
        path = folder / basename
        if (
            not path.exists()
            and not path.is_symlink()
            or path.is_file()
            and owned(path)
        ):
            return path
    raise ValueError(f"User notes occupy both generated index names in {folder}")


def inside_directory(vault, path):
    if path.is_symlink() or not path.resolve().is_relative_to(vault):
        raise ValueError(f"Plan directory escapes vault: {path}")
    path.mkdir(parents=True, exist_ok=True)
    return path


@contextmanager
def vault_lock(vault):
    vault.mkdir(parents=True, exist_ok=True)
    path = vault / ".ats-plans.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        deadline = time.monotonic() + 2
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Shared plans vault busy; try next turn")
                time.sleep(0.02)
        yield


def project_root(cwd):
    path = Path(cwd).expanduser().resolve()
    if not path.is_dir():
        raise ValueError("Hook cwd is not an existing directory")
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(path),
                "rev-parse",
                "--show-toplevel",
                "--git-common-dir",
            ],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        lines = result.stdout.splitlines()
        if result.returncode == 0 and len(lines) == 2:
            root = Path(lines[0]).resolve()
            common = Path(lines[1])
            if not common.is_absolute():
                common = path / common
            # Linked worktrees share their original repository's project folder.
            return common.resolve().parent if common.name == ".git" else root
    except (OSError, subprocess.TimeoutExpired):
        pass
    return path


def repository_from_index(folder):
    for name in ("_Plans.md", "_ATS Plans.md"):
        index = folder / name
        if index.is_file() and owned(index):
            with index.open() as stream:
                header = stream.read(1024)
            match = re.search(r"^repository: (.+)$", header, re.MULTILINE)
            if match:
                return json.loads(match[1])
    return ""


def project_folder(vault, root):
    name = re.sub(r"[\x00-\x1f/\\\[\]#|]", "-", root.name).strip(". ") or "project"
    if name.casefold() == "inbox":
        name += "-project"
    for folder in vault.iterdir():
        if (
            folder.is_dir()
            and not folder.is_symlink()
            and repository_from_index(folder) == str(root)
        ):
            return folder
    folder = vault / name
    if (
        folder.is_symlink()
        or folder.exists()
        and repository_from_index(folder) not in ("", str(root))
    ):
        folder = vault / (
            name + "--" + hashlib.sha256(str(root).encode()).hexdigest()[:8]
        )
    return inside_directory(vault, folder)


def markdown_files(folder):
    # ponytail: scan at most 10,000 notes per project; add incremental indexing if vaults grow beyond this.
    count = 0
    for directory, children, names in os.walk(folder, followlinks=False):
        children[:] = sorted(
            name
            for name in children
            if not name.startswith(".") and not (Path(directory) / name).is_symlink()
            and not (
                name == "Library"
                and (Path(directory) / "ProjectSettings/ProjectVersion.txt").is_file()
            )
        )
        for name in sorted(names):
            path = Path(directory) / name
            if (
                path.suffix.lower() == ".md"
                and not path.is_symlink()
                and path.is_file()
            ):
                count += 1
                if count > 10_000:
                    raise ValueError(f"Project index exceeds 10,000 notes: {folder}")
                yield path


def link(relative, label):
    target = relative.as_posix()
    title = label.replace("[", "").replace("]", "").replace("|", " ").replace("\n", " ")
    if any(character in target for character in "#|[]\n"):
        return f"[{title}]({quote(target)})"
    return f"[[{target.removesuffix('.md')}|{title}]]"


def header(**properties):
    return (
        "---\n"
        + "".join(
            f"{key}: {json.dumps(value, ensure_ascii=False)}\n"
            for key, value in properties.items()
        )
        + "---\n\n"
    )


def index_project(vault, folder, root=""):
    index = owned_name(folder, "_Plans.md", "_ATS Plans.md")
    repository = str(root) or repository_from_index(folder)
    notes = [
        path
        for path in markdown_files(folder)
        if path != index and (path.name.endswith("-plan.md") or not owned(path))
    ]
    lines = [
        header(project=folder.name, repository=repository, type="index") + MARKER,
        f"\n# {folder.name}\n",
        f"{len(notes)} {'note' if len(notes) == 1 else 'notes'}. Keep plans, designs, specs, decisions, and reviews linked here.\n",
    ]
    for note in sorted(
        notes, key=lambda path: path.relative_to(folder).as_posix(), reverse=True
    ):
        lines.append("- " + link(note.relative_to(folder), note.stem))
    atomic_write(index, "\n".join(lines) + "\n")
    return index, len(notes)


def index_home(vault):
    path = owned_name(vault, "Plans Home.md", "ATS Plans Home.md")
    lines = [
        header(type="index") + MARKER,
        "\n# Plans knowledge store\n",
        "Canonical plans across projects. "
        + link(Path("Plans.base"), "Browse properties")
        + ".\n",
        "## Projects\n",
    ]
    for folder in sorted(vault.iterdir()):
        if not folder.is_dir() or folder.is_symlink() or folder.name.startswith("."):
            continue
        for name in ("_Plans.md", "_ATS Plans.md"):
            index = folder / name
            if index.is_file() and owned(index):
                lines.append("- " + link(index.relative_to(vault), folder.name))
                break
    atomic_write(path, "\n".join(lines) + "\n")


def index_all(vault):
    total = 0
    for folder in sorted(vault.iterdir()):
        if not folder.is_dir() or folder.is_symlink() or folder.name.startswith("."):
            continue
        if any(
            re.match(r"\d{4}-\d{2}-\d{2}-.+\.md$", path.name)
            for path in markdown_files(folder)
        ):
            _, count = index_project(vault, folder)
            total += count
    index_home(vault)
    return total


def resources(vault):
    inside_directory(vault, vault / ".obsidian")
    app = vault / ".obsidian/app.json"
    if not app.exists():
        atomic_write(app, "{}\n")
    base = vault / "Plans.base"
    if not base.exists() and not base.is_symlink():
        atomic_write(
            base,
            BASE_MARKER
            + "\nfilters:\n  and:\n    - 'file.ext == \"md\"'\n    - 'type != \"index\"'\nviews:\n  - type: table\n    name: Knowledge\n    order:\n      - file.name\n      - project\n      - type\n      - status\n      - created\n      - file.folder\n",
        )


def rules(vault):
    return f"""{RULE_START}
## Shared plans and Obsidian knowledge

Canonical plans vault: `{vault}`. Store planning artifacts only here, in a
per-project folder; never create planning documents in a code repository.
Session hooks provide the resolved project folder. Read its `_Plans.md` index
and relevant existing notes before drafting. Link related plans, specs, decisions,
and reviews using relative Markdown or Obsidian links.

Use `YYYY-MM-DD-<topic>-plan.md`, `-design.md`, `-spec.md`, or `-decision.md`.
Start new notes with YAML properties: `project`, `session`, `created`, `type`,
and `status`. Keep status accurate: proposed, approved, implemented, or superseded.
Codex proposed plans retain `<proposed_plan>` tags; Stop hooks save them automatically.
Claude native working plans live in the vault's Inbox; ExitPlanMode hooks file
approved snapshots under the resolved project. Do not change old notes silently.
{RULE_END}
"""


def instruction_text(path, vault):
    text = path.read_text() if path.exists() else ""
    if RULE_START in text or RULE_END in text:
        if text.count(RULE_START) != 1 or text.count(RULE_END) != 1:
            raise ValueError(f"Malformed managed plan instructions: {path}")
        text = re.sub(
            re.escape(RULE_START) + r".*?" + re.escape(RULE_END) + r"\n?",
            lambda _: rules(vault),
            text,
            flags=re.DOTALL,
        )
    else:
        text = text.rstrip() + "\n\n" + rules(vault)
    return text


def add_writable_root(text, vault):
    data = tomllib.loads(text)
    roots = data.get("sandbox_workspace_write", {}).get("writable_roots", [])
    if not isinstance(roots, list) or not all(
        isinstance(value, str) for value in roots
    ):
        raise ValueError("Codex writable_roots must be a list of paths")
    if str(vault) in roots:
        return text
    value = json.dumps([*roots, str(vault)], ensure_ascii=False)
    section = re.search(r"(?m)^\[sandbox_workspace_write\][ \t]*(?:#[^\n]*)?\n?", text)
    if section:
        stop = re.search(r"(?m)^\[", text[section.end() :])
        end = section.end() + stop.start() if stop else len(text)
        match = re.search(
            r"(?m)^[ \t]*writable_roots[ \t]*=[ \t]*", text[section.end() : end]
        )
        if match:
            start = section.end() + match.end()
            for last in range(start, end):
                if text[last] != "]":
                    continue
                try:
                    tomllib.loads("roots = " + text[start : last + 1])
                except tomllib.TOMLDecodeError:
                    continue
                text = text[:start] + value + text[last + 1 :]
                break
            else:
                raise ValueError(
                    "Unsupported Codex writable_roots syntax; config preserved"
                )
        else:
            text = (
                text[: section.end()]
                + "writable_roots = "
                + value
                + "\n"
                + text[section.end() :]
            )
    else:
        text = (
            text.rstrip()
            + "\n\n[sandbox_workspace_write]\nwritable_roots = "
            + value
            + "\n"
        )
    tomllib.loads(
        text
    )  # Refuse incompatible inline/dotted tables rather than damaging configuration.
    return text


def hooks(data, command, agent):
    events = data.setdefault("hooks", {})
    for event, groups in events.items():
        kept = []
        for group in groups:
            handlers = [
                hook
                for hook in group.get("hooks", [])
                if not (
                    HOOK_MARKER in hook.get("command", "")
                    and "plans.py" in hook.get("command", "")
                )
            ]
            if handlers:
                kept.append({**group, "hooks": handlers})
        events[event] = kept
    selections = {"SessionStart": "startup|resume", "UserPromptSubmit": "", "Stop": ""}
    if agent == "claude":
        selections["PostToolUse"] = "ExitPlanMode|Write|Edit|MultiEdit"
    for event, matcher in selections.items():
        events.setdefault(event, []).append(
            {
                "matcher": matcher,
                "hooks": [{"type": "command", "command": command, "timeout": 5}],
            }
        )
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def link_native_claude(home, vault):
    native = home / ".claude/plans"
    destination = vault / "Inbox/Claude"
    inside_directory(vault, destination.parent)
    if native.is_symlink():
        if native.resolve() != destination.resolve():
            raise ValueError(
                f"Existing native plans link points elsewhere; preserved: {native}"
            )
        inside_directory(vault, destination)
        return
    native.parent.mkdir(parents=True, exist_ok=True)
    if native.exists():
        if not native.is_dir() or destination.exists() or destination.is_symlink():
            raise ValueError(
                "Native Claude plans and vault Inbox conflict; both preserved"
            )
        shutil.move(str(native), str(destination))
    else:
        inside_directory(vault, destination)
    try:
        native.symlink_to(destination, target_is_directory=True)
    except OSError:
        # Restore the original directory if migration succeeded but the link failed.
        if not native.exists():
            shutil.move(str(destination), str(native))
        raise


def install(home, vault, agents):
    candidates = []
    for agent in agents:
        directory = home / (".claude" if agent == "claude" else ".codex")
        settings = directory / ("settings.json" if agent == "claude" else "hooks.json")
        data = json.loads(settings.read_text()) if settings.exists() else {}
        command = shlex.join(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "hook",
                "--vault",
                str(vault),
                "--agent",
                agent,
                HOOK_MARKER,
            ]
        )
        if agent == "claude":
            data.pop(
                "plansDirectory", None
            )  # Use the native default linked into the shared vault.
            directories = data.setdefault("permissions", {}).setdefault(
                "additionalDirectories", []
            )
            if not isinstance(directories, list) or not all(
                isinstance(value, str) for value in directories
            ):
                raise ValueError("Claude additionalDirectories must be a list of paths")
            if str(vault) not in directories:
                directories.append(str(vault))
        else:
            config = directory / "config.toml"
            candidates.append(
                (
                    config,
                    add_writable_root(
                        config.read_text() if config.exists() else "", vault
                    ),
                )
            )
        candidates.append((settings, hooks(data, command, agent)))
        instructions = directory / ("CLAUDE.md" if agent == "claude" else "AGENTS.md")
        candidates.append((instructions, instruction_text(instructions, vault)))
    with vault_lock(vault):
        resources(vault)
        if "claude" in agents:
            link_native_claude(home, vault)
            index_project(vault, vault / "Inbox")
        for path, content in candidates:
            atomic_write(path, content, backup=True)
        count = index_all(vault)
    return {"vault": str(vault), "agents": agents, "indexed_notes": count}


def capture(vault, folder, root, body, agent, event, status):
    title = re.search(r"(?m)^#\s+(.+)$", body)
    slug = re.sub(
        r"[^a-z0-9]+", "-", (title.group(1) if title else "agent-plan").lower()
    ).strip("-")[:65]
    identifier = hashlib.sha256(
        json.dumps(
            [agent, event.get("session_id"), event.get("turn_id"), body]
        ).encode()
    ).hexdigest()[:12]
    now = datetime.now().astimezone()
    path = folder / f"{now:%Y-%m-%d}-{slug or 'agent-plan'}-{identifier}-plan.md"
    text = (
        header(
            project=folder.name,
            repository=str(root),
            agent=agent,
            session=event.get("session_id") or "unknown",
            created=now.strftime("%Y-%m-%d %H:%M:%S %z"),
            type="plan",
            status=status,
            ats_plan_id=identifier,
        )
        + MARKER
        + "\n\n"
        + body.strip()
        + "\n"
    )
    fd, temporary = tempfile.mkstemp(dir=folder)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
        try:
            os.link(temporary, path, follow_symlinks=False)
        except FileExistsError:
            if path.is_symlink() or not owned(path):
                raise ValueError(
                    f"Existing note preserved; automatic capture name occupied: {path}"
                )
    finally:
        os.unlink(temporary)
    index_project(vault, folder, root)
    index_home(vault)
    return path


def hook(vault, agent, event):
    name = event.get("hook_event_name")
    if not event.get("cwd"):
        return {}
    root = project_root(event["cwd"])
    with vault_lock(vault):
        folder = project_folder(vault, root)
        if name in {"SessionStart", "UserPromptSubmit"}:
            index, _ = index_project(vault, folder, root)
            index_home(vault)
            context = (
                f"Canonical planning directory for this project: {folder}. "
                f"Store all plans, designs, specs, and decisions here, never in the code repo. "
                f"Read {index} and link relevant prior notes. "
                "Use YAML project/session/created/type/status properties. "
                "Keep Codex proposed plans wrapped in <proposed_plan>...</proposed_plan>; "
                "the Stop hook saves them automatically to this directory."
            )
            return {
                "hookSpecificOutput": {
                    "hookEventName": name,
                    "additionalContext": context,
                }
            }
        body, status = None, "proposed"
        if name == "Stop":
            text = event.get("last_assistant_message") or ""
            matches = re.findall(
                r"<proposed_plan>\s*(.*?)\s*</proposed_plan>", text, re.DOTALL
            )
            if matches:
                body = matches[-1]
        elif (
            name == "PostToolUse"
            and agent == "claude"
            and event.get("tool_name") == "ExitPlanMode"
        ):
            response = event.get("tool_response") or {}
            if (
                isinstance(response, dict)
                and response.get("approved") is not False
                and not response.get("is_error")
            ):
                body, status = response.get("plan"), "approved"
        if isinstance(body, str) and body.strip():
            path = capture(vault, folder, root, body, agent, event, status)
            return {"systemMessage": f"Plan saved to shared vault: {path}"}
        if name in {"Stop", "PostToolUse"}:
            index_project(vault, folder, root)
            index_home(vault)
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["install", "hook", "index"])
    parser.add_argument("--vault", type=Path, required=True)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument(
        "--agents", nargs="+", choices=["claude", "codex"], default=["claude", "codex"]
    )
    parser.add_argument("--agent", choices=["claude", "codex"], default="codex")
    parser.add_argument(HOOK_MARKER, action="store_true")
    args = parser.parse_args()
    vault = args.vault.expanduser().resolve()
    try:
        if args.action == "install":
            result = install(args.home.expanduser().resolve(), vault, args.agents)
        elif args.action == "index":
            with vault_lock(vault):
                resources(vault)
                result = {"indexed_notes": index_all(vault)}
        else:
            event = json.loads(sys.stdin.read(8 * 1024 * 1024))
            if not isinstance(event, dict):
                raise ValueError("Hook input must be a JSON object")
            result = hook(vault, args.agent, event)
        print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError, TimeoutError, TypeError) as error:
        if args.action == "hook":
            # Do not block a turn when the vault is unavailable; make lost capture visible.
            print(
                json.dumps(
                    {
                        "systemMessage": f"ATS plans hook could not save/index plans: {error}"
                    }
                )
            )
        else:
            print(str(error), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
