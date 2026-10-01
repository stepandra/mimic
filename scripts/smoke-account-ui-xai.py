#!/usr/bin/env python3
"""F07 actual root UI -> S5 -> existing refresh manager -> gateway HTTP.

Every issuer, API/proxy peer, grant and client key is synthetic loopback data.
Use --root-command for the exact exported shipment entrypoint. No CPA/provider
requests, credentials in argv, ambient proxy or private output are permitted.
"""

import argparse
import base64
import errno
import http.client
from http.server import ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("f07_f05_fixture", ROOT / "scripts/smoke-account-ui.py")
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)
ACCOUNTS = ["synthetic-xai-one", "synthetic-xai-two"]
MODELS = ["grok-4.7", "grok-4.6"]
CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"
SCOPE = "openid profile email offline_access grok-cli:access api:access"
GRANT = "urn:ietf:params:oauth:grant-type:device_code"


def token(field, n):
    return f"synthetic-private-xai-{field}-{n}"


local.SECRETS.extend(token(field, n) for n in (1, 2)
                     for field in ("device", "access", "refresh", "rotated-access",
                                   "rotated-refresh", "admin-access", "admin-refresh"))
local.SECRETS.append(token("binding-key", 1))


def slot(state, n):
    key = json.dumps(["xai", "oauth", ACCOUNTS[n - 1]], separators=(",", ":")).encode()
    return state / ("runtime-" + base64.urlsafe_b64encode(key).decode().rstrip("=") + ".json")


class Peer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, fixture, role):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.fixture, self.role = fixture, role
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"


class Upstream(local.Upstream):
    def boundary_start(self, method):
        f = self.server.fixture
        routes = {
            "/discovery/1": "discovery", "/discovery/2": "discovery",
            "/verify/1": "verification", "/verify/2": "verification",
            "/device/1": "device", "/device/2": "device",
            "/token/1": "token", "/token/2": "token",
            "/v1/responses": "responses", "/v1/responses/compact": "compact",
            "/favicon.ico": "favicon",
        }
        phases = ("authorize", "expire", "blocked-discovery", "blocked-start",
                  "blocked-poll", "blocked-exchange")
        self.boundary = {
            "method": method, "route": routes.get(self.path, "unknown_route"),
            "role": self.server.role if self.server.role in ("issuer", "proxy", "api") else "unknown",
            "phase": f.mode if f.mode in phases else "unknown",
            "attempt": f.attempt_sequence,
            "account": (
                "one" if self.path in ("/discovery/1", "/verify/1", "/device/1", "/token/1")
                else "two" if self.path in ("/discovery/2", "/verify/2", "/device/2", "/token/2")
                else "none"),
        }
        self.branch = "request_entry"
        tag = method + ":" + self.boundary["route"]
        f.route_counts[tag] = f.route_counts.get(tag, 0) + 1

    def boundary_failure(self, exc, peer_close=False):
        f = self.server.fixture
        classes = ("AssertionError", "ValueError", "KeyError", "TypeError",
                   "JSONDecodeError", "BrokenPipeError", "ConnectionResetError",
                   "OSError", "TimeoutError")
        name = type(exc).__name__
        diagnostic = dict(
            self.boundary, branch=self.branch,
            exception=name if name in classes else "Other",
            errno=getattr(exc, "errno", None) if isinstance(exc, OSError) else None,
            counters=dict(f.counts),
        )
        reset = isinstance(exc, (BrokenPipeError, ConnectionResetError)) or (
            isinstance(exc, OSError) and exc.errno in (errno.EPIPE, errno.ECONNRESET))
        attempt = (self.boundary["attempt"], self.boundary["account"])
        declared_cancel = attempt in f.expected_peer_closes
        confirmed_cancel = attempt in f.confirmed_peer_closes
        diagnostic["cancel_intent"] = declared_cancel
        diagnostic["cancel_confirmed"] = confirmed_cancel
        oauth_route = self.boundary["role"] == "issuer" and self.boundary["route"] in (
            "discovery", "device", "token")
        if peer_close and reset and declared_cancel and oauth_route:
            diagnostic["classification"] = (
                "confirmed_cancel_peer_close" if confirmed_cancel else "cancel_intent_peer_close")
            f.peer_closes.append(diagnostic)
        else:
            diagnostic["classification"] = (
                "unsolicited_browser_route" if self.boundary["route"] in ("favicon", "unknown_route")
                else "unexpected_peer_close" if peer_close else "protocol_boundary")
        # Diagnostic run preserves the legacy final-error signal. Classification
        # is evidence only: even a matched confirmed close is not exempted here.
        f.errors.append(diagnostic)

    def write_reply(self, status, data, media):
        previous = self.branch
        self.branch = "response_write"
        try:
            self.send_response(status)
            self.send_header("Content-Type", media)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except OSError as exc:
            # Record the precise boundary without exempting any failure during
            # diagnosis; cancellation intent alone proves no successful cancel.
            self.boundary_failure(exc, peer_close=True)
        finally:
            self.branch = previous

    def reply(self, status, body):
        self.write_reply(status, json.dumps(body).encode(), "application/json")

    def do_GET(self):
        f = self.server.fixture
        self.boundary_start("GET")
        if self.server.role == "issuer" and self.path == "/favicon.ico":
            # Exact public browser resource, before OAuth route/code parsing.
            # No query, authorization, grant, refresh or inference side effect.
            self.branch = "public_favicon"
            f.resource_counts["favicon"] += 1
            return self.write_reply(204, b"", "image/x-icon")
        try:
            self.branch = "get_role"
            assert self.server.role == "issuer"
            self.branch = "get_route_parse"
            kind, number = self.path.strip("/").split("/")
            n = int(number)
            self.branch = "get_account_number"
            assert n in (1, 2)
            if kind == "discovery":
                self.branch = "discovery_headers"
                assert self.headers.get("Content-Length") == "0"
                assert self.headers.get("Accept") == "application/json"
                self.branch = "discovery_s5_reservation"
                assert slot(f.state, n).exists(), "S5 reservation must precede discovery"
                f.counts["discovery"] += 1
                self.branch = "discovery_block"
                f.block("blocked-discovery")
                return self.reply(200, {
                    "device_authorization_endpoint": f.issuer_origin + f"/device/{n}",
                    "token_endpoint": f.issuer_origin + f"/token/{n}",
                })
            self.branch = "verification_route"
            assert kind == "verify"
            self.branch = "verification_no_authorization_header"
            assert self.headers.get("Authorization") is None
            f.authorized[n] = True
            f.counts["verification"] += 1
            return self.reply(200, {"synthetic": True, "instructions": "Return to MIMIC. No live OAuth."})
        except Exception as exc:
            self.boundary_failure(exc)
            self.reply(500, {"error": "synthetic boundary assertion failed"})

    def do_POST(self):
        f = self.server.fixture
        self.boundary_start("POST")
        try:
            self.branch = "post_body_length"
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if self.server.role != "issuer":
                return self.inference(raw)
            self.branch = "post_route_parse"
            kind, number = self.path.strip("/").split("/")
            n = int(number)
            self.branch = "oauth_form_parse"
            fields = parse_qs(raw.decode())
            self.branch = "oauth_content_type"
            assert self.headers.get("Content-Type") == "application/x-www-form-urlencoded"
            self.branch = "oauth_client_id"
            assert fields["client_id"] == [CLIENT_ID]
            if kind == "device":
                self.branch = "device_scope_fields"
                assert set(fields) == {"client_id", "scope"} and fields["scope"] == [SCOPE]
                self.branch = "device_s5_reservation"
                assert slot(f.state, n).exists()
                f.counts["device"] += 1
                self.branch = "device_block"
                f.block("blocked-start")
                return self.reply(200, {
                    "device_code": token("device", n), "user_code": f"SYNTHETIC-F07-{n}",
                    "verification_uri": f.issuer_origin + f"/verify/{n}",
                    "expires_in": 1 if f.mode == "expire" else 60, "interval": 1,
                })
            self.branch = "token_route"
            assert kind == "token"
            self.branch = "token_grant_type"
            if fields["grant_type"] == ["refresh_token"]:
                self.branch = "refresh_form_fields"
                assert set(fields) == {"client_id", "grant_type", "refresh_token"}
                self.branch = "refresh_account_credential"
                assert fields["refresh_token"] == [token("refresh", n)]
                f.counts["refresh"] += 1
                if f.refresh_mode == "unknown":
                    # The issuer may have rotated. No response is affirmative
                    # evidence that the same refresh token can be retried.
                    self.close_connection = True
                    self.connection.shutdown(__import__("socket").SHUT_RDWR)
                    self.connection.close()
                    return
                f.accepted[n] = token("rotated-access", n)
                return self.reply(200, {
                    "access_token": f.accepted[n],
                    "refresh_token": token("rotated-refresh", n), "expires_in": 3600,
                })
            self.branch = "poll_form_fields"
            assert set(fields) == {"client_id", "grant_type", "device_code"}
            self.branch = "poll_grant_type"
            assert fields["grant_type"] == [GRANT]
            self.branch = "poll_account_device_code"
            assert fields["device_code"] == [token("device", n)]
            f.counts["poll"] += 1
            self.branch = "poll_block"
            f.block("blocked-poll")
            if not f.authorized[n]:
                return self.reply(400, {"error": "authorization_pending"})
            self.branch = "authorized_exchange_block"
            f.block("blocked-exchange")
            f.counts["exchange"] += 1
            f.accepted[n] = token("access", n)
            return self.reply(200, {
                "access_token": f.accepted[n], "refresh_token": token("refresh", n),
                "token_type": "Bearer", "expires_in": 1,
            })
        except Exception as exc:
            self.boundary_failure(exc)
            self.reply(500, {"error": "synthetic boundary assertion failed"})

    def inference(self, raw):
        f = self.server.fixture
        self.branch = "inference_json"
        payload = json.loads(raw)
        self.branch = "inference_model"
        n = MODELS.index(payload["model"]) + 1
        expected = f.key_access if self.server.role == "api" and f.key_access else f.accepted[n]
        self.branch = "inference_account_authorization"
        assert self.headers.get("Authorization") == "Bearer " + expected
        self.branch = "inference_conversation_header"
        assert self.headers.get("x-grok-conv-id")
        if self.server.role == "proxy":
            self.branch = "proxy_operation_and_stream"
            assert self.path == "/v1/responses" and payload["stream"] is True
            f.counts["proxy"] += 1
            base = {"id": f"resp_f07_{n}", "object": "response",
                    "model": payload["model"], "output": []}
            frames = "".join(
                "event: " + event + "\ndata: " + json.dumps({
                    "type": event, "sequence_number": sequence,
                    "response": dict(base, status=status),
                }) + "\n\n"
                for sequence, event, status in (
                    (0, "response.created", "in_progress"),
                    (1, "response.completed", "completed"),
                )
            ).encode()
            self.write_reply(200, frames, "text/event-stream")
        else:
            self.branch = "api_compact_operation"
            assert self.server.role == "api" and self.path == "/v1/responses/compact"
            f.counts["api"] += 1
            self.reply(200, {"id": f"compact_f07_{n}", "object": "response.compaction",
                             "output": [{"type": "compaction", "encrypted_content": "synthetic-state"}]})


class Fixture(local.Fixture):
    def __init__(self, directory, args):
        super().__init__(directory, args)
        self.provider.RequestHandlerClass = Upstream
        self.provider.fixture, self.provider.role = self, "issuer"
        self.issuer_origin = f"http://127.0.0.1:{self.provider.server_port}"
        self.proxy, self.api_peer = Peer(self, "proxy"), Peer(self, "api")
        self.counts = dict.fromkeys(("discovery", "device", "poll", "verification",
                                     "exchange", "refresh", "proxy", "api"), 0)
        # Reuse the inherited strict raw-header probe against the actual F07
        # slot/counters, not the constructor's unused synthetic Kimi slot.
        self.slot = slot(self.state, 1)
        self.provider.counts = self.counts
        self.errors = []
        self.peer_closes = []
        self.route_counts = {}
        self.resource_counts = {"favicon": 0}
        self.attempt_sequence = 0
        self.attempt_account = "none"
        self.expected_peer_closes = set()
        self.confirmed_peer_closes = set()
        self.mode = "authorize"
        self.refresh_mode = "rotate"
        self.authorized = {1: False, 2: False}
        self.accepted = {}
        self.key_access = None
        self.entered = threading.Event()
        self.release = threading.Event()
        settings = {
            "version": 1, "state_dir": str(self.state), "listen_port": self.gateway_port,
            "accounts": [{
                "provider": "xai", "auth_mode": "oauth", "id": account,
                # This is deliberately NOT an inference peer: no ambient fallback.
                "origin": self.issuer_origin, "models": [model],
                "oauth": {"discovery_url": self.issuer_origin + f"/discovery/{n}"},
                "xai_operations": [
                    {"protocol": "responses", "operation": "responses",
                     "base": self.proxy.origin + "/v1", "using_api": False},
                    {"protocol": "responses", "operation": "responses/compact",
                     "base": self.api_peer.origin + "/v1", "using_api": True},
                ],
            } for n, (account, model) in enumerate(zip(ACCOUNTS, MODELS), 1)],
        }
        self.config.write_text(json.dumps(settings))
        # Intentionally omit ambient credentials, provider/proxy configuration.
        self.env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
                    "TMPDIR": str(directory), "ERL_FLAGS": "+S 2:2 +A 2"}

    def block(self, mode):
        if self.mode == mode:
            self.entered.set()
            assert self.release.wait(20), "synthetic blocked phase was not released"

    def prepare(self, n, mode="authorize"):
        self.attempt_sequence += 1
        self.attempt_account = "one" if n == 1 else "two"
        self.mode = mode
        self.authorized[n] = False
        self.entered.clear()
        self.release.clear()

    def expect_peer_close(self):
        """Test-declared cancellation intent, never provider revocation."""
        self.expected_peer_closes.add((self.attempt_sequence, self.attempt_account))

    def confirm_cancel(self, attempt, account):
        """Only after the actual API/served page confirms this exact attempt."""
        assert (attempt, account) == (self.attempt_sequence, self.attempt_account)
        assert (attempt, account) in self.expected_peer_closes
        self.confirmed_peer_closes.add((attempt, account))

    def api(self, path, data=None, **overrides):
        if path in ("/api/cancel", "/api/logout"):
            self.expect_peer_close()
        attempt, account = self.attempt_sequence, self.attempt_account
        response = super().api(path, data, **overrides)
        if path == "/api/cancel" and response[0] == 200:
            rows = response[2].get("accounts", [])
            if any(row.get("id") == (data or {}).get("account") and row.get("login") == "cancelled"
                   for row in rows):
                self.confirm_cancel(attempt, account)
        return response

    def stop(self, process):
        if process is self.ui:
            self.expect_peer_close()
        return super().stop(process)

    def row(self, n):
        status, _, value = self.api("/api/status")
        assert status == 200
        return next(a for a in value["accounts"] if a["id"] == ACCOUNTS[n - 1])

    def xai_phase(self, n, expected):
        value = local.wait(lambda: (row if (row := self.row(n))["login"] == expected else None),
                           label=f"xAI {n} {expected}")
        if expected not in ("waiting", "starting"):
            assert "user_code" not in value and "verification_uri" not in value
        return value

    def begin(self, n):
        assert self.api("/api/login", {"account": ACCOUNTS[n - 1]})[0] == 202

    def verify(self, n):
        uri = self.xai_phase(n, "waiting")["verification_uri"]
        assert uri == self.issuer_origin + f"/verify/{n}"
        port = self.provider.server_port
        assert self.http(port, "GET", f"/verify/{n}")[0] == 200

    def enroll(self, n):
        self.prepare(n)
        self.begin(n)
        self.verify(n)
        self.xai_phase(n, "stored")
        record = json.loads(slot(self.state, n).read_text())
        assert record["kind"] == "oauth" and record["version"] == 2
        assert record["refresh_gate"]["state"] == "ready"
        assert record["private_metadata"] == [["token_endpoint", self.issuer_origin + f"/token/{n}"]]
        assert slot(self.state, n).stat().st_mode & 0o777 == 0o600

    def request(self, n, operation="responses", expected=200, **extra):
        status, _, body = self.http(
            self.gateway_port, "POST", "/v1/" + operation,
            dict({"model": MODELS[n - 1], "input": []}, **extra),
            {"Authorization": "Bearer " + local.CLIENT, "Content-Type": "application/json"},
        )
        assert status == expected, f"actual configured xAI {operation}: status {status}, expected {expected}"
        if status == 200:
            assert json.loads(body)["id"] == (
                f"resp_f07_{n}" if operation == "responses" else f"compact_f07_{n}"
            )

    def admin_xai(self, n, action):
        if action == "delete":
            self.command(["providers", "credential", "delete", str(self.config), ACCOUNTS[n - 1]])
            return
        previous = json.loads(slot(self.state, n).read_text())
        if action == "same":
            access, refresh, expiry = (previous["access_token"], previous["refresh_token"],
                                      previous["expires_at_ms"])
        else:
            access, refresh, expiry = token("admin-access", n), token("admin-refresh", n), int(time.time() * 1000) + 3600000
        path = local.private(self.directory / f"admin-{n}.json", json.dumps({
            "access_token": access, "refresh_token": refresh, "expires_at_ms": expiry,
            "token_endpoint": self.issuer_origin + f"/token/{n}",
        }))
        self.command(["providers", "credential", "import", str(self.config), ACCOUNTS[n - 1], path])
        self.accepted[n] = access

    def close(self):
        self.expect_peer_close()
        self.release.set()
        try:
            super().close()
        finally:
            for peer in (self.proxy, self.api_peer):
                peer.shutdown()
                peer.server_close()


def smoke(f, quick=False):
    f.start_ui()
    assert local.raw_header_report(f), "inherited raw singleton boundary gate failed (not waived)"
    before = dict(f.counts)
    assert f.api("/api/status", Origin="null")[0] == 403
    assert f.api("/api/status", Host=f"localhost:{f.ui_port}")[0] == 403
    assert f.api("/api/status", **{"X-CSRF-Token": "wrong"})[0] == 401
    assert f.counts == before
    f.start_gateway()  # Same runtime remains alive while UI commits into S5.
    f.request(1, expected=503)
    f.enroll(1)
    f.request(1)
    f.request(1, "responses/compact")
    assert f.counts["refresh"] == 1, "two operations must not create two managers"
    assert len(list(f.state.glob("runtime-*.json"))) == 1
    assert not slot(f.state, 2).exists()
    f.enroll(2)
    f.request(2)
    f.request(2, "responses/compact")
    assert f.counts["refresh"] == 2
    assert len(list(f.state.glob("runtime-*.json"))) == 2
    before = dict(f.counts)
    f.request(1, expected=422, previous_response_id="synthetic-unqualified-http-receipt")
    f.request(1, "responses/compact", expected=422, tools=[{"type": "function", "name": "unsupported"}])
    assert f.counts == before
    f.stop(f.gateway)
    f.start_gateway()
    f.request(1)
    f.request(1, "responses/compact")
    assert f.counts["refresh"] == 2, "persisted rotation must survive fresh-process reuse"
    if quick:
        return

    # Unknown delivery is a durable reauthorization fence, not an automatic
    # retry. Account two remains usable through the same running gateway.
    f.enroll(1)
    f.refresh_mode = "unknown"
    before = f.counts["refresh"]
    f.request(1, expected=503)
    f.request(1, "responses/compact", expected=503)
    assert f.counts["refresh"] == before + 1
    assert json.loads(slot(f.state, 1).read_text())["refresh_gate"]["state"] == "needs_reauthorization"
    f.stop(f.gateway)
    f.start_gateway()
    f.request(1, expected=503)
    assert f.counts["refresh"] == before + 1
    f.request(2)
    f.refresh_mode = "rotate"
    f.admin_xai(1, "replace")  # Explicit admin recovery, never automatic replay.

    for mode in ("blocked-discovery", "blocked-start", "blocked-poll", "blocked-exchange"):
        previous = json.loads(slot(f.state, 1).read_text())
        f.prepare(1, mode)
        f.begin(1)
        if mode == "blocked-exchange":
            f.verify(1)
        local.wait(f.entered.is_set, label=mode)
        assert f.api("/api/cancel", {"account": ACCOUNTS[0]})[0] == 200
        f.xai_phase(1, "cancelled")
        winner = json.loads(slot(f.state, 1).read_text())
        assert winner["access_token"] == previous["access_token"]
        assert winner["generation"] != previous["generation"]
        f.release.set()
        time.sleep(0.05)
        assert json.loads(slot(f.state, 1).read_text()) == winner

    for action in ("same", "replace", "delete"):
        if not slot(f.state, 1).exists():
            f.enroll(1)
        f.prepare(1, "blocked-exchange")
        f.begin(1)
        f.verify(1)
        local.wait(f.entered.is_set, label="admin blocked exchange")
        f.admin_xai(1, action)
        winner = slot(f.state, 1).read_bytes() if action != "delete" else None
        f.release.set()
        f.xai_phase(1, "installation_unconfirmed")
        assert (slot(f.state, 1).read_bytes() if slot(f.state, 1).exists() else None) == winner

    f.prepare(1, "expire")
    f.begin(1)
    f.xai_phase(1, "expired")
    assert not slot(f.state, 1).exists()
    f.prepare(1, "blocked-poll")
    f.begin(1)
    local.wait(f.entered.is_set, label="restart blocked poll")
    old_cookie, old_csrf = f.cookie, f.csrf
    f.stop(f.ui)
    f.release.set()
    f.start_ui()
    f.cookie, f.csrf = old_cookie, old_csrf
    assert f.api("/api/status")[0] == 401
    f.cookie, f.csrf = "", ""
    f.unlock()
    assert not slot(f.state, 1).exists()

    f.prepare(1, "blocked-poll")
    f.begin(1)
    local.wait(f.entered.is_set, label="whole-VM loss pending reservation")
    f.expect_peer_close()
    os.killpg(f.ui.pid, signal.SIGKILL)
    f.ui.wait(timeout=5)
    f.release.set()
    f.start_ui()
    f.unlock()
    assert f.api("/api/login", {"account": ACCOUNTS[0]})[0] == 409
    assert json.loads(slot(f.state, 1).read_text())["kind"] == "enrollment_pending"
    f.admin_xai(1, "delete")
    f.enroll(1)
    f.request(1)
    f.admin_xai(1, "delete")
    before = dict(f.counts)
    f.request(1, expected=503)
    assert f.counts == before, "deleted account must not send"
    f.request(2)
    f.command(["providers", "key", "revoke", str(f.config), "synthetic-client"])
    before = dict(f.counts)
    f.request(2, expected=401)
    assert f.counts == before, "revoked client must not acquire or send"
    assert f.api("/api/logout")[0] == 200
    assert f.api("/api/status")[0] == 401


def mixed_auth_operations(base, args):
    """Actual Compact dispatch must skip a proxy-Responses-only OAuth row.

    This is operation admission, not cross-auth retry/fallback for Responses.
    Same-operation auth priority remains the configured account order.
    """
    observed = []
    for oauth_first in (True, False):
        with tempfile.TemporaryDirectory(prefix="mixed-", dir=base) as raw:
            directory = Path(raw)
            directory.chmod(0o700)
            f = Fixture(directory, argparse.Namespace(
                root_command=args.root_command, ui_command=local.DEFAULT_UI, root_ui=True))
            try:
                settings = json.loads(f.config.read_text())
                oauth = settings["accounts"][0]
                oauth["xai_operations"] = oauth["xai_operations"][:1]
                key = {"provider": "xai", "auth_mode": "api_key", "id": "synthetic-xai-binding-key",
                       "origin": f.api_peer.origin, "models": [MODELS[0]]}
                settings["accounts"] = [oauth, key] if oauth_first else [key, oauth]
                f.config.write_text(json.dumps(settings))
                f.key_access = token("binding-key", 1)
                private = local.private(directory / "binding-key.json", json.dumps({"api_key": f.key_access}))
                f.command(["providers", "credential", "import", str(f.config), key["id"], private])
                f.start_ui()
                f.unlock()
                f.enroll(1)
                f.start_gateway()
                f.request(1, "responses/compact")
                assert f.counts["api"] == 1 and f.counts["refresh"] == 0 and f.counts["proxy"] == 0
                # Only the OAuth-first order is expected to select OAuth for
                # Responses. No claim of cross-auth fallback in the other order.
                if oauth_first:
                    f.request(1)
                    assert f.counts["proxy"] == 1 and f.counts["refresh"] == 1
                assert len(list(f.state.glob("runtime-*.json"))) == 2
                assert not f.errors
                observed.append({"oauth_first": oauth_first, "compact_auth_mode": "api_key"})
            finally:
                f.close()
                for n, path in enumerate(f.logs):
                    data = path.read_bytes()
                    local.clean(data)
                    (base / f"mixed-{int(oauth_first)}-{n}.log").write_bytes(data)
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root-command", default=local.DEFAULT_ROOT)
    parser.add_argument("--quick", action="store_true", help="only real enroll/rotate/two-origin/restart/privacy core")
    args = parser.parse_args()
    base = ROOT / "build/account-ui-f07"
    base.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="root-", dir=base) as raw:
        directory = Path(raw)
        directory.chmod(0o700)
        f = Fixture(directory, argparse.Namespace(
            root_command=args.root_command, ui_command=local.DEFAULT_UI, root_ui=True))
        try:
            smoke(f, args.quick)
            assert not f.errors, "synthetic issuer/peer boundary failed"
        finally:
            f.close()
            for n, path in enumerate(f.logs):
                data = path.read_bytes()
                local.clean(data)
                (base / f"root-{n}.log").write_bytes(data)
        print(json.dumps({
            "scope": "F07 actual root/shipment entrypoint", "synthetic_only": True,
            "quick": args.quick, "observed": f.counts,
            "device_ui_s5_existing_manager_two_explicit_origins": True,
            "live_provider": False, "cpa_differential": False,
        }))
    print(json.dumps({"synthetic_mixed_auth_operation_admission": mixed_auth_operations(base, args)}))


if __name__ == "__main__":
    main()
