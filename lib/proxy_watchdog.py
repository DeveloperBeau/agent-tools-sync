#!/usr/bin/env python3
"""Recover stalled Headroom streams and preserve evidence without running ATS."""

from __future__ import annotations

import fcntl
import ipaddress
import json
import math
import os
import plistlib
import re
import shutil
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
INCIDENT_LIMIT = 64
METADATA_KEYS = frozenset("""
pid active recent connections first_faults event_loop ready routes codex claude
fault
fault_id timestamp time kind phase error type errno connection_id record_id request_id
attempt stream_id request connection pool id waiting state last_reason reason outcome
last_observed_seconds_ago lag_seconds lag_ms max_lag_ms active_omitted probe_error
local_ip local_port peer_ip peer_port interface gateway count exit_code availability
session_hash client_id provider_request_id native_request_id correlation
created_at started_at updated_at ended_at completed_at age_seconds silence_seconds
duration_seconds elapsed_seconds upstream_request_id protocol http_version tls_version
cipher alpn port origin host http2_stream_id events lifecycle frames frame_counts
inbound outbound read_bytes written_bytes reads writes reused reuse_count closed
active_streams idle_connections active_connections queued_requests configured_limits
max_connections max_keepalive_connections keepalive_expiry max_concurrent_streams
read write connect close timeout timeouts current_wait last_activity
stream_id flags length frame_type error_code last_stream_id increment settings
bytes bytes_read bytes_written eof fin rst exceptions cancellation cancellation_origin
stack function module line line_number cancelled terminal_event status status_code
total completed failed interrupted healthy unhealthy unknown responsive
rss_vsz_etime cpu_percent process_state rss_kib vsz_kib elapsed
caveman_8787 headroom_8788
route client_request_id session_ids cancellations first_fault_id pool_id client_port
client_http_version upstream_http_version upstream_ids attempts errors http2_settings waits
age_ms at_ms duration_ms error_type retry_delay_ms disconnected event task_cancelled
total_ms max_ms active_ms last_completed_ms_ago first_error tcp close_evidence
read_eof fin_rst_direction tls_close_notify last_read_ms_ago last_write_ms_ago write_bytes
http2 remote_settings local_settings data_payload_bytes window_update_increments streams
recent_frames metadata_omitted_frames observer_errors buffered_bytes pending_frames
remaining_payload_bytes direction metadata_omitted origin_id keepalive_expiry_seconds
assigned_requests total_connections omitted_connections omitted_records origins pools
idle expired stream_limit retransmits unacked rtt_us total_retrans h2_event remote_reset
client_addr server_addr socket_read socket_write upstream_read downstream_send downstream_yield
connect_tcp start_tls send_request_headers send_request_body receive_response_headers
receive_response_body receive_remote_settings response_closed
HEADER_TABLE_SIZE ENABLE_PUSH MAX_CONCURRENT_STREAMS INITIAL_WINDOW_SIZE MAX_FRAME_SIZE
MAX_HEADER_LIST_SIZE DATA HEADERS PRIORITY RST_STREAM SETTINGS PUSH_PROMISE PING GOAWAY
WINDOW_UPDATE CONTINUATION request-id x-request-id anthropic-request-id cf-ray
header_table_size enable_push initial_window_size max_frame_size max_header_list_size
enable_connect_protocol no_rfc7540_priorities connect_unix_socket send_connection_init retry
""".split())
HASH_KEYS = frozenset({"session_id", "x-session-id", "x-claude-code-session-id", "conversation_id"})
METADATA_KEYS |= HASH_KEYS
METADATA_KEYS |= frozenset("""
loop_lag_ms max_loop_lag_ms samples uptime_seconds tasks running cancelled_count
forensics_schema tls version rtt_ms tx_packets tx_retransmit_bytes rx_packets
rx_out_of_order_bytes tx_retransmit_packets captured_at runtime python libraries
http_client httpx httpcore h2 http2_enabled proxy_configured connect_timeout_seconds
read_timeout_seconds write_timeout_seconds pool_timeout_seconds compression_executor
max_workers queued queued_max queue_timeouts_total queue_wait_seconds_total
queue_wait_seconds_max in_flight in_flight_max run_seconds_total run_seconds_max
leaked_threads_total quarantine_active timed_out_workers timed_out_workers_max
quarantine_activations_total quarantine_skips_total source websocket_sessions
active_sessions active_relay_tasks anthropic_pre_upstream enabled resolved_concurrency
acquire_timeout_seconds compression_timeout_seconds memory_context_timeout_seconds codex_ws_gated
interval_ms window_seconds last_lag_ms heartbeat_age_ms consecutive_failures
last_observed_at last_stream active_requests oldest_active_seconds longest_active_idle_seconds
""".split())
IDENTIFIER_KEYS = frozenset({"fault_id", "request_id", "connection_id", "client_id", "provider_request_id",
                            "native_request_id", "upstream_request_id", "session_hash"})
IDENTIFIER_KEYS |= frozenset({"client_request_id", "first_fault_id", "pool_id", "origin_id",
                             "request-id", "x-request-id", "anthropic-request-id", "cf-ray"})


def _metadata(value, key="", depth=0):
    """Whitelist at every retention boundary, including older installed proxies."""
    if depth > 12:
        return None
    if isinstance(value, dict):
        return {k: _metadata(v, k, depth + 1) for k, v in list(value.items())[:256]
                if k in METADATA_KEYS}
    if isinstance(value, list):
        if key in {"client_addr", "server_addr"}:
            if len(value) != 2 or type(value[1]) is not int or not 0 < value[1] <= 65535:
                return None
            try:
                if isinstance(value[0], str) and "%" in value[0]:
                    return None
                return [str(ipaddress.ip_address(value[0])), value[1]]
            except ValueError:
                return None
        return [_metadata(v, key, depth + 1) for v in value[:64]]
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value if abs(value) <= 10**18 and math.isfinite(value) else None
    if not isinstance(value, str):
        return None
    if key in {"error", "errors", "first_error", "stack", "session_ids", "upstream_ids"}:
        return None
    if key in HASH_KEYS:
        return value if re.fullmatch(r"[0-9a-f]{24}", value) else None
    if key in {"http_version", "client_http_version", "upstream_http_version", "alpn"}:
        return value if value in {"1.0", "1.1", "2", "3", "HTTP/1.0", "HTTP/1.1", "HTTP/2", "HTTP/3", "h2", "http/1.1"} else None
    if key in {"time", "timestamp", "captured_at", "last_observed_at", "created_at", "started_at", "updated_at", "ended_at", "completed_at"}:
        return value if re.fullmatch(r"\d{4}-\d\d-\d\dT[0-9:.+-]{8,32}Z?", value) else None
    if key in {"local_ip", "peer_ip", "gateway"}:
        try:
            if "%" in value:
                return None
            return str(ipaddress.ip_address(value))
        except ValueError:
            return None
    if key == "rss_vsz_etime":
        return value if re.fullmatch(r"[0-9: -]{1,80}", value) else None
    if key in IDENTIFIER_KEYS:
        return value if re.fullmatch(r"[A-Za-z0-9_-]{1,160}", value) else None
    return value if re.fullmatch(r"[A-Za-z0-9_.:-]{1,96}", value) else None


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
            payload = response.read(2 * 1024 * 1024 + 1)
            if len(payload) > 2 * 1024 * 1024:
                raise ValueError("diagnostic snapshot exceeds 2 MiB")
            result = json.loads(payload)
            if not isinstance(result, dict):
                raise ValueError("invalid diagnostic snapshot")
            return result
    except HTTPError as error:
        # /readyz returns 503 when observed route health is unhealthy.
        if url == READY_URL and error.code == 503:
            payload = error.read(2 * 1024 * 1024 + 1)
            if len(payload) > 2 * 1024 * 1024:
                raise ValueError("diagnostic snapshot exceeds 2 MiB")
            result = json.loads(payload)
            if not isinstance(result, dict):
                raise ValueError("invalid diagnostic snapshot")
            return result
        raise


def _safe_log_tail() -> list[dict]:
    result = deque(maxlen=100)
    for path in (HEADROOM / "logs/proxy-8788.log.1", HEADROOM / "logs/proxy-8788.log"):
        try:
            with path.open(errors="replace") as source:
                for line in source:
                    for event in ("stream_diagnostic", "proxy_loop_lag", "route_stream_outcome", "upstream_stream_timing"):
                        marker = f"event={event} "
                        if marker not in line:
                            continue
                        payload = line.split(marker, 1)[1][:32000]
                        try:
                            fields = json.loads(payload)
                        except ValueError:
                            fields = dict(re.findall(r"\b([a-z_]+)=([^\s]+)", payload))
                        if isinstance(fields, dict):
                            prefix = re.search(r"\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:[.,]\d{1,6})?(?:Z|[+-]\d\d:?\d\d)?", line[:80])
                            stamp = None
                            zone = "unknown"
                            if prefix:
                                try:
                                    parsed = datetime.fromisoformat(prefix[0].replace(",", "."))
                                    zone = "explicit" if parsed.tzinfo else "host_local_assumed"
                                    stamp = parsed.astimezone(timezone.utc).isoformat()
                                except ValueError:
                                    pass
                            result.append({"event": event, "time": stamp, "timestamp_timezone": zone,
                                           "metadata": _metadata(fields)})
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
                if not isinstance(event, dict):
                    continue
                if event.get("msg") in {
                    "upstream transport error; retrying",
                    "upstream rejected transformed request; retrying with original bytes",
                    "cannot bind proxy listener",
                }:
                    result.append({"category": {"upstream transport error; retrying": "transport_retry",
                                   "upstream rejected transformed request; retrying with original bytes": "upstream_retry",
                                   "cannot bind proxy listener": "listener_bind_failed"}[event["msg"]],
                                   **_metadata({key: event[key] for key in ("time", "attempt", "request_id") if key in event})})
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
        pid = str(int(found.stdout.splitlines()[0]))
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


def _command_snapshot(command: list[str], parser=None) -> dict:
    """Fixed probes retain parsed metadata only; stdout/stderr never leave here."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=3, check=False)
        output = result.stdout[-64000:] if command[0] == "pmset" else result.stdout[:64000]
        return {"exit_code": result.returncode, "availability": "available" if result.returncode == 0 else "probe_failed",
                "truncated": len(result.stdout) > 64000, **(parser(output) if parser else {})}
    except (OSError, subprocess.TimeoutExpired, ValueError, TypeError) as error:
        return {"availability": "probe_unavailable", "probe_error": type(error).__name__}


def _parse_route(output: str) -> dict:
    result = {}
    for key in ("gateway", "interface"):
        found = re.search(rf"^\s*{key}:\s*(\S+)\s*$", output, re.MULTILINE)
        if found:
            value = _metadata(found[1], key)
            if value:
                result[key] = value
    return result


def _parse_tcp_counters(output: str) -> dict:
    counters = {}
    for name, pattern in {"retransmitted_packets": r"packets? retransmitted", "dropped_connections": r"connections? dropped",
                          "sent_resets": r"(?:control packets|resets?) sent", "received_packets": r"packets? received"}.items():
        found = re.search(rf"^\s*(\d+)\s+{pattern}\b", output, re.MULTILINE)
        if found:
            counters[name] = int(found[1])
    return {"counters": counters, "scope": "host_wide"}


def _parse_sockets(output: str) -> dict:
    connections = []
    current = None
    for line in output.splitlines():
        if line.startswith(("p", "f", "n")):
            current = None
        if line.startswith("TST=") and current is not None and line[4:] in {"ESTABLISHED", "CLOSED", "SYN_SENT", "SYN_RECEIVED",
            "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING", "LAST_ACK", "TIME_WAIT", "LISTEN"}:
            current["state"] = line[4:]
        match = re.fullmatch(r"n(\d+(?:\.\d+){3}):(\d+)->(\d+(?:\.\d+){3}):(\d+)", line)
        if not match:
            continue
        try:
            local, peer = str(ipaddress.ip_address(match[1])), str(ipaddress.ip_address(match[3]))
            local_port, peer_port = int(match[2]), int(match[4])
            if not 0 < local_port <= 65535 or not 0 < peer_port <= 65535:
                continue
            current = {"local_ip": local, "local_port": local_port, "peer_ip": peer, "peer_port": peer_port}
            connections.append(current)
        except ValueError:
            continue
    return {"connections": connections[:32], "ipv6_availability": "unparsed"}


def _network_snapshot(listeners: dict) -> dict:
    return {
        # These counters are host-wide, not proof that this proxy lost packets.
        "default_route": _command_snapshot(["route", "-n", "get", "default"], _parse_route),
        "tcp_counters": _command_snapshot(["netstat", "-s", "-p", "tcp"], _parse_tcp_counters),
        "sockets": {
            name: _command_snapshot(["lsof", "-nP", "-a", "-p", str(sample["pid"]),
                                     "-iTCP", "-FpfntT"], _parse_sockets)
            for name, sample in listeners.items() if sample is not None
        },
    }


def _power_events(output: str) -> dict:
    events = []
    for line in output.splitlines():
        match = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [+-]\d{4})\s+(Sleep|Wake|DarkWake)\b", line)
        if match:
            stamp = datetime.strptime(match[1], "%Y-%m-%d %H:%M:%S %z").astimezone(timezone.utc).isoformat()
            events.append({"time": stamp, "category": match[2].lower()})
    return {"events": events[-16:]}


def _host_snapshot(listeners=None) -> dict:
    listeners = listeners if listeners is not None else {"headroom_8788": _listener_memory(8788)}
    try:
        load = list(os.getloadavg())
    except OSError:
        load = None
    if sys.platform != "darwin":
        return {"availability": "unsupported_platform", "load_average": load}
    network = _network_snapshot(listeners)
    return {
        "availability": "available", "network": network, "load_average": load,
        "descriptor_counts": {name: _command_snapshot(["lsof", "-nP", "-a", "-p", str(sample["pid"]), "-Ff"],
                                      lambda output: {"count": sum(bool(re.fullmatch(r"f\d+", line)) for line in output.splitlines())})
                              for name, sample in listeners.items() if sample is not None},
        "memory_pressure": _command_snapshot(["vm_stat"], lambda output: {"pages": {
            name.replace(" ", "_"): int(count) for name, count in re.findall(
                r"^(Pages (?:free|active|inactive|wired down|occupied by compressor)):\s*(\d+)\.", output, re.MULTILINE)}}),
        "power_events": _command_snapshot(["pmset", "-g", "log"], _power_events),
        "packet_metadata": _packet_metadata(network.get("sockets", {}), network.get("default_route", {}).get("interface")),
    }


def _sample_host_context(state: dict, now: float) -> None:
    current = _host_snapshot()
    mono = time.monotonic()
    previous = state.get("host_context") or {}
    before = previous.get("network") or {}
    after = current.get("network") or {}
    categories = []
    if previous:
        if before.get("default_route") != after.get("default_route"):
            categories.append("route_change")
            old_interface = (before.get("default_route") or {}).get("interface", "")
            new_interface = (after.get("default_route") or {}).get("interface", "")
            if str(old_interface).startswith("utun") != str(new_interface).startswith("utun"):
                categories.append("vpn_interface_transition")
        if before.get("sockets") != after.get("sockets"):
            categories.append("peer_or_socket_change")
        wall_gap = now - previous.get("sample_wall", now)
        mono_gap = mono - previous.get("sample_monotonic", mono)
        if wall_gap > SAMPLE_SECONDS * 2 or abs(wall_gap - mono_gap) > 5:
            categories.append("sleep_or_clock_change")
    current.update(sample_wall=now, sample_monotonic=mono)
    state["host_context"] = current
    if categories:
        state["host_changes"] = (state.get("host_changes") or [])[-31:] + [{
            "time": datetime.fromtimestamp(now, timezone.utc).isoformat(), "categories": categories}]


def _packet_metadata(sockets: dict, interface: str | None) -> dict:
    """Opt-in, exact IPv4 tuples and zero TCP payload, enforced by capture BPF."""
    result = {"availability": "disabled_permission_required", "events": [],
              "retransmission": "unavailable_control_only_capture", "window_seconds": 1,
              "coverage": "future_window_only", "tuple_limit": 4, "ipv6_availability": "unsupported"}
    if os.environ.get("PROXY_WATCHDOG_PACKET_METADATA") != "1":
        return result
    binary = shutil.which("tcpdump")
    if not binary:
        return {**result, "availability": "tool_unavailable"}
    if not isinstance(interface, str) or not re.fullmatch(r"(?:en|eth|utun|lo)\d{1,3}", interface):
        return {**result, "availability": "interface_unavailable"}
    tuples = []
    for sample in sockets.values():
        for connection in sample.get("connections", [])[:32]:
            try:
                local, peer = ipaddress.IPv4Address(connection["local_ip"]), ipaddress.IPv4Address(connection["peer_ip"])
                local_port, peer_port = int(connection["local_port"]), int(connection["peer_port"])
                if 0 < local_port <= 65535 and 0 < peer_port <= 65535:
                    tuples.append((str(local), local_port, str(peer), peer_port))
            except (KeyError, TypeError, ValueError, ipaddress.AddressValueError):
                continue
    tuples = list(dict.fromkeys(tuples))[:4]
    if not tuples:
        return {**result, "availability": "connection_unavailable"}
    filters = [f"((src host {local} and src port {lp} and dst host {peer} and dst port {pp}) or "
               f"(src host {peer} and src port {pp} and dst host {local} and dst port {lp}))"
               for local, lp, peer, pp in tuples]
    # BPF rejects fragments and requires total IP length == IP + TCP headers.
    # The kernel admits zero TCP payload bytes regardless of either option length.
    controls = ("ip and (ip[0] & 0xf0 = 0x40) and (ip[0] & 0x0f >= 5) "
                "and (ip[6:2] & 0x3fff = 0) and (tcp[12] & 0xf0 >= 0x50) "
                "and (ip[2:2] = ((ip[0] & 0x0f) * 4 + ((tcp[12] & 0xf0) >> 2)))")
    command = [binary, "-n", "-tt", "-l", "-S", "-s", "96", "-c", "64", "-i", interface,
               controls + " and (" + " or ".join(filters) + ")"]
    try:
        captured = subprocess.run(command, capture_output=True, text=True, timeout=1, check=False)
        if captured.returncode:
            return {**result, "availability": "permission_or_probe_failed", "exit_code": captured.returncode}
        output = captured.stdout
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("ascii", errors="ignore")
    except OSError as error:
        return {**result, "availability": "probe_unavailable", "probe_error": type(error).__name__}
    pattern = r"^(\d+(?:\.\d+)?) IP (\d+(?:\.\d+){3})\.(\d+) > (\d+(?:\.\d+){3})\.(\d+): Flags \[([FSRPAU.EW]+)\]"
    events = []
    for line in output[:16000].splitlines():
        match = re.match(pattern, line)
        length = re.search(r"\blength (\d+)\b", line)
        if not match or not length or int(length[1]) != 0:
            continue
        src, sp, dst, dp = match[2], int(match[3]), match[4], int(match[5])
        direction = None
        if (src, sp, dst, dp) in tuples:
            direction = "outbound"
        elif (dst, dp, src, sp) in tuples:
            direction = "inbound"
        if direction:
            events.append({"time_epoch": float(match[1]), "direction": direction, "fin": "F" in match[6],
                           "rst": "R" in match[6], "local_port": sp if direction == "outbound" else dp,
                           "peer_port": dp if direction == "outbound" else sp,
                           "local_ip": src if direction == "outbound" else dst,
                           "peer_ip": dst if direction == "outbound" else src})
    return {**result, "availability": "available", "events": events[:64]}


def _save_json(path: Path, data: dict) -> bool:
    if path.parent != INCIDENTS:
        return _write_json(path, data)
    descriptor = None
    try:
        descriptor = os.open(INCIDENTS, os.O_RDONLY)
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        data["incident_storage"] = {"availability": "capacity_unavailable", "probe_error": type(error).__name__,
                                    "reason": "incident_writer_busy" if isinstance(error, BlockingIOError) else "directory_lock_unavailable"}
        return False
    try:
        return _write_json(path, data)
    finally:
        os.close(descriptor)


def _write_json(path: Path, data: dict) -> bool:
    if path == STATE_PATH:
        for key in ("diagnostic_samples", "last_routes"):
            if key in data:
                data[key] = _metadata(data[key])
        if "memory_samples" in data:
            data["memory_samples"] = [_metadata(sample) for sample in data["memory_samples"][-SAMPLE_LIMIT:]]
        previous = data.get("last_stream_diagnostics")
        if isinstance(previous, dict):
            data["last_stream_diagnostics"] = {"time": _metadata(previous.get("time"), "time"),
                                               "data": _metadata(previous.get("data"))}
    if path.parent == INCIDENTS and not path.exists():
        retained = sorted(p for p in INCIDENTS.glob("*.json")
                          if re.fullmatch(r"\d{8}T\d{12}Z-(?:codex|claude|manual|first-fault|headroom_health_endpoint)\.json", p.name))
        needed = max(0, len(retained) + 1 - INCIDENT_LIMIT)
        storage = {"availability": "capacity_unavailable", "limit": INCIDENT_LIMIT,
                   "retained_files": len(retained), "reason": "existing_directory_over_limit" if len(retained) > INCIDENT_LIMIT
                   else "incident_file_limit"}
        for expired in retained[:needed]:
            try:
                expired.unlink(missing_ok=True)
                storage["retained_files"] -= 1
            except OSError as error:
                data["incident_storage"] = {**storage, "probe_error": type(error).__name__}
                return False
        if needed > len(retained):
            data["incident_storage"] = storage
            return False
    data.pop("incident_storage", None)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)
    return True


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
        return {"exit_code": result.returncode, "output": "omitted_metadata_only"}
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"exit_code": None, "probe_error": type(error).__name__, "output": "omitted_metadata_only"}


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
        return _metadata(_get_json(url))
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
        snapshot = _metadata(snapshot)
        connections = snapshot.get("connections", [])
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
    _capture_first_faults(snapshot, state, now)


def _capture_first_faults(snapshot: dict, state: dict, now: float) -> None:
    if not isinstance(snapshot.get("first_faults"), list):
        state["first_fault_capture"] = {"availability": "unsupported_proxy_schema"}
        return
    try:
        status = _persist_first_faults(snapshot, state, now)
    except Exception as error:
        # Observation failures must not skip health polling or existing recovery.
        state["first_fault_capture"] = {"availability": "probe_unavailable", "probe_error": type(error).__name__}
    else:
        state["first_fault_capture"] = status or {"availability": "available"}


def _persist_first_faults(snapshot: dict, state: dict, now: float) -> dict | None:
    faults = snapshot.get("first_faults") or []
    if not isinstance(faults, list):
        return
    retained = state.setdefault("first_fault_incidents", [])
    seen = {item.get("fault_id") for item in retained if isinstance(item, dict)}
    host = state.get("host_context")
    for fault in faults[:16]:
        if not isinstance(fault, dict):
            continue
        fault_id = fault.get("fault_id")
        if not fault_id or fault_id in seen:
            continue
        INCIDENTS.mkdir(parents=True, exist_ok=True)
        stamp = datetime.fromtimestamp(now, timezone.utc).isoformat()
        path = INCIDENTS / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S%fZ}-first-fault.json"
        incident = {"time": stamp, "event": "first_transport_fault", "first_fault": fault,
                    "stream_diagnostics": snapshot, "host": host or {"availability": "pending"},
                    "host_changes": state.get("host_changes", [])[-32:],
                    "recovery": "not_requested_by_first_fault", "outcome": "unknown"}
        if _save_json(path, incident) is False:
            return incident["incident_storage"]
        retained.append({"fault_id": fault_id, "pid": fault.get("pid"), "time": stamp, "incident": str(path)})
        retained[:] = retained[-64:]
        seen.add(fault_id)
        if host is None:
            host = _host_snapshot()
        incident["host"] = host
        _save_json(path, incident)


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
    stream_diagnostics = _metadata(_snapshot(STREAMS_URL))
    _capture_first_faults(stream_diagnostics, state, time.time())
    listeners = {
        "caveman_8787": _listener_memory(8787),
        "headroom_8788": _listener_memory(8788),
    }
    host = _host_snapshot(listeners)
    incident = {
        "time": datetime.now(timezone.utc).isoformat(),
        "route": route,
        "stream_diagnostics": stream_diagnostics,
        "last_stream_diagnostics": ({"time": _metadata(state["last_stream_diagnostics"].get("time"), "time"),
                                      "data": _metadata(state["last_stream_diagnostics"].get("data"))}
                                     if isinstance(state.get("last_stream_diagnostics"), dict) else None),
        "diagnostic_samples": _metadata(state.get("diagnostic_samples", [])),
        "diagnostics_probe_error": state.get("diagnostics_probe_error"),
        "routes": _metadata(routes),
        "listeners": listeners,
        "network": host.get("network", {}),
        "host": host,
        "host_changes": state.get("host_changes", [])[-32:],
        "first_fault_incidents": state.get("first_fault_incidents", [])[-64:],
        "first_fault_capture": state.get("first_fault_capture"),
        "readiness": _metadata(_snapshot(READY_URL)),
        "tasks": _metadata(_snapshot("http://127.0.0.1:8788/debug/tasks")),
        "stream_logs": _safe_log_tail(),
        "caveman_events": _safe_caveman_tail(),
        "memory_samples": [_metadata(sample) for sample in state.get("memory_samples", [])[-SAMPLE_LIMIT:]],
    }
    incident_path = INCIDENTS / f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S%fZ}-{route}.json"
    if _save_json(incident_path, incident) is False:
        # A single replacement record preserves recovery evidence without adding
        # files when old incidents cannot be expired.
        state["incident_fallback"] = {"requested_path": str(incident_path), "data": incident}
    return incident_path, incident


def capture() -> None:
    """Save evidence on demand, including failures before reaching Headroom."""
    os.umask(0o077)
    state = json.loads(STATE_PATH.read_text()) if STATE_PATH.exists() else {}
    path, _ = _capture_incident("manual", _snapshot(ROUTE_URL), state)
    print(f"Captured proxy evidence: {path}" if path.exists() else "Incident storage unavailable; no new report saved.")


def _report_cooldown_failure(route: str, routes: dict, state: dict, now: float, remaining: int) -> None:
    alerts = state.setdefault("cooldown_alerts", {})
    reason = _metadata((routes.get(route) or {}).get("last_reason") or routes.get("probe_error") or "unhealthy", "reason") or "unknown"
    previous = alerts.get(route)
    if previous and previous.get("last_attempt") == state["last_attempt"]:
        previous.update(failure_reason=reason, cooldown_remaining_seconds=remaining)
        _save_json(STATE_PATH, state)
        return
    incident_path, incident = _capture_incident(route, routes, state)
    suppression = {"reason": "restart_cooldown", "failure_reason": reason,
                   "last_attempt": state["last_attempt"], "cooldown_remaining_seconds": remaining}
    incident["recovery_suppressed"] = suppression
    incident["restart_decision"] = _restart_decision(route, incident, "restart_cooldown")
    _save_json(incident_path, incident)
    report_path = incident_path if incident_path.exists() else STATE_PATH
    alerts[route] = {**suppression, "detected_at": datetime.fromtimestamp(now, timezone.utc).isoformat(),
                     "incident": str(report_path)}
    state["incident"] = str(report_path)
    _save_json(STATE_PATH, state)
    _notify(f"{route} failure; restart delayed by cooldown ({remaining}s). Evidence captured.")
    print(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "event": "recovery_suppressed",
                      "route": route, **suppression, "incident": str(report_path)}), flush=True)


def recover(route: str, routes: dict, state: dict, now: float) -> bool:
    # A deliberately unloaded service must stay stopped. KeepAlive handles
    # crashes; a loaded but unresponsive service still needs recovery.
    if not _managed_headroom_loaded():
        state["restart_decision"] = {"time": datetime.now(timezone.utc).isoformat(), "trigger": route,
                                     "decision": "service_deliberately_unloaded"}
        return False
    last_attempt = state.get("last_attempt", 0)
    remaining = max(0, math.ceil(last_attempt + COOLDOWN_SECONDS - now)) if last_attempt else 0
    if remaining:
        _report_cooldown_failure(route, routes, state, now, remaining)
        return False
    incident_path, incident = _capture_incident(route, routes, state)
    incident["restart_decision"] = _restart_decision(route, incident, "restart")
    _save_json(incident_path, incident)
    report_path = incident_path if incident_path.exists() else STATE_PATH
    for fault in incident["first_fault_incidents"]:
        old_pid = incident["restart_decision"].get("old_pid")
        if old_pid is not None and fault.get("pid") != old_pid:
            continue
        path = Path(fault.get("incident", ""))
        if path.parent == INCIDENTS and path.name.endswith("-first-fault.json") and path.exists():
            try:
                frozen = json.loads(path.read_text())
                frozen["recovery_incident"] = str(report_path)
                frozen["recovery"] = "restart_requested"
                _save_json(path, frozen)
            except (OSError, ValueError, TypeError):
                pass
    state.update(last_attempt=now, incident=str(report_path), cooldown_alerts={})
    _save_json(STATE_PATH, state)
    incident["restart"] = _restart_headroom()
    incident["ready_after_restart"] = _ready_after_restart()
    # Process readiness cannot prove that either provider recovered. Only a
    # subsequent real request can establish route health after restart.
    incident["provider_recovery"] = "unverified_pending_real_traffic"
    incident["aftermath"] = _restart_aftermath(incident)
    if _save_json(incident_path, incident) is False:
        state["incident_fallback"] = {"requested_path": str(incident_path), "data": incident}
        _save_json(STATE_PATH, state)
    restarted = incident["restart"]["exit_code"] == 0 and incident["ready_after_restart"]
    message = (
        f"{route} failure; Headroom restarted. API recovery awaits real traffic."
        if restarted
        else f"{route} failure; Headroom recovery failed. See incident report."
    )
    _notify(message)
    print(f"{datetime.now(timezone.utc).isoformat()} {message} {report_path}", flush=True)
    return True


def _restart_decision(route: str, incident: dict, decision: str) -> dict:
    snapshot = incident.get("stream_diagnostics") or {}
    evidence_source = "live_snapshot"
    if snapshot.get("probe_error"):
        previous = incident.get("last_stream_diagnostics") or {}
        snapshot = previous.get("data") or {}
        evidence_source = "last_good_snapshot"
    listener_pid = ((incident.get("listeners") or {}).get("headroom_8788") or {}).get("pid")
    return {"time": datetime.now(timezone.utc).isoformat(), "monotonic": time.monotonic(),
            "trigger": route, "decision": decision, "old_pid": listener_pid or snapshot.get("pid"),
            "request_evidence_source": evidence_source,
            "readiness": incident.get("readiness"), "event_loop": snapshot.get("event_loop"),
            "active_requests": [{"request_id": item.get("request_id"), "record_id": item.get("record_id", item.get("id")),
                                 "pid": snapshot.get("pid")} for item in snapshot.get("active", [])[:64]
                                if isinstance(item, dict)]}


def _restart_aftermath(incident: dict) -> dict:
    after = _metadata(_snapshot(STREAMS_URL))
    decision = incident["restart_decision"]
    old_pid, new_pid = decision.get("old_pid"), after.get("pid")
    requests = []
    for identity in decision.get("active_requests", []):
        outcome = "unknown"
        # PID mismatch or disappearance alone cannot establish abortion/completion.
        if old_pid is not None and old_pid == new_pid and identity.get("pid", old_pid) == old_pid and identity.get("request_id"):
            for recent in after.get("recent", []):
                record_matches = identity.get("record_id") is None or recent.get("record_id") == identity["record_id"]
                if recent.get("request_id") == identity["request_id"] and record_matches:
                    reason = recent.get("reason", recent.get("outcome", recent.get("last_reason")))
                    if reason == "completed":
                        outcome = "completed"
                    elif reason in {"interrupted", "cancelled", "downstream_disconnect", "sse_error", "missing_terminal_event"}:
                        outcome = "aborted"
        requests.append({**identity, "outcome": outcome})
    return {"time": datetime.now(timezone.utc).isoformat(), "monotonic": time.monotonic(), "new_pid": new_pid,
            "readiness": _metadata(_snapshot(READY_URL)), "event_loop": after.get("event_loop"),
            "probe_error": after.get("probe_error"), "requests": requests}


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
                _sample_host_context(state, now)
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
                routes = _metadata(_get_json(ROUTE_URL))
            except (OSError, ValueError, HTTPException) as error:
                probe_failures += 1
                if probe_failures >= 3:
                    recover("headroom_health_endpoint", {"probe_error": type(error).__name__}, state, now)
                    _save_json(STATE_PATH, state)
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
            _save_json(STATE_PATH, state)
        except (OSError, ValueError, TypeError, HTTPException) as error:
            message = type(error).__name__
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
