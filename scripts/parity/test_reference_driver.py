"""Synthetic negative controls, not CPA execution or passing parity evidence."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import reference_build as build
import reference_driver as driver
import reference_sandbox as sandbox


def plan(target="cpa"):
    text = (driver.ROOT / "test/parity/fixtures/messages-v1.json").read_text()
    return {
        "schema_version": 1, "capability_id": "claude-messages",
        "provider": "claude", "auth_mode": "api_key", "input_protocol": "messages",
        "upstream_mode": "messages_native", "fixture_json": text,
        "fixture_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "cpa_revision": build.REVISION, "target": target,
        "target_revision": build.REVISION if target == "cpa" else driver.BASE,
        "phase": "exercise", "state_dir": "/not/a/runner/directory",
    }


class ReferenceContractTest(unittest.TestCase):
    def test_exact_known_fixture_is_selected(self):
        _, supported = driver.validate_plan(plan())
        self.assertTrue(supported)

    def test_stale_misbound_and_auth_substitution_fail_before_launch(self):
        for key, value in [
            ("fixture_sha256", "0" * 64), ("target_revision", "stale"),
            ("cpa_revision", "wrong"), ("provider", "kimi"),
            ("auth_mode", "oauth"), ("input_protocol", "responses"),
            ("upstream_mode", "openai_compatible"), ("phase", "seed"),
        ]:
            with self.subTest(key=key), patch.object(driver, "launch") as launch:
                changed = dict(plan(), **{key: value})
                with self.assertRaises(ValueError):
                    driver.run(changed, Path("/missing"))
                launch.assert_not_called()

    def test_added_checks_cannot_default_to_true(self):
        changed = plan()
        fixture = json.loads(changed["fixture_json"])
        fixture["required_checks"].append("unknown_future_check")
        changed["fixture_json"] = json.dumps(fixture)
        changed["fixture_sha256"] = hashlib.sha256(changed["fixture_json"].encode()).hexdigest()
        with self.assertRaises(ValueError):
            driver.validate_plan(changed)

    def test_unknown_capability_cannot_execute_known_fixture(self):
        changed = dict(plan(), capability_id="kimi-native")
        with patch.object(driver, "launch") as launch:
            result = driver.run(changed, Path("/missing"))
            self.assertEqual(result["status"], "unsupported")
            self.assertTrue(all(not check["passed"] for check in result["checks"]))
            launch.assert_not_called()

    def test_restart_cannot_reseed_buffered_fixture(self):
        changed = dict(plan(), phase="restart")
        self.assertFalse(driver.validate_plan(changed)[1])

    def test_background_policy_blocker_cannot_be_reported_as_execution(self):
        with patch.object(driver, "validate_targets", return_value={}), \
                patch.object(driver.local_driver, "exercise") as exercise:
            result = driver.run(plan(), Path("/synthetic-test"))
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["observations"], "{}")
        self.assertEqual(result["diagnostics"]["blocker"], driver.CPA_STARTUP_BLOCKER)
        exercise.assert_not_called()

    def test_fake_partial_stale_artifacts_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            stage = directory / "targets"
            stage.mkdir()
            (stage / "cpa").write_bytes(b"synthetic-fake-not-an-executable")
            provenance = {
                "revision": build.REVISION, "source_modified": False,
                "archive_sha256": build.ARCHIVE_SHA256,
                "executable_sha256": "0" * 64,
            }
            (directory / "provenance.json").write_text(json.dumps(provenance))
            manifest = {
                "schema": "mimic.reference-targets/v1", "cpa_revision": build.REVISION,
                "mimic_revision": driver.BASE, "files": driver.tree_hashes(stage),
                "build_provenance_sha256": build.digest(directory / "provenance.json"),
            }
            path = directory / "targets.json"
            changes = [{}, {"cpa_revision": "old"}, {"files": {}},
                       {"build_provenance_sha256": "stale"}]
            with patch.object(driver, "STAGE", stage), patch.object(build, "BUILD", directory):
                for changeset in changes:
                    with self.subTest(changes=changeset):
                        path.write_text(json.dumps(dict(manifest, **changeset)))
                        with self.assertRaises(ValueError):
                            driver.validate_targets(path)
                # Synthetic metadata-only positive control, never executable
                # evidence: bind the bytes of an alternate --targets file, not
                # the default filename or a later re-read.
                provenance["executable_sha256"] = build.digest(stage / "cpa")
                (directory / "provenance.json").write_text(json.dumps(provenance))
                manifest["build_provenance_sha256"] = build.digest(directory / "provenance.json")
                alternate = directory / "alternate-targets.json"
                alternate.write_text(json.dumps(manifest, indent=2))
                verified = driver.validate_targets(alternate)
                self.assertEqual(verified["_verified_manifest_sha256"], build.digest(alternate))
                self.assertNotEqual(verified["_verified_manifest_sha256"], build.digest(path))

    def test_environment_does_not_inherit_home_proxies_credentials_or_dyld(self):
        env = sandbox.environment(Path("/synthetic"))
        self.assertEqual(env["HOME"], "/synthetic/home")
        self.assertNotIn("HTTP_PROXY", env)
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertNotIn("DYLD_INSERT_LIBRARIES", env)

    def test_unsupported_platform_is_not_an_unsandboxed_fallback(self):
        with patch.object(sandbox.platform, "system", return_value="unsupported"):
            with self.assertRaises(RuntimeError):
                sandbox.policy(Path("."), 1234, 1235)

    def test_policy_binding_ignores_disk_copy_and_revalidates_root(self):
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(sandbox.platform, "system", return_value="Darwin"):
            directory = Path(temp).resolve()
            boundary = sandbox.LaunchPolicy(directory, sandbox.policy(directory, 43217, 43218))
            sandbox.record_policy(boundary)
            (directory / "sandbox.sb").write_text("(version 1)(allow default)")
            command = sandbox.argv(boundary, ["/usr/bin/true"])
            self.assertEqual(command[1:3], ["-p", boundary.text])
            self.assertNotIn("-f", command)
            directory.chmod(0o755)
            with self.assertRaises(ValueError):
                sandbox.argv(boundary, ["/usr/bin/true"])
            directory.chmod(0o700)

    def test_policy_binding_rejects_replaced_directory_and_filename_api(self):
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(sandbox.platform, "system", return_value="Darwin"):
            parent = Path(temp).resolve()
            directory = parent / "runtime"
            directory.mkdir(mode=0o700)
            boundary = sandbox.LaunchPolicy(directory, sandbox.policy(directory, 43217, 43218))
            directory.rename(parent / "old-runtime")
            directory.mkdir(mode=0o700)
            with self.assertRaises(ValueError):
                sandbox.argv(boundary, ["/usr/bin/true"])
            with self.assertRaises(TypeError):
                sandbox.argv(directory, ["/usr/bin/true"])

    def test_real_launcher_reuses_parent_policy_for_all_three_mimic_phases(self):
        # Control-flow unit only: no process, socket, compiler or target runs.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            ebin = root / "staged/mimic/mimic/ebin"
            ebin.mkdir(parents=True)
            (ebin / "mimic.beam").write_bytes(b"synthetic-marker")
            request = plan("mimic")
            request["state_dir"] = str(root / "build/parity-results/row/mimic")
            manifest = {"_stage": root / "staged", "erl": "/synthetic/not-executed",
                        "_verified_manifest_sha256": "a" * 64}
            child = SimpleNamespace(pid=123, wait=lambda timeout: 0)
            with patch.object(driver, "ROOT", root), \
                    patch.object(driver, "port", return_value=43217), \
                    patch.object(driver, "wait_ready"), \
                    patch.object(sandbox.platform, "system", return_value="Darwin"), \
                    patch.object(sandbox, "probe", return_value={"synthetic": True}), \
                    patch.object(sandbox, "stop"), \
                    patch.object(sandbox, "start", return_value=child) as start:
                driver.launch(request, "http://127.0.0.1:43218", manifest)
            self.assertEqual(start.call_count, 3)
            boundary = start.call_args_list[0].args[0]
            self.assertIsInstance(boundary, sandbox.LaunchPolicy)
            self.assertTrue(all(call.args[0] is boundary for call in start.call_args_list))
            execution = json.loads((Path(request["state_dir"]) /
                                    "reference-runtime/execution.json").read_text())
            self.assertEqual(execution["launch_policy_sha256"], boundary.sha256)

    def test_safe_suite_guards_exec_datagrams_and_dns_without_executing_them(self):
        import safe_unit_tests
        with safe_unit_tests.execution_guards():
            for event in ("os.exec", "os.posix_spawn", "socket.sendto",
                          "socket.gethostbyname", "socket.gethostbyaddr"):
                with self.subTest(event=event), self.assertRaises(AssertionError):
                    sys.audit(event, "synthetic-audit-control")


if __name__ == "__main__":
    unittest.main()
