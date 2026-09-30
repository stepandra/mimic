"""Explicit local-target integration tests; never part of default unit discovery.

Run only when authorized: python3 scripts/parity/integration_local_driver.py
Requires `gleam test` to have already built the target. Does not build it.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class LocalDriverTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="mimic-parity-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def plan(self, fixture_id, phase="exercise"):
        text = Path(f"test/parity/fixtures/{fixture_id}.json").read_text()
        return {
            "schema_version": 1,
            "capability_id": "driver-self-test",
            "fixture_json": text,
            "fixture_sha256": hashlib.sha256(text.encode()).hexdigest(),
            "target": "mimic",
            "target_revision": "synthetic-harness-test-not-parity-evidence",
            "phase": phase,
            "state_dir": str(self.root / "state"),
        }

    def invoke(self, plan):
        path = self.root / "plan.json"
        path.write_text(json.dumps(plan))
        env = {key: value for key, value in os.environ.items()
               if key in ("PATH", "TMPDIR", "SystemRoot")}
        env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root),
                   XDG_CACHE_HOME=str(self.root), PARITY_OFFLINE="1")
        return subprocess.run(
            [sys.executable, "scripts/parity/local_driver.py", str(path)],
            env=env, capture_output=True, text=True, timeout=25, check=False)

    def result(self, plan):
        process = self.invoke(plan)
        self.assertEqual(process.returncode, 0, process.stderr)
        return json.loads(process.stdout)

    def test_real_ingress_messages_and_auth_isolation(self):
        result = self.result(self.plan("messages-v1"))
        self.assertEqual(result["status"], "passed")
        wire = json.loads(result["observations"])
        self.assertEqual(wire["unauthorized"]["status"], 401)
        self.assertEqual(wire["response"]["status"], 200)
        self.assertEqual(len(wire["upstream"]), 1)
        self.assertEqual(wire["upstream"][0]["path"], "/v1/messages")
        self.assertIsInstance(wire["upstream"][0]["headers"], list)
        self.assertNotIn("synthetic-client-key", json.dumps(wire["upstream"]))

    def test_real_chat_translation(self):
        result = self.result(self.plan("chat-v1"))
        self.assertEqual(result["status"], "passed")
        wire = json.loads(result["observations"])
        self.assertEqual(wire["response"]["status"], 200)
        self.assertEqual(wire["upstream"][0]["path"], "/v1/messages")

    def test_persisted_state_survives_two_fresh_driver_and_beam_processes(self):
        first = self.result(self.plan("restart-v1"))
        second = self.result(self.plan("restart-v1", "restart"))
        self.assertEqual(first["status"], "passed")
        self.assertEqual(second["status"], "passed")
        self.assertNotEqual(first["diagnostics"]["target_pid"],
                            second["diagnostics"]["target_pid"])
        credentials = list((self.root / "state").rglob("credential-*.json"))
        self.assertEqual(len(credentials), 2)
        self.assertEqual((self.root / "state").stat().st_mode & 0o777, 0o700)
        for path in credentials:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_restart_cannot_reseed_missing_state(self):
        process = self.invoke(self.plan("restart-v1", "restart"))
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn('"status":"passed"', process.stdout)
        self.assertEqual(list((self.root / "state").rglob("credential-*.json")), [])

    def test_unimplemented_scenario_is_not_passing_coverage(self):
        result = self.result(self.plan("oauth-v1"))
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(result["checks"], [])
        self.assertEqual(json.loads(result["observations"]), {})

    def test_wrong_fixture_digest_fails_before_side_effects(self):
        plan = self.plan("messages-v1")
        plan["fixture_sha256"] = "stale"
        process = self.invoke(plan)
        self.assertNotEqual(process.returncode, 0)
        self.assertFalse((self.root / "state").exists())

    def test_baseline_driver_cannot_masquerade_as_cpa(self):
        plan = self.plan("messages-v1")
        plan["target"] = "cpa"
        result = self.result(plan)
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(result["checks"], [])


if __name__ == "__main__":
    unittest.main()
