#!/usr/bin/env python3
"""Exercise macOS bootstrap with fake Homebrew, Git, and a terminal."""

import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time


installer = Path(__file__).resolve().parents[1] / "install.sh"


def executable(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


with tempfile.TemporaryDirectory() as directory:
    home = Path(directory) / "home"
    home.mkdir()
    fakebin = Path(directory) / "bin"
    fakebin.mkdir()
    executable(fakebin / "uname", "echo Darwin\n")
    executable(fakebin / "id", "echo 501\n")
    executable(fakebin / "brew", """case "$1" in
  shellenv) ;;
  install)
    echo "brew $*" >> "$HOME/steps"
    if [ "$2" = --cask ]; then
      [ "$3" = claude-code ] && name=claude || name=codex
      printf '#!/bin/sh\\nexit 0\\n' > "$TEST_BIN/$name"
      chmod +x "$TEST_BIN/$name"
    elif [ "$2" = node ]; then
      for name in node npm npx; do
        printf '#!/bin/sh\\nexit 0\\n' > "$TEST_BIN/$name"
        chmod +x "$TEST_BIN/$name"
      done
    elif [ "$2" = python ]; then
      printf '#!/bin/sh\\nexit 0\\n' > "$TEST_BIN/python3"
      chmod +x "$TEST_BIN/python3"
    else
      printf '#!/bin/sh\\nexit 0\\n' > "$TEST_BIN/$2"
      chmod +x "$TEST_BIN/$2"
    fi ;;
  *) exit 1 ;;
esac
""")
    executable(fakebin / "git", """case "$1" in
  clone)
    mkdir -p "$3/.git"
    printf '#!/bin/sh\\necho ATS_RAN\\n' > "$3/agent-tools-sync.sh"
    chmod +x "$3/agent-tools-sync.sh" ;;
  -C) echo https://github.com/DeveloperBeau/agent-tools-sync.git ;;
  *) exit 1 ;;
esac
""")

    env = dict(os.environ, HOME=str(home), TEST_BIN=str(fakebin),
               PATH=f"{fakebin}:/usr/bin:/bin", SHELL="/bin/zsh")
    pid, terminal = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", str(installer)], env)

    output = b""
    answered = set()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        readable, _, _ = select.select([terminal], [], [], 0.2)
        if not readable:
            continue
        try:
            chunk = os.read(terminal, 4096)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        output += chunk
        if b"Install Claude Code? [y/N]" in output and "claude" not in answered:
            os.write(terminal, b"y\n")
            answered.add("claude")
        if b"Install Codex? [y/N]" in output and "codex" not in answered:
            os.write(terminal, b"n\n")
            answered.add("codex")
        if b"in ~/.zshrc? [Y/n]" in output and "path" not in answered:
            os.write(terminal, b"\n")
            answered.add("path")
    else:
        os.kill(pid, 9)
        raise AssertionError("installer timed out")
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0, output.decode(errors="replace")
    assert b"ATS_RAN" in output
    assert "brew install --cask claude-code" in (home / "steps").read_text()
    assert "brew install --cask codex" not in (home / "steps").read_text()
    assert (home / ".local/bin/agent-tools-sync").is_symlink()
    assert (home / ".local/bin/ats").is_symlink()
    assert 'export PATH="$HOME/.local/bin:$PATH"' in (home / ".zshrc").read_text()
    assert not (home / ".zprofile").exists()
    assert b"ats is taken" not in output


# A different tool already named ats is left alone and reported.
with tempfile.TemporaryDirectory() as directory:
    home = Path(directory) / "home"
    (home / ".local/bin").mkdir(parents=True)
    other = Path(directory) / "other"
    executable(other, "exit 0\n")
    (home / ".local/bin/ats").symlink_to(other)
    source = installer.read_text()
    function = source[source.index("link_shorthand() {"):source.index("# Offer to put")]
    result = subprocess.run(
        ["bash", "-c", function + "\nCHECKOUT=/x link_shorthand"],
        env=dict(os.environ, HOME=str(home), SHELL="/bin/sh"),
        capture_output=True, text=True)
    assert "ats is taken, so you need to use agent-tools-sync." in result.stdout, result
    assert (home / ".local/bin/ats").resolve() == other.resolve()
