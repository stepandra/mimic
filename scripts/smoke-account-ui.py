#!/usr/bin/env python3
"""F05 actual local Mist/CLI smoke. Every account/secret/upstream is synthetic.

Default UI uses its independent module main, NOT an unadmitted root dispatch.
--root-ui is the separate post-admission root CLI gate. --browser-fixture holds
the same real local fixture for independent browser QA; no provider/CPA access.
"""

import argparse
import base64
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs


ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "synthetic-kimi"
DEVICE = "synthetic-private-kimi-device"
DEVICE_CODE = "synthetic-private-device-code"
ACCESS = "synthetic-private-access"
REFRESH = "synthetic-private-refresh"
ROTATED_ACCESS = "synthetic-private-rotated-access"
ROTATED_REFRESH = "synthetic-private-rotated-refresh"
ADMIN_ACCESS = "synthetic-private-admin-access"
ADMIN_REFRESH = "synthetic-private-admin-refresh"
CLIENT = "synthetic-private-client-key-account-ui-0001"
SECRETS = [DEVICE, DEVICE_CODE, ACCESS, REFRESH, ROTATED_ACCESS,
           ROTATED_REFRESH, ADMIN_ACCESS, ADMIN_REFRESH, CLIENT]
DEFAULT_ROOT = "mise exec gleam@1.18.1 -- gleam run --"
DEFAULT_UI = "mise exec gleam@1.18.1 -- gleam run -m mimic/account_ui --"


def clean(raw):
    for secret in SECRETS:
        assert secret.encode() not in raw, "secret escaped into public output"


def private(path, value):
    path.write_text(value)
    path.chmod(0o600)
    return str(path)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait(predicate, seconds=20, label="condition"):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(f"deadline exceeded: {label}")


class Provider(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, state, slot):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.state = state
        self.slot = slot
        self.mode = "authorize"
        self.started = threading.Event()
        self.polled = threading.Event()
        self.release = threading.Event()
        self.counts = {"start": 0, "poll": 0, "refresh": 0, "chat": 0}
        self.reservation_before_io = True
        self.identity_ok = True
        self.auth_ok = True

    def phase(self, mode):
        self.mode = mode
        self.started.clear()
        self.polled.clear()
        self.release.clear()


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass  # Expected when the actual network worker is cancelled.

    def do_GET(self):
        # Optional browser QA only, on the explicit synthetic verification URL.
        if self.path == "/verify":
            self.reply(200, {"synthetic": True, "instructions": "Return to MIMIC. No live OAuth."})
        else:
            self.reply(404, {"error": "synthetic fixture only"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.identity_ok &= self.headers.get("X-Msh-Device-Id") == DEVICE
        if self.path == "/api/oauth/device_authorization":
            self.server.counts["start"] += 1
            slot = self.server.slot
            self.server.reservation_before_io &= slot.exists()
            if slot.exists():
                self.server.reservation_before_io &= json.loads(slot.read_text())["kind"] in (
                    "enrollment_pending", "oauth")
            self.server.started.set()
            mode = self.server.mode
            if mode == "blocked-start":
                self.server.release.wait(30)
            self.reply(200, {
                "device_code": DEVICE_CODE,
                "user_code": "SYNTHETIC-OPERATOR-CODE",
                "verification_uri": f"http://127.0.0.1:{self.server.server_port}/verify",
                "expires_in": 1 if mode == "expire" else 60,
                "interval": 5,
            })
        elif self.path == "/api/oauth/token":
            fields = parse_qs(raw.decode())
            if fields.get("grant_type") == ["refresh_token"]:
                self.server.counts["refresh"] += 1
                self.server.auth_ok &= fields.get("refresh_token") == [REFRESH]
                self.reply(200, {"access_token": ROTATED_ACCESS,
                                 "refresh_token": ROTATED_REFRESH, "expires_in": 3600})
            else:
                self.server.counts["poll"] += 1
                self.server.auth_ok &= fields.get("device_code") == [DEVICE_CODE]
                self.server.polled.set()
                mode = self.server.mode
                if mode == "blocked-poll":
                    self.server.release.wait(30)
                if mode == "deny":
                    self.reply(200, {"error": "access_denied"})
                elif mode == "pending":
                    self.reply(200, {"error": "authorization_pending"})
                else:
                    self.reply(200, {"access_token": ACCESS, "refresh_token": REFRESH,
                                     "expires_in": 1})
        elif self.path == "/coding/v1/chat/completions":
            self.server.counts["chat"] += 1
            self.server.auth_ok &= self.headers.get("Authorization") == f"Bearer {ROTATED_ACCESS}"
            request = json.loads(raw)
            self.reply(200, {
                "id": "chat_synthetic_account_ui", "object": "chat.completion",
                "model": request["model"],
                "choices": [{"index": 0, "message": {"role": "assistant",
                             "content": "synthetic usable Kimi grant"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })
        else:
            self.reply(404, {"error": "unknown synthetic endpoint"})


class Fixture:
    def __init__(self, directory, args):
        self.directory = directory
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        scoped = json.dumps(["kimi", "oauth", ACCOUNT], separators=(",", ":")).encode()
        name = "runtime-" + base64.urlsafe_b64encode(scoped).decode().rstrip("=") + ".json"
        self.slot = self.state / name
        self.provider = Provider(self.state, self.slot)
        threading.Thread(target=self.provider.serve_forever, daemon=True).start()
        self.ui_port, self.gateway_port = free_port(), free_port()
        self.root_command = shlex.split(args.root_command)
        self.ui_command = self.root_command if args.root_ui else shlex.split(args.ui_command)
        self.axis = "root CLI" if args.root_ui else "independent source module main (root UI NOT tested)"
        self.identity = private(directory / "identity.json", json.dumps({"device_id": DEVICE}))
        self.client_path = private(directory / "client.txt", CLIENT)
        self.config = directory / "providers.json"
        self.config.write_text(json.dumps({
            "version": 1, "state_dir": str(self.state), "listen_port": self.gateway_port,
            "accounts": [{
                "provider": "kimi", "auth_mode": "oauth", "id": ACCOUNT,
                "origin": f"http://127.0.0.1:{self.provider.server_port}",
                "models": ["kimi-k2.7-code"],
                "oauth": {
                    "domain": "kimi.com",
                    "device_url": f"http://127.0.0.1:{self.provider.server_port}/api/oauth/device_authorization",
                    "token_url": f"http://127.0.0.1:{self.provider.server_port}/api/oauth/token",
                },
            }],
        }))
        self.cookie = ""
        self.csrf = ""
        self.ui = None
        self.gateway = None
        self.logs = []
        self.handles = []
        self.env = dict(os.environ, TMPDIR=str(directory))
        self.cli_runs = 0
        self.key_provisioned = False
        self.root_ui = args.root_ui

    def command(self, tail):
        result = subprocess.run([*self.root_command, *tail], cwd=ROOT, env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        clean(result.stdout)
        assert result.returncode == 0, "root provisioning command failed"
        self.cli_runs += 1
        return result.stdout

    def launch(self, command, tail, name):
        path = self.directory / f"{name}-{len(self.logs)}.log"
        handle = path.open("wb")
        self.logs.append(path)
        self.handles.append(handle)
        return subprocess.Popen([*command, *tail], cwd=ROOT, env=self.env,
                                stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)

    def http(self, port, method, path, data=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        body = None if data is None else json.dumps(data)
        try:
            conn.request(method, path, body, headers or {})
            response = conn.getresponse()
            raw = response.read()
            clean(raw)
            return response.status, dict(response.getheaders()), raw
        finally:
            conn.close()

    def api(self, path, data=None, **overrides):
        headers = {
            "Origin": f"http://127.0.0.1:{self.ui_port}",
            "Content-Type": "application/json", "X-Mimic-UI": "1",
            "Cookie": self.cookie, "X-CSRF-Token": self.csrf,
        }
        headers.update(overrides)
        status, response_headers, body = self.http(self.ui_port, "POST", path, data or {}, headers)
        return status, response_headers, json.loads(body)

    def start_ui(self):
        before = set(self.state.glob("account-ui-bootstrap-*.txt"))
        self.ui = self.launch(self.ui_command, ["accounts", "ui", "serve", str(self.config),
                                               self.identity, str(self.ui_port)], "ui")

        def ready():
            assert self.ui.poll() is None, "UI exited before readiness"
            try:
                return self.http(self.ui_port, "GET", "/")[0] == 200
            except (OSError, http.client.HTTPException):
                return False
        wait(ready, 60, "UI listener")
        self.bootstrap = wait(lambda: next(iter(set(self.state.glob("account-ui-bootstrap-*.txt")) - before), None),
                              label="private bootstrap file")
        assert self.bootstrap.stat().st_mode & 0o777 == 0o600
        self.cookie, self.csrf = "", ""

    def unlock(self):
        code = self.bootstrap.read_text()
        status, headers, body = self.api("/api/session", {"code": code})
        assert status == 200, "one-time exchange failed"
        cookie = headers["set-cookie"]
        assert "HttpOnly" in cookie and "SameSite=Strict" in cookie
        assert not self.bootstrap.exists(), "consumed bootstrap file retained"
        self.cookie = cookie.split(";")[0]
        self.csrf = body["csrf"]
        assert self.api("/api/session", {"code": code})[0] == 401, "bootstrap replay accepted"

    def login(self):
        assert self.api("/api/login", {"account": ACCOUNT})[0] == 202
        wait(self.provider.started.is_set, label="actual device HTTP")

    def status(self):
        status, _, body = self.api("/api/status")
        assert status == 200
        return body["accounts"][0]

    def phase(self, name):
        value = wait(lambda: (value if (value := self.status())["login"] == name else None),
                     label=f"login {name}")
        if name not in ("starting", "waiting"):
            assert "verification_uri" not in value and "user_code" not in value
        return value

    def stop(self, process):
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise AssertionError("graceful CLI shutdown did not finish")

    def start_gateway(self):
        if not self.key_provisioned:
            self.command(["providers", "key", "import", str(self.config), "synthetic-client", self.client_path])
            self.key_provisioned = True
        self.gateway = self.launch(self.root_command, ["serve", "providers", str(self.config)], "gateway")

        def ready():
            assert self.gateway.poll() is None, "gateway exited before readiness"
            try:
                return self.http(self.gateway_port, "GET", "/v1/models")[0] == 401
            except (OSError, http.client.HTTPException):
                return False
        wait(ready, 60, "actual root gateway")

    def chat(self):
        status, _, body = self.http(self.gateway_port, "POST", "/v1/chat/completions",
                                   {"model": "kimi-k2.7-code", "messages": [{"role": "user", "content": "synthetic"}]},
                                   {"Authorization": f"Bearer {CLIENT}", "Content-Type": "application/json"})
        assert status == 200, "enrolled grant unusable in actual gateway"
        assert json.loads(body)["choices"][0]["message"]["content"] == "synthetic usable Kimi grant"

    def admin(self, action):
        if action == "delete":
            self.command(["providers", "credential", "delete", str(self.config), ACCOUNT])
        else:
            grant = private(self.directory / "admin.json", json.dumps({
                "device_id": DEVICE, "access_token": ADMIN_ACCESS, "refresh_token": ADMIN_REFRESH,
                "expires_at_ms": int(time.time() * 1000) + 3_600_000,
            }))
            self.command(["providers", "credential", "import", str(self.config), ACCOUNT, grant])

    def close(self):
        self.provider.release.set()
        self.stop(self.ui)
        self.stop(self.gateway)
        self.provider.shutdown()
        self.provider.server_close()
        for handle in self.handles:
            handle.close()
        for path in self.logs:
            clean(path.read_bytes())
        assert not list(self.state.glob(".mutation-*")), "filesystem mutation guard retained"
        assert not (self.state / ".provider-runtime-owner").exists(), "runtime owner guard retained"


def raw_header_report(fixture):
    """No tokens printed. Duplicate singleton heads must close before a response."""
    fixture.unlock()
    base = [
        ("Host", f"127.0.0.1:{fixture.ui_port}"),
        ("Origin", f"http://127.0.0.1:{fixture.ui_port}"),
        ("X-CSRF-Token", fixture.csrf), ("Cookie", fixture.cookie),
        ("Content-Type", "application/json"), ("X-Mimic-UI", "1"), ("Content-Length", "2"),
    ]
    cases = []
    for name, invalid in [("Origin", "null"), ("X-CSRF-Token", "wrong"), ("Cookie", "wrong=1"),
                          ("Content-Length", "3"), ("Content-Type", "text/plain")]:
        good = next(value for key, value in base if key == name)
        others = [(key, value) for key, value in base if key != name]
        for variant, fields in [
            ("equal", [(name, good), (name, good)]),
            ("conflicting-invalid-first", [(name, invalid), (name, good)]),
            ("mixed-case-invalid-first", [(name.lower(), invalid), (name.upper(), good)]),
        ]:
            # Raw singleton rejection is peer closure, not a route-level 400.
            # Old Content-Type 200/report-only receipts remain retained evidence.
            cases.append((name + ":" + variant, [*fields, *others], "HTTP/1.1", None))
    cases.extend([
        ("CL+TE", [*base, ("Transfer-Encoding", "chunked")], "HTTP/1.1", None),
        ("TE+CL", [("Transfer-Encoding", "chunked"), *base], "HTTP/1.1", None),
        ("TE+TE", [("Transfer-Encoding", "identity"), ("transfer-encoding", "chunked"),
                   *[(k, v) for k, v in base if k != "Content-Length"]], "HTTP/1.1", None),
        ("legal-Accept-list", [*base, ("Accept", "application/json"), ("Accept", "*/*")], "HTTP/1.1", 200),
        ("legal-HTTP/1.0", base, "HTTP/1.0", 200),
    ])
    results = []
    for name, fields, version, expected in cases:
        before = dict(fixture.provider.counts)
        wire = f"POST /api/status {version}\r\n" + "".join(f"{k}: {v}\r\n" for k, v in fields)
        wire += "Connection: close\r\n\r\n{}"
        with socket.create_connection(("127.0.0.1", fixture.ui_port), timeout=10) as sock:
            sock.sendall(wire.encode())  # Headers/body coalesced deliberately.
            chunks = []
            termination = "eof"
            while True:
                try:
                    chunk = sock.recv(65536)
                except ConnectionResetError:
                    termination = "reset"
                    break
                if not chunk:
                    break
                chunks.append(chunk)
        raw = b"".join(chunks)
        clean(raw)
        status = int(raw.split(b"\r\n", 1)[0].split()[1]) if raw else None
        assert before == fixture.provider.counts, "security probe contacted provider"
        assert not fixture.slot.exists(), "security probe left enrollment residue"
        if name.startswith("Content-Type:"):
            assert not raw and status is None, "duplicate Content-Type reached an HTTP response"
        results.append({"case": name, "actual_status": status, "desired_status": expected,
                        "provider_sends_delta": 0, "runtime_residue": False,
                        "peer_closed": True, "peer_termination": termination,
                        "before_handler_rejection": "not instrumented", "strict_gate": True})
    print(json.dumps({"axis": fixture.axis, "synthetic_only": True, "wire": results}, indent=2))
    return all(row["actual_status"] == row["desired_status"] for row in results if row["strict_gate"])


def smoke(fixture):
    invalid = subprocess.run(
        [*fixture.ui_command, "accounts", "ui", "serve", "unused", "unused", "0"],
        cwd=ROOT, env=fixture.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
    )
    clean(invalid.stdout)
    assert b"explicit numeric loopback operator port required" in invalid.stdout
    # The independent feature main cannot exit the VM; root supplies exit policy.
    assert invalid.returncode == (1 if fixture.root_ui else 0)
    page = fixture.http(fixture.ui_port, "GET", "/")
    assert page[0] == 200 and b"Kimi account enrollment" in page[2]
    assert page[1]["cache-control"] == "no-store, max-age=0"
    assert page[1]["referrer-policy"] == "no-referrer"
    assert fixture.api("/api/login", {"account": ACCOUNT})[0] == 401
    assert fixture.api("/api/session", {"code": "x" * 43}, Origin="https://attacker.invalid")[0] == 403
    fixture.unlock()
    assert fixture.api("/api/login", {"account": "codex"})[0] == 404
    assert fixture.api("/api/status", **{"X-CSRF-Token": "wrong"})[0] == 401
    assert fixture.api("/api/status", Host=f"localhost:{fixture.ui_port}")[0] == 403
    fixture.start_gateway()  # One existing runtime, alive BEFORE enrollment.
    fixture.provider.phase("authorize")
    fixture.login()
    pending = fixture.phase("waiting")
    assert pending["user_code"] == "SYNTHETIC-OPERATOR-CODE"
    fixture.phase("stored")
    fixture.chat()  # Expiring grant refreshes in the existing gateway manager.
    assert fixture.provider.counts["refresh"] == 1
    grant = json.loads(fixture.slot.read_text())
    assert grant["access_token"] == ROTATED_ACCESS and grant["refresh_token"] == ROTATED_REFRESH
    assert ["device_id", DEVICE] in grant["private_metadata"]
    fixture.stop(fixture.gateway)
    fixture.start_gateway()  # Fresh process, no credential reseed.
    fixture.chat()
    assert fixture.provider.counts["refresh"] == 1
    fixture.stop(fixture.gateway)

    before = json.loads(fixture.slot.read_text())
    fixture.provider.phase("blocked-start")
    fixture.login()
    assert fixture.api("/api/cancel", {"account": ACCOUNT})[0] == 200
    fixture.provider.release.set()
    fixture.phase("cancelled")
    after = json.loads(fixture.slot.read_text())
    assert before["access_token"] == after["access_token"]
    assert before["generation"] != after["generation"]

    for operation in ("cancel", "replace", "delete"):
        fixture.provider.phase("blocked-poll")
        fixture.login()
        wait(fixture.provider.polled.is_set, label="blocked actual token HTTP")
        before = json.loads(fixture.slot.read_text())
        if operation == "cancel":
            assert fixture.api("/api/cancel", {"account": ACCOUNT})[0] == 200
        else:
            fixture.admin(operation)
        fixture.provider.release.set()
        fixture.phase("cancelled" if operation == "cancel" else "installation_unconfirmed")
        time.sleep(0.1)
        if operation == "delete":
            assert not fixture.slot.exists()
        else:
            after = json.loads(fixture.slot.read_text())
            expected = before["access_token"] if operation == "cancel" else ADMIN_ACCESS
            assert after["access_token"] == expected, "late token overwrote administrative state"

    fixture.provider.phase("expire")
    polls = fixture.provider.counts["poll"]
    fixture.login()
    fixture.phase("waiting")
    fixture.phase("expired")
    assert not fixture.slot.exists() and fixture.provider.counts["poll"] == polls

    fixture.provider.phase("blocked-start")
    fixture.login()
    fixture.stop(fixture.ui)
    fixture.provider.release.set()
    assert not fixture.slot.exists(), "graceful shutdown stranded enrollment"
    old_cookie, old_csrf = fixture.cookie, fixture.csrf
    fixture.start_ui()
    fixture.cookie, fixture.csrf = old_cookie, old_csrf
    assert fixture.api("/api/status")[0] == 401, "restart restored operator session"
    fixture.unlock()
    assert fixture.api("/api/logout")[0] == 200
    assert fixture.api("/api/status")[0] == 401
    assert fixture.provider.reservation_before_io and fixture.provider.identity_ok and fixture.provider.auth_ok
    print(json.dumps({
        "result": "PASS", "axis": fixture.axis, "live": "BLOCKED/not performed",
        "actual_local_provider_counts": fixture.provider.counts,
        "reservation_before_io": True, "native_device_identity": True,
        "gateway_refresh_and_fresh_process_reuse": True,
        "cancel_admin_CAS_expiry_shutdown_restart": True,
        "raw_duplicate_gate": "separate --raw-header-report, not waived",
    }, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-command", default=DEFAULT_ROOT)
    parser.add_argument("--ui-command", default=DEFAULT_UI)
    parser.add_argument("--root-ui", action="store_true", help="Only AFTER root admission")
    parser.add_argument("--raw-header-report", action="store_true")
    parser.add_argument("--browser-fixture", action="store_true")
    parser.add_argument("--hold-seconds", type=int, default=240)
    args = parser.parse_args()
    scratch = ROOT / "build" / "account-ui" / "tmp"
    scratch.mkdir(parents=True, exist_ok=True)
    # Explicit private synthetic state remains INSIDE this attached worktree.
    with tempfile.TemporaryDirectory(prefix="f05-", dir=scratch) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        fixture = Fixture(directory, args)
        try:
            fixture.start_ui()
            if args.raw_header_report:
                passed = raw_header_report(fixture)
                if not passed:
                    raise SystemExit(1)
            elif args.browser_fixture:
                print(json.dumps({
                    "synthetic_browser_fixture": True, "axis": fixture.axis,
                    "ui": f"http://127.0.0.1:{fixture.ui_port}",
                    "bootstrap_file": str(fixture.bootstrap),
                    "provider_verification": f"http://127.0.0.1:{fixture.provider.server_port}/verify",
                    "private_state": str(fixture.state), "hold_seconds": args.hold_seconds,
                    "live": "BLOCKED/not performed",
                }), flush=True)
                time.sleep(max(1, min(args.hold_seconds, 600)))
            else:
                smoke(fixture)
        finally:
            fixture.close()


if __name__ == "__main__":
    main()
