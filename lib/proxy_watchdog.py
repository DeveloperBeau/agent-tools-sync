#!/usr/bin/env python3
"""Recover stalled Headroom streams and preserve evidence without running ATS."""

from __future__ import annotations

import fcntl
import json
import math
import os
import plistlib
import subprocess
import sys
import time
from collections import deque
from datetime import datetime, timezone
from http.client import HTTPException
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen


HEADROOM = Path.home() / ".headroom"
ROUTE_URL = "http://127.0.0.1:8788/health/routes"
READY_URL = "http://127.0.0.1:8788/readyz"
STREAMS_URL = "http://127.0.0.1:8788/debug/streams"
STATE_PATH = HEADROOM / "watchdog-state.json"
INCIDENTS = HEADROOM / "incidents"
LABEL = "au.com.beauayres.agent-tools-sync.proxy-watchdog"
POLL_SECONDS = 10
COOLDOWN_SECONDS = 30 * 60
SAMPLE_SECONDS = 60
SAMPLE_LIMIT = 360
RECOVERABLE = frozenset({"sse_error", "missing_terminal_event", "interrupted"})


def recovery_candidates(routes: dict) -> list[str]:
    """Detect failures independently of whether another restart is allowed."""
    failed = []
    for route in ("codex", "claude"):
        health = routes.get(route) or {}
        if (
            health.get("state") == "unhealthy"
            and (
                health.get("last_reason") in RECOVERABLE
                or str(health.get("last_reason", "")).startswith("http_5")
            )
        ):
            failed.append(route)
    return failed


def _get_json(url: str) -> dict:
    try:
        with urlopen(url, timeout=3) as response:
            if url == STREAMS_URL:
                payload = response.read(2 * 1024 * 1024 + 1)
                if len(payload) > 2 * 1024 * 1024:
                    raise ValueError("diagnostic snapshot exceeds 2 MiB")
                return json.loads(payload)
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
                    if "event=stream_diagnostic " in line or "event=proxy_loop_lag " in line:
                        result.append(line.rstrip()[:16000])
                    elif "event=route_stream_outcome" in line or "event=upstream_stream_timing" in line:
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
            ["ps", "-p", pid, "-o", "rss=,vsz=,etime=,pcpu=,stat="],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        fields = stats.stdout.split()
        return {"pid": int(pid), "rss_vsz_etime": " ".join(fields[:3]),
                "cpu_percent": float(fields[3]), "process_state": fields[4]}
    except (IndexError, OSError, subprocess.TimeoutExpired, ValueError):
        return None


def _command_snapshot(command: list[str]) -> dict:
    """Only fixed, payload-free OS probes call this; never capture stderr."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=3, check=False)
        return {"exit_code": result.returncode, "output": result.stdout[:8000],
                "truncated": len(result.stdout) > 8000}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"probe_error": type(error).__name__}


def _network_snapshot(listeners: dict) -> dict:
    return {
        # These counters are host-wide, not proof that this proxy lost packets.
        "tcp_counters": _command_snapshot(["netstat", "-s", "-p", "tcp"]),
        "default_route": _command_snapshot(["route", "-n", "get", "default"]),
        "sockets": {
            name: _command_snapshot(["lsof", "-nP", "-a", "-p", str(sample["pid"]),
                                     "-iTCP", "-FpfntT"])
            for name, sample in listeners.items() if sample is not None
        },
    }


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
        except (OSError, ValueError, HTTPException):
            pass
        time.sleep(2)
    return False


def _snapshot(url: str):
    try:
        return _get_json(url)
    except (OSError, ValueError, HTTPException) as error:
        return {"probe_error": type(error).__name__}


def _sample_diagnostics(state: dict, now: float) -> None:
    """Retain evidence even when a later event-loop stall prevents HTTP probes."""
    try:
        snapshot = _get_json(STREAMS_URL)
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("active"), list):
            raise ValueError("invalid diagnostic snapshot")
        connections = snapshot.get("connections", [])
        if not isinstance(connections, list):
            raise ValueError("invalid diagnostic connection list")
        stamp = datetime.fromtimestamp(now, timezone.utc).isoformat()
        sample = {
            "time": stamp,
            "pid": snapshot.get("pid"),
            "event_loop": snapshot.get("event_loop"),
            "active": snapshot["active"][:16],
            "connections": connections[:16],
            "active_omitted": max(0, len(snapshot["active"]) - 16),
        }
    except (OSError, ValueError, HTTPException) as error:
        state["diagnostics_probe_error"] = type(error).__name__
        return
    state["last_stream_diagnostics"] = {"time": stamp, "data": snapshot}
    state.pop("diagnostics_probe_error", None)
    # Two minutes at the normal poll interval. Completed requests already live
    # in the proxy's bounded recent ring; retaining them every poll wastes space.
    state["diagnostic_samples"] = (state.get("diagnostic_samples") or [])[-11:] + [sample]


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


def _capture_incident(route: str, routes: dict, state: dict) -> tuple[Path, dict]:
    INCIDENTS.mkdir(parents=True, exist_ok=True)
    # Capture live waits before spending time on subprocesses or other probes.
    stream_diagnostics = _snapshot(STREAMS_URL)
    listeners = {
        "caveman_8787": _listener_memory(8787),
        "headroom_8788": _listener_memory(8788),
    }
    incident = {
        "time": datetime.now(timezone.utc).isoformat(),
        "route": route,
        "stream_diagnostics": stream_diagnostics,
        "last_stream_diagnostics": state.get("last_stream_diagnostics"),
        "diagnostic_samples": state.get("diagnostic_samples", []),
        "diagnostics_probe_error": state.get("diagnostics_probe_error"),
        "routes": routes,
        "listeners": listeners,
        "network": _network_snapshot(listeners),
        "readiness": _snapshot(READY_URL),
        "tasks": _snapshot("http://127.0.0.1:8788/debug/tasks"),
        "stream_logs": _safe_log_tail(),
        "caveman_events": _safe_caveman_tail(),
        "memory_samples": state.get("memory_samples", []),
    }
    incident_path = INCIDENTS / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S%fZ}-{route}.json"
    _save_json(incident_path, incident)
    return incident_path, incident


def capture() -> None:
    """Save evidence on demand, including failures before reaching Headroom."""
    os.umask(0o077)
    state = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}
    path, _ = _capture_incident("manual", _snapshot(ROUTE_URL), state)
    print(f"Captured proxy evidence: {path}")


def _report_cooldown_failure(route: str, routes: dict, state: dict, now: float, remaining: int) -> None:
    alerts = state.setdefault("cooldown_alerts", {})
    reason = str((routes.get(route) or {}).get("last_reason") or routes.get("probe_error") or "unhealthy")[:80]
    previous = alerts.get(route)
    if previous and previous.get("last_attempt") == state["last_attempt"]:
        previous.update(failure_reason=reason, cooldown_remaining_seconds=remaining)
        _save_json(STATE_PATH, state)
        return
    incident_path, incident = _capture_incident(route, routes, state)
    suppression = {"reason": "restart_cooldown", "failure_reason": reason,
                   "last_attempt": state["last_attempt"], "cooldown_remaining_seconds": remaining}
    incident["recovery_suppressed"] = suppression
    _save_json(incident_path, incident)
    alerts[route] = {**suppression, "detected_at": datetime.fromtimestamp(now, timezone.utc).isoformat(),
                     "incident": str(incident_path)}
    state["incident"] = str(incident_path)
    _save_json(STATE_PATH, state)
    _notify(f"{route} failure; restart delayed by cooldown ({remaining}s). Evidence captured.")
    print(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "event": "recovery_suppressed",
                      "route": route, **suppression, "incident": str(incident_path)}), flush=True)


def recover(route: str, routes: dict, state: dict, now: float) -> bool:
    # A deliberately unloaded service must stay stopped. KeepAlive handles
    # crashes; a loaded but unresponsive service still needs recovery.
    if not _managed_headroom_loaded():
        return False
    last_attempt = state.get("last_attempt", 0)
    remaining = max(0, math.ceil(last_attempt + COOLDOWN_SECONDS - now)) if last_attempt else 0
    if remaining:
        _report_cooldown_failure(route, routes, state, now, remaining)
        return False
    incident_path, incident = _capture_incident(route, routes, state)
    state.update(last_attempt=now, incident=str(incident_path), cooldown_alerts={})
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
    return True


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
            _sample_diagnostics(state, now)
            _save_json(STATE_PATH, state)
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
            except (OSError, ValueError, HTTPException) as error:
                probe_failures += 1
                if probe_failures >= 3:
                    recover("headroom_health_endpoint", {"probe_error": type(error).__name__}, state, now)
                    probe_failures = 0
                raise
            probe_failures = 0
            last_error = None
            state["last_routes"] = routes
            state["last_poll"] = datetime.now(timezone.utc).isoformat()
            _save_json(STATE_PATH, state)
            for route in recovery_candidates(routes):
                if recover(route, routes, state, now):
                    # A restart invalidates this snapshot of both routes.
                    break
        except (OSError, ValueError, TypeError, HTTPException) as error:
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
    elif sys.argv[1:] == ["capture"]:
        capture()
    else:
        raise SystemExit("usage: proxy_watchdog.py [watch|install|capture]")
