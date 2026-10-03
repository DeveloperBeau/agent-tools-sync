import importlib.util
import fcntl
import ctypes
import ctypes.util
import io
import pathlib
import json
import plistlib
import tempfile
import struct
import subprocess
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from http.client import IncompleteRead
from unittest.mock import patch
from types import SimpleNamespace


MODULE = pathlib.Path(__file__).resolve().parents[1] / "lib" / "proxy_watchdog.py"
spec = importlib.util.spec_from_file_location("proxy_watchdog", MODULE)
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


def route(state, reason, age=1):
    return {
        "state": state,
        "last_reason": reason,
        "last_observed_seconds_ago": age,
    }


class RecoveryDecisionTests(unittest.TestCase):
    def test_stop_requested_during_capture_prevents_restart_and_preserves_cooldown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = {"last_attempt": 100, "operator_setting": "keep"}
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_managed_headroom_loaded", side_effect=[True, False]), \
                 patch.object(watchdog, "_snapshot", return_value={"ready": True}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_notify"):
                self.assertFalse(watchdog.recover("manual", {}, state, 10000, force=True))
                restart.assert_not_called()
            self.assertEqual(state["last_attempt"], 100)
            self.assertEqual(state["operator_setting"], "keep")
            incident = json.loads(next((root / "incidents").glob("*-manual.json")).read_text())
            self.assertEqual(incident["restart_decision"]["decision"], "service_deliberately_unloaded")

    def test_manual_fire_refuses_old_running_watcher_without_state_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            original = '{"last_attempt":9500,"operator_setting":"keep"}'
            state_path.write_text(original)
            with state_path.with_suffix(".lock").open("a") as lock, \
                 patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_snapshot") as snapshot:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with redirect_stdout(io.StringIO()) as output:
                    self.assertFalse(watchdog.fire())
                self.assertIn("reload", output.getvalue())
                self.assertEqual(state_path.read_text(), original)
                restart.assert_not_called()
                snapshot.assert_not_called()

    def test_poll_owns_control_lock_through_diagnostic_sampling(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def sample(state, now):
                with self.assertRaises(BlockingIOError):
                    with watchdog._state_lock(blocking=False):
                        pass
                self.assertEqual(state["control_schema"], 1)
                raise KeyboardInterrupt
            with patch.object(watchdog, "STATE_PATH", root / "state.json"), \
                 patch.object(watchdog, "_sample_diagnostics", side_effect=sample):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog._watch()
                with watchdog._state_lock(blocking=False):
                    pass

    def test_stop_marker_blocks_loaded_service_without_launchctl_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            (pathlib.Path(directory) / "ats-stopped").touch()
            with patch.dict(watchdog.os.environ, {"CAVEMAN_HOME": directory}), \
                 patch.object(watchdog.subprocess, "run") as run:
                self.assertFalse(watchdog._managed_headroom_loaded())
                run.assert_not_called()

    def test_manual_fire_returns_failure_for_failed_restart_or_missing_readiness(self):
        for exit_code, ready in [(1, True), (0, False)]:
            with self.subTest(exit_code=exit_code, ready=ready), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                state_path = root / "state.json"
                with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                     patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                     patch.object(watchdog, "_snapshot", return_value={"ready": True}), \
                     patch.object(watchdog, "_listener_memory", return_value=None), \
                     patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                     patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                     patch.object(watchdog, "_restart_headroom", return_value={"exit_code": exit_code}), \
                     patch.object(watchdog, "_ready_after_restart", return_value=ready), \
                     patch.object(watchdog, "_restart_aftermath", return_value={}), \
                     patch.object(watchdog, "_notify"), redirect_stdout(io.StringIO()):
                    self.assertFalse(watchdog.fire())
                stored = json.loads(state_path.read_text())
                self.assertEqual(stored["last_recovery_result"], {"exit_code": exit_code, "ready": ready})
                self.assertIn("incident", stored)

    def test_manual_fire_bypasses_detection_and_cooldown_with_saved_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            state_path.write_text(json.dumps({"last_attempt": 9999, "operator_setting": "keep"}))
            def restart():
                state = json.loads(state_path.read_text())
                incident = json.loads(pathlib.Path(state["incident"]).read_text())
                self.assertEqual(incident["restart_decision"]["trigger"], "manual")
                self.assertTrue(incident["restart_decision"]["forced"])
                self.assertEqual(state["operator_setting"], "keep")
                return {"exit_code": 0}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_snapshot", return_value={"ready": True}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart) as run, \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_restart_aftermath", return_value={}), \
                 patch.object(watchdog, "_notify"), patch.object(watchdog.time, "time", return_value=10000):
                self.assertTrue(watchdog.fire())
                run.assert_called_once()

    def test_manual_fire_waits_for_poll_and_reads_state_after_lock_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            started = threading.Event()

            def fire():
                started.set()
                return watchdog.fire()

            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_snapshot", return_value={"ready": True}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_restart_headroom", return_value={"exit_code": 0}), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_restart_aftermath", return_value={}), \
                 patch.object(watchdog, "_notify"), redirect_stdout(io.StringIO()) as output, \
                 ThreadPoolExecutor(max_workers=1) as executor:
                with watchdog._state_lock():
                    future = executor.submit(fire)
                    self.assertTrue(started.wait(1))
                    with self.assertRaises(TimeoutError):
                        future.result(timeout=0.05)
                    state_path.write_text(json.dumps({"operator_setting": "latest poll"}))
                self.assertTrue(future.result(timeout=5))
            stored = json.loads(state_path.read_text())
            self.assertEqual(stored["operator_setting"], "latest poll")
            self.assertEqual(stored["last_recovery_result"], {"exit_code": 0, "ready": True})
            self.assertIn("waiting", output.getvalue())

    def test_manual_fire_honors_stop_requested_while_waiting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            started = threading.Event()

            def fire():
                started.set()
                return watchdog.fire()

            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.dict(watchdog.os.environ, {"CAVEMAN_HOME": directory}), \
                 patch.object(watchdog, "_snapshot", return_value={}), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 redirect_stdout(io.StringIO()) as output, ThreadPoolExecutor(max_workers=1) as executor:
                with watchdog._state_lock():
                    future = executor.submit(fire)
                    self.assertTrue(started.wait(1))
                    with self.assertRaises(TimeoutError):
                        future.result(timeout=0.05)
                    (root / "ats-stopped").touch()
                self.assertFalse(future.result(timeout=5))
                restart.assert_not_called()
            self.assertIn("deliberately stopped", output.getvalue())

    def test_manual_fire_times_out_when_poll_keeps_lock_and_never_restarts_stopped_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=False), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_notify"):
                with watchdog._state_lock(), \
                     patch.object(watchdog.time, "monotonic", side_effect=[100, 100, 280]), \
                     patch.object(watchdog.time, "sleep"), redirect_stdout(io.StringIO()) as output:
                    self.assertFalse(watchdog.fire())
                    self.assertIn("180", output.getvalue())
                    self.assertFalse((root / "state.json").exists())
                self.assertFalse(watchdog.fire())
                restart.assert_not_called()

    def setUp(self):
        if self._testMethodName not in {"test_host_snapshot_parses_only_route_addresses_and_numeric_counters",
                                       "test_packet_probe_failures_and_unsupported_host_do_not_expose_error_text"}:
            host = patch.object(watchdog, "_host_snapshot", return_value={"availability": "fixture"})
            host.start()
            self.addCleanup(host.stop)
        permission = patch.dict(watchdog.os.environ, {"PROXY_WATCHDOG_PACKET_METADATA": "0"})
        permission.start()
        self.addCleanup(permission.stop)

    def test_first_fault_is_captured_once_before_route_failure_and_retention_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            state = {}
            snapshot = {"pid": 42, "active": [], "connections": [], "first_faults": [
                {"fault_id": "fault-1", "timestamp": "2026-10-03T00:00:00Z", "pid": 42,
                 "kind": "transport_error", "phase": "read", "request_id": "hr_1",
                 "error": [{"type": "BrokenPipeError", "message": "secret sentinel"}]}]}
            with patch.object(watchdog, "INCIDENTS", pathlib.Path(directory)), \
                 patch.object(watchdog, "_get_json", return_value=snapshot), \
                 patch.object(watchdog, "_host_snapshot", return_value={}), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_notify") as notify:
                watchdog._sample_diagnostics(state, 100)
                watchdog._sample_diagnostics(state, 110)
                self.assertEqual(len(list(pathlib.Path(directory).glob("*.json"))), 1)
                self.assertEqual(state["first_fault_incidents"][0]["fault_id"], "fault-1")
                for i in range(100):
                    snapshot["first_faults"][0]["fault_id"] = f"fault-{i + 2}"
                    watchdog._sample_diagnostics(state, 120 + i)
            self.assertLessEqual(len(state["first_fault_incidents"]), 64)
            self.assertLessEqual(len(list(pathlib.Path(directory).glob("*.json"))), 64)
            self.assertNotIn("secret sentinel", json.dumps(state))
            restart.assert_not_called()
            notify.assert_not_called()

    def test_diagnostic_metadata_rejects_queries_headers_bodies_and_unsafe_ids(self):
        state = {}
        snapshot = {"pid": 42, "active": [{"request_id": "hr_safe", "session_id": "secret sentinel",
                    "session_ids": {"conversation_id": "secret_sentinel"},
                    "provider_request_id": "https://host/?secret=sentinel", "body": "secret sentinel",
                    "waiting": "upstream_read", "headers": {"authorization": "secret sentinel"}}],
                    "connections": [{"id": 1, "error": [{"type": "BrokenPipeError", "message": "secret sentinel"}]}],
                    "first_faults": []}
        with patch.object(watchdog, "_get_json", return_value=snapshot):
            watchdog._sample_diagnostics(state, 100)
        retained = json.dumps(state)
        self.assertNotIn("secret", retained)
        self.assertNotIn("https://", retained)
        self.assertIn("hr_safe", retained)
        self.assertIn("BrokenPipeError", retained)

    def test_host_snapshot_parses_only_route_addresses_and_numeric_counters(self):
        outputs = ["Routing tables\n gateway: 192.0.2.1\n interface: en0\nsecret sentinel\n",
                   "tcp:\n 12 packets retransmitted\n 3 connections dropped\nsecret sentinel\n",
                   "p42\nf1\nn192.0.2.2:50000->198.51.100.5:443\nTST=ESTABLISHED\nsecret sentinel\n",
                   "p42\nf1\nf2\nsecret sentinel\n", "vm_stat secret sentinel\nPages free: 123.\n",
                   "2026-10-03 10:00:00 +1000 Sleep Entering Sleep secret sentinel\n"
                   "2026-10-03 11:00:00 +1000 Wake Wake from Normal Sleep secret sentinel\n"]
        def run(command, **kwargs):
            return SimpleNamespace(returncode=0, stdout=outputs.pop(0), stderr="secret sentinel")
        with patch.object(watchdog.subprocess, "run", side_effect=run), \
             patch.object(watchdog.sys, "platform", "darwin"), \
             patch.object(watchdog.os, "getloadavg", return_value=(1.0, 2.0, 3.0)):
            host = watchdog._host_snapshot({"headroom_8788": {"pid": 42}})
        self.assertEqual(host["network"]["default_route"]["gateway"], "192.0.2.1")
        self.assertEqual(host["descriptor_counts"]["headroom_8788"]["count"], 2)
        self.assertEqual([e["category"] for e in host["power_events"]["events"]], ["sleep", "wake"])
        self.assertNotIn("secret sentinel", json.dumps(host))

    def test_host_changes_and_sleep_gap_are_categories_not_raw_logs(self):
        state = {"host_context": {"network": {"default_route": {"interface": "en0", "gateway": "192.0.2.1"},
                   "sockets": {}}, "sample_wall": 100, "sample_monotonic": 50}}
        current = {"network": {"default_route": {"interface": "utun2", "gateway": "192.0.2.2"}, "sockets": {}}}
        with patch.object(watchdog, "_host_snapshot", return_value=current), \
             patch.object(watchdog.time, "monotonic", return_value=60):
            watchdog._sample_host_context(state, 300)
        self.assertIn("route_change", state["host_changes"][-1]["categories"])
        self.assertIn("vpn_interface_transition", state["host_changes"][-1]["categories"])
        self.assertIn("sleep_or_clock_change", state["host_changes"][-1]["categories"])

    def test_restart_aftermath_links_fault_and_marks_unobserved_requests_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = {"first_fault_incidents": [{"fault_id": "fault-1", "pid": 42, "incident": "first-fault.json"}]}
            before = {"pid": 42, "active": [{"request_id": "hr_done"}, {"request_id": "hr_lost"}],
                      "event_loop": {"lag_seconds": 0.1}}
            after = {"pid": 43, "active": [], "recent": [{"request_id": "hr_done", "reason": "completed"}]}
            def snapshot(url):
                if url == watchdog.STREAMS_URL:
                    return before if not state.get("last_attempt") else after
                return {"ready": True}
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_snapshot", side_effect=snapshot), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_host_snapshot", return_value={}), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_restart_headroom", return_value={"exit_code": 0}), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_notify"):
                watchdog.recover("codex", {"codex": route("unhealthy", "sse_error")}, state, 10000)
            incident = json.loads(next((root / "incidents").glob("*.json")).read_text())
            self.assertEqual(incident["restart_decision"]["old_pid"], 42)
            self.assertEqual(incident["aftermath"]["new_pid"], 43)
            # A new process's reused request ID cannot prove the old request completed.
            self.assertEqual([r["outcome"] for r in incident["aftermath"]["requests"]], ["unknown", "unknown"])
            self.assertEqual(incident["first_fault_incidents"][0]["fault_id"], "fault-1")

    def test_packet_metadata_requires_permission_and_only_retains_tuple_flags(self):
        sockets = {"headroom_8788": {"connections": [{"local_ip": "192.0.2.2", "local_port": 50000,
                   "peer_ip": "198.51.100.5", "peer_port": 443}]}}
        with patch.dict(watchdog.os.environ, {}, clear=True), patch.object(watchdog.subprocess, "run") as run:
            self.assertEqual(watchdog._packet_metadata(sockets, "en0")["availability"], "disabled_permission_required")
            run.assert_not_called()
        output = "1728000000.1 IP 198.51.100.5.443 > 192.0.2.2.50000: Flags [R.], seq 123, ack 456, win 0, length 0\nsecret sentinel\n"
        with patch.dict(watchdog.os.environ, {"PROXY_WATCHDOG_PACKET_METADATA": "1"}), \
             patch.object(watchdog.shutil, "which", return_value="/usr/sbin/tcpdump"), \
             patch.object(watchdog.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=output, stderr="secret sentinel")) as run:
            result = watchdog._packet_metadata(sockets, "en0")
        self.assertEqual(result["events"][0]["direction"], "inbound")
        self.assertTrue(result["events"][0]["rst"])
        self.assertNotIn("secret sentinel", json.dumps(result))
        self.assertNotIn("-w", run.call_args.args[0])
        self.assertNotIn("-A", run.call_args.args[0])
        self.assertIn("192.0.2.2", run.call_args.args[0][-1])

    def test_packet_metadata_rejects_payload_and_marks_retransmission_unavailable(self):
        sockets = {"headroom_8788": {"connections": [{"local_ip": "192.0.2.2", "local_port": 50000,
                   "peer_ip": "198.51.100.5", "peer_port": 443}]}}
        line = "1728000000.1 IP 192.0.2.2.50000 > 198.51.100.5.443: Flags [P.], seq 100:200, ack 456, win 0, length 100\n"
        with patch.dict(watchdog.os.environ, {"PROXY_WATCHDOG_PACKET_METADATA": "1"}), \
             patch.object(watchdog.shutil, "which", return_value="/usr/sbin/tcpdump"), \
             patch.object(watchdog.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=line + line, stderr="")):
            result = watchdog._packet_metadata(sockets, "en0")
        self.assertEqual(result["events"], [])
        self.assertEqual(result["retransmission"], "unavailable_control_only_capture")

    def test_packet_filter_accepts_only_unfragmented_ipv4_without_tcp_payload(self):
        sockets = {"headroom_8788": {"connections": [{"local_ip": "192.0.2.2", "local_port": 50000,
                   "peer_ip": "198.51.100.5", "peer_port": 443}]}}
        with patch.dict(watchdog.os.environ, {"PROXY_WATCHDOG_PACKET_METADATA": "1"}), \
             patch.object(watchdog.shutil, "which", return_value="/usr/sbin/tcpdump"), \
             patch.object(watchdog.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")) as run:
            watchdog._packet_metadata(sockets, "en0")
        expression = run.call_args.args[0][-1].encode("ascii")
        library = ctypes.util.find_library("pcap")
        if library is None:
            self.skipTest("libpcap offline filter unavailable")
        pcap = ctypes.CDLL(library)
        class Program(ctypes.Structure):
            _fields_ = [("length", ctypes.c_uint), ("instructions", ctypes.c_void_p)]
        class Timeval(ctypes.Structure):
            _fields_ = [("seconds", ctypes.c_long), ("microseconds", ctypes.c_long)]
        class Header(ctypes.Structure):
            _fields_ = [("time", Timeval), ("captured", ctypes.c_uint32), ("length", ctypes.c_uint32)]
        pcap.pcap_open_dead.argtypes = [ctypes.c_int, ctypes.c_int]
        pcap.pcap_open_dead.restype = ctypes.c_void_p
        pcap.pcap_compile.argtypes = [ctypes.c_void_p, ctypes.POINTER(Program), ctypes.c_char_p, ctypes.c_int, ctypes.c_uint32]
        pcap.pcap_offline_filter.argtypes = [ctypes.POINTER(Program), ctypes.POINTER(Header), ctypes.c_void_p]
        pcap.pcap_freecode.argtypes = [ctypes.POINTER(Program)]
        pcap.pcap_close.argtypes = [ctypes.c_void_p]
        handle = pcap.pcap_open_dead(1, 65535)  # Ethernet; no device or capture is opened.
        program = Program()
        try:
            self.assertEqual(pcap.pcap_compile(handle, ctypes.byref(program), expression, 1, 0xffffffff), 0)
            def accepted(payload=b"", ip_options=0, tcp_options=0, fragments=0, peer_port=443, truncate=0):
                ip_length, tcp_length = 20 + ip_options, 20 + tcp_options
                ip = struct.pack("!BBHHHBBH4s4s", 0x40 + ip_length // 4, 0, ip_length + tcp_length + len(payload),
                                 0, fragments, 64, 6, 0, bytes((192, 0, 2, 2)), bytes((198, 51, 100, 5)))
                tcp = struct.pack("!HHIIBBHHH", 50000, peer_port, 100, 200, (tcp_length // 4) << 4, 0x11, 0, 0, 0)
                packet = bytes(12) + b"\x08\x00" + ip + bytes(ip_options) + tcp + bytes(tcp_options) + payload
                if truncate:
                    packet = packet[:-truncate]
                buffer = ctypes.create_string_buffer(packet)
                header = Header(Timeval(0, 0), len(packet), len(packet))
                return bool(pcap.pcap_offline_filter(ctypes.byref(program), ctypes.byref(header), buffer))
            for ip_options, tcp_options in ((0, 0), (4, 0), (0, 12), (40, 40)):
                with self.subTest(ip_options=ip_options, tcp_options=tcp_options):
                    self.assertTrue(accepted(ip_options=ip_options, tcp_options=tcp_options))
                    self.assertFalse(accepted(b"private payload", ip_options=ip_options, tcp_options=tcp_options))
            self.assertFalse(accepted(fragments=0x2000))
            self.assertFalse(accepted(fragments=1))
            self.assertFalse(accepted(peer_port=8443))
            self.assertFalse(accepted(truncate=12))
        finally:
            pcap.pcap_freecode(ctypes.byref(program))
            pcap.pcap_close(handle)

    def test_first_fault_write_failure_does_not_block_recovery_or_dedup_unsaved_fault(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            state_path.write_text("{}")
            snapshot = {"pid": 42, "active": [], "connections": [], "first_faults": [
                {"fault_id": "fault-1", "pid": 42, "kind": "transport_error"}]}
            routes = {"codex": route("unhealthy", "sse_error")}
            def get_json(url):
                return snapshot if url == watchdog.STREAMS_URL else routes if url == watchdog.ROUTE_URL else {"ready": True}
            original_save = watchdog._save_json
            def save(path, data):
                if path.name.endswith("-first-fault.json"):
                    raise PermissionError("secret sentinel")
                original_save(path, data)
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", side_effect=get_json), \
                 patch.object(watchdog, "_save_json", side_effect=save), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", return_value={"exit_code": 0}), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_notify"), \
                 patch.object(watchdog.time, "time", return_value=10000), \
                 patch.object(watchdog.time, "sleep", side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog._watch()
            state = json.loads(state_path.read_text())
            self.assertIn("last_routes", state)
            self.assertEqual(state["last_routes"]["codex"]["state"], "unhealthy")
            self.assertEqual(state["last_attempt"], 10000)
            self.assertEqual(state["first_fault_capture"]["probe_error"], "PermissionError")
            self.assertNotIn("secret sentinel", json.dumps(state))
            self.assertEqual(state["first_fault_incidents"], [])
            incident = json.loads(next((root / "incidents").glob("*-codex.json")).read_text())
            self.assertEqual(incident["restart_decision"]["decision"], "restart")
            with patch.object(watchdog, "INCIDENTS", root / "incidents"), patch.object(watchdog, "_get_json", return_value=snapshot):
                watchdog._sample_diagnostics(state, 10010)
            self.assertEqual(state["first_fault_incidents"][0]["fault_id"], "fault-1")

    def test_persistent_expiration_failure_bounds_files_and_preserves_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            incidents = root / "incidents"
            incidents.mkdir()
            existing = incidents / "20260101T000000000000Z-manual.json"
            existing.write_text("{}")
            state_path = root / "state.json"
            state_path.write_text('{"operator_setting":"preserve_me"}')
            faults = 0
            restarted = False
            def get_json(url):
                nonlocal faults
                if url == watchdog.STREAMS_URL:
                    faults += 1
                    return {"pid": 42, "active": [], "connections": [], "first_faults": [
                        {"fault_id": f"fault-{faults}", "pid": 42, "kind": "transport_error"}]}
                if url == watchdog.ROUTE_URL:
                    return {"codex": route("unhealthy", "sse_error")}
                return {"ready": True}
            def restart():
                nonlocal restarted
                stored = json.loads(state_path.read_text())
                self.assertLessEqual(len(list(incidents.iterdir())), 1)
                self.assertIn("incident_fallback", stored)
                self.assertEqual(stored["incident_fallback"]["data"]["restart_decision"]["decision"], "restart")
                restarted = True
                return {"exit_code": 0}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=incidents, INCIDENT_LIMIT=1), \
                 patch.object(watchdog, "_get_json", side_effect=get_json), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_notify"), \
                 patch.object(watchdog.time, "time", return_value=10000), \
                 patch.object(watchdog.time, "sleep", side_effect=[None, None, KeyboardInterrupt]), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret sentinel")):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog._watch()
            state = json.loads(state_path.read_text())
            self.assertLessEqual(len(list(incidents.iterdir())), 1)
            self.assertTrue(restarted)
            self.assertEqual(state["last_attempt"], 10000)
            self.assertEqual(state["operator_setting"], "preserve_me")
            self.assertEqual(state["last_routes"]["codex"]["state"], "unhealthy")
            self.assertEqual(state["first_fault_incidents"], [])
            self.assertEqual(state["first_fault_capture"]["availability"], "capacity_unavailable")
            self.assertEqual(state["incident_fallback"]["data"]["incident_storage"]["probe_error"], "PermissionError")
            self.assertNotIn("secret sentinel", json.dumps(state))
            self.assertGreater(faults, 3)

    def test_failed_staging_with_denied_cleanup_is_bounded_and_recovery_continues(self):
        for failure in ("replace", "partial_write"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                incidents = root / "incidents"
                incidents.mkdir()
                unrelated = incidents / "operator.tmp"
                unrelated.write_text("preserve me")
                state_path = root / "state.json"
                state_path.write_text('{"operator_setting":"preserve_me"}')
                snapshot = {"pid": 42, "active": [], "connections": [], "first_faults": [
                    {"fault_id": "fault-1", "pid": 42, "kind": "transport_error"}]}
                routes = {"codex": route("unhealthy", "sse_error")}
                original_write, original_replace = pathlib.Path.write_text, pathlib.Path.replace
                failed_stages = []
                counts = []
                decisions = []

                def write(path, data, *args, **kwargs):
                    if path.parent == incidents and failure == "partial_write":
                        original_write(path, data[:10], *args, **kwargs)
                        failed_stages.append(path)
                        raise OSError("secret partial write")
                    return original_write(path, data, *args, **kwargs)

                def replace(path, target):
                    if path.parent == incidents and failure == "replace":
                        failed_stages.append(path)
                        raise PermissionError("secret replace")
                    return original_replace(path, target)

                def restart():
                    stored = json.loads(state_path.read_text())
                    self.assertEqual(stored["last_attempt"], 10000)
                    self.assertEqual(stored["incident"], str(state_path))
                    self.assertEqual(stored["incident_fallback"]["data"]["restart_decision"]["decision"], "restart")
                    return {"exit_code": 0}

                def sleep(_):
                    counts.append(len(list(incidents.iterdir())) - 1)
                    saved = json.loads(state_path.read_text())
                    decisions.append(saved["incident_fallback"]["data"].get("restart_decision", {}).get("decision"))
                    if len(counts) == 5:
                        raise KeyboardInterrupt

                with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=incidents, INCIDENT_LIMIT=1), \
                     patch.object(watchdog, "_get_json", side_effect=lambda url: snapshot if url == watchdog.STREAMS_URL else routes if url == watchdog.ROUTE_URL else {"ready": True}), \
                     patch.object(watchdog, "_listener_memory", return_value=None), \
                     patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                     patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                     patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                     patch.object(watchdog, "_restart_headroom", side_effect=restart) as restart_mock, \
                     patch.object(watchdog, "_ready_after_restart", return_value=True), \
                     patch.object(watchdog, "_notify"), \
                     patch.object(watchdog.time, "time", return_value=10000), \
                     patch.object(watchdog.time, "sleep", side_effect=sleep), \
                     patch.object(watchdog.Path, "write_text", new=write), \
                     patch.object(watchdog.Path, "replace", new=replace), \
                     patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret cleanup")):
                    with self.assertRaises(KeyboardInterrupt):
                        watchdog._watch()
                self.assertEqual(counts, [1] * 5)
                self.assertEqual(len(failed_stages), 1)
                self.assertTrue(failed_stages[0].exists())
                stored = json.loads(state_path.read_text())
                self.assertEqual(stored["operator_setting"], "preserve_me")
                self.assertEqual(stored["last_routes"], routes)
                self.assertEqual(stored["first_fault_incidents"], [])
                self.assertEqual(stored["first_fault_capture"]["availability"], "capacity_unavailable")
                self.assertEqual(stored["first_fault_capture"]["retained_files"], 1)
                self.assertEqual(decisions[:2], ["restart", "restart_cooldown"])
                self.assertEqual(stored["incident_fallback"]["data"]["first_fault"]["fault_id"], "fault-1")
                self.assertEqual(restart_mock.call_count, 1)
                self.assertNotIn("secret", json.dumps(stored))
                self.assertEqual(unrelated.read_text(), "preserve me")
                with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=incidents, INCIDENT_LIMIT=2):
                    watchdog._capture_first_faults(snapshot, stored, 10010)
                self.assertEqual(stored["first_fault_capture"]["availability"], "available")
                self.assertEqual(stored["first_fault_incidents"][0]["fault_id"], "fault-1")
                self.assertLessEqual(len(list(incidents.iterdir())) - 1, 2)

    def test_existing_incident_update_reserves_staging_capacity_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            incident = root / "20260101T000000000000Z-manual.json"
            incident.write_text('{"kind":"original"}')
            leftover = root / "20260101T000000000001Z-first-fault.tmp"
            leftover.write_text("partial")
            data = {"kind": "update"}
            with patch.multiple(watchdog, INCIDENTS=root, INCIDENT_LIMIT=2), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret cleanup")):
                self.assertFalse(watchdog._save_json(incident, data))
            self.assertEqual(json.loads(incident.read_text()), {"kind": "original"})
            self.assertFalse(incident.with_suffix(".tmp").exists())
            self.assertEqual(data["incident_storage"]["retained_files"], 2)

    def test_denied_expiration_rejects_new_files_without_leaving_temporary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with patch.multiple(watchdog, INCIDENTS=root, INCIDENT_LIMIT=1), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret sentinel")):
                for i in range(3):
                    path = root / f"20260101T000000{i:06}Z-manual.json"
                    data = {"time": "2026-01-01T00:00:00Z"}
                    saved = watchdog._save_json(path, data)
                    self.assertLessEqual(len(list(root.iterdir())), 1)
                    if i:
                        self.assertIs(saved, False)
                        self.assertEqual(data["incident_storage"]["availability"], "capacity_unavailable")
                        self.assertNotIn("secret sentinel", json.dumps(data))

    def test_concurrent_incident_writers_cannot_race_past_capacity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            first = root / "20260101T000000000000Z-manual.json"
            second = root / "20260101T000000000001Z-manual.json"
            entered, release = threading.Event(), threading.Event()
            original_write = pathlib.Path.write_text
            def write(path, *args, **kwargs):
                if path == first.with_suffix(".tmp"):
                    entered.set()
                    release.wait(2)
                return original_write(path, *args, **kwargs)
            with patch.multiple(watchdog, INCIDENTS=root, INCIDENT_LIMIT=1), \
                 patch.object(watchdog.Path, "write_text", new=write), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret sentinel")), \
                 ThreadPoolExecutor(max_workers=2) as pool:
                pending = pool.submit(watchdog._save_json, first, {"kind": "metadata"})
                try:
                    self.assertTrue(entered.wait(1))
                    data = {"kind": "metadata"}
                    saved = pool.submit(watchdog._save_json, second, data).result(timeout=1)
                    self.assertIs(saved, False)
                    self.assertEqual(data["incident_storage"]["reason"], "incident_writer_busy")
                finally:
                    release.set()
                    pending.result(timeout=1)
            self.assertLessEqual(len(list(root.iterdir())), 1)

    def test_existing_oversized_incident_directory_is_reported_without_growing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for i in range(3):
                (root / f"20260101T000000{i:06}Z-manual.json").write_text("{}")
            data = {"kind": "metadata"}
            with patch.multiple(watchdog, INCIDENTS=root, INCIDENT_LIMIT=1), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret sentinel")):
                saved = watchdog._save_json(root / "20260101T000000000003Z-manual.json", data)
            self.assertIs(saved, False)
            self.assertEqual(data["incident_storage"]["reason"], "existing_directory_over_limit")
            self.assertEqual(data["incident_storage"]["retained_files"], 3)
            self.assertEqual(len(list(root.iterdir())), 3)

    def test_manual_capture_at_capacity_leaves_watcher_state_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            incidents = root / "incidents"
            incidents.mkdir()
            (incidents / "20260101T000000000000Z-manual.json").write_text("{}")
            state_path = root / "state.json"
            state_path.write_text('{"last_attempt":9500,"cooldown_alerts":{"codex":{"last_attempt":9500}}}')
            before = state_path.read_bytes()
            output = io.StringIO()
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=incidents, INCIDENT_LIMIT=1), \
                 patch.object(watchdog, "_snapshot", return_value={"pid": 42, "active": [], "connections": [], "first_faults": []}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog.Path, "unlink", side_effect=PermissionError("secret sentinel")), \
                 patch.object(watchdog.os, "umask"), redirect_stdout(output):
                watchdog.capture()
            self.assertEqual(state_path.read_bytes(), before)
            self.assertLessEqual(len(list(incidents.iterdir())), 1)
            self.assertIn("storage unavailable", output.getvalue())
            self.assertNotIn("Captured proxy evidence", output.getvalue())

    def test_restart_decision_update_refusal_preserves_state_before_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            state = {}
            original_save = watchdog._save_json
            def save(path, data):
                if path.parent == root / "incidents" and "restart_decision" in data:
                    data["incident_storage"] = {"availability": "capacity_unavailable", "reason": "incident_writer_busy"}
                    return False
                return original_save(path, data)
            def restart():
                initial = json.loads(next((root / "incidents").glob("*-codex.json")).read_text())
                self.assertNotIn("restart_decision", initial)
                stored = json.loads(state_path.read_text())
                self.assertIn("incident_fallback", stored)
                self.assertEqual(stored["incident_fallback"]["data"]["restart_decision"]["decision"], "restart")
                self.assertEqual(stored["last_attempt"], 10000)
                self.assertEqual(stored["incident"], str(state_path))
                return {"exit_code": 0}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_save_json", side_effect=save), \
                 patch.object(watchdog, "_snapshot", return_value={"pid": 42, "active": [], "first_faults": []}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), patch.object(watchdog, "_notify"):
                watchdog.recover("codex", {"codex": route("unhealthy", "sse_error")}, state, 10000)
            stored = json.loads(state_path.read_text())
            self.assertEqual(stored["incident_fallback"]["data"]["aftermath"]["new_pid"], 42)

    def test_cooldown_and_aftermath_update_refusals_use_actual_fallback_path(self):
        for field in ("recovery_suppressed", "aftermath"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                state_path = root / "state.json"
                state = {"last_attempt": 9500} if field == "recovery_suppressed" else {}
                original_save = watchdog._save_json
                def save(path, data):
                    if path.parent == root / "incidents" and field in data:
                        data["incident_storage"] = {"availability": "capacity_unavailable", "reason": "incident_writer_busy"}
                        return False
                    return original_save(path, data)
                with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                     patch.object(watchdog, "_save_json", side_effect=save), \
                     patch.object(watchdog, "_snapshot", return_value={"pid": 42, "active": [], "first_faults": []}), \
                     patch.object(watchdog, "_listener_memory", return_value=None), \
                     patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                     patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                     patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                     patch.object(watchdog, "_restart_headroom", return_value={"exit_code": 0}), \
                     patch.object(watchdog, "_ready_after_restart", return_value=True), patch.object(watchdog, "_notify"):
                    watchdog.recover("codex", {"codex": route("unhealthy", "sse_error")}, state, 10000)
                stored = json.loads(state_path.read_text())
                self.assertIn("incident_fallback", stored)
                self.assertIn(field, stored["incident_fallback"]["data"])
                self.assertEqual(stored["incident"], str(state_path))
                if field == "recovery_suppressed":
                    self.assertEqual(stored["cooldown_alerts"]["codex"]["incident"], str(state_path))

    def test_first_fault_enrichment_update_refusal_retains_saved_id_and_availability(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = {}
            snapshot = {"pid": 42, "active": [], "connections": [], "first_faults": [
                {"fault_id": "fault-1", "pid": 42, "kind": "transport_error"}]}
            original_save = watchdog._save_json
            def save(path, data):
                if path.parent == root and data.get("host", {}).get("availability") == "fixture":
                    data["incident_storage"] = {"availability": "capacity_unavailable", "reason": "incident_writer_busy"}
                    return False
                return original_save(path, data)
            with patch.object(watchdog, "INCIDENTS", root), patch.object(watchdog, "_save_json", side_effect=save), \
                 patch.object(watchdog, "_get_json", return_value=snapshot):
                watchdog._sample_diagnostics(state, 10000)
            self.assertEqual(state["first_fault_incidents"][0]["fault_id"], "fault-1")
            self.assertEqual(state["first_fault_capture"]["availability"], "capacity_unavailable")
            self.assertEqual(state["incident_fallback"]["data"]["first_fault"]["fault_id"], "fault-1")
            self.assertEqual(len(list(root.iterdir())), 1)

    def test_first_fault_link_refusal_is_explicit_without_replacing_restart_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            incidents = root / "incidents"
            incidents.mkdir()
            first = incidents / "20260101T000000000000Z-first-fault.json"
            first.write_text('{"first_fault":{"fault_id":"fault-1","pid":42}}')
            state_path = root / "state.json"
            state = {"first_fault_incidents": [{"fault_id": "fault-1", "pid": 42, "incident": str(first)}]}
            original_save = watchdog._save_json
            def save(path, data):
                if path.parent == incidents and ("restart_decision" in data or "recovery_incident" in data):
                    data["incident_storage"] = {"availability": "capacity_unavailable", "reason": "incident_writer_busy"}
                    return False
                return original_save(path, data)
            def restart():
                stored = json.loads(state_path.read_text())
                self.assertIn("incident_fallback", stored)
                fallback = stored["incident_fallback"]["data"]
                self.assertEqual(fallback["restart_decision"]["decision"], "restart")
                self.assertEqual(fallback["first_fault_link_updates"][0]["availability"], "capacity_unavailable")
                self.assertNotIn("recovery_incident", json.loads(first.read_text()))
                return {"exit_code": 0}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=incidents), \
                 patch.object(watchdog, "_save_json", side_effect=save), \
                 patch.object(watchdog, "_snapshot", return_value={"pid": 42, "active": [], "first_faults": []}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), patch.object(watchdog, "_notify"):
                watchdog.recover("codex", {"codex": route("unhealthy", "sse_error")}, state, 10000)

    def test_first_fault_links_to_recovery_before_restart_and_dedup_survives_reload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = {}
            snapshot = {"pid": 42, "active": [{"record_id": 1, "request_id": "hr_1"}], "connections": [],
                        "first_faults": [{"fault_id": "fault-1", "pid": 42, "kind": "transport_error"}]}
            def restart():
                fault = json.loads(next((root / "incidents").glob("*-first-fault.json")).read_text())
                recovery = json.loads(pathlib.Path(fault["recovery_incident"]).read_text())
                self.assertEqual(recovery["restart_decision"]["decision"], "restart")
                self.assertEqual(fault["recovery"], "restart_requested")
                return {"exit_code": 1}
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", return_value=snapshot), \
                 patch.object(watchdog, "_snapshot", return_value=snapshot), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart), \
                 patch.object(watchdog, "_ready_after_restart", return_value=False), \
                 patch.object(watchdog, "_notify"):
                watchdog._sample_diagnostics(state, 100)
                watchdog._save_json(root / "state.json", state)
                state = json.loads((root / "state.json").read_text())
                watchdog._sample_diagnostics(state, 110)
                watchdog.recover("codex", {"codex": route("unhealthy", "sse_error")}, state, 10000)
            self.assertEqual(len(list((root / "incidents").glob("*-first-fault.json"))), 1)

    def test_aftermath_reports_only_observed_same_process_outcomes(self):
        incident = {"restart_decision": {"old_pid": 42, "active_requests": [
            {"request_id": "hr_done"}, {"request_id": "hr_error"}, {"request_id": "hr_unknown"}]}}
        after = {"pid": 42, "recent": [{"request_id": "hr_done", "reason": "completed"},
                 {"request_id": "hr_error", "reason": "interrupted"}]}
        with patch.object(watchdog, "_snapshot", return_value=after):
            result = watchdog._restart_aftermath(incident)
        self.assertEqual([r["outcome"] for r in result["requests"]], ["completed", "aborted", "unknown"])

    def test_packet_probe_failures_and_unsupported_host_do_not_expose_error_text(self):
        with patch.object(watchdog.sys, "platform", "unsupported"), patch.object(watchdog.subprocess, "run") as run:
            host = watchdog._host_snapshot({})
        self.assertEqual(host["availability"], "unsupported_platform")
        run.assert_not_called()
        sockets = {"headroom_8788": {"connections": [{"local_ip": "192.0.2.2", "local_port": 50000,
                   "peer_ip": "198.51.100.5", "peer_port": 443}]}}
        with patch.dict(watchdog.os.environ, {"PROXY_WATCHDOG_PACKET_METADATA": "1"}), \
             patch.object(watchdog.shutil, "which", return_value="/usr/sbin/tcpdump"), \
             patch.object(watchdog.subprocess, "run", side_effect=PermissionError("secret sentinel")):
            result = watchdog._packet_metadata(sockets, "en0")
        self.assertEqual(result["availability"], "probe_unavailable")
        self.assertNotIn("secret sentinel", json.dumps(result))

    def test_metadata_retention_preserves_six_hours_of_memory_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            state = {"memory_samples": [{"time": "2026-10-03T00:00:00Z", "headroom_8788": {"pid": i}}
                                       for i in range(360)]}
            path = pathlib.Path(directory) / "state.json"
            with patch.object(watchdog, "STATE_PATH", path):
                watchdog._save_json(path, state)
            self.assertEqual(len(json.loads(path.read_text())["memory_samples"]), 360)

    def test_first_fault_schema_keeps_tls_tcp_session_pool_and_frame_metadata(self):
        snapshot = {"forensics_schema": 1, "pid": 42, "active": [], "connections": [], "first_faults": [{
            "fault_id": "fault-1", "pid": 42, "kind": "transport_error", "phase": "socket_read",
            "request": {"client_request_id": "12345678-1234-1234-1234-123456789abc", "session_ids": {
                "session_id": "0123456789abcdef01234567", "x-session-id": "1123456789abcdef01234567",
                "x-claude-code-session-id": "2123456789abcdef01234567", "conversation_id": "3123456789abcdef01234567"},
                "waits": {"upstream_read": {"active_ms": 125}},
                "upstream_ids": {"request-id": "safe-id"}},
            "connection": {"tls": {"availability": "available", "alpn": "h2", "version": "TLSv1.3"},
                "tcp": {"availability": "available", "rtt_ms": 12, "tx_retransmit_packets": 3},
                "http2": {"remote_settings": {"max_concurrent_streams": 100}, "frame_counts": {"inbound": {"RST_STREAM": 1}},
                          "recent_frames": [{"type": 3, "stream_id": 9, "error_code": 2}]}},
            "pool": {"availability": "available", "origins": [{"origin_id": "0123456789abcdef01234567", "active_streams": 2}]}}]}
        snapshot["active"] = [snapshot["first_faults"][0]["request"]]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(watchdog, "INCIDENTS", pathlib.Path(directory)), patch.object(watchdog, "_get_json", return_value=snapshot):
                watchdog._sample_diagnostics({}, 100)
            incident = json.loads(next(pathlib.Path(directory).glob("*.json")).read_text())
        fault = incident["first_fault"]
        self.assertEqual(fault["connection"]["tls"]["version"], "TLSv1.3")
        self.assertEqual(fault["connection"]["tcp"]["tx_retransmit_packets"], 3)
        self.assertEqual(fault["request"]["session_ids"]["session_id"], "0123456789abcdef01234567")
        self.assertEqual(set(fault["request"]["session_ids"]), {"session_id", "x-session-id", "x-claude-code-session-id", "conversation_id"})
        self.assertEqual(set(incident["stream_diagnostics"]["active"][0]["session_ids"]),
                         {"session_id", "x-session-id", "x-claude-code-session-id", "conversation_id"})
        wrapper = watchdog._metadata({"kind": "first_fault", "fault": snapshot["first_faults"][0]})
        self.assertEqual(wrapper["fault"]["request"]["session_ids"]["conversation_id"], "3123456789abcdef01234567")
        self.assertEqual(fault["request"]["waits"]["upstream_read"]["active_ms"], 125)
        self.assertEqual(fault["connection"]["http2"]["frame_counts"]["inbound"]["RST_STREAM"], 1)

    def test_process_sample_includes_cpu_and_state_without_command_line(self):
        results = [SimpleNamespace(stdout="123\n"),
                   SimpleNamespace(stdout="2048 8192 01:30 12.5 S\n")]
        with patch.object(watchdog.subprocess, "run", side_effect=results) as run:
            sample = watchdog._listener_memory(8788)
        self.assertEqual(sample["rss_vsz_etime"], "2048 8192 01:30")
        self.assertEqual(sample["cpu_percent"], 12.5)
        self.assertEqual(sample["process_state"], "S")
        self.assertNotIn("command", run.call_args.args[0][-1])

    def test_log_and_restart_retention_drops_exception_messages_and_payload_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "logs").mkdir()
            (root / "logs/proxy-8788.log").write_text('2026-10-03T00:00:00+00:00 event=stream_diagnostic {"kind":"first_fault",'
                '"request_id":"hr_safe","error":"secret_sentinel","body":"secret sentinel"}\n')
            (root / ".caveman").mkdir()
            (root / ".caveman/proxy.log").write_text(json.dumps({"msg": "upstream transport error; retrying",
                "request_id": "hr_safe", "error": "secret sentinel"}) + "\n")
            with patch.object(watchdog, "HEADROOM", root), patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog.subprocess, "run", side_effect=PermissionError("secret sentinel")):
                retained = {"logs": watchdog._safe_log_tail(), "caveman": watchdog._safe_caveman_tail(),
                            "restart": watchdog._restart_headroom()}
        self.assertNotIn("secret", json.dumps(retained))
        self.assertIn("hr_safe", json.dumps(retained))
        self.assertEqual(retained["restart"]["probe_error"], "PermissionError")
        self.assertEqual(retained["logs"][0]["time"], "2026-10-03T00:00:00+00:00")

    def test_network_snapshot_is_bounded_and_command_failures_are_nonfatal(self):
        result = SimpleNamespace(returncode=0, stdout="x" * 100000, stderr="secret sentinel")
        with patch.object(watchdog.subprocess, "run", return_value=result):
            snapshot = watchdog._network_snapshot({"headroom_8788": {"pid": 123}})
        self.assertNotIn("output", snapshot["tcp_counters"])
        self.assertEqual(snapshot["tcp_counters"]["counters"], {})
        self.assertTrue(snapshot["tcp_counters"]["truncated"])
        self.assertIn("headroom_8788", snapshot["sockets"])
        self.assertNotIn("secret sentinel", json.dumps(snapshot))
        with patch.object(watchdog.subprocess, "run", side_effect=OSError("secret sentinel")):
            snapshot = watchdog._network_snapshot({})
        self.assertEqual(snapshot["tcp_counters"]["probe_error"], "OSError")
        self.assertNotIn("secret sentinel", json.dumps(snapshot))

    def test_incident_captures_streams_before_slower_probes_and_keeps_history(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            state = {
                "last_stream_diagnostics": {"time": "2026-10-03T00:00:00Z", "data": {"active": []}},
                "diagnostic_samples": [{"time": "2026-10-02T00:00:00Z", "active": []}],
            }
            def snapshot(url):
                calls.append(url)
                return {"active": [{"request_id": "hr_test", "waiting": "upstream_read"}]}
            with patch.object(watchdog, "INCIDENTS", pathlib.Path(directory)), \
                 patch.object(watchdog, "_snapshot", side_effect=snapshot), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]):
                _, incident = watchdog._capture_incident("codex", {}, state)
            self.assertEqual(calls[0], "http://127.0.0.1:8788/debug/streams")
            self.assertEqual(incident["stream_diagnostics"]["active"][0]["request_id"], "hr_test")
            self.assertEqual(incident["last_stream_diagnostics"], state["last_stream_diagnostics"])
            self.assertEqual(incident["diagnostic_samples"], state["diagnostic_samples"])

    def test_diagnostics_keep_last_good_snapshot_when_proxy_stops_responding(self):
        state = {}
        snapshot = {"active": [{"request_id": "hr_test"}], "connections": [], "recent": []}
        with patch.object(watchdog, "_get_json", return_value=snapshot):
            watchdog._sample_diagnostics(state, 100)
        previous = state["last_stream_diagnostics"]
        with patch.object(watchdog, "_get_json", side_effect=TimeoutError("private sentinel")):
            watchdog._sample_diagnostics(state, 110)
        self.assertEqual(state["last_stream_diagnostics"], previous)
        self.assertEqual(state["diagnostics_probe_error"], "TimeoutError")
        self.assertNotIn("private sentinel", json.dumps(state))

    def test_truncated_diagnostic_response_does_not_block_recovery(self):
        state = {"last_stream_diagnostics": {"time": "before", "data": {"active": []}}}
        previous = dict(state)
        with patch.object(watchdog, "_get_json", side_effect=IncompleteRead(b"private sentinel")):
            watchdog._sample_diagnostics(state, 100)
            self.assertIn("probe_error", watchdog._snapshot(watchdog.STREAMS_URL))
        self.assertEqual(state["last_stream_diagnostics"], previous["last_stream_diagnostics"])
        self.assertEqual(state["diagnostics_probe_error"], "IncompleteRead")

    def test_malformed_diagnostic_connections_do_not_replace_last_good_snapshot(self):
        state = {"last_stream_diagnostics": {"time": "before", "data": {"active": []}}}
        previous = dict(state)
        with patch.object(watchdog, "_get_json", return_value={"active": [], "connections": {"id": 1}}):
            watchdog._sample_diagnostics(state, 100)
        self.assertEqual(state["last_stream_diagnostics"], previous["last_stream_diagnostics"])
        self.assertEqual(state["diagnostics_probe_error"], "ValueError")

    def test_diagnostic_history_is_bounded_and_omits_completed_requests(self):
        state = {}
        snapshot = {"active": [{"request_id": str(i)} for i in range(200)],
                    "connections": [{"id": i} for i in range(200)],
                    "recent": [{"request_id": "already-finished"}]}
        with patch.object(watchdog, "_get_json", return_value=snapshot):
            for now in range(20):
                watchdog._sample_diagnostics(state, now)
        self.assertLessEqual(len(state["diagnostic_samples"]), 12)
        self.assertLessEqual(len(state["diagnostic_samples"][-1]["active"]), 16)
        self.assertNotIn("already-finished", json.dumps(state["diagnostic_samples"]))

    def test_recover_codex_from_repeated_broken_streams(self):
        routes = {
            "codex": route("unhealthy", "missing_terminal_event"),
            "claude": route("healthy", "completed"),
        }
        self.assertEqual(watchdog.recovery_candidates(routes), ["codex"])

    def test_auth_and_rate_limits_are_not_recoverable_failures(self):
        for reason in ("http_401", "http_429"):
            routes = {"claude": route("unhealthy", reason)}
            self.assertEqual(watchdog.recovery_candidates(routes), [])

    def test_repeated_server_errors_restart_either_route(self):
        for provider in ("codex", "claude"):
            for reason in ("http_500", "http_502", "http_503", "http_504"):
                routes = {provider: route("unhealthy", reason)}
                self.assertEqual(watchdog.recovery_candidates(routes), [provider])

    def test_healthy_and_unknown_routes_do_not_restart(self):
        routes = {
            "codex": route("healthy", "completed"),
            "claude": route("unknown", None, age=None),
        }
        self.assertEqual(watchdog.recovery_candidates(routes), [])

    def test_failed_restart_preserves_evidence_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            routes = {"codex": route("unhealthy", "http_500")}

            def restart():
                # Evidence and cooldown must already exist before touching proxy.
                self.assertTrue((root / "state.json").exists())
                self.assertEqual(len(list((root / "incidents").glob("*.json"))), 1)
                return {"exit_code": 1, "output": "restart failed"}

            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", return_value=routes), \
                 patch.object(watchdog, "_listener_memory", return_value={"pid": 123}), \
                 patch.object(watchdog, "_network_snapshot", return_value={}), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", side_effect=restart), \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_notify") as notify, \
                 patch.object(watchdog.os, "umask"), \
                 patch.object(watchdog.time, "sleep", side_effect=KeyboardInterrupt):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog.watch()

            import json
            incident = json.loads(next((root / "incidents").glob("*.json")).read_text())
            self.assertEqual(len(incident["memory_samples"]), 1)
            self.assertEqual(incident["restart"]["exit_code"], 1)
            self.assertIn("recovery failed", notify.call_args.args[0])

    def test_deliberately_unloaded_headroom_is_not_restarted(self):
        for last_attempt in (0, 9500):
            with patch.object(watchdog, "_managed_headroom_loaded", return_value=False), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_capture_incident") as capture, \
                 patch.object(watchdog, "_notify") as notify, \
                 patch.object(watchdog, "_save_json") as save:
                watchdog.recover("headroom_health_endpoint", {}, {"last_attempt": last_attempt}, 10_000)
            restart.assert_not_called()
            capture.assert_not_called()
            notify.assert_not_called()
            save.assert_not_called()

    def test_manual_capture_does_not_restart_or_change_watchdog_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state = root / "state.json"
            state.write_text('{"memory_samples": []}')
            before = state.read_bytes()
            with patch.multiple(watchdog, STATE_PATH=state, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_snapshot", return_value={"probe_error": "unreachable"}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog.os, "umask"), \
                 patch.object(watchdog, "_restart_headroom") as restart:
                watchdog.capture()
            incident = json.loads(next((root / "incidents").glob("*.json")).read_text())
            self.assertEqual(incident["route"], "manual")
            self.assertEqual(state.read_bytes(), before)
            restart.assert_not_called()

    def test_install_uses_personal_launchagent_identifier(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            agents = root / "Library/LaunchAgents"
            agents.mkdir(parents=True)
            with patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog, "HEADROOM", root / ".headroom"), \
                 patch.object(watchdog.os, "umask"), \
                 patch.object(watchdog.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
                watchdog.install()
            with (agents / f"{watchdog.LABEL}.plist").open("rb") as source:
                self.assertEqual(plistlib.load(source)["Label"], "au.com.beauayres.agent-tools-sync.proxy-watchdog")
            calls = [call.args[0] for call in run.call_args_list]
            self.assertTrue(calls[0][-1].endswith("/au.com.beauayres.agent-tools-sync.proxy-watchdog"))
            self.assertEqual(calls[-1][1], "bootstrap")

    def test_install_bootstrap_failure_reports_native_error_without_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            def run(command, **kwargs):
                code = 5 if command[1] == "bootstrap" else 0
                error = "Bootstrap failed: 5: Input/output error\nTry re-running the command as root for richer errors."
                if code and kwargs.get("check"):
                    raise subprocess.CalledProcessError(code, command, stderr=error)
                return subprocess.CompletedProcess(command, code, "", error if code else "")
            with patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog, "HEADROOM", root / ".headroom"), \
                 patch.object(watchdog.subprocess, "run", side_effect=run):
                with self.assertRaises(SystemExit) as failure:
                    watchdog.install()
            message = str(failure.exception)
            self.assertIn("Input/output error", message)
            self.assertIn("log show", message)
            self.assertNotIn("as root", message)

    def test_install_failed_unload_does_not_bootstrap_over_loaded_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            calls = []
            def run(command, **kwargs):
                calls.append(command[1])
                return subprocess.CompletedProcess(command, 1 if command[1] == "bootout" else 0, "", "unload refused")
            with patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog, "HEADROOM", root / ".headroom"), \
                 patch.object(watchdog.subprocess, "run", side_effect=run):
                with self.assertRaises(SystemExit):
                    watchdog.install()
            self.assertNotIn("bootstrap", calls)

    def test_install_absent_service_can_bootstrap_after_confirmed_missing_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            calls = []
            def run(command, **kwargs):
                calls.append(command[1])
                code = {"bootout": 3, "print": 113, "bootstrap": 0}[command[1]]
                return subprocess.CompletedProcess(command, code, "", "")
            with patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog, "HEADROOM", root / ".headroom"), \
                 patch.object(watchdog.subprocess, "run", side_effect=run):
                watchdog.install()
            self.assertEqual(calls, ["bootout", "print", "bootstrap"])

    def test_install_timeout_reports_failed_action_without_bootstrap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with patch.object(watchdog.Path, "home", return_value=root), \
                 patch.object(watchdog, "HEADROOM", root / ".headroom"), \
                 patch.object(watchdog.subprocess, "run", side_effect=subprocess.TimeoutExpired("launchctl", 10)) as run:
                with self.assertRaises(SystemExit) as failure:
                    watchdog.install()
            self.assertIn("bootout failed: TimeoutExpired", str(failure.exception))
            run.assert_called_once()
            self.assertEqual(run.call_args.kwargs["timeout"], 10)

    def test_three_unresponsive_health_probes_trigger_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", side_effect=TimeoutError("probe timeout")), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "recover") as recover, \
                 patch.object(watchdog.os, "umask"), \
                 patch.object(watchdog.time, "sleep", side_effect=[None, None, KeyboardInterrupt]):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog.watch()
            recover.assert_called_once()
            self.assertEqual(recover.call_args.args[0], "headroom_health_endpoint")

    def test_cooldown_captures_and_notifies_each_failed_route_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            state_path.write_text(json.dumps({"last_attempt": 9500}))
            routes = {"codex": route("unhealthy", "sse_error"),
                      "claude": route("unhealthy", "http_503")}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", return_value=routes), \
                 patch.object(watchdog, "_snapshot", return_value={}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_network_snapshot", return_value={}), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom") as restart, \
                 patch.object(watchdog, "_notify") as notify, \
                 patch.object(watchdog.time, "time", return_value=10_000), \
                 patch.object(watchdog.time, "sleep", side_effect=[None, None, KeyboardInterrupt]):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog.watch()
            restart.assert_not_called()
            self.assertEqual(notify.call_count, 2)
            self.assertEqual(len(list((root / "incidents").glob("*.json"))), 2)
            state = json.loads(state_path.read_text())
            self.assertEqual(state["last_attempt"], 9500)
            self.assertEqual(set(state["cooldown_alerts"]), {"codex", "claude"})
            for name, reason in (("codex", "sse_error"), ("claude", "http_503")):
                alert = state["cooldown_alerts"][name]
                self.assertEqual(alert["failure_reason"], reason)
                self.assertEqual(alert["cooldown_remaining_seconds"], 1300)
                incident = json.loads(pathlib.Path(alert["incident"]).read_text())
                self.assertEqual(incident["recovery_suppressed"]["reason"], "restart_cooldown")

    def test_cooldown_alert_survives_reload_and_rearms_after_next_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            state_path = root / "state.json"
            routes = {"codex": route("unhealthy", "sse_error")}
            state = {"last_attempt": 9500}
            with patch.multiple(watchdog, STATE_PATH=state_path, INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_snapshot", return_value={}), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "_network_snapshot", return_value={}), \
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
                 patch.object(watchdog, "_managed_headroom_loaded", return_value=True), \
                 patch.object(watchdog, "_restart_headroom", return_value={"exit_code": 0}) as restart, \
                 patch.object(watchdog, "_ready_after_restart", return_value=True), \
                 patch.object(watchdog, "_notify") as notify:
                watchdog.recover("codex", routes, state, 10_000)
                state = json.loads(state_path.read_text())
                watchdog.recover("codex", routes, state, 10_010)
                restart.assert_not_called()
                self.assertEqual(notify.call_count, 1)
                self.assertEqual(state["cooldown_alerts"]["codex"]["cooldown_remaining_seconds"], 1290)
                watchdog.recover("codex", routes, state, 11_300)
                restart.assert_called_once()
                self.assertEqual(state["last_attempt"], 11_300)
                watchdog.recover("codex", routes, state, 11_310)
                self.assertEqual(restart.call_count, 1)
                self.assertEqual(notify.call_count, 3)
                self.assertEqual(state["cooldown_alerts"]["codex"]["cooldown_remaining_seconds"], 1790)

    def test_unresponsive_health_is_detected_even_during_cooldown(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "state.json").write_text(json.dumps({"last_attempt": 9500}))
            with patch.multiple(watchdog, STATE_PATH=root / "state.json", INCIDENTS=root / "incidents"), \
                 patch.object(watchdog, "_get_json", side_effect=TimeoutError("probe timeout")), \
                 patch.object(watchdog, "_listener_memory", return_value=None), \
                 patch.object(watchdog, "recover") as recover, \
                 patch.object(watchdog.time, "time", return_value=10_000), \
                 patch.object(watchdog.time, "sleep", side_effect=[None, None, KeyboardInterrupt]):
                with self.assertRaises(KeyboardInterrupt):
                    watchdog.watch()
            recover.assert_called_once()
            self.assertEqual(recover.call_args.args[0], "headroom_health_endpoint")


if __name__ == "__main__":
    unittest.main()
