"""Harness contract tests, NOT native client/provider compatibility evidence."""

import base64
import hashlib
import http.client
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts/native-clients"
sys.path.insert(0, str(SCRIPTS))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


qa, live, harness, fixtures = [load(name) for name in ["qa", "live", "harness", "fixtures"]]


class AcquisitionTests(unittest.TestCase):
    def test_lock_has_exact_platform_integrities(self):
        for pin in qa.LOCK["clients"].values():
            self.assertNotIn("latest", pin["url"])
            self.assertEqual(len(base64.b64decode(pin["integrity"].split("-")[1])), 64)
            self.assertTrue(pin["url"].startswith("https://registry.npmjs.org/"))

    def test_integrity_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact"
            path.write_bytes(b"synthetic")
            pin = {"integrity": "sha512-" + base64.b64encode(
                hashlib.sha512(b"synthetic").digest()).decode()}
            qa.verify_integrity(pin, path)
            path.write_bytes(b"tampered")
            with self.assertRaises(qa.Blocked):
                qa.verify_integrity(pin, path)

    def test_extraction_is_member_only_and_repeatable(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sample.tgz"
            with tarfile.open(archive, "w:gz") as package:
                for name in ["package/bin", "../../escaped"]:
                    entry = tarfile.TarInfo(name)
                    entry.size = 4
                    package.addfile(entry, io.BytesIO(b"test"))
            target = Path(temporary) / "bin"
            qa.extract_binary(archive, "package/bin", target)
            qa.extract_binary(archive, "package/bin", target)
            self.assertEqual(target.read_bytes(), b"test")
            self.assertEqual(set(p.name for p in Path(temporary).iterdir()), {"sample.tgz", "bin"})

    def test_archive_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sample.tgz"
            with tarfile.open(archive, "w:gz") as package:
                entry = tarfile.TarInfo("package/bin")
                entry.type, entry.linkname = tarfile.SYMTYPE, "/etc/passwd"
                package.addfile(entry)
            with self.assertRaises(qa.Blocked):
                qa.extract_binary(archive, "package/bin", Path(temporary) / "bin")

    def test_codex_resource_tree_rejects_parent_traversal(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "sample.tgz"
            prefix = "package/vendor/x86_64-unknown-linux-musl/"
            with tarfile.open(archive, "w:gz") as package:
                entry = tarfile.TarInfo(prefix + "../../escape")
                entry.size = 4
                package.addfile(entry, io.BytesIO(b"test"))
            with self.assertRaises(qa.Blocked):
                qa.extract_codex_tree(archive, Path(temporary) / "tree")


class ContainmentTests(unittest.TestCase):
    def test_no_docker_is_blocked_not_passed(self):
        with patch.object(qa, "require_docker", side_effect=qa.Blocked("no_daemon")):
            result = qa.offline(Path("/not/read"), ["claude", "codex"], qa.WORKFLOWS)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(len(result["results"]), 8)
        self.assertTrue(all(row["status"] == "blocked" for row in result["results"]))
        self.assertEqual(result["live"], "not_run")
        self.assertEqual(result["source_base_revision"],
                         "3e00808ff0fefbb6728edb1769c17139ef0fd93a")
        self.assertNotIn("base", result)

    def test_container_has_only_readonly_shipment_mount(self):
        argv = qa.container_args("synthetic", "sha256:" + "a" * 64,
                                 "/synthetic/shipment", "claude", "sse")
        for flag, value in [("--network", "none"), ("--pull", "never"),
                            ("--cap-drop", "ALL"), ("--user", "10001:10001"),
                            ("--security-opt", "no-new-privileges")]:
            self.assertEqual(argv[argv.index(flag) + 1], value)
        self.assertIn("--read-only", argv)
        self.assertEqual(argv.count("--mount"), 1)
        self.assertIn("dst=/shipment,readonly", argv[argv.index("--mount") + 1])
        self.assertNotIn("--privileged", argv)
        self.assertNotIn("--env-file", argv)

    def test_environment_is_allowlist(self):
        for client in ["claude", "codex"]:
            _, env = harness.client_command(client, 12345, "tool")
            self.assertEqual(env["HOME"], "/work/home")
            for secret in ["SSH_AUTH_SOCK", "HTTP_PROXY", "AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY"]:
                self.assertNotIn(secret, env)

    def test_host_harness_refuses_before_spawn(self):
        with patch.object(harness.os, "getuid", return_value=0):
            with self.assertRaises(RuntimeError):
                harness.containment()

    def test_only_compiled_public_shipment_crosses_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, target = Path(temporary) / "source", Path(temporary) / "target"
            (source / "mimic/ebin").mkdir(parents=True)
            target.mkdir()
            (source / "entrypoint.sh").write_text("synthetic entry")
            (source / "mimic/ebin/mimic.beam").write_bytes(b"synthetic beam")
            (source / "private-key").write_text("must not copy")
            qa.shipment_copy(source, target)
            self.assertFalse((target / "private-key").exists())
            self.assertEqual((target / "mimic/ebin").stat().st_mode & 0o777, 0o755)
            self.assertEqual((target / "mimic/ebin/mimic.beam").stat().st_mode & 0o777, 0o444)
            (source / "link").symlink_to(source / "private-key")
            second_target = Path(temporary) / "second-target"
            second_target.mkdir()
            with self.assertRaises(qa.Blocked):
                qa.shipment_copy(source, second_target)

    def test_cleanup_after_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / "acquisition.json").write_text(json.dumps({
                "image_id": "sha256:" + "a" * 64, "inputs": qa.acquisition_fingerprint()}))
            calls = []

            def docker(args, timeout=30):
                calls.append(args)
                if args[0] == "run":
                    raise qa.Blocked("docker_unavailable_or_timeout")
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with patch.object(qa, "WORK", work), patch.object(qa, "require_docker"), \
                    patch.object(qa, "shipment_copy", return_value="synthetic"), \
                    patch.object(qa, "docker", side_effect=docker):
                report = qa.offline(work, ["claude"], ["sse"])
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(calls[-1][:2], ["rm", "--force"])
            self.assertEqual(calls[-1][2], calls[-2][calls[-2].index("--name") + 1])

    def test_inner_containment_block_is_not_compatibility_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            (work / "acquisition.json").write_text(json.dumps({
                "image_id": "sha256:" + "a" * 64, "inputs": qa.acquisition_fingerprint()}))

            def docker(args, timeout=30):
                if args[0] == "run":
                    return subprocess.CompletedProcess(args, 2, json.dumps({
                        "status": "blocked", "reason": "privilege_containment_missing"}).encode(), b"")
                return subprocess.CompletedProcess(args, 0, b"", b"")

            with patch.object(qa, "WORK", work), patch.object(qa, "require_docker"), \
                    patch.object(qa, "shipment_copy", return_value="synthetic"), \
                    patch.object(qa, "docker", side_effect=docker):
                report = qa.offline(work, ["claude"], ["sse"])
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["results"][0]["status"], "blocked")


class FixtureTests(unittest.TestCase):
    def test_cancellation_requires_native_event_not_rendered_text(self):
        self.assertFalse(harness.native_stream_event_seen("codex", b'{"type":"turn.started"}'))
        self.assertFalse(harness.native_stream_event_seen("claude", b'{"type":"system"}'))
        self.assertTrue(harness.native_stream_event_seen("claude", json.dumps({
            "type": "stream_event", "event": {"type": "content_block_delta"}}).encode()))
        self.assertTrue(harness.native_stream_event_seen("codex", json.dumps({
            "type": "item.started", "item": {"type": "agent_message"}}).encode()))
        self.assertFalse(harness.native_stream_event_seen("codex", b'{"type":"item.completed"}'))

    def test_error_output_cannot_pass_by_echoing_marker(self):
        for client in ["claude", "codex"]:
            for output in [fixtures.MARKER.encode(), json.dumps({
                    "type": "error", "message": fixtures.MARKER}).encode()]:
                self.assertFalse(harness.successful_output(client, output))
        result = {"type": "result", "subtype": "success", "is_error": False,
                  "result": fixtures.MARKER}
        self.assertTrue(harness.successful_output("claude", json.dumps(result).encode()))
        self.assertFalse(harness.successful_output(
            "claude", json.dumps(dict(result, is_error=True)).encode()))
        events = [{"type": "item.completed", "item": {
            "type": "agent_message", "text": fixtures.MARKER}}, {"type": "turn.completed"}]
        output = b"\n".join(json.dumps(item).encode() for item in events)
        self.assertTrue(harness.successful_output("codex", output))
        self.assertFalse(harness.successful_output("codex", output + b'\n{"type":"turn.failed"}'))

    def test_sse_deterministic_complete_and_synthetic(self):
        for frames in [fixtures.claude_frames(), fixtures.codex_frames()]:
            raw = b"".join(frames)
            self.assertIn(b"synthetic", raw)
            for frame in frames:
                data = json.loads(frame.split(b"\ndata: ")[1])
                self.assertIn("type", data)
        self.assertEqual(fixtures.codex_frames(), fixtures.codex_frames())
        self.assertIn(b"message_stop", fixtures.claude_frames()[-1])
        self.assertIn(b"response.completed", fixtures.codex_frames()[-1])

    def test_tools_are_bounded_to_synthetic_file(self):
        for frames in [fixtures.claude_frames(True), fixtures.codex_frames(True)]:
            raw = b"".join(frames)
            self.assertIn(b"/work/project/canary.txt", raw)
            self.assertNotIn(b"curl", raw)
            self.assertNotIn(b"rm ", raw)

    def test_local_fixture_requires_tool_result_before_completion(self):
        with fixtures.Fixture("codex", "tool") as server:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            payload = {"model": "gpt-5.5", "stream": True, "input": [
                {"type": "function_call_output", "call_id": "call_synthetic",
                 "output": fixtures.CANARY}]}
            connection.request("POST", "/backend-api/codex/responses", json.dumps(payload), {
                "Authorization": f"Bearer {fixtures.UPSTREAM_KEY}"})
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn(b"response.completed", response.read())
            connection.close()
            self.assertTrue(server.observations[0]["tool_result_canary"])
            self.assertTrue(server.observations[0]["upstream_auth_ok"])


class LiveGateTests(unittest.TestCase):
    def approval(self):
        return {"approved_by": "synthetic-operator", "account_label": "synthetic-account",
                "endpoint": "https://operator.invalid/v1", "model": "synthetic-model",
                "allowed_data": "synthetic-only", "max_requests": 2, "max_input_tokens": 100,
                "max_output_tokens": 50, "max_cost_usd": 0.01, "max_seconds": 10}

    def test_default_does_not_read_approval_or_credentials(self):
        with patch.object(live.Path, "read_text", side_effect=AssertionError("must not read")):
            result = live.preflight(Path("/private"), False)
        self.assertEqual(result["status"], "not_run")
        self.assertFalse(result["credentials_read"])

    def test_execute_without_approval_blocked(self):
        self.assertEqual(live.preflight(execute=True)["status"], "blocked")

    def test_valid_approval_still_never_runs_without_enforcer(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "approval"
            path.write_text(json.dumps(self.approval()))
            path.chmod(0o600)
            result = live.preflight(path, True)
        self.assertEqual(result["status"], "blocked")
        self.assertIn("not_implemented", result["reason"])
        self.assertEqual(result["requests_sent"], 0)

    def test_endpoint_secrets_and_unbounded_budgets_rejected(self):
        for key, value in [("endpoint", "https://secret@operator.invalid"),
                           ("max_requests", 0), ("max_seconds", True),
                           ("max_cost_usd", float("nan")), ("allowed_data", "private-code")]:
            self.assertIsNotNone(live.validate(dict(self.approval(), **{key: value})))


if __name__ == "__main__":
    unittest.main()
