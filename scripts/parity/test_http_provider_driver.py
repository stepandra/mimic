import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import http_provider_driver


class HttpProviderDriverTest(unittest.TestCase):
    def plan(self, target="mimic", capability="kimi-native"):
        fixture = (Path(__file__).resolve().parents[2] /
                   "test/parity/fixtures/backend-v1.json").read_text()
        return {
            "target": target, "capability_id": capability, "fixture_json": fixture,
            "fixture_sha256": hashlib.sha256(fixture.encode()).hexdigest(),
            "target_revision": "synthetic-test-only", "phase": "seed",
        }

    def test_missing_header_case_cannot_become_passing_row(self):
        with patch.object(http_provider_driver, "exercise_kimi", return_value={"synthetic": True}):
            output = http_provider_driver.run(self.plan())
        self.assertEqual(output["status"], "failed")
        self.assertIn({"name": "ordered_headers_preserved", "passed": False}, output["checks"])

    def test_cannot_masquerade_as_cpa_or_generic_compatibility(self):
        with patch.object(http_provider_driver, "exercise_kimi") as probe:
            self.assertEqual(http_provider_driver.run(self.plan("cpa"))["status"], "unsupported")
            self.assertEqual(http_provider_driver.run(self.plan(capability="kimi-generic"))["status"], "unsupported")
            probe.assert_not_called()

    def test_digest_is_checked_before_any_effect(self):
        plan = self.plan()
        plan["fixture_sha256"] = "0" * 64
        with patch.object(http_provider_driver, "exercise_kimi") as probe:
            with self.assertRaises(ValueError):
                http_provider_driver.run(plan)
            probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
