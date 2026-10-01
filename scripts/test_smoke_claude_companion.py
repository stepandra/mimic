"""Harness contracts only; actual root CLI coverage is the companion smoke."""

import base64
import contextlib
import errno
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import runpy
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


SMOKE = runpy.run_path(str(Path(__file__).with_name("smoke-claude-companion.py")))
Failure = SMOKE["SmokeFailure"]


@contextlib.contextmanager
def fixture_server(role, handler=None):
    fixture = SMOKE["Fixture"](SMOKE["OutputGuard"]())
    server = SMOKE["Server"](("127.0.0.1", 0), handler or SMOKE["Handler"])
    server.fixture, server.role = fixture, role
    worker = threading.Thread(target=server.serve_forever,
                              kwargs={"poll_interval": 0.01}, daemon=True)
    worker.start()
    try:
        yield server, fixture
    finally:
        fixture.release.set()
        SMOKE["Workflow"].close_server(server, worker)


class HarnessTest(unittest.TestCase):
    def test_gleam_is_one_executable_argv_element(self):
        self.assertEqual(SMOKE["command_for"](None, {"GLEAM": "/tool with spaces/gleam"}),
                         ["/tool with spaces/gleam", "run", "--"])
        self.assertEqual(SMOKE["command_for"](None, {}), ["gleam", "run", "--"])
        with self.assertRaises(Failure):
            SMOKE["command_for"](None, {"GLEAM": ""})

    def test_shipment_uses_exported_entrypoint_not_provider_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(Failure):
                SMOKE["command_for"](directory, {})
            SMOKE["private_file"](directory / "entrypoint.sh", "")
            self.assertEqual(SMOKE["command_for"](directory, {"GLEAM": "ignored"}),
                             ["sh", str(directory.resolve() / "entrypoint.sh"), "run"])

    def test_environment_has_private_home_and_no_ambient_credentials_or_vm_flags(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            env = SMOKE["child_environment"](directory, {
                "PATH": "/usr/bin", "LANG": "C", "HOME": "/ambient/home",
                "ANTHROPIC_API_KEY": "not-a-real-key", "HTTP_PROXY": "not-a-proxy",
                "AWS_SECRET_ACCESS_KEY": "not-a-real-key", "ERL_AFLAGS": "injected",
                "GLEAM": "/caller/tool", "XDG_CONFIG_HOME": "/ambient/config",
            })
            self.assertEqual(env["PATH"], "/usr/bin")
            self.assertEqual(env["ERL_CRASH_DUMP"], os.devnull)
            self.assertFalse(any(name in env for name in (
                "ANTHROPIC_API_KEY", "HTTP_PROXY", "AWS_SECRET_ACCESS_KEY", "ERL_AFLAGS",
                "GLEAM",
            )))
            for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "TMPDIR"):
                path = Path(env[name])
                self.assertTrue(path.is_relative_to(directory))
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)

    def test_private_file_is_0600_at_creation_without_overwriting(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "private"
            original = os.umask(0)
            try:
                SMOKE["private_file"](path, "synthetic")
            finally:
                os.umask(original)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                SMOKE["private_file"](path, "replacement")
            self.assertEqual(path.read_text(), "synthetic")

    def test_output_guard_rejects_every_private_fixture_value(self):
        guard = SMOKE["OutputGuard"]()
        for secret in SMOKE["SECRETS"]:
            with self.assertRaisesRegex(Failure, "private value leaked"):
                guard.check(secret.encode(), "unit")
        guard.check(b"credential configured: selected (oauth)\n", "unit")

    def test_os_diagnostic_contains_errno_but_not_private_message_or_path(self):
        error = OSError(errno.EMFILE, SMOKE["PRIVATE_ERROR"], SMOKE["ACCESS"])
        diagnostic = SMOKE["safe_error"](error)
        self.assertIn("errno=24(EMFILE)", diagnostic)
        SMOKE["OutputGuard"]().check(diagnostic.encode(), "OS diagnostic")

    def test_cleanup_failure_never_masks_primary_case_failure(self):
        class FailedCleanup:
            def __init__(self, *_args):
                self.fixture = SMOKE["Fixture"](SMOKE["OutputGuard"]())
                self.callbacks, self.public_status, self.cleanup_errors, self.processes = [], [], [], []
                self.login_exit, self.failure_phase, self.phase = -1, None, "unit primary"

            def close(self):
                raise OSError(errno.EMFILE, SMOKE["PRIVATE_ERROR"], SMOKE["ACCESS"])

        def primary(_flow):
            raise Failure("deliberate primary failure")

        run_case = SMOKE["run_case"]
        # Mock only the new harness's reporting boundary, never a production
        # transport/module or an existing smoke helper. This is not root evidence.
        with patch.dict(run_case.__globals__, {
            "Workflow": FailedCleanup, "CASES": {"unit": primary},
        }):
            result = run_case(Path("."), "unit", [], False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["failure"], "deliberate primary failure")
        self.assertIn("errno=24(EMFILE)", result["cleanup_error"])
        SMOKE["OutputGuard"]().check(json.dumps(result).encode(), "failed case diagnostic")

    def test_verifier_fingerprint_detects_leaks_without_retaining_verifier(self):
        guard = SMOKE["OutputGuard"]()
        verifier = "synthetic-unpersisted-pkce-verifier-" + "z" * 32
        guard.remember_verifier(verifier)
        self.assertNotIn(verifier, repr(vars(guard)))
        with self.assertRaisesRegex(Failure, "PKCE verifier leaked"):
            guard.check(("verifier=" + verifier + "\n").encode(), "unit")

    def test_partial_announcement_has_a_real_deadline_and_child_is_reaped(self):
        with tempfile.TemporaryDirectory() as temporary:
            env = SMOKE["child_environment"](Path(temporary), os.environ)
            process = subprocess.Popen(
                [sys.executable, "-c", "import sys,time; sys.stdout.write('partial'); "
                 "sys.stdout.flush(); time.sleep(20)"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                began = time.monotonic()
                with self.assertRaisesRegex(Failure, "deadline"):
                    SMOKE["read_line_bounded"](process.stdout, seconds=0.1)
                self.assertLess(time.monotonic() - began, 2)
            finally:
                SMOKE["terminate"](process)
            self.assertIsNotNone(process.poll())

    def test_raw_media_fixture_is_exact_utf8_and_legal_ows_is_distinct(self):
        media_cases = (
            ("nbsp", b"\xc2\xa0application/json"),
            ("vt", b"\x0bapplication/json"),
            ("lrm", b"\xe2\x80\x8eapplication/json"),
            ("space", b" application/json"),
            ("htab", b"\tapplication/json"),
        )
        for name, media in media_cases:
            with self.subTest(media=name), fixture_server("roles") as (server, fixture):
                fixture.media["roles"] = media
                with socket.create_connection(("127.0.0.1", server.server_port), timeout=2) as sock:
                    sock.sendall((
                        f"GET /operator/roles HTTP/1.1\r\nHost: 127.0.0.1:{server.server_port}\r\n"
                        f"Authorization: Bearer {SMOKE['ACCESS']}\r\nAccept: application/json\r\n"
                        "Content-Type: application/json\r\nCache-Control: no-cache\r\n"
                        "Accept-Encoding: identity\r\nConnection: close\r\n\r\n"
                    ).encode())
                    # Inspect headers only; do not capture the private roles body.
                    headers = bytearray()
                    while not headers.endswith(b"\r\n\r\n"):
                        byte = sock.recv(1)
                        self.assertTrue(byte)
                        headers.extend(byte)
                        self.assertLess(len(headers), 4096)
                    self.assertIn(b"Content-Type: " + media + b"\r\n", headers)
                fixture.check()
                SMOKE["OutputGuard"]().check(json.dumps(fixture.snapshot()).encode(), "journal")

    def test_token_observations_do_not_retain_post_body_headers_or_verifier(self):
        verifier = "synthetic-test-private-verifier-" + "q" * 32
        challenge = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()
        ).decode().rstrip("=")
        with fixture_server("api") as (server, fixture):
            fixture.exchange = {
                "state": "synthetic-state", "redirect_uri": "http://127.0.0.1:1/callback",
                "code_challenge": challenge,
            }
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
            try:
                connection.request("POST", "/oauth/token", json.dumps({
                    "grant_type": "authorization_code", "code": SMOKE["CODE"],
                    "client_id": "synthetic-client", "code_verifier": verifier,
                    "state": fixture.exchange["state"],
                    "redirect_uri": fixture.exchange["redirect_uri"],
                }), {"Content-Type": "application/json"})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                # Drain without retaining or inspecting the synthetic token body.
                response.read()
            finally:
                connection.close()
            fixture.check()
            journal = json.dumps(fixture.snapshot()).encode()
            fixture.guard.check(journal, "journal")
            self.assertNotIn(verifier.encode(), journal)
            event = fixture.snapshot()[0]
            self.assertTrue(all(isinstance(value, (str, int, bool)) for value in event.values()))
            self.assertTrue(event["pkce_ok"] and event["exchange_ok"])
            with self.assertRaises(Failure):
                fixture.record("token", "POST", "/oauth/token", unsafe="private")

    def test_callback_disconnect_is_recorded_without_resending_the_grant(self):
        class EOFCallback(SMOKE["Handler"]):
            def do_GET(self):
                self.server.fixture.record("callback", "GET", "/callback", received_ok=True)
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()

        with fixture_server("callback", EOFCallback) as (server, fixture):
            flow = SMOKE["Workflow"].__new__(SMOKE["Workflow"])
            flow.callback_port, flow.guard, flow.callbacks = server.server_port, fixture.guard, []
            status = flow.callback("/callback", [("state", "synthetic"), ("code", SMOKE["CODE"])],
                                   valid=True)
            self.assertEqual(status, 0)
            self.assertEqual(len(fixture.snapshot()), 1)
            self.assertEqual(flow.callbacks, [{
                "counter": 1, "path": "/callback", "method": "GET", "valid": True,
                "status": 0, "response_length": 0, "disconnected": True,
            }])
            fixture.guard.check(json.dumps(flow.callbacks).encode(), "callback journal")

    def test_failure_cleanup_releases_held_request_and_closes_server(self):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            with self.assertRaisesRegex(Failure, "deliberate"):
                with fixture_server("profile") as (server, fixture):
                    port = server.server_port
                    fixture.hold("profile")
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                    try:
                        connection.request("GET", "/operator/profile", headers={
                            "Authorization": f"Bearer {SMOKE['ACCESS']}",
                        })
                        self.assertTrue(fixture.entered.wait(2))
                        raise Failure("deliberate safe harness failure")
                    finally:
                        connection.close()
        with socket.socket() as probe:
            probe.settimeout(1)
            self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0)
        self.assertTrue(fixture.release.is_set())
        self.assertEqual(output.getvalue() + errors.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
