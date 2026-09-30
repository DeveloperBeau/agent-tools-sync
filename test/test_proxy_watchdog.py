import importlib.util
import pathlib
import json
import plistlib
import tempfile
import unittest
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
    def test_process_sample_includes_cpu_and_state_without_command_line(self):
        results = [SimpleNamespace(stdout="123\n"),
                   SimpleNamespace(stdout="2048 8192 01:30 12.5 S\n")]
        with patch.object(watchdog.subprocess, "run", side_effect=results) as run:
            sample = watchdog._listener_memory(8788)
        self.assertEqual(sample["rss_vsz_etime"], "2048 8192 01:30")
        self.assertEqual(sample["cpu_percent"], 12.5)
        self.assertEqual(sample["process_state"], "S")
        self.assertNotIn("command", run.call_args.args[0][-1])

    def test_network_snapshot_is_bounded_and_command_failures_are_nonfatal(self):
        result = SimpleNamespace(returncode=0, stdout="x" * 20000, stderr="secret sentinel")
        with patch.object(watchdog.subprocess, "run", return_value=result):
            snapshot = watchdog._network_snapshot({"headroom_8788": {"pid": 123}})
        self.assertLessEqual(len(snapshot["tcp_counters"]["output"]), 8000)
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
                "last_stream_diagnostics": {"time": "before", "data": {"active": []}},
                "diagnostic_samples": [{"time": "earlier", "active": []}],
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
                 patch.object(watchdog.subprocess, "run") as run:
                watchdog.install()
            with (agents / f"{watchdog.LABEL}.plist").open("rb") as source:
                self.assertEqual(plistlib.load(source)["Label"], "au.com.beauayres.agent-tools-sync.proxy-watchdog")
            calls = [call.args[0] for call in run.call_args_list]
            self.assertTrue(calls[0][-1].endswith("/au.com.beauayres.agent-tools-sync.proxy-watchdog"))
            self.assertEqual(calls[-1][1], "bootstrap")

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
