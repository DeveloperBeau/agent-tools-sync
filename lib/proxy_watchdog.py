#!/usr/bin/env python3
"""Recover stalled Headroom streams and preserve evidence without running ATS."""

from __future__ import annotations

import fcntl
import json
import os
import plistlib
import subprocess
import sys
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen


HEADROOM = Path.home() / ".headroom"
ROUTE_URL = "http://127.0.0.1:8788/health/routes"
READY_URL = "http://127.0.0.1:8788/readyz"
STATE_PATH = HEADROOM / "watchdog-state.json"
INCIDENTS = HEADROOM / "incidents"
LABEL = "com.agent-tools-sync.proxy-watchdog"
POLL_SECONDS = 10
COOLDOWN_SECONDS = 30 * 60
SAMPLE_SECONDS = 60
SAMPLE_LIMIT = 360
RECOVERABLE = frozenset({"sse_error", "missing_terminal_event", "interrupted"})


def recovery_candidate(routes: dict, last_attempt: float, now: float) -> str | None:
    if now - last_attempt < COOLDOWN_SECONDS:
        return None
    for route in ("codex", "claude"):
        health = routes.get(route) or {}
        if (
            health.get("state") == "unhealthy"
            and (
                health.get("last_reason") in RECOVERABLE
                or str(health.get("last_reason", "")).startswith("http_5")
            )
        ):
            return route
    return None


def _get_json(url: str) -> dict:
    try:
        with urlopen(url, timeout=3) as response:
            return json.load(response)
    except HTTPError as error:
        # /readyz returns 503 when observed route health is unhealthy.
        if url == READY_URL and error.code == 503:
            return json.load(error)
        raise


def _safe_log_tail() -> list[str]:
    result = deque(maxlen=100)
    for path in (HEADROOM / "logs/proxy-8788.log.1", HEADROOM / "logs/proxy-8788.log"):
        try:
            with path.open(errors="replace") as source:
                for line in source:
                    if "event=route_stream_outcome" in line or "event=upstream_stream_timing" in line:
                        result.append(line.rstrip()[:600])
        except FileNotFoundError:
            pass
    return list(result)


def _safe_caveman_tail() -> list[dict]:
    result = deque(maxlen=100)
    try:
        with (Path.home() / ".caveman/proxy.log").open(errors="replace") as source:
            for line in source:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("msg") in {
                    "upstream transport error; retrying",
                    "upstream rejected transformed request; retrying with original bytes",
                    "cannot bind proxy listener",
                }:
                    result.append({key: event[key] for key in ("time", "level", "msg", "error", "attempt", "request_id") if key in event})
    except FileNotFoundError:
        pass
    return list(result)


def _listener_memory(port: int) -> dict | None:
    try:
        found = subprocess.run(
            ["lsof", "-nP", f"-tiTCP:{port}", "-sTCP:LISTEN"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        pid = found.stdout.splitlines()[0]
        stats = subprocess.run(
            ["ps", "-p", pid, "-o", "rss=,vsz=,etime="],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        return {"pid": int(pid), "rss_vsz_etime": stats.stdout.strip()}
    except (IndexError, OSError, subprocess.TimeoutExpired, ValueError):
        return None


def _save_json(path: Path, data: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def _notify(message: str) -> None:
    try:
        subprocess.run(
            ["osascript", "-e", f'display notification "{message}" with title "ATS proxy watchdog"'],
            capture_output=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def _restart_headroom() -> dict:
    try:
        result = subprocess.run(
            [str(Path.home() / ".local/bin/headroom"), "install", "restart", "--profile", "default"],
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        return {"exit_code": result.returncode, "output": (result.stdout + result.stderr)[-1000:]}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"exit_code": None, "output": str(error)}


def _ready_after_restart() -> bool:
    for _ in range(15):
        try:
            if _get_json(READY_URL).get("ready") is True:
                return True
        except (OSError, ValueError):
            pass
        time.sleep(2)
    return False


def _snapshot(url: str):
    try:
        return _get_json(url)
    except (OSError, ValueError) as error:
        return {"probe_error": f"{type(error).__name__}: {error}"}


def _managed_headroom_loaded() -> bool:
    try:
        result = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/com.headroom.default"],
            capture_output=True,
            timeout=3,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def recover(route: str, routes: dict, state: dict, now: float) -> None:
    # A deliberately unloaded service must stay stopped. KeepAlive handles
    # crashes; a loaded but unresponsive service still needs recovery.
    if not _managed_headroom_loaded():
        return
    incident = {
        "time": datetime.now(timezone.utc).isoformat(),
        "route": route,
        "routes": routes,
        "listeners": {
            "caveman_8787": _listener_memory(8787),
            "headroom_8788": _listener_memory(8788),
        },
        "readiness": _snapshot(READY_URL),
        "tasks": _snapshot("http://127.0.0.1:8788/debug/tasks"),
        "stream_logs": _safe_log_tail(),
        "caveman_events": _safe_caveman_tail(),
        "memory_samples": state.get("memory_samples", []),
    }
    incident_path = INCIDENTS / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{route}.json"
    _save_json(incident_path, incident)
    state.update(last_attempt=now, incident=str(incident_path))
    _save_json(STATE_PATH, state)
    incident["restart"] = _restart_headroom()
    incident["ready_after_restart"] = _ready_after_restart()
    # Process readiness cannot prove that either provider recovered. Only a
    # subsequent real request can establish route health after restart.
    incident["provider_recovery"] = "unverified_pending_real_traffic"
    _save_json(incident_path, incident)
    restarted = incident["restart"]["exit_code"] == 0 and incident["ready_after_restart"]
    message = (
        f"{route} failure; Headroom restarted. API recovery awaits real traffic."
        if restarted
        else f"{route} failure; Headroom recovery failed. See incident report."
    )
    _notify(message)
    print(f"{datetime.now(timezone.utc).isoformat()} {message} {incident_path}", flush=True)


def watch() -> None:
    os.umask(0o077)
    INCIDENTS.mkdir(parents=True, exist_ok=True)
    lock = STATE_PATH.with_suffix(".lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise SystemExit("proxy watchdog already running")
    try:
        _watch()
    finally:
        lock.close()


def _watch() -> None:
    last_error = None
    probe_failures = 0
    while True:
        try:
            state = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}
            now = time.time()
            if now - state.get("last_sample", 0) >= SAMPLE_SECONDS:
                samples = (state.get("memory_samples") or [])[-SAMPLE_LIMIT + 1 :]
                samples.append({
                    "time": datetime.now(timezone.utc).isoformat(),
                    "caveman_8787": _listener_memory(8787),
                    "headroom_8788": _listener_memory(8788),
                })
                state["memory_samples"] = samples
                state["last_sample"] = now
                _save_json(STATE_PATH, state)
            try:
                routes = _get_json(ROUTE_URL)
            except (OSError, ValueError) as error:
                probe_failures += 1
                if probe_failures >= 3 and now - state.get("last_attempt", 0) >= COOLDOWN_SECONDS:
                    recover("headroom_health_endpoint", {"probe_error": str(error)}, state, now)
                    probe_failures = 0
                raise
            probe_failures = 0
            last_error = None
            state["last_routes"] = routes
            state["last_poll"] = datetime.now(timezone.utc).isoformat()
            _save_json(STATE_PATH, state)
            route = recovery_candidate(routes, state.get("last_attempt", 0), now)
            if route is not None:
                recover(route, routes, state, now)
        except (OSError, ValueError, TypeError) as error:
            message = f"{type(error).__name__}: {error}"
            if message != last_error:
                print(f"{datetime.now(timezone.utc).isoformat()} health check: {message}", file=sys.stderr, flush=True)
                last_error = message
        time.sleep(POLL_SECONDS)


def install() -> None:
    os.umask(0o077)
    launch_agents = Path.home() / "Library/LaunchAgents"
    launch_agents.mkdir(parents=True, exist_ok=True)
    HEADROOM.mkdir(parents=True, exist_ok=True)
    plist_path = launch_agents / f"{LABEL}.plist"
    with plist_path.open("wb") as output:
        plistlib.dump(
            {
                "Label": LABEL,
                "ProgramArguments": [sys.executable, str(Path(__file__).resolve()), "watch"],
                "RunAtLoad": True,
                "KeepAlive": True,
                "ThrottleInterval": 30,
                "StandardOutPath": str(HEADROOM / "watchdog.stdout.log"),
                "StandardErrorPath": str(HEADROOM / "watchdog.stderr.log"),
            },
            output,
        )
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{domain}/{LABEL}"], capture_output=True, check=False)
    subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], check=True)
    print(f"Installed {LABEL} from {Path(__file__).resolve()}")


if __name__ == "__main__":
    if sys.argv[1:] == ["watch"]:
        watch()
    elif sys.argv[1:] == ["install"]:
        install()
    else:
        raise SystemExit("usage: proxy_watchdog.py [watch|install]")
