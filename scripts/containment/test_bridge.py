"""Synthetic ABI/mocking regressions ONLY, never native containment evidence."""
import importlib.util
import json
from pathlib import Path
import stat
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

HERE = Path(__file__).resolve().parent
NATIVE = HERE.parent / "native-clients"
sys.path.insert(0, str(NATIVE))
sys.path.insert(0, str(HERE.parent / "parity"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = load("f02_bridge_test_subject", HERE / "bridge.py")
qa = load("f02_qa_test_subject", NATIVE / "qa.py")
harness = load("f02_harness_test_subject", NATIVE / "harness.py")
sandbox = load("f02_seatbelt_test_subject", HERE.parent / "parity/reference_sandbox.py")
IMAGE = "sha256:" + "a" * 64  # synthetic identifier, not an acquired image


class SessionAbiTests(unittest.TestCase):
    def invoke(self, receipt, code=0):
        with patch.object(bridge.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], code, json.dumps(receipt).encode(), b"")) as run:
            result = bridge.session(
                "/synthetic/docker", "/synthetic/socket", IMAGE,
                "/usr/local/bin/python3", ["/qa/harness.py", "--request-id", "unit-only"],
                [39011, 39012], [39011, 39012])
        return result, run.call_args

    def test_full_session_output_is_unwrapped_not_a_popen_substitute(self):
        # The payload is deliberately opaque here. The unchanged native report
        # validator, NOT this bridge, owns its workflow/provenance interpretation.
        payload = '{"synthetic":"unit-only; no native workflow executed"}'
        result, call = self.invoke({
            "schema": "mimic.containment/v1", "code": 0,
            "reason": "leader_exited", "output": payload})
        self.assertEqual(result.stdout, payload.encode())
        self.assertEqual(result.returncode, 0)
        argv = call.args[0]
        self.assertIn("39011,39012", argv)
        self.assertEqual(argv[-3:], ["/qa/harness.py", "--request-id", "unit-only"])
        self.assertNotIn("--mount", argv)
        self.assertNotIn("--env-file", argv)

    def test_unavailable_boundary_does_not_become_native_success(self):
        with self.assertRaisesRegex(bridge.Blocked, "backend_unavailable"):
            self.invoke({
                "schema": "mimic.containment/v1", "status": "blocked",
                "reason": "containment_backend_unavailable"}, 2)

    def test_timeout_and_owner_failure_are_not_leader_success(self):
        for reason, code in [("deadline_exceeded", 124), ("lease_expired", 125),
                             ("launch_failed", 126)]:
            with self.subTest(reason=reason), self.assertRaises(bridge.Blocked):
                self.invoke({"schema": "mimic.containment/v1", "code": code,
                             "reason": reason, "output": "{}"}, code)

    def test_mismatched_exit_and_status_only_receipts_are_rejected(self):
        for receipt in [
            {"status": "passed"},
            {"schema": "mimic.containment/v1", "code": False,
             "reason": "leader_exited", "output": "{}"},
            {"schema": "mimic.containment/v1", "code": 1,
             "reason": "leader_exited", "output": "{}"},
        ]:
            with self.subTest(receipt=receipt), self.assertRaises(bridge.Blocked):
                self.invoke(receipt)

    def test_no_explicit_backend_means_no_process(self):
        with patch.object(bridge.subprocess, "run", side_effect=AssertionError("no process")):
            with self.assertRaises(bridge.Blocked):
                bridge.session(None, None, IMAGE, "/never-spawn", [], [], [])

    def test_no_default_native_execution_even_with_daemon_available(self):
        with patch.object(qa, "docker", side_effect=AssertionError("no legacy execution")), \
                patch.object(qa.containment, "session", side_effect=AssertionError("no session")):
            result = qa.offline(Path("/not-read"), ["claude"], ["sse"])
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["blocked_reason"], "explicit_f02_docker_executable_and_socket_required")


class ConsumerBoundaryTests(unittest.TestCase):
    def test_native_fixture_bind_is_deterministic_without_changing_fixture_logic(self):
        fixture = harness.ContainedFixture.__new__(harness.ContainedFixture)
        fixture.server_address = ("127.0.0.1", 0)
        with patch.object(harness.Fixture, "server_bind") as bind:
            fixture.server_bind()
        bind.assert_called_once_with()
        self.assertEqual(fixture.server_address, ("127.0.0.1", 39011))
        self.assertEqual(harness.port(), 39012)

    def test_legacy_seatbelt_never_starts_a_qualifying_target(self):
        with patch.object(sandbox.subprocess, "Popen", side_effect=AssertionError("no target")):
            with self.assertRaisesRegex(RuntimeError, "lifetime_unqualified"):
                sandbox.start(None, ["/never-spawn"], None)

    def marker_path(self, marker_uid=0, marker_text=None):
        expected = "mimic.containment/v1 bind=39011,39012 connect=39011,39012\n"

        def path(name):
            value = MagicMock()
            value.exists.return_value = True
            value.read_text.return_value = {
                "/proc/self/status": "NoNewPrivs:\t1\nCapEff:\t0000000000000000\n",
                "/proc/mounts": "root / fs ro 0 0\n",
                "/tmp/mimic-f02-owner": expected if marker_text is None else marker_text,
            }.get(name, "")
            value.lstat.return_value = SimpleNamespace(
                st_mode=stat.S_IFREG | 0o444, st_uid=marker_uid)
            return value
        return path

    def test_forged_unprivileged_marker_is_rejected_before_native_children(self):
        with patch.object(harness, "Path", side_effect=self.marker_path(10001)), \
                patch.object(harness.os, "getuid", return_value=10001), \
                patch.object(harness.os, "listdir", return_value=["lo"]), \
                patch.object(harness, "child", side_effect=AssertionError("no child")):
            with self.assertRaisesRegex(RuntimeError, "f02_namespace_owner_required"):
                harness.containment()

    def test_wrong_port_marker_does_not_qualify_all_loopback(self):
        with patch.object(harness, "Path", side_effect=self.marker_path(
                marker_text="mimic.containment/v1 all-loopback\n")), \
                patch.object(harness.os, "getuid", return_value=10001), \
                patch.object(harness.os, "listdir", return_value=["lo"]):
            with self.assertRaisesRegex(RuntimeError, "f02_namespace_owner_required"):
                harness.containment()


if __name__ == "__main__":
    unittest.main()
