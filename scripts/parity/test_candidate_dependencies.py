"""Synthetic dependency-boundary controls; never parity or CPA evidence."""

import hashlib
import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import candidate_dependencies as deps


ROOT = Path(__file__).resolve().parents[2]


def tar_bytes(entries, mode="w"):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode=mode) as archive:
        for name, contents, kind in entries:
            member = tarfile.TarInfo(name)
            if kind == "file":
                member.size = len(contents)
            elif kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = "gleam.toml"
            elif kind == "dir":
                member.type = tarfile.DIRTYPE
            archive.addfile(member, io.BytesIO(contents) if kind == "file" else None)
    return output.getvalue()


def hex_archive(entries=None):
    if entries is None:
        entries = [("gleam.toml", b'name = "pkg"\nversion = "1.0.0"\n', "file"),
                   ("src/pkg.gleam", b"pub fn hello() { 1 }\n", "file")]
    contents = tar_bytes(entries, "w:gz")
    return tar_bytes([
        ("VERSION", b"3", "file"), ("metadata.config", b"", "file"),
        ("contents.tar.gz", contents, "file"), ("CHECKSUM", b"0" * 64, "file"),
    ])


class CandidateDependenciesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.cache = self.base / "candidate-cache"
        self.cache.mkdir()
        self.archive = hex_archive()
        self.checksum = hashlib.sha256(self.archive).hexdigest()
        (self.source / "vendor/one").mkdir(parents=True)
        (self.source / "vendor/one/gleam.toml").write_text(
            'name = "one"\nversion = "1.0.0"\n'
            '[dependencies]\npkg = ">= 1.0.0 and < 2.0.0"\n'
            '[dev-dependencies]\nunlocked_dev_of_local = ">= 1.0.0"\n'
        )
        self.config = (
            'name = "app"\nversion = "0.1.0"\n'
            '[dependencies]\none = { path = "vendor/one" }\n'
            '[dev-dependencies]\npkg = ">= 1.0.0 and < 2.0.0"\n'
        )
        self.packages = (
            '{ name = "one", version = "1.0.0", source = "local", '
            'path = "vendor/one", requirements = ["pkg"], build_tools = ["gleam"] },\n'
            '{ name = "pkg", version = "1.0.0", source = "hex", '
            'outer_checksum = "' + self.checksum + '", '
            'requirements = [], build_tools = ["gleam"], otp_app = "pkg" },'
        )
        self.requirements = (
            '[requirements]\none = { path = "vendor/one" }\n'
            'pkg = { version = ">= 1.0.0 and < 2.0.0" }\n'
        )
        self.write_config()

    def write_config(self):
        (self.source / "gleam.toml").write_text(self.config)
        (self.source / "manifest.toml").write_text(
            "packages = [\n" + self.packages + "\n]\n" + self.requirements
        )

    def cache_archive(self, data=None):
        (self.cache / (self.checksum + ".tar")).write_bytes(
            self.archive if data is None else data
        )

    def test_actual_root_closure_includes_root_dev_and_local_runtime(self):
        packages = deps.derive(ROOT)
        self.assertEqual(len(packages), 19)
        self.assertEqual(sum(p["source"] == "hex" for p in packages), 18)
        self.assertEqual([p["name"] for p in packages if p["source"] == "local"], ["mist"])
        self.assertIn("gleeunit", {p["name"] for p in packages})
        self.assertIn("hpack_erl", {p["name"] for p in packages})
        self.assertNotIn("gleam_hackney", {p["name"] for p in packages})

    def test_actual_root_offline_missing_archive_fails_before_build(self):
        source = self.base / "actual-source"
        for name in ("gleam.toml", "manifest.toml", "vendor/mist/gleam.toml"):
            destination = source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, destination)
        with patch.object(deps.urllib.request, "build_opener") as network:
            with self.assertRaisesRegex(ValueError, "missing or unsafe cached archive"):
                deps.stage(source, self.cache)
        network.assert_not_called()
        self.assertFalse((source / "build").exists())

    def test_synthetic_complete_offline_stage_and_index(self):
        self.cache_archive()
        with patch.object(deps.urllib.request, "build_opener") as network:
            deps.stage(self.source, self.cache)
        network.assert_not_called()
        self.assertEqual(
            (self.source / "build/packages/pkg/src/pkg.gleam").read_text(),
            "pub fn hello() { 1 }\n",
        )
        self.assertEqual(
            (self.source / "build/packages/packages.toml").read_text(),
            '[packages]\none = "1.0.0"\npkg = "1.0.0"\n',
        )
        fingerprint = self.source / "build/packages/one.config_fingerprint"
        self.assertEqual(fingerprint.read_text(), "invalid")
        self.assertEqual(
            fingerprint.stat().st_mtime_ns,
            (self.source / "vendor/one/gleam.toml").stat().st_mtime_ns,
        )
        self.assertFalse((self.source / "build/packages/one").exists())
        with self.assertRaisesRegex(ValueError, "build directory must be absent"):
            deps.stage(self.source, self.cache)

    def test_staging_uses_verified_snapshot_not_mutated_cache_path(self):
        self.cache_archive()
        unpack = deps._unpack
        def replace_cache_then_unpack(data, *args):
            self.cache_archive(b"changed after verification")
            return unpack(data, *args)
        with patch.object(deps, "_unpack", side_effect=replace_cache_then_unpack):
            deps.stage(self.source, self.cache)
        self.assertEqual(
            (self.source / "build/packages/pkg/src/pkg.gleam").read_text(),
            "pub fn hello() { 1 }\n",
        )

    def test_acquire_public_url_and_checked_bytes_only(self):
        urls, archive, test = [], self.archive, self

        class Opener:
            def open(self, request, timeout):
                urls.append(request.full_url)
                test.assertEqual(timeout, 30)
                return io.BytesIO(archive)

        with patch.object(deps.urllib.request, "build_opener", return_value=Opener()):
            deps.acquire(self.source, self.cache)
        self.assertEqual(urls, ["https://repo.hex.pm/tarballs/pkg-1.0.0.tar"])
        self.assertEqual((self.cache / (self.checksum + ".tar")).read_bytes(), self.archive)

    def test_checksum_mismatch_and_no_partial_build(self):
        self.cache_archive(b"not a tarball")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            deps.stage(self.source, self.cache)
        self.assertFalse((self.source / "build").exists())
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            deps.acquire(self.source, self.cache)

    def test_candidate_cache_rejects_unrelated_files(self):
        self.cache_archive()
        (self.cache / "host-package.tar").write_bytes(b"untrusted")
        with self.assertRaisesRegex(ValueError, "non-locked artifacts"):
            deps.stage(self.source, self.cache)
        with self.assertRaisesRegex(ValueError, "non-locked artifacts"):
            deps.acquire(self.source, self.cache)
        self.assertFalse((self.source / "build").exists())

    def test_lock_drift_unlocked_git_and_out_of_tree_fail(self):
        cases = [
            ("root dev drift", "requirements", self.requirements.replace(
                'pkg = { version = ">= 1.0.0 and < 2.0.0" }\n', "")),
            ("git", "config", self.config.replace(
                'one = { path = "vendor/one" }', 'one = { git = "https://example.com/one" }')),
            ("unlocked", "local", 'name = "one"\nversion = "1.0.0"\n'
             '[dependencies]\nmissing = ">= 1.0.0"\n'),
            ("path escape", "config", self.config.replace(
                'vendor/one', '../elsewhere')),
            ("version mismatch", "local", 'name = "one"\nversion = "2.0.0"\n'
             '[dependencies]\npkg = ">= 1.0.0"\n'),
            ("constraint mismatch", "local", 'name = "one"\nversion = "1.0.0"\n'
             '[dependencies]\npkg = ">= 2.0.0"\n'),
            ("unknown lock source", "packages", self.packages.replace(
                'source = "hex"', 'source = "git"')),
        ]
        for label, target, changed in cases:
            with self.subTest(label=label):
                old = {"config": self.config, "packages": self.packages,
                       "requirements": self.requirements,
                       "local": (self.source / "vendor/one/gleam.toml").read_text()}
                try:
                    if target == "local":
                        (self.source / "vendor/one/gleam.toml").write_text(changed)
                    else:
                        setattr(self, target, changed)
                    self.write_config()
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        deps.derive(self.source)
                finally:
                    self.config, self.packages = old["config"], old["packages"]
                    self.requirements = old["requirements"]
                    (self.source / "vendor/one/gleam.toml").write_text(old["local"])
                    self.write_config()

    def test_local_path_symlink_is_rejected(self):
        (self.source / "vendor/one").rename(self.source / "vendor/real")
        (self.source / "vendor/one").symlink_to("real")
        with self.assertRaisesRegex(ValueError, "symlinked local path"):
            deps.derive(self.source)

    def test_nested_local_closure_and_existing_out_of_tree_path(self):
        (self.source / "vendor/two").mkdir()
        (self.source / "vendor/two/gleam.toml").write_text(
            'name = "two"\nversion = "1.0.0"\n[dependencies]\n'
            'pkg = ">= 1.0.0 and < 2.0.0"\n'
        )
        local = self.source / "vendor/one/gleam.toml"
        local.write_text(local.read_text().replace(
            '[dev-dependencies]', 'two = { path = "../two" }\n[dev-dependencies]'
        ))
        self.packages = self.packages.replace(
            'requirements = ["pkg"]', 'requirements = ["pkg", "two"]'
        ) + '\n{ name = "two", version = "1.0.0", source = "local", ' \
            'path = "vendor/two", requirements = ["pkg"] },'
        self.write_config()
        self.assertEqual(len(deps.derive(self.source)), 3)
        (self.base / "outside").mkdir()
        (self.base / "outside/gleam.toml").write_text(
            'name = "two"\nversion = "1.0.0"\n[dependencies]\n'
            'pkg = ">= 1.0.0 and < 2.0.0"\n'
        )
        local.write_text(local.read_text().replace("../two", "../../../outside"))
        with self.assertRaisesRegex(ValueError, "outside candidate"):
            deps.derive(self.source)

    def test_bounded_expansion_and_hex_metadata_drift(self):
        self.cache_archive()
        with patch.object(deps, "MAX_EXPANDED", 3):
            with self.assertRaisesRegex(ValueError, "expands beyond bound"):
                deps.stage(self.source, self.cache)
        self.assertFalse((self.source / "build").exists())
        self.archive = hex_archive([
            ("gleam.toml", b'name = "pkg"\nversion = "1.0.0"\n'
             b'[dependencies]\nother = ">= 1.0.0"\n', "file"),
        ])
        old = self.checksum
        self.checksum = hashlib.sha256(self.archive).hexdigest()
        self.packages = self.packages.replace(old, self.checksum)
        (self.cache / (old + ".tar")).unlink()
        self.write_config()
        self.cache_archive()
        with self.assertRaisesRegex(ValueError, "requirements differ from lock"):
            deps.stage(self.source, self.cache)
        self.assertFalse((self.source / "build").exists())

    def test_unsafe_hex_entries_cannot_escape_or_link(self):
        base = [("gleam.toml", b'name = "pkg"\nversion = "1.0.0"\n', "file")]
        cases = [
            ("traversal", base + [("../escape", b"x", "file")]),
            ("absolute", base + [("/escape", b"x", "file")]),
            ("symlink", base + [("src/evil", b"", "symlink")]),
            ("duplicate", base + [("gleam.toml", b"x", "file")]),
            ("file parent", base + [("gleam.toml/deeper", b"x", "file")]),
        ]
        for label, entries in cases:
            with self.subTest(label=label):
                old = self.checksum
                self.archive = hex_archive(entries)
                self.checksum = hashlib.sha256(self.archive).hexdigest()
                self.packages = self.packages.replace(old, self.checksum)
                old_archive = self.cache / (old + ".tar")
                if old_archive.exists():
                    old_archive.unlink()
                self.write_config()
                self.cache_archive()
                with self.assertRaises(ValueError):
                    deps.stage(self.source, self.cache)
                self.assertFalse((self.source / "build").exists())
                self.assertFalse((self.base / "escape").exists())


if __name__ == "__main__":
    unittest.main()
