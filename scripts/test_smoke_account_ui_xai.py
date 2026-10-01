#!/usr/bin/env python3
"""F07 synthetic fixture resource boundary; no BEAM, provider or CPA calls."""

import argparse
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("f07_resource_fixture", ROOT / "scripts/smoke-account-ui-xai.py")
f07 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f07)


class IssuerResourceBoundary(unittest.TestCase):
    def setUp(self):
        base = ROOT / "build/account-ui-f07/fixture-regression"
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="resource-", dir=base)
        self.directory = Path(self.temp.name)
        self.directory.chmod(0o700)
        self.f = f07.Fixture(self.directory, argparse.Namespace(
            root_command=f07.local.DEFAULT_ROOT,
            ui_command=f07.local.DEFAULT_UI, root_ui=True))
        f07.slot(self.f.state, 1).write_text(json.dumps({
            "version": 1, "kind": "enrollment_pending",
            "nonce": "synthetic-resource-regression"}))
        f07.slot(self.f.state, 1).chmod(0o600)

    def tearDown(self):
        self.f.close()
        self.temp.cleanup()

    def state(self):
        return {str(p.relative_to(self.f.state)): p.read_bytes()
                for p in self.f.state.rglob("*") if p.is_file()}

    def test_exact_favicon_is_empty_204_without_oauth_or_state_effects(self):
        before = self.state()
        counts = dict(self.f.counts)
        authorized = dict(self.f.authorized)
        accepted = dict(self.f.accepted)
        status, headers, body = self.f.http(self.f.provider.server_port, "GET", "/favicon.ico")
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")
        self.assertEqual(headers["Content-Length"], "0")
        self.assertEqual(self.f.resource_counts, {"favicon": 1})
        self.assertEqual(self.f.counts, counts)
        self.assertEqual(self.f.authorized, authorized)
        self.assertEqual(self.f.accepted, accepted)
        self.assertEqual(self.state(), before)
        self.assertEqual(self.f.errors, [])
        self.assertEqual(self.f.peer_closes, [])

    def test_unknown_query_and_nonexact_paths_remain_fatal(self):
        before = self.state()
        counts = dict(self.f.counts)
        for path in ("/unknown", "/favicon.ico?unexpected=1", "/favicon.ico/"):
            status, _, _ = self.f.http(self.f.provider.server_port, "GET", path)
            self.assertEqual(status, 500)
        self.assertEqual(len(self.f.errors), 3)
        self.assertTrue(all(error["classification"] == "unsolicited_browser_route"
                            for error in self.f.errors))
        self.assertEqual(self.f.resource_counts, {"favicon": 0})
        self.assertEqual(self.f.counts, counts)
        self.assertEqual(self.state(), before)


if __name__ == "__main__":
    unittest.main()
