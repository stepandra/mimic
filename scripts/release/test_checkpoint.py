"""Synthetic local release-tool tests; no provider or reference calls."""

import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import checkpoint as cp


class CheckpointTest(unittest.TestCase):
    def setUp(self):
        # Keep all generated artifacts inside the ignored workspace build tree.
        root = cp.ROOT / "build/integration/cpa-gap"
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.path = "src/mimic/providers/claude/example.gleam"
        self.allow = [self.path]
        self.target = self.bundle / "source" / self.path
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"// synthetic source fixture\n")
        self.data = {
            "schema": 1, "checkpoint": "synthetic-v1", "owner": "claude-owner",
            "owner_approved": True, "base": cp.BASE, "cpa": cp.CPA,
            "dependencies": [],
            "files": [{"path": self.path,
                       "sha256": cp.digest(self.target.read_bytes())}],
            "tests": [{"command": "synthetic-not-executed", "exit_code": 0,
                       "scope": "unit fixture", "log_sha256": "a" * 64}],
            "axes": {axis: "not_run" for axis in cp.AXES},
            "limits": ["Synthetic verifier input, not feature evidence"],
        }
        self.write()

    def write(self):
        (self.bundle / "manifest.json").write_text(json.dumps(self.data))

    def verify(self):
        return cp.verify(self.bundle, self.allow)

    def test_valid_bundle_and_exclusive_staging(self):
        checked = self.verify()
        overlays = self.root / "overlays"
        with patch.object(cp, "OVERLAYS", overlays):
            staged = cp.stage(checked)
            self.assertEqual(cp.verify(staged, self.allow), checked)
            with self.assertRaises(FileExistsError):
                cp.stage(checked)

    def test_stages_verified_bytes_not_later_changes(self):
        checked = self.verify()
        self.target.write_text("changed after verification")
        with patch.object(cp, "OVERLAYS", self.root / "overlays"):
            staged = cp.stage(checked)
            self.assertEqual(cp.verify(staged, self.allow), checked)

    def test_pins_approval_schema_and_evidence_are_required(self):
        original = copy.deepcopy(self.data)
        for key, value in [("base", "0" * 40), ("cpa", "0" * 40),
                           ("owner_approved", False), ("schema", True),
                           ("tests", []), ("dependencies", ["moving"]),
                           ("axes", {"mock": "passed"})]:
            with self.subTest(key=key):
                self.data = {**original, key: value}
                self.write()
                with self.assertRaises(ValueError):
                    self.verify()

    def test_ownership_grant_is_not_string_prefix(self):
        self.allow = ["src/mimic/providers/claud"]
        with self.assertRaises(ValueError):
            self.verify()

    def test_explicit_directory_grant_allows_only_descendants(self):
        self.assertEqual(cp.verify(self.bundle, [],
                                   ["src/mimic/providers/claude"]),
                         self.verify())
        with self.assertRaises(ValueError):
            cp.verify(self.bundle, [], ["src/mimic/providers/claud"])
        with self.assertRaises(ValueError):
            cp.verify(self.bundle, [], [self.path])

    def test_hash_inventory_and_duplicate_entries(self):
        self.target.write_text("tampered")
        with self.assertRaises(ValueError):
            self.verify()
        self.target.write_bytes(b"// synthetic source fixture\n")
        extra = self.target.parent / "extra.gleam"
        extra.write_text("unlisted")
        with self.assertRaises(ValueError):
            self.verify()
        extra.unlink()
        self.data["files"] *= 2
        self.write()
        with self.assertRaises(ValueError):
            self.verify()

    def test_symlink_hardlink_and_fifo_rejected(self):
        real = self.root / "real"
        self.target.rename(real)
        self.target.symlink_to(real)
        with self.assertRaises(ValueError):
            self.verify()
        self.target.unlink()
        os.link(real, self.target)
        with self.assertRaises(ValueError):
            self.verify()
        self.target.unlink()
        os.mkfifo(self.target)
        with self.assertRaises(ValueError):
            self.verify()

    def test_symlink_directory_rejected(self):
        directory = self.target.parent
        moved = self.root / "moved"
        directory.rename(moved)
        directory.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.verify()

    def test_traversal_metadata_private_and_noncanonical_paths(self):
        for path in ["../escape", "/absolute", "src//file", "src/../file",
                     "src/.git/config", "src/.jj/repo", "build/app.gleam",
                     "src/private/token", "src/.env", "src/file\\name",
                     "src/file\nname", "src/name/"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                cp.source_path(path)

    def test_duplicate_json_keys_and_extra_metadata_rejected(self):
        manifest = self.bundle / "manifest.json"
        manifest.write_text('{"schema":1,"schema":1}')
        with self.assertRaises(ValueError):
            self.verify()
        self.write()
        (self.bundle / ".git").mkdir()
        with self.assertRaises(ValueError):
            self.verify()

    def test_limits_and_test_commands_are_never_executed(self):
        self.data["tests"][0]["command"] = "exit 0; do-not-execute"
        self.write()
        with patch.object(cp, "MAX_TOTAL", 1):
            with self.assertRaises(ValueError):
                self.verify()
        self.verify()

    def test_exact_file_grant_does_not_authorize_descendants(self):
        self.data["files"][0]["path"] = self.path + "/extra.gleam"
        with self.assertRaises(ValueError):
            cp.manifest(json.dumps(self.data), [self.path])

    def test_traversal_errors_reject_incomplete_inventory(self):
        walk = os.walk

        def failing_walk(root, **kwargs):
            # Portable stand-in for a permission-denied unlisted subtree.
            if kwargs.get("onerror"):
                kwargs["onerror"](PermissionError("synthetic unreadable tree"))
            yield from walk(root, followlinks=False)

        with patch.object(cp.os, "walk", failing_walk):
            with self.assertRaises(PermissionError):
                self.verify()


if __name__ == "__main__":
    unittest.main()
