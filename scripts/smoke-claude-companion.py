#!/usr/bin/env python3
"""F08 root CLI smoke: synthetic loopback OAuth -> companion -> stored Messages.

Usage: GLEAM=/path/to/gleam python3 scripts/smoke-claude-companion.py
       python3 scripts/smoke-claude-companion.py --shipment build/erlang-shipment
       ... --case profile-nbsp

GLEAM is one executable argv element, not a shell command. Build/export first
when necessary. No browser, injected provider transport, ambient credentials,
live upstream, or raw credential-store inspection. Fixture observations contain
only paths, counters and booleans. Profile and roles use distinct approved origins.
The Workflow/login_checks pattern comes from smoke-http-providers.py; its port
helper and smoke-gateway.py's SIGTERM/owner-guard check are reused unchanged.
"""

import argparse
import base64
import contextlib
import errno
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import runpy
import select
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlencode, urlsplit


ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
BASE = HTTP["BASE"]
AVAILABLE_PORT = HTTP["available_port"]
CLIENT = BASE["CLIENT_KEY"]
MODEL = BASE["MODEL"]
ACCOUNT_ID = "selected"
ACCESS = "synthetic-companion-access"
REFRESH = "synthetic-companion-refresh"
OLD_ACCESS = "synthetic-companion-old-access"
OLD_REFRESH = "synthetic-companion-old-refresh"
ROTATED = "synthetic-companion-rotated-access"
ROTATED_REFRESH = "synthetic-companion-rotated-refresh"
ACCOUNT = "synthetic-companion-account"
ORG = "synthetic-companion-organization"
OTHER_ACCOUNT = "synthetic-companion-conflicting-account"
OTHER_ORG = "synthetic-companion-conflicting-organization"
OLD_ACCOUNT = "synthetic-companion-prior-account"
DEVICE = "a" * 64
OLD_DEVICE = "b" * 64
CODE = "synthetic-companion-callback-code"
PRIVATE_ERROR = "synthetic-companion-private-error"
PRIVATE_ROLES = "synthetic-companion-private-roles"
SECRETS = (
    CLIENT, ACCESS, REFRESH, OLD_ACCESS, OLD_REFRESH, ROTATED, ROTATED_REFRESH,
    ACCOUNT, ORG, OTHER_ACCOUNT, OTHER_ORG, OLD_ACCOUNT, DEVICE, OLD_DEVICE,
    CODE, PRIVATE_ERROR, PRIVATE_ROLES,
)
SOCKET_TIMEOUT = 5
CLI_TIMEOUT = 60
LOGIN_TIMEOUT = 30
HOLD_TIMEOUT = 30
JSON_MEDIA = b"application/json"
NBSP_MEDIA = b"\xc2\xa0application/json"
VT_MEDIA = b"\x0bapplication/json"
LRM_MEDIA = b"\xe2\x80\x8eapplication/json"


class SmokeFailure(Exception):
    """Messages must be safe diagnostics, never request/response contents."""


def require(condition, message):
    if not condition:
        raise SmokeFailure(message)


def safe_error(error):
    if isinstance(error, (SmokeFailure, AssertionError)):
        return str(error)
    code = getattr(error, "errno", None)
    return (f"harness {type(error).__name__}"
            + (f" errno={code}({errno.errorcode.get(code, 'UNKNOWN')})" if code is not None else "")
            + " (private details suppressed)")


class OutputGuard:
    def __init__(self):
        self.verifier_hashes = set()
        self.lock = threading.Lock()

    def remember_verifier(self, verifier):
        # Keep only a fingerprint, not the private verifier or token POST body.
        with self.lock:
            self.verifier_hashes.add(hashlib.sha256(verifier.encode()).digest())

    def check(self, output, where):
        require(not any(secret.encode() in output for secret in SECRETS),
                f"synthetic private value leaked in {where}")
        with self.lock:
            fingerprints = set(self.verifier_hashes)
        words = re.findall(rb"[A-Za-z0-9_~.-]{32,}", output)
        require(not any(hashlib.sha256(word).digest() in fingerprints for word in words),
                f"PKCE verifier leaked in {where}")


def private_file(path, value):
    # Private at creation, unlike write_text followed by chmod under a loose umask.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(value.encode() if isinstance(value, str) else value)
    return str(path)


def command_for(shipment, environ):
    if shipment is not None:
        entrypoint = shipment.resolve() / "entrypoint.sh"
        require(entrypoint.is_file(), "shipment entrypoint.sh is missing")
        # Gleam's exported script has no shebang. No implicit shell fallback.
        return ["sh", str(entrypoint), "run"]
    executable = environ.get("GLEAM", "gleam")
    require(bool(executable), "GLEAM must name an executable")
    return [executable, "run", "--"]


def child_environment(directory, environ):
    # Do not pass provider keys, proxies, Erlang injection flags or real HOME.
    allowed = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "SYSTEMROOT", "WINDIR")
    env = {name: environ[name] for name in allowed if name in environ}
    for name, relative in (
        ("HOME", "home"), ("XDG_CONFIG_HOME", "home/config"),
        ("XDG_DATA_HOME", "home/data"), ("XDG_CACHE_HOME", "home/cache"),
        ("TMPDIR", "tmp"),
    ):
        path = directory / relative
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        env[name] = str(path)
    env["TMP"] = env["TEMP"] = env["TMPDIR"]
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    # A VM crash dump could contain its private heap; never persist one.
    env["ERL_CRASH_DUMP"] = os.devnull
    return env


def read_line_bounded(stream, seconds=CLI_TIMEOUT, limit=16384):
    deadline = time.monotonic() + seconds
    line = bytearray()
    while len(line) <= limit:
        remaining = deadline - time.monotonic()
        require(remaining > 0 and bool(select.select([stream], [], [], remaining)[0]),
                "root login announcement deadline exceeded")
        byte = os.read(stream.fileno(), 1)
        require(bool(byte), "root login exited without an announcement")
        line.extend(byte)
        if byte == b"\n":
            require(len(line) <= limit, "root login announcement exceeded bound")
            return bytes(line)
    raise SmokeFailure("root login announcement exceeded bound")


def identity_fields(account=None, organization=None):
    value = {}
    if account is not None:
        value["account"] = {"uuid": account}
    if organization is not None:
        value["organization"] = {"uuid": organization}
    return value


class Fixture:
    """Shared safe journal; private values exist only in synthetic request handling."""

    def __init__(self, guard):
        self.guard = guard
        self.events = []
        self.errors = []
        self.lock = threading.Lock()
        self.token_identity = identity_fields(organization=ORG)
        self.profile_identity = identity_fields(ACCOUNT, ORG)
        self.profile_status = self.roles_status = 200
        self.media = {name: JSON_MEDIA for name in ("token", "profile", "roles")}
        self.login_access, self.login_refresh = ACCESS, REFRESH
        self.expires_in = 3600
        self.expected_refresh = REFRESH
        self.expected_message = (ACCESS, ACCOUNT, DEVICE)
        self.exchange = None
        self.held = None
        self.entered = threading.Event()
        self.release = threading.Event()
        self.release.set()

    def record(self, endpoint, method, path, **checks):
        require(all(isinstance(value, bool) for value in checks.values()),
                "fixture attempted to retain unsafe observations")
        with self.lock:
            self.events.append({
                "counter": len(self.events) + 1, "endpoint": endpoint,
                "method": method, "path": path, **checks,
            })

    def fail(self, message):
        with self.lock:
            self.errors.append(message)

    def snapshot(self):
        with self.lock:
            return [dict(event) for event in self.events]

    def check(self):
        with self.lock:
            errors = list(self.errors)
        require(not errors, "synthetic fixture failed: " + ", ".join(errors))
        for event in self.snapshot():
            require(all(value for value in event.values() if isinstance(value, bool)),
                    f"wire check failed at {event['endpoint']} #{event['counter']}")

    def hold(self, endpoint):
        self.held = endpoint
        self.entered.clear()
        self.release.clear()

    def wait_if_held(self, endpoint):
        if self.held == endpoint:
            self.entered.set()
            if not self.release.wait(HOLD_TIMEOUT):
                self.fail("companion gate timeout")
                return False
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(SOCKET_TIMEOUT)

    def log_message(self, *_args):
        pass

    def reply(self, status, value, media=JSON_MEDIA):
        raw = json.dumps(value, ensure_ascii=False).encode()
        # send_header encodes Latin-1: use controlled bytes so NBSP is C2 A0,
        # not invalid UTF-8 A0. The remaining framing/body is identical.
        headers = (
            f"HTTP/1.1 {status} Synthetic\r\n".encode()
            + b"Content-Type: " + media + b"\r\n"
            + f"Content-Length: {len(raw)}\r\n".encode()
            + b"Connection: close\r\n\r\n"
        )
        self.close_connection = True
        self.wfile.write(headers + raw)
        self.wfile.flush()

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def dispatch(self, method):
        try:
            self.handle_fixture(method)
        except (OSError, ValueError, KeyError, TypeError, SmokeFailure):
            # Never let http.server print a traceback containing request data.
            self.server.fixture.fail("request handling failure")
            self.close_connection = True

    def handle_fixture(self, method):
        fixture = self.server.fixture
        role = self.server.role
        expected_host = f"127.0.0.1:{self.server.server_port}"
        host_ok = self.headers.get("Host") == expected_host
        clean = self.headers.get("x-api-key") is None and self.headers.get("Cookie") is None
        if role == "api" and method == "POST" and self.path == "/oauth/token":
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length <= 32768, "invalid synthetic token request length")
            body = json.loads(self.rfile.read(length))
            common = {
                "origin_ok": host_ok,
                "headers_ok": clean and self.headers.get("Authorization") is None,
                "json_ok": self.headers.get_content_type() == "application/json",
                "client_ok": body.get("client_id") == "synthetic-client",
            }
            if body.get("grant_type") == "authorization_code":
                verifier = body.get("code_verifier", "")
                fixture.guard.remember_verifier(verifier)
                challenge = base64.urlsafe_b64encode(
                    hashlib.sha256(verifier.encode()).digest()
                ).decode().rstrip("=")
                expected = fixture.exchange or {}
                fixture.record("token", method, self.path, **common,
                               exchange_ok=body.get("code") == CODE
                               and body.get("state") == expected.get("state")
                               and body.get("redirect_uri") == expected.get("redirect_uri"),
                               pkce_ok=bool(verifier)
                               and challenge == expected.get("code_challenge"))
                payload = {
                    "access_token": fixture.login_access,
                    "refresh_token": fixture.login_refresh,
                    "expires_in": fixture.expires_in, **fixture.token_identity,
                }
            else:
                fixture.record("refresh", method, self.path, **common,
                               refresh_ok=body.get("grant_type") == "refresh_token"
                               and body.get("refresh_token") == fixture.expected_refresh)
                payload = {"access_token": ROTATED, "refresh_token": ROTATED_REFRESH,
                           "expires_in": 3600}
            self.reply(200, payload, fixture.media["token"])
            return
        if role in ("profile", "roles") and method == "GET" and self.path == f"/operator/{role}":
            fixture.record(
                role, method, self.path, origin_ok=host_ok,
                bearer_ok=self.headers.get("Authorization") == f"Bearer {fixture.login_access}",
                headers_ok=clean and self.headers.get("Accept") == "application/json"
                and self.headers.get("Content-Type") == "application/json"
                and self.headers.get("Cache-Control") == "no-cache"
                and self.headers.get("Accept-Encoding") == "identity",
                empty_body_ok=self.headers.get("Content-Length") in (None, "0")
                and self.headers.get("Transfer-Encoding") is None,
            )
            if not fixture.wait_if_held(role):
                self.reply(503, {"error": PRIVATE_ERROR})
                return
            status = getattr(fixture, f"{role}_status")
            payload = (fixture.profile_identity if role == "profile" else {
                "roles": [PRIVATE_ROLES], **identity_fields(OTHER_ACCOUNT, OTHER_ORG),
            })
            self.reply(status, payload if status == 200 else {"error": PRIVATE_ERROR},
                       fixture.media[role])
            return
        if role == "api" and method == "POST" and self.path == "/v1/messages?beta=true":
            length = int(self.headers.get("Content-Length", "0"))
            require(0 < length <= 65536, "invalid synthetic Messages request length")
            body = json.loads(self.rfile.read(length))
            observed = json.loads(body.get("metadata", {}).get("user_id", "{}"))
            access, account, device = fixture.expected_message
            fixture.record(
                "message", method, self.path, origin_ok=host_ok, headers_ok=clean,
                bearer_ok=self.headers.get("Authorization") == f"Bearer {access}",
                identity_ok=observed.get("account_uuid") == account
                and observed.get("device_id") == device,
                session_ok=isinstance(observed.get("session_id"), str)
                and bool(observed.get("session_id")),
                model_ok=body.get("model") == MODEL,
            )
            self.reply(200, {
                "id": "msg_synthetic_companion", "type": "message", "role": "assistant",
                "model": MODEL, "content": [{"type": "text", "text": "synthetic reply"}],
                "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 3, "output_tokens": 2},
            })
            return
        # Do not retain an unexpected target that might itself contain a secret.
        fixture.record("unexpected", method, "/unexpected", approved_endpoint_ok=False)
        self.reply(404, {"error": "synthetic unexpected endpoint"})


class Server(ThreadingHTTPServer):
    # Join request handlers on close. Socket reads have a 5s deadline and every
    # held request is released before close, so failures leave no fixture threads.
    daemon_threads = False

    def handle_error(self, _request, _client_address):
        self.fixture.fail("HTTP server failure")


def terminate(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        return process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        return process.communicate(timeout=5)


class Workflow:
    def __init__(self, directory, command, shipment):
        self.directory, self.command = directory, command
        self.cwd = directory if shipment else ROOT
        self.guard = OutputGuard()
        self.fixture = Fixture(self.guard)
        self.cleanup = contextlib.ExitStack()
        self.processes = []
        self.logs = []
        self.callbacks = []
        self.valid_callback_failed = False
        self.login_exit = -1
        self.public_status = []
        self.phase = "setup"
        self.failure_phase = None
        self.cleanup_errors = []
        self.env = child_environment(directory, os.environ)
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        self.port, self.callback_port = AVAILABLE_PORT(), AVAILABLE_PORT()
        self.redirect = f"http://127.0.0.1:{self.callback_port}/callback"
        self.origins = {}
        try:
            for role in ("api", "profile", "roles"):
                server = Server(("127.0.0.1", 0), Handler)
                server.fixture, server.role = self.fixture, role
                worker = threading.Thread(target=server.serve_forever,
                                          kwargs={"poll_interval": 0.05}, daemon=True)
                worker.start()
                self.cleanup.callback(self.close_server, server, worker)
                self.origins[role] = f"http://127.0.0.1:{server.server_port}"
            require(len(set(self.origins.values())) == 3, "fixture origins are not distinct")
            self.config = directory / "providers.json"
            self.settings = {
                "version": 1, "state_dir": str(self.state), "listen_port": self.port,
                "accounts": [{
                    "provider": "claude", "auth_mode": "oauth", "id": ACCOUNT_ID,
                    "origin": self.origins["api"], "models": [MODEL],
                    "oauth": {
                        "client_id": "synthetic-client",
                        "authorize_url": self.origins["api"] + "/authorize",
                        "token_url": self.origins["api"] + "/oauth/token",
                        "redirect_uri": self.redirect,
                        "companion": {
                            "profile_url": self.origins["profile"] + "/operator/profile",
                            "roles_url": self.origins["roles"] + "/operator/roles",
                            "approved": True,
                        },
                    },
                }],
            }
            self.write_config()
            key = private_file(directory / "client-key", CLIENT)
            self.cli("key", "import", str(self.config), "client", key)
        except BaseException as primary:
            try:
                self.close()
            except (SmokeFailure, AssertionError, OSError, subprocess.TimeoutExpired):
                primary.cleanup_errors = list(self.cleanup_errors)
            raise

    @staticmethod
    def close_server(server, worker):
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        require(not worker.is_alive(), "fixture server did not stop")

    def write_config(self):
        if self.config.exists():
            self.config.write_text(json.dumps(self.settings))
        else:
            private_file(self.config, json.dumps(self.settings))

    def spawn(self, arguments, **kwargs):
        process = subprocess.Popen([*self.command, *arguments], cwd=self.cwd,
                                   env=self.env, start_new_session=True, **kwargs)
        self.processes.append(process)
        return process

    def finish(self, process, timeout, label):
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            stdout, stderr = terminate(process)
            self.guard.check((stdout or b"") + (stderr or b""), label)
            raise SmokeFailure(f"{label} exceeded {timeout}s deadline") from None
        self.guard.check((stdout or b"") + (stderr or b""), label)
        return stdout or b"", stderr or b""

    def expect_exit(self, process, expected, label, output):
        if process.returncode != expected:
            # Only a public root diagnostic after scanning; never dump stdout/URL.
            lines = output.decode(errors="replace").splitlines()
            error = next((line for line in lines if line.startswith("mimic: ")), "")
            raise SmokeFailure(f"{label} exited {process.returncode}, expected {expected}"
                               + (f"; {error}" if error else ""))

    def cli(self, *arguments, expected=0):
        self.phase = "CLI " + " ".join(arguments[:2])
        process = self.spawn(["providers", *arguments],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = self.finish(process, CLI_TIMEOUT, "root CLI " + " ".join(arguments[:2]))
        self.expect_exit(process, expected, "root CLI " + " ".join(arguments[:2]), stdout + stderr)
        return stdout + stderr

    def seed(self, expired=False, same=False):
        path = self.directory / "prior-grant"
        if not same:
            private_file(path, json.dumps({
                "access_token": OLD_ACCESS, "refresh_token": OLD_REFRESH,
                "expires_at_ms": 1 if expired else int(time.time() * 1000) + 3600000,
                "device_id": OLD_DEVICE, "account_uuid": OLD_ACCOUNT,
                "organization_uuid": ORG,
            }))
        self.cli("credential", "import", str(self.config), ACCOUNT_ID, str(path))

    def status(self, present):
        output = self.cli("credential", "status", str(self.config), ACCOUNT_ID,
                          expected=0 if present else 1)
        metadata_ok = f"credential configured: {ACCOUNT_ID} (oauth)".encode() in output
        self.public_status.append({"expected_present": present, "oauth_metadata_ok": metadata_ok})
        if present:
            require(metadata_ok, "public credential metadata did not report OAuth")

    def callback(self, path, pairs, valid=False):
        self.phase = "callback request"
        connection = http.client.HTTPConnection("127.0.0.1", self.callback_port,
                                                timeout=SOCKET_TIMEOUT)
        observed = {"counter": len(self.callbacks) + 1, "path": path, "method": "GET",
                    "valid": valid, "status": 0, "response_length": 0, "disconnected": False}
        try:
            connection.request("GET", path + "?" + urlencode(pairs))
            self.phase = "callback response"
            response = connection.getresponse()
            raw = response.read(65537)
            require(len(raw) <= 65536, "callback response exceeded fixture bound")
            self.guard.check(raw, "callback response")
            observed.update(status=response.status, response_length=len(raw))
            return response.status
        except (http.client.RemoteDisconnected, ConnectionResetError):
            observed["disconnected"] = True
            return 0
        finally:
            connection.close()
            self.callbacks.append(observed)

    @contextlib.contextmanager
    def login(self, operator, invalid_callbacks=False):
        self.phase = "login private identity"
        identity = private_file(self.directory / "operator-identity", json.dumps(operator))
        self.phase = "login spawn"
        process = self.spawn(["providers", "credential", "login", str(self.config),
                              ACCOUNT_ID, identity],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        primary_failed = False
        try:
            self.phase = "login announcement"
            announced = read_line_bounded(process.stdout)
            self.guard.check(announced, "login announcement")
            parsed = urlsplit(announced.decode().strip())
            require(parsed.scheme + "://" + parsed.netloc == self.origins["api"]
                    and parsed.path == "/authorize", "login announced an unconfigured origin")
            query = parse_qs(parsed.query, strict_parsing=True)
            require(all(len(values) == 1 for values in query.values()),
                    "ambiguous login announcement")
            require(query.get("redirect_uri") == [self.redirect]
                    and query.get("client_id") == ["synthetic-client"]
                    and query.get("code_challenge_method") == ["S256"]
                    and query.get("code") == ["true"], "invalid configured PKCE announcement")
            self.fixture.exchange = {name: query[name][0] for name in (
                "state", "redirect_uri", "code_challenge",
            )}
            state = query["state"][0]
            if invalid_callbacks:
                for path, pairs in (
                    ("/wrong", [("state", state), ("code", CODE)]),
                    ("/callback", [("state", "wrong"), ("code", CODE)]),
                    ("/callback", [("state", state), ("state", "duplicate"), ("code", CODE)]),
                ):
                    require(self.callback(path, pairs) == 400, "invalid callback was accepted")
                    require(not self.fixture.snapshot(), "provider I/O before valid callback")
            status = self.callback("/callback", [("state", state), ("code", CODE)], valid=True)
            # A lost HTTP response does not prove the callback was unconsumed.
            # Never resend it. Wait for this root process's outcome once and run
            # the grant checks, but keep required HTTP 200 as a separate FAILURE.
            self.valid_callback_failed = status != 200
            yield process
        except BaseException:
            primary_failed = True
            self.failure_phase = self.phase
            raise
        finally:
            try:
                stdout, stderr = terminate(process)
                self.guard.check((stdout or b"") + (stderr or b""), "login teardown")
                self.fixture.exchange = None
                with socket.socket() as probe:
                    probe.settimeout(1)
                    require(probe.connect_ex(("127.0.0.1", self.callback_port)) != 0,
                            "login left callback listener open")
            except (SmokeFailure, AssertionError, OSError, subprocess.TimeoutExpired) as error:
                self.cleanup_errors.append("login cleanup: " + safe_error(error))
                if not primary_failed:
                    raise SmokeFailure(self.cleanup_errors[-1]) from None

    def complete_login(self, process, expected):
        self.phase = "login root outcome"
        stdout, stderr = self.finish(process, LOGIN_TIMEOUT, "root credential login")
        self.login_exit = process.returncode
        self.expect_exit(process, expected, "root credential login", stdout + stderr)
        if expected == 0:
            require(b"credential stored" in stdout, "root did not acknowledge stored credential")

    def request(self, method, path, payload=None, authorized=True, timeout=SOCKET_TIMEOUT):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        headers = {"Content-Type": "application/json"}
        if authorized:
            headers["Authorization"] = f"Bearer {CLIENT}"
        try:
            connection.request(method, path, None if payload is None else json.dumps(payload),
                               headers)
            response = connection.getresponse()
            raw = response.read(65537)
            require(len(raw) <= 65536, "gateway response exceeded fixture bound")
            self.guard.check(raw, "gateway response")
            return response.status, raw
        finally:
            connection.close()

    @contextlib.contextmanager
    def running(self):
        self.phase = "gateway spawn"
        path = self.directory / f"gateway-{len(self.logs) + 1}.log"
        self.logs.append(path)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as log:
            process = self.spawn(["serve", "providers", str(self.config)],
                                 stdout=log, stderr=subprocess.STDOUT)
            primary_failed = False
            try:
                self.phase = "gateway readiness"
                deadline = time.monotonic() + CLI_TIMEOUT
                while time.monotonic() < deadline:
                    require(process.poll() is None, "root gateway exited before readiness")
                    try:
                        if self.request("GET", "/v1/models", authorized=False, timeout=1)[0] == 401:
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    time.sleep(0.05)
                else:
                    raise SmokeFailure("root gateway readiness deadline exceeded")
                require((self.state / ".provider-runtime-owner").exists(),
                        "running gateway did not hold runtime owner guard")
                yield
            except BaseException:
                primary_failed = True
                self.failure_phase = self.phase
                raise
            finally:
                # Shared helper sends process-group SIGTERM, bounds shutdown and
                # asserts that the actual runtime owner guard is released.
                errors = []
                try:
                    BASE["stop"](process, self.state)
                except (SmokeFailure, AssertionError, OSError, subprocess.TimeoutExpired) as error:
                    errors.append("gateway shutdown: " + safe_error(error))
                try:
                    self.guard.check(path.read_bytes(), "gateway log")
                except (SmokeFailure, OSError) as error:
                    errors.append("gateway log: " + safe_error(error))
                self.cleanup_errors.extend(errors)
                if errors and not primary_failed:
                    raise SmokeFailure(errors[0]) from None

    def messages(self, present, expected=(ACCESS, ACCOUNT, DEVICE), restart=False):
        self.status(present)
        self.fixture.expected_message = expected
        payload = {"model": MODEL, "max_tokens": 16,
                   "messages": [{"role": "user", "content": "synthetic hello"}]}
        for _ in range(2 if restart else 1):
            before = len(self.fixture.snapshot())
            with self.running():
                self.phase = "gateway Messages"
                status, raw = self.request("POST", "/v1/messages", payload)
                require(status == (200 if present else 503),
                        f"gateway Messages returned {status}, expected {200 if present else 503}")
                if present:
                    require(json.loads(raw).get("content") == [
                        {"type": "text", "text": "synthetic reply"}],
                        "gateway did not deliver synthetic Messages reply")
                else:
                    require(len(self.fixture.snapshot()) == before,
                            "gateway contacted provider without a usable grant")
            self.fixture.check()

    def check_permissions(self):
        for root, directories, files in os.walk(self.directory):
            require(not Path(root).is_symlink()
                    and stat.S_IMODE(Path(root).stat().st_mode) == 0o700,
                    "synthetic runtime directory is not 0700")
            require(not any((Path(root) / name).is_symlink() for name in directories),
                    "synthetic runtime contains a symlink directory")
            for name in files:
                path = Path(root) / name
                require(not path.is_symlink()
                        and stat.S_ISREG(path.stat().st_mode)
                        and stat.S_IMODE(path.stat().st_mode) == 0o600,
                        "synthetic runtime file is not a private regular 0600 file")

    def close(self):
        self.fixture.release.set()
        failures = []
        try:
            for process in self.processes:
                try:
                    stdout, stderr = terminate(process)
                    self.guard.check((stdout or b"") + (stderr or b""), "subprocess teardown")
                except (OSError, subprocess.TimeoutExpired, SmokeFailure) as error:
                    failures.append(error)
            for path in self.logs:
                try:
                    self.guard.check(path.read_bytes(), "gateway log")
                except (OSError, SmokeFailure) as error:
                    failures.append(error)
            try:
                self.check_permissions()
            except (OSError, SmokeFailure) as error:
                failures.append(error)
        finally:
            try:
                self.cleanup.close()
            except (SmokeFailure, AssertionError, OSError) as error:
                failures.append(error)
        self.cleanup_errors.extend("workflow cleanup: " + safe_error(error) for error in failures)
        if failures:
            raise SmokeFailure(self.cleanup_errors[-len(failures)]) from None
        require(not self.cleanup_errors, "workflow retained cleanup failures")


def operator(full=False):
    return ({"device_id": DEVICE, "account_uuid": ACCOUNT, "organization_uuid": ORG}
            if full else {"device_id": DEVICE})


def sequence(flow, endpoints):
    events = flow.fixture.snapshot()
    require([event["endpoint"] for event in events] == endpoints,
            "unexpected token/companion request count or ordering")
    flow.fixture.check()


def login_case(flow, identity, succeeds, before_gateway=("token", "profile", "roles"),
               existing=False, restart=False, invalid_callbacks=False):
    if existing:
        flow.seed()
    with flow.login(identity, invalid_callbacks=invalid_callbacks) as process:
        flow.complete_login(process, 0 if succeeds else 1)
    sequence(flow, list(before_gateway))
    flow.messages(succeeds or existing,
                  expected=(ACCESS, ACCOUNT, DEVICE) if succeeds else
                  (OLD_ACCESS, OLD_ACCOUNT, OLD_DEVICE), restart=restart)
    # Usable non-expired grants do not perform refresh or extra companion I/O.
    sequence(flow, list(before_gateway) + ["message"] * (
        (2 if restart else 1) if succeeds or existing else 0))


def reconciliation(flow):
    login_case(flow, operator(), True, restart=True, invalid_callbacks=True)


def advisory(flow, failing):
    flow.fixture.token_identity = {}
    for endpoint in failing:
        setattr(flow.fixture, f"{endpoint}_status", 503)
    # Full operator identity remains usable despite advisory failures; an older
    # valid grant exists but Messages must use the newly persisted login token.
    login_case(flow, operator(full=True), True, existing=True)


def missing_identity(flow, existing):
    flow.fixture.token_identity = {}
    flow.fixture.profile_identity = {}
    # Roles include UUIDs deliberately: opaque roles cannot supply an account.
    login_case(flow, operator(), False, existing=existing)


def conflict(flow, kind):
    identity = operator(full=True)
    if kind == "operator-token":
        flow.fixture.token_identity = identity_fields(OTHER_ACCOUNT, ORG)
    elif kind == "token-profile":
        identity = operator()
        flow.fixture.token_identity = identity_fields(ACCOUNT, ORG)
        flow.fixture.profile_identity = identity_fields(OTHER_ACCOUNT, ORG)
    elif kind == "operator-profile":
        flow.fixture.token_identity = {}
        flow.fixture.profile_identity = identity_fields(OTHER_ACCOUNT, ORG)
    else:
        flow.fixture.profile_identity = identity_fields(ACCOUNT, OTHER_ORG)
    login_case(flow, identity, False, existing=True)


def default_login(flow):
    del flow.settings["accounts"][0]["oauth"]["companion"]
    flow.write_config()
    login_case(flow, operator(full=True), True, before_gateway=("token",))


def approval_rejections(flow):
    companion = flow.settings["accounts"][0]["oauth"]["companion"]
    for index, approval in enumerate(("absent", False, "true", None, 0, [], {})):
        invalid = dict(companion)
        if approval == "absent":
            del invalid["approved"]
        else:
            invalid["approved"] = approval
        settings = json.loads(json.dumps(flow.settings))
        settings["accounts"][0]["oauth"]["companion"] = invalid
        config = private_file(flow.directory / f"unapproved-{index}.json", json.dumps(settings))
        identity = private_file(flow.directory / f"unapproved-identity-{index}",
                                json.dumps(operator(full=True)))
        output = flow.cli("credential", "login", config, ACCOUNT_ID, identity, expected=1)
        require(b"mimic: invalid gateway configuration" in output,
                "approval was not rejected by root config")
        require(flow.origins["api"].encode() not in output,
                "unapproved login announced a URL")
        sequence(flow, [])
    flow.messages(False)


def admin_race(flow, deletion=False, existing=True):
    if existing:
        flow.seed()
    if not deletion:
        # Same access AND refresh tokens as the exact preexisting/admin import.
        # The attempted login changes device/account metadata, making a stale
        # write distinguishable through real Messages without raw store reads.
        flow.fixture.login_access, flow.fixture.login_refresh = OLD_ACCESS, OLD_REFRESH
    flow.fixture.hold("roles" if deletion else "profile")
    with flow.login(operator()) as process:
        try:
            require(flow.fixture.entered.wait(15), "login never reached companion gate")
            require(process.poll() is None, "login exited while companion request was held")
            if deletion:
                flow.cli("credential", "delete", str(flow.config), ACCOUNT_ID)
            else:
                flow.seed(same=True)
        finally:
            flow.fixture.release.set()
        flow.complete_login(process, 1)
    sequence(flow, ["token", "profile", "roles"])
    flow.messages(not deletion, expected=(OLD_ACCESS, OLD_ACCOUNT, OLD_DEVICE))
    sequence(flow, ["token", "profile", "roles"] + ([] if deletion else ["message"]))


def refresh(flow):
    flow.fixture.expires_in = 1
    with flow.login(operator()) as process:
        flow.complete_login(process, 0)
    sequence(flow, ["token", "profile", "roles"])
    # Expire the actual persisted login grant, not a rewritten runtime record.
    time.sleep(1.2)
    flow.messages(True, expected=(ROTATED, ACCOUNT, DEVICE), restart=True)
    sequence(flow, ["token", "profile", "roles", "refresh", "message", "message"])


def media_case(flow, endpoint, media):
    flow.fixture.media[endpoint] = media
    if endpoint == "token":
        login_case(flow, operator(full=True), False, before_gateway=("token",))
    elif endpoint == "profile":
        # No operator/token account: accepting malformed profile media would
        # incorrectly manufacture a usable identity, observable at the root CLI.
        login_case(flow, operator(), False)
    else:
        login_case(flow, operator(), True)


def ows(flow, media):
    flow.fixture.media = {endpoint: media for endpoint in ("token", "profile", "roles")}
    login_case(flow, operator(), True)


CASES = {
    "reconciliation": reconciliation,
    "advisory-profile": lambda flow: advisory(flow, ("profile",)),
    "advisory-roles": lambda flow: advisory(flow, ("roles",)),
    "advisory-both": lambda flow: advisory(flow, ("profile", "roles")),
    "missing-identity": lambda flow: missing_identity(flow, False),
    "missing-identity-existing": lambda flow: missing_identity(flow, True),
    "conflict-operator-token": lambda flow: conflict(flow, "operator-token"),
    "conflict-token-profile": lambda flow: conflict(flow, "token-profile"),
    "conflict-operator-profile": lambda flow: conflict(flow, "operator-profile"),
    "conflict-organization": lambda flow: conflict(flow, "organization"),
    "default-login": default_login,
    "approval-rejections": approval_rejections,
    "admin-same-token": admin_race,
    "admin-delete": lambda flow: admin_race(flow, deletion=True),
    "admin-delete-first-enrollment": lambda flow: admin_race(flow, deletion=True, existing=False),
    "refresh-no-companion": refresh,
    "token-nbsp": lambda flow: media_case(flow, "token", NBSP_MEDIA),
    "profile-nbsp": lambda flow: media_case(flow, "profile", NBSP_MEDIA),
    "roles-nbsp-advisory": lambda flow: media_case(flow, "roles", NBSP_MEDIA),
    "token-vt": lambda flow: media_case(flow, "token", VT_MEDIA),
    "profile-vt": lambda flow: media_case(flow, "profile", VT_MEDIA),
    "roles-vt-advisory": lambda flow: media_case(flow, "roles", VT_MEDIA),
    "token-lrm": lambda flow: media_case(flow, "token", LRM_MEDIA),
    "profile-lrm": lambda flow: media_case(flow, "profile", LRM_MEDIA),
    "roles-lrm-advisory": lambda flow: media_case(flow, "roles", LRM_MEDIA),
    "media-sp-ows": lambda flow: ows(flow, b" application/json"),
    "media-htab-ows": lambda flow: ows(flow, b"\tapplication/json"),
}


def run_case(case_dir, name, command, shipment):
    began = time.monotonic()
    flow = None
    result = {"case": name, "ok": False}
    try:
        flow = Workflow(case_dir, command, shipment)
        CASES[name](flow)
        flow.fixture.check()
        result["checks_ok"] = True
        result["ok"] = not flow.valid_callback_failed
        if flow.valid_callback_failed:
            result["failure"] = "valid callback response was not HTTP 200; not retried"
    except (SmokeFailure, AssertionError, OSError, ValueError, KeyError,
            http.client.HTTPException, subprocess.TimeoutExpired) as error:
        result["failure"] = safe_error(error)
        if getattr(error, "cleanup_errors", None):
            result["cleanup_errors"] = error.cleanup_errors
    finally:
        if flow is not None:
            try:
                flow.close()
            except (SmokeFailure, AssertionError, OSError, subprocess.TimeoutExpired) as error:
                result["ok"], result["cleanup_error"] = False, safe_error(error)
            result["observations"] = flow.fixture.snapshot()
            result["callbacks"] = flow.callbacks
            result["root_login_exit"] = flow.login_exit
            result["public_status"] = flow.public_status
            result["phase"] = flow.failure_phase or flow.phase
            result["child_exits"] = [process.returncode for process in flow.processes]
            if flow.cleanup_errors:
                result["cleanup_errors"] = list(dict.fromkeys(flow.cleanup_errors))
        result["elapsed_ms"] = int((time.monotonic() - began) * 1000)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path, help="exported root CLI; otherwise use GLEAM")
    parser.add_argument("--case", choices=tuple(CASES), action="append",
                        help="run a focused reproduction (repeatable); default: all")
    args = parser.parse_args(argv)
    command = command_for(args.shipment, os.environ)
    results = []
    names = list(args.case or CASES)
    integration = ROOT / "build/integration"
    integration.mkdir(parents=True, exist_ok=True)
    workspace_error = None
    try:
        with tempfile.TemporaryDirectory(prefix="claude-companion-", dir=integration) as temporary:
            directory = Path(temporary)
            directory.chmod(0o700)
            for index, name in enumerate(names):
                case_dir = directory / f"{index:02d}-{name}"
                case_dir.mkdir(mode=0o700)
                result = run_case(case_dir, name, command, args.shipment)
                results.append(result)
                # stdout remains one JSON result; never print CLI contents.
                print(f"F08 {index + 1}/{len(names)} {name}: "
                      + ("PASS" if result["ok"] else "FAIL"), file=sys.stderr, flush=True)
    except OSError as error:
        # Keep completed/failed case evidence even if workspace cleanup fails.
        workspace_error = safe_error(error)
    summary = {
        "scope": "root_claude_companion_f08", "synthetic": True,
        "shipment": bool(args.shipment), "live_provider": False,
        "requested_case_count": len(names),
        "case_count": len(results), "passed": sum(result["ok"] for result in results),
        "checks_completed": sum(result.get("checks_ok", False) for result in results),
        "cases": results,
        "limits": [
            "opaque roles media acceptance/discard is not observable through public CLI",
            "no live provider, TLS fidelity, browser, native client or CPA validation",
        ],
    }
    if workspace_error:
        summary["workspace_error"] = workspace_error
    encoded = json.dumps(summary, sort_keys=True).encode()
    OutputGuard().check(encoded, "harness summary")
    print(encoded.decode())
    return 0 if (not workspace_error and len(results) == len(names)
                 and all(result["ok"] for result in results)) else 1


if __name__ == "__main__":
    # Python finally blocks tear down children/fixtures if the harness is stopped.
    def interrupted(_signum, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if hasattr(signal, "SIGHUP"):
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, interrupted)
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130) from None
    except (SmokeFailure, OSError) as error:
        # No traceback/source excerpt, raw CLI output or credential value.
        print(json.dumps({"scope": "root_claude_companion_f08", "ok": False,
                          "failure": safe_error(error)}))
        raise SystemExit(1) from None
