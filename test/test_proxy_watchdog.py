import importlib.util
import pathlib
import tempfile
import unittest
from unittest.mock import patch


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
    def test_recover_codex_from_repeated_broken_streams(self):
        routes = {
            "codex": route("unhealthy", "missing_terminal_event"),
            "claude": route("healthy", "completed"),
        }
        self.assertEqual(watchdog.recovery_candidate(routes, 0, 10_000), "codex")

    def test_auth_limits_and_cooldown_do_not_restart(self):
        for reason in ("http_401", "http_429"):
            routes = {"claude": route("unhealthy", reason)}
            self.assertIsNone(watchdog.recovery_candidate(routes, 0, 10_000))

        routes = {"codex": route("unhealthy", "sse_error")}
        self.assertIsNone(watchdog.recovery_candidate(routes, 9_500, 10_000))

    def test_repeated_server_errors_restart_either_route(self):
        for provider in ("codex", "claude"):
            for reason in ("http_500", "http_502", "http_503", "http_504"):
                routes = {provider: route("unhealthy", reason)}
                self.assertEqual(watchdog.recovery_candidate(routes, 0, 10_000), provider)

    def test_healthy_and_unknown_routes_do_not_restart(self):
        routes = {
            "codex": route("healthy", "completed"),
            "claude": route("unknown", None, age=None),
        }
        self.assertIsNone(watchdog.recovery_candidate(routes, 0, 10_000))

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
                 patch.object(watchdog, "_safe_log_tail", return_value=[]), \
                 patch.object(watchdog, "_safe_caveman_tail", return_value=[]), \
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


if __name__ == "__main__":
    unittest.main()
