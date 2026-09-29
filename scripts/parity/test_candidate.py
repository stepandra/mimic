"""Candidate approval/identity negative controls, not provider parity evidence."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import candidate
import reference_driver as driver
from test_reference_driver import plan


def sha(data):
    return hashlib.sha256(data).hexdigest()


class CandidateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = {
            "gleam.toml": b'name = "mimic"\nversion = "0.1.0"\n',
            "manifest.toml": b"packages = []\n[requirements]\n",
            "src/mimic.gleam": b"pub fn main() { Nil }\n",
        }

    def package(self, extra=None):
        archive = self.root / "source.tar.gz"
        with tarfile.open(archive, "w:gz") as out:
            for name, data in self.files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                out.addfile(info, io.BytesIO(data))
            if extra:
                out.addfile(extra, io.BytesIO(b""))
        value = {
            "schema": candidate.SCHEMA, "base_revision": candidate.BASE,
            "source_archive_sha256": candidate.build.digest(archive),
            "files": {path: sha(data) for path, data in self.files.items()},
        }
        manifest = self.root / "candidate.json"
        manifest.write_text(json.dumps(value, indent=2) + "\n")
        return manifest, candidate.build.digest(manifest), archive, value

    def test_approval_is_exact_bytes_not_self_asserted_flag(self):
        path, expected, _, value = self.package()
        self.assertEqual(candidate.read_manifest(path, expected)[1], value)
        with self.assertRaises(ValueError):
            candidate.read_manifest(path, "0" * 64)
        path.write_text(path.read_text() + " ")
        with self.assertRaises(ValueError):
            candidate.read_manifest(path, expected)
        value["approved"] = True
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            candidate.read_manifest(path, candidate.build.digest(path))

    def test_duplicate_manifest_keys_are_rejected(self):
        path, _, _, _ = self.package()
        path.write_text(path.read_text().replace('"files": {', '"files": {}, "files": {'))
        with self.assertRaises(ValueError):
            candidate.read_manifest(path, candidate.build.digest(path))

    def test_archive_inventory_and_postbuild_inventory_are_exact(self):
        path, expected, archive, value = self.package()
        source = self.root / "source"
        source.mkdir()
        candidate.extract_source(archive, source, value)
        candidate.verify_source(source, value)
        (source / "build").mkdir()
        (source / "build/generated").write_text("allowed output")
        candidate.verify_source(source, value)
        for name in ("src/mimic.gleam", "src/extra.gleam"):
            with self.subTest(name=name):
                target = source / name
                previous = target.read_bytes() if target.exists() else None
                target.write_text("not approved")
                with self.assertRaises(ValueError):
                    candidate.verify_source(source, value)
                if previous is None:
                    target.unlink()
                else:
                    target.write_bytes(previous)

    def test_archive_links_traversal_duplicates_special_and_extra_files_block(self):
        cases = [
            ("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
            ("src/mimic.gleam", tarfile.REGTYPE), ("src/link", tarfile.SYMTYPE),
            ("src/hard", tarfile.LNKTYPE), ("src/pipe", tarfile.FIFOTYPE),
            ("extra", tarfile.REGTYPE), (".git/config", tarfile.REGTYPE),
            ("build/stale.beam", tarfile.REGTYPE),
        ]
        for index, (name, kind) in enumerate(cases):
            with self.subTest(name=name):
                member = tarfile.TarInfo(name)
                member.type = kind
                member.linkname = "../../outside"
                _, _, archive, value = self.package(extra=member)
                directory = self.root / str(index)
                directory.mkdir()
                with self.assertRaises((ValueError, FileExistsError)):
                    candidate.extract_source(archive, directory, value)

    def test_manifest_missing_or_unsafe_source_paths_block(self):
        path, _, _, value = self.package()
        for name in ("../x", "build/a", ".jj/a", "src/a.beam", ".env.secret"):
            changed = dict(value, files=dict(value["files"], **{name: "0" * 64}))
            path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                candidate.read_manifest(path, candidate.build.digest(path))
        del value["files"]["manifest.toml"]
        path.write_text(json.dumps(value))
        with self.assertRaises(ValueError):
            candidate.read_manifest(path, candidate.build.digest(path))

    def test_archive_hash_mismatch_blocks(self):
        _, _, archive, value = self.package()
        value["source_archive_sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            candidate.extract_source(archive, self.root / "unused", value)

    def test_source_extraction_uses_verified_immutable_snapshot(self):
        _, _, archive, value = self.package()
        source = self.root / "source"
        source.mkdir()
        open_archive = candidate.tarfile.open
        def mutate_then_parse(*args, **kwargs):
            archive.write_bytes(b"changed after verification")
            return open_archive(*args, **kwargs)
        with patch.object(candidate.tarfile, "open", side_effect=mutate_then_parse):
            candidate.extract_source(archive, source, value)
        candidate.verify_source(source, value)
        self.assertNotEqual(candidate.build.digest(archive), value["source_archive_sha256"])

    def test_offline_prepare_cannot_acquire_missing_dependencies_and_keeps_failure(self):
        path, expected, archive, _ = self.package()
        dependencies = SimpleNamespace(
            derive=lambda source: [], acquire=lambda *args: self.fail("implicit download"),
            stage=lambda *args: (_ for _ in ()).throw(ValueError("missing locked archive")),
        )
        with patch.dict(sys.modules, candidate_dependencies=dependencies), \
                patch.object(candidate.build, "BUILD", self.root / "build"), \
                patch.object(candidate, "export") as export:
            with self.assertRaises(RuntimeError):
                candidate.prepare(path, expected, archive)
            export.assert_not_called()
        failures = list((self.root / "build").rglob("failure.json"))
        self.assertEqual(len(failures), 1)
        self.assertEqual(json.loads(failures[0].read_text())["phase"], "offline-dependency-staging")

    def test_post_export_source_mutation_never_emits_success_manifest(self):
        path, expected, archive, _ = self.package()
        dependencies = SimpleNamespace(derive=lambda source: [], stage=lambda *args: None)
        def mutate(attempt, source):
            (source / "src/mimic.gleam").write_text("changed during export")
            return {}
        with patch.dict(sys.modules, candidate_dependencies=dependencies), \
                patch.object(candidate.build, "BUILD", self.root / "build"), \
                patch.object(candidate, "export", side_effect=mutate):
            with self.assertRaises(RuntimeError):
                candidate.prepare(path, expected, archive)
        self.assertEqual(list((self.root / "build").rglob("targets.json")), [])
        self.assertEqual(len(list((self.root / "build").rglob("failure.json"))), 1)

    def test_exporter_cannot_redirect_parent_staging_or_adopt_external_shipment(self):
        path, expected, archive, _ = self.package()
        dependencies = SimpleNamespace(derive=lambda source: [], stage=lambda *args: None)
        for root_link in (False, True):
            with self.subTest(shipment_root_link=root_link):
                outside = self.root / ("outside-" + str(root_link))
                outside.mkdir()
                def malicious_export(attempt, source):
                    shipment = source / "build/erlang-shipment"
                    shipment.parent.mkdir(parents=True)
                    if root_link:
                        external_ebin = outside / "mimic/ebin"
                        external_ebin.mkdir(parents=True)
                        (external_ebin / "mimic.beam").write_bytes(b"unapproved fake")
                        shipment.symlink_to(outside, target_is_directory=True)
                    else:
                        ebin = shipment / "mimic/ebin"
                        ebin.mkdir(parents=True)
                        (ebin / "mimic.beam").write_bytes(b"synthetic fake")
                        (attempt / "targets").mkdir()
                        (attempt / "targets/mimic").symlink_to(outside, target_is_directory=True)
                    return {}
                with patch.dict(sys.modules, candidate_dependencies=dependencies), \
                        patch.object(candidate.build, "BUILD", self.root / ("build-" + str(root_link))), \
                        patch.object(candidate, "export", side_effect=malicious_export):
                    with self.assertRaises(RuntimeError):
                        candidate.prepare(path, expected, archive)
                self.assertFalse((outside / "mimic/ebin/mimic.beam").exists() and not root_link)
                self.assertEqual(list((self.root / ("build-" + str(root_link))).rglob("targets.json")), [])

    def test_toolchain_resolution_executes_no_unsandboxed_commands(self):
        with patch.object(candidate.subprocess, "run") as run, \
                patch.object(candidate.subprocess, "check_output") as output:
            # Resolution may fail on a host missing installed prerequisites,
            # but it must never invoke a downloader/tool manager as fallback.
            try:
                candidate.toolchain()
            except (FileNotFoundError, RuntimeError):
                pass
            run.assert_not_called()
            output.assert_not_called()

    def test_explicit_acquire_does_not_export(self):
        path, expected, archive, _ = self.package()
        calls = []
        dependencies = SimpleNamespace(
            derive=lambda source: [], acquire=lambda *args: calls.append(args),
            stage=lambda *args: self.fail("acquire must not compile"),
        )
        with patch.dict(sys.modules, candidate_dependencies=dependencies), \
                patch.object(candidate.build, "BUILD", self.root / "build"), \
                patch.object(candidate, "export") as export:
            receipt = candidate.prepare(path, expected, archive, acquire=True)
        self.assertEqual(len(calls), 1)
        self.assertTrue(receipt.is_file())
        export.assert_not_called()

    def test_candidate_plan_cannot_be_assigned_base_or_another_candidate(self):
        request = plan("mimic")
        request["target_revision"] = "candidate-sha256:" + "a" * 64
        manifest = {"mimic_revision": "candidate-sha256:" + "b" * 64}
        with patch.object(driver, "validate_targets", return_value=manifest), \
                patch.object(driver.local_driver, "exercise") as exercise:
            with self.assertRaises(ValueError):
                driver.run(request, self.root / "targets.json")
            request["target_revision"] = driver.BASE
            with self.assertRaises(ValueError):
                driver.run(request, self.root / "targets.json")
            exercise.assert_not_called()

    def test_prepared_candidate_identity_and_artifact_hashes_are_bound(self):
        path, expected, archive, _ = self.package()
        dependencies = SimpleNamespace(derive=lambda source: [], stage=lambda *args: None)
        def synthetic_export(attempt, source):
            # Metadata-only control. Never executed or counted as MIMIC evidence.
            ebin = source / "build/erlang-shipment/mimic/ebin"
            ebin.mkdir(parents=True)
            (ebin / "mimic.beam").write_bytes(b"synthetic-not-an-executable")
            return {"erl": "/synthetic/never-executed"}
        with patch.dict(sys.modules, candidate_dependencies=dependencies), \
                patch.object(candidate.build, "BUILD", self.root / "build"), \
                patch.object(candidate, "export", side_effect=synthetic_export):
            target_path = candidate.prepare(path, expected, archive)
        manifest = json.loads(target_path.read_text())
        checked = driver.validate_targets(target_path)
        self.assertEqual(checked["mimic_revision"], "candidate-sha256:" + expected)
        self.assertEqual(checked["base_revision"], candidate.BASE)
        self.assertEqual(checked["_verified_manifest_sha256"], candidate.build.digest(target_path))
        manifest["mimic_revision"] = candidate.BASE
        target_path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            driver.validate_targets(target_path)
        manifest["mimic_revision"] = "candidate-sha256:" + expected
        target_path.write_text(json.dumps(manifest))
        (checked["_stage"] / "mimic/mimic/ebin/mimic.beam").write_bytes(b"stale")
        with self.assertRaises(ValueError):
            driver.validate_targets(target_path)

    def test_candidate_mode_retains_cpa_blocker_in_both_entrypoints(self):
        with patch.object(driver, "validate_targets", return_value={
                "mimic_revision": "candidate-sha256:" + "a" * 64,
                "candidate_manifest_sha256": "a" * 64, "base_revision": candidate.BASE}), \
                patch.object(driver.local_driver, "exercise") as exercise:
            result = driver.run(plan(), self.root / "targets.json")
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["diagnostics"]["blocker"], driver.CPA_STARTUP_BLOCKER)
            exercise.assert_not_called()
        with self.assertRaisesRegex(RuntimeError, driver.CPA_STARTUP_BLOCKER):
            driver.launch(plan(), "http://127.0.0.1:1", {})

    def test_partial_cli_candidate_arguments_fail_before_effects(self):
        with patch.object(sys, "stderr", new_callable=io.StringIO) as stderr:
            with self.assertRaises(SystemExit) as failure:
                driver.main(["--prepare", "--candidate-sha256", "0" * 64])
        self.assertEqual(failure.exception.code, 2)
        self.assertIn("requires all three", stderr.getvalue())

    def test_candidate_export_blocks_before_tool_resolution_or_process_launch(self):
        with patch.object(candidate, "toolchain") as tools, \
                patch.object(candidate.subprocess, "Popen") as process:
            with self.assertRaisesRegex(RuntimeError, candidate.DESCENDANT_CONTAINMENT_BLOCKER):
                candidate.export(self.root, self.root / "source")
            tools.assert_not_called()
            process.assert_not_called()

    def test_candidate_runtime_blocks_at_result_and_launch_boundaries(self):
        request = plan("mimic")
        digest = "a" * 64
        request["target_revision"] = "candidate-sha256:" + digest
        manifest = {"mimic_revision": request["target_revision"],
                    "candidate_manifest_sha256": digest, "base_revision": candidate.BASE}
        with patch.object(driver, "validate_targets", return_value=manifest), \
                patch.object(driver.local_driver, "exercise") as exercise:
            result = driver.run(request, self.root / "targets.json")
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["observations"], "{}")
            self.assertEqual(result["diagnostics"]["blocker"], candidate.DESCENDANT_CONTAINMENT_BLOCKER)
            exercise.assert_not_called()
        with self.assertRaisesRegex(RuntimeError, candidate.DESCENDANT_CONTAINMENT_BLOCKER):
            driver.launch(request, "http://127.0.0.1:1", manifest)

    def test_integration_selector_requires_opt_in_and_cannot_override_blocker(self):
        import integration_candidate
        with patch.object(candidate, "export") as export:
            for args, expected in (([], "not_run"), (["--run"], "blocked")):
                with self.subTest(args=args), patch.object(sys, "stdout", new_callable=io.StringIO) as out:
                    self.assertEqual(integration_candidate.main(args), 1)
                    self.assertEqual(json.loads(out.getvalue())["status"], expected)
            export.assert_not_called()


if __name__ == "__main__":
    unittest.main()
