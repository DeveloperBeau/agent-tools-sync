#!/usr/bin/env python3
"""Build the pinned Caveman patch without replacing vendor-managed binaries."""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


PIN = "6b42a31e10ee4c1b8549ccde30b451ddd060023d"
SOURCE = "https://github.com/JuliusBrussee/caveman.git"
PATCH = Path(__file__).resolve().parents[1] / "patches/caveman-request-size.patch"
ROOT = Path.home() / ".caveman/ats-proxy"
WRAPPER = '''#!/bin/sh
# ATS-owned override: native-hook delegates must start this same patched proxy.
CAVEMAN_PROXY_BIN="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/caveman-proxy"
export CAVEMAN_PROXY_BIN
case ",${CAVE_SSRF_ALLOWLIST:-}," in
  *,127.0.0.1:8788,*) ;;
  *) CAVE_SSRF_ALLOWLIST="${CAVE_SSRF_ALLOWLIST:+$CAVE_SSRF_ALLOWLIST,}127.0.0.1:8788" ;;
esac
export CAVE_SSRF_ALLOWLIST
if [ -e "${CAVEMAN_HOME:-$HOME/.caveman}/ats-stopped" ]; then
  case "${1:-serve}" in
    native-hook) exit 0 ;;
    serve) echo "ATS proxies deliberately stopped; run ats start." >&2; exit 1 ;;
  esac
fi
case "$(cat "${CAVEMAN_HOME:-$HOME/.caveman}/ats-mode" 2>/dev/null)" in
  no-caveman|direct)
    case "${1:-serve}" in
      native-hook) exit 0 ;;
      serve) echo "ATS mode skips Caveman; run plain ats to restore it." >&2; exit 1 ;;
    esac ;;
esac
if [ "$#" -eq 0 ] || [ "$1" = serve ]; then
  caveman_log="${CAVEMAN_HOME:-$HOME/.caveman}/proxy.log"
  mkdir -p "$(dirname -- "$caveman_log")" || exit 1
  (umask 077; touch "$caveman_log") || exit 1
  chmod 600 "$caveman_log" || exit 1
  exec >>"$caveman_log" 2>&1
fi
exec "${CAVEMAN_PROXY_BIN}.bin" "$@"
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=kwargs.pop("timeout", 120), **kwargs)


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def install(source=None):
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    binary, wrapper, receipt = (ROOT / name for name in ("caveman-proxy.bin", "caveman-proxy", "build.json"))
    wanted = {"commit": PIN, "patch_sha256": digest(PATCH)}
    with (ROOT / "install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            previous = json.loads(receipt.read_text())
            current = {**wanted, "binary_sha256": digest(binary)}
            if previous == current and os.access(binary, os.X_OK):
                if not (os.access(wrapper, os.X_OK) and wrapper.read_text() == WRAPPER):
                    with tempfile.TemporaryDirectory(prefix=".wrapper-", dir=ROOT) as temporary:
                        staged = Path(temporary) / "caveman-proxy"
                        staged.write_text(WRAPPER)
                        staged.chmod(0o755)
                        staged.replace(wrapper)
                print(f"Patched Caveman already installed: {wrapper}")
                return
        except (OSError, ValueError):
            pass

        if source is None:
            source = ROOT / "source.git"
            if not source.exists():
                run(["git", "init", "--bare", str(source)])
            try:
                run(["git", "-C", str(source), "cat-file", "-e", f"{PIN}^{{commit}}"])
            except subprocess.CalledProcessError:
                run(["git", "-C", str(source), "fetch", "--depth=1", SOURCE, PIN])
        actual = run(["git", "-C", str(source), "rev-parse", f"{PIN}^{{commit}}"]).stdout.strip()
        if actual != PIN:
            raise ValueError("Caveman source does not match the pinned commit")

        with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
            stage = Path(temporary)
            tree = stage / "source"
            tree.mkdir()
            archive = stage / "source.tar"
            run(["git", "-C", str(source), "archive", PIN, "-o", str(archive)])
            run(["tar", "-xf", str(archive), "-C", str(tree)])
            run(["git", "apply", "--check", str(PATCH)], cwd=tree)
            run(["git", "apply", str(PATCH)], cwd=tree)
            built = stage / "caveman-proxy.bin"
            run(["go", "build", "-trimpath", "-ldflags",
                 "-X main.version=ats-size-bypass-" + wanted["patch_sha256"][:12],
                 "-o", str(built), "./proxy/cmd/caveman-proxy"],
                cwd=tree, env={**os.environ, "CGO_ENABLED": "0"}, timeout=600)
            version = json.loads(run([str(built), "version", "--json"], timeout=5).stdout)
            if not {"run_state", "native_hook_bridge_v1"}.issubset(version.get("capabilities", [])):
                raise ValueError("Built proxy lacks the native integration capabilities")
            staged_wrapper = stage / "caveman-proxy"
            staged_wrapper.write_text(WRAPPER)
            staged_wrapper.chmod(0o755)
            staged_receipt = stage / "build.json"
            staged_receipt.write_text(json.dumps({**wanted, "binary_sha256": digest(built)}, indent=2) + "\n")
            # Only validated artifacts reach stable paths. Existing processes and
            # failed builds retain the previous executable; each replacement is atomic.
            built.replace(binary)
            staged_wrapper.replace(wrapper)
            staged_receipt.replace(receipt)
        print(f"Installed patched Caveman: {wrapper}")


if __name__ == "__main__":
    try:
        if len(sys.argv) > 2:
            raise ValueError("usage: install_caveman_proxy.py [source-checkout]")
        install(Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else None)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"Caveman patch install failed; previous proxy preserved: {detail[-2000:]}", file=sys.stderr)
        raise SystemExit(1)
