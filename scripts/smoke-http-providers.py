#!/usr/bin/env python3
"""Synthetic real-Mist/fresh-VM HTTP provider checks; never contacts a provider."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import contextlib
import http.client
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import select
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit, urlencode


ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
CLIENT = BASE["CLIENT_KEY"]
SECRETS = [CLIENT, "synthetic-old-access", "synthetic-old-refresh",
           "synthetic-new-access", "synthetic-new-refresh", "synthetic-admin-access",
           "synthetic-kimi-key", "synthetic-device-code"]
MODEL = "synthetic-claude"
START = 'event: message_start\ndata: {"type":"message_start","message":{"id":"synthetic","usage":{"input_tokens":3}}}\n\n'
DELTA = 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好🌍"}}\n\n'
STOP = 'event: message_stop\ndata: {"type":"message_stop"}\n\n'
KIMI_MODEL = "kimi-k2.7-code"
KIMI_RESPONSE = {"id": "resp_synthetic", "object": "response", "model": "kimi-for-coding",
                 "status": "completed", "output": [],
                 "usage": {"input_tokens": 3, "output_tokens": 0, "total_tokens": 3}}


def kimi_sse(terminal=True):
    created = dict(KIMI_RESPONSE, status="in_progress")
    created.pop("usage")
    frames = [("response.created", {"type": "response.created", "sequence_number": 0,
                                    "response": created})]
    if terminal:
        frames.append(("response.completed", {"type": "response.completed",
                                               "sequence_number": 1, "response": KIMI_RESPONSE}))
    return "".join(f"event: {name}\ndata: {json.dumps(value, separators=(',', ':'))}\n\n"
                   for name, value in frames)


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, content, media="application/json"):
        raw = content.encode()
        self.send_response(status)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        self.close_connection = True
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = ({k: v[0] for k, v in parse_qs(raw.decode()).items()}
                if self.headers.get_content_type() == "application/x-www-form-urlencoded"
                else json.loads(raw))
        if self.path == "/api/oauth/device_authorization":
            self.server.devices.append((dict(self.headers), body))
            self.reply(200, json.dumps({
                "device_code": "synthetic-device-code", "user_code": "SYNTHETIC",
                "verification_uri": f"http://127.0.0.1:{self.server.server_port}/verify",
                "expires_in": 60, "interval": 1,
            }))
            return
        if self.path in ("/token", "/api/oauth/token"):
            self.server.tokens.append(body)
            self.server.token_headers.append(dict(self.headers))
            self.server.token_entered.set()
            self.server.token_release.wait(10)
            if self.server.token_mode == "disconnect":
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            status = 429 if self.server.token_mode in ("limited", "duplicate429") else 200
            payload = {
                "success": '{"access_token":"synthetic-new-access","refresh_token":"synthetic-new-refresh","expires_in":3600}',
                "limited": '{"error":"rate_limit_error"}',
                "duplicate429": '{"error":"rate_limit_error","error":"ambiguous"}',
                "duplicate": '{"access_token":"synthetic-a","access_token":"synthetic-b","expires_in":3600}',
            }[self.server.token_mode]
            self.reply(status, payload)
            return
        self.server.requests.append((self.path, dict(self.headers), body))
        if self.server.status != 200:
            self.reply(self.server.status, '{"error":{"type":"synthetic_rejection"}}')
            return
        if "/operator/kimi/" in self.path:
            if self.path.endswith("/chat/completions"):
                self.reply(200, json.dumps({
                    "id": "chat_synthetic", "object": "chat.completion",
                    "model": "kimi-for-coding", "choices": [
                        {"index": 0, "message": {"role": "assistant", "content": "synthetic"},
                         "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
                }))
            elif body.get("stream"):
                payload = kimi_sse(self.server.stream_mode == "good")
                if self.server.stream_mode == "malformed":
                    payload += "event: response.completed\ndata: {bad}\n\n"
                if self.server.stream_mode == "cancel":
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    try:
                        for sequence in range(1000):
                            frame = payload if sequence == 0 else (
                                "event: response.in_progress\ndata: " +
                                json.dumps({"type": "response.in_progress", "sequence_number": sequence,
                                            "response": dict(KIMI_RESPONSE, status="in_progress")}) + "\n\n")
                            raw = frame.encode()
                            self.wfile.write(f"{len(raw):x}\r\n".encode() + raw + b"\r\n")
                            self.wfile.flush()
                            time.sleep(0.01)
                        raise AssertionError("Kimi upstream not cancelled")
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        self.server.cancel_seen.set()
                else:
                    self.reply(200, payload, "text/event-stream")
            else:
                self.reply(200, json.dumps(KIMI_RESPONSE))
            return
        if body.get("stream"):
            mode = self.server.stream_mode
            payload = START + DELTA + {
                "good": STOP,
                "malformed": "data: {broken}\n\n",
                "disconnect": "",
                "cancel": "",
                "error": 'event: error\ndata: {"type":"error","error":{"type":"overloaded_error"}}\n\n',
            }[mode]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                # Force arbitrary byte/UTF-8/SSE boundaries in the real HTTP body.
                for byte in payload.encode():
                    self.wfile.write(b"1\r\n" + bytes([byte]) + b"\r\n")
                self.wfile.flush()
                if mode == "cancel":
                    for _ in range(1000):
                        ping = b"event: ping\ndata: {\"type\":\"ping\"}\n\n"
                        self.wfile.write(f"{len(ping):x}\r\n".encode() + ping + b"\r\n")
                        self.wfile.flush()
                        time.sleep(0.01)
                    raise AssertionError("upstream not cancelled")
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                self.server.cancel_seen.set()
            return
        value = ({"input_tokens": 7} if "count_tokens" in self.path else
                 {"type": "message", "content": [{"type": "text", "text": "synthetic"}]})
        self.reply(200, json.dumps(value))


def call(port, payload=None, path="/v1/messages", key=CLIENT, allow_incomplete=False):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("POST", path, json.dumps(payload), {
            "Authorization": f"Bearer {key}", "Content-Type": "application/json",
            "X-Client-Request-Id": "synthetic-client-session",
        })
        response = connection.getresponse()
        incomplete = False
        try:
            raw = response.read()
        except http.client.IncompleteRead as error:
            assert allow_incomplete
            raw = error.partial
            incomplete = True
        for secret in SECRETS:
            assert secret.encode() not in raw
        return response.status, raw.decode(), incomplete
    finally:
        connection.close()


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def ambiguous_http_denied(port, payload, path):
    raw_body = json.dumps(payload).encode()
    for lines in [
        f"Authorization: Bearer wrong\r\naUtHoRiZaTiOn: Bearer {CLIENT}\r\n",
        f"Authorization: Bearer {CLIENT}\r\nAuthorization: Bearer wrong\r\n",
        f"Authorization: Bearer {CLIENT}\r\nhOsT: duplicate.invalid\r\n",
    ]:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
            sock.sendall((f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                          "Content-Type: application/json\r\nConnection: close\r\n"
                          f"Content-Length: {len(raw_body)}\r\n{lines}\r\n").encode() + raw_body)
            try:
                response = sock.recv(4096)
            except ConnectionResetError:
                response = b""
            assert b"200" not in response.split(b"\r\n")[0]


def private(path, value):
    return BASE["private_file"](path, value)


class Workflow:
    def __init__(self, directory, command, shipment):
        self.directory = directory
        self.command = command
        self.cwd = directory if shipment else ROOT
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        self.port = available_port()
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        self.upstream.requests = []
        self.upstream.tokens = []
        self.upstream.token_headers = []
        self.upstream.devices = []
        self.upstream.stream_mode = "good"
        self.upstream.token_mode = "success"
        self.upstream.status = 200
        self.upstream.cancel_seen = threading.Event()
        self.upstream.token_entered = threading.Event()
        self.upstream.token_release = threading.Event()
        self.upstream.token_release.set()
        self.worker = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.worker.start()
        self.origin = f"http://127.0.0.1:{self.upstream.server_port}"
        self.config = directory / "providers.json"
        account = {
            "provider": "claude", "auth_mode": "oauth", "id": "selected",
            "origin": self.origin, "models": [MODEL],
            "oauth": {
                "client_id": "synthetic-client", "authorize_url": self.origin + "/authorize",
                "token_url": self.origin + "/token",
                "redirect_uri": f"http://127.0.0.1:{available_port()}/callback",
            },
        }
        # No credential for first configured account. Origin/auth must come from
        # runtime-selected second account, not config.accounts[0].
        absent = dict(account, id="absent", origin="http://127.0.0.1:1")
        self.config.write_text(json.dumps({
            "version": 1, "state_dir": str(self.state), "listen_port": self.port,
            "accounts": [absent, account],
        }))
        self.key_path = private(directory / "client", CLIENT)
        self.cli("key", "import", str(self.config), "client", self.key_path)
        self.generation = 0
        self.payload = {"model": MODEL, "messages": [{"role": "user", "content": "hello"}],
                        "max_tokens": 16, "stream": True}

    def cli(self, *args):
        result = subprocess.run([*self.command, "providers", *args], cwd=self.cwd,
                                capture_output=True, timeout=60)
        output = result.stdout + result.stderr
        assert not any(secret.encode() in output for secret in SECRETS)
        assert result.returncode == 0, f"CLI failure: {output.decode(errors='replace')}"
        return result.stdout

    def grant(self, expired=True, access="synthetic-old-access"):
        return {
            "access_token": access, "refresh_token": "synthetic-old-refresh",
            "expires_at_ms": 1 if expired else int(time.time() * 1000) + 3600000,
            "device_id": "a" * 64, "account_uuid": "synthetic-account",
            "organization_uuid": "synthetic-org",
        }

    def seed(self, expired=True, access="synthetic-old-access"):
        path = private(self.directory / "grant", json.dumps(self.grant(expired, access)))
        self.cli("credential", "import", str(self.config), "selected", path)
        self.cli("credential", "status", str(self.config), "selected")

    @contextlib.contextmanager
    def running(self):
        self.generation += 1
        path = self.directory / f"gateway-{self.generation}.log"
        with path.open("wb") as log:
            process = BASE["start"](self.command, self.config, self.port, log, self.state, self.cwd)
            try:
                yield
            finally:
                BASE["stop"](process, self.state)
        assert not any(secret.encode() in path.read_bytes() for secret in SECRETS)

    def close(self):
        self.upstream.shutdown()
        self.upstream.server_close()
        self.worker.join(timeout=5)


def claude_checks(flow):
    upstream = flow.upstream
    flow.seed()
    # Actual ingress refresh singleflight: hold response until both callers enter.
    upstream.token_release.clear()
    with flow.running(), ThreadPoolExecutor(max_workers=2) as pool:
        first = pool.submit(call, flow.port, flow.payload)
        assert upstream.token_entered.wait(5)
        second = pool.submit(call, flow.port, flow.payload)
        time.sleep(0.15)
        assert len(upstream.tokens) == 1
        upstream.token_release.set()
        for future in (first, second):
            status, raw, incomplete = future.result(timeout=10)
            assert status == 200 and raw == START + DELTA + STOP and not incomplete
    assert len(upstream.tokens) == 1
    sessions = []
    for path, headers, body in upstream.requests:
        assert path == "/v1/messages?beta=true"
        assert headers["Host"] == flow.origin.removeprefix("http://")
        assert headers["Authorization"] == "Bearer synthetic-new-access"
        assert "x-api-key" not in headers
        identity = json.loads(body["metadata"]["user_id"])
        assert identity["device_id"] == "a" * 64
        assert identity["account_uuid"] == "synthetic-account"
        sessions.append(identity["session_id"])
    assert sessions[0] == sessions[1]
    with flow.running():
        # Fresh process uses persisted rotation, not reseeded credentials.
        before = len(upstream.requests)
        ambiguous_http_denied(flow.port, flow.payload, "/v1/messages")
        assert len(upstream.requests) == before
        assert call(flow.port, flow.payload)[1] == START + DELTA + STOP
        assert len(upstream.tokens) == 1
        for mode in ("malformed", "disconnect", "error"):
            upstream.stream_mode = mode
            status, raw, incomplete = call(flow.port, flow.payload, allow_incomplete=True)
            assert status == 200 and raw.startswith(START + DELTA)
            assert STOP not in raw
            assert incomplete == (mode != "error")
        upstream.stream_mode = "cancel"
        connection = http.client.HTTPConnection("127.0.0.1", flow.port, timeout=10)
        connection.request("POST", "/v1/messages", json.dumps(flow.payload), {
            "Authorization": f"Bearer {CLIENT}", "Content-Type": "application/json",
        })
        response = connection.getresponse()
        assert response.read(len(START.encode())) == START.encode()
        response.close()
        connection.close()
        assert upstream.cancel_seen.wait(5), "downstream close did not cancel upstream"
        upstream.stream_mode = "good"
        assert call(flow.port, flow.payload)[0] == 200

    # Proven rate-limit deferral and ambiguous outcomes survive a fresh process.
    for mode in ("limited", "duplicate", "duplicate429", "disconnect"):
        flow.seed()
        upstream.token_mode = mode
        before_tokens = len(upstream.tokens)
        before_requests = len(upstream.requests)
        for _ in range(2):
            with flow.running():
                assert call(flow.port, flow.payload)[0] == 503
        assert len(upstream.tokens) == before_tokens + 1
        assert len(upstream.requests) == before_requests

    # Admin replacement while rotation is in flight defeats stale refresh CAS.
    upstream.token_mode = "success"
    upstream.token_entered.clear()
    upstream.token_release.clear()
    flow.seed()
    before = len(upstream.requests)
    with flow.running(), ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(call, flow.port, flow.payload)
        assert upstream.token_entered.wait(5)
        flow.seed(expired=False, access="synthetic-admin-access")
        upstream.token_release.set()
        assert pending.result(timeout=10)[0] == 503
        assert len(upstream.requests) == before
    with flow.running():
        assert call(flow.port, flow.payload)[0] == 200
        assert upstream.requests[-1][1]["Authorization"] == "Bearer synthetic-admin-access"
        # Provider rejections are sanitized and never replayed after delivery.
        for status in (401, 429):
            upstream.status = status
            before = len(upstream.requests)
            assert call(flow.port, flow.payload)[0] == 503
            assert len(upstream.requests) == before + 1
            upstream.status = 200
            # Import is an explicit administrator reset of rejection gates.
            flow.seed(expired=False, access="synthetic-admin-access")
        before = len(upstream.requests)
        flow.cli("key", "revoke", str(flow.config), "client")
        assert call(flow.port, flow.payload)[0] == 401
        assert len(upstream.requests) == before


def login_checks(flow):
    """Actual configured CLI callback -> JSON token exchange -> runtime store."""
    flow.upstream.token_mode = "success"
    identity = private(flow.directory / "identity", json.dumps({
        "device_id": "a" * 64, "account_uuid": "synthetic-account",
    }))
    for fail_persistence in (False, True):
        before = len(flow.upstream.tokens)
        process = subprocess.Popen([
            *flow.command, "providers", "credential", "login", str(flow.config),
            "selected", identity,
        ], cwd=flow.cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            assert select.select([process.stdout], [], [], 60)[0], "login did not announce URL"
            announced = process.stdout.readline().decode().strip()
            parsed = urlsplit(announced)
            assert parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
            query = parse_qs(parsed.query)
            redirect = urlsplit(query["redirect_uri"][0])
            callback = http.client.HTTPConnection(redirect.hostname, redirect.port, timeout=5)
            for path, pairs in [
                ("/wrong", [("state", query["state"][0]), ("code", "synthetic-code")]),
                (redirect.path, [("state", "wrong"), ("code", "synthetic-code")]),
                (redirect.path, [("state", query["state"][0]), ("state", "duplicate"), ("code", "synthetic-code")]),
            ]:
                callback.request("GET", path + "?" + urlencode(pairs))
                reply = callback.getresponse()
                assert reply.status == 400
                reply.read()
                assert len(flow.upstream.tokens) == before
            if fail_persistence:
                # Runtime storage rechecks permissions at persistence time.
                flow.state.chmod(0o755)
            callback.request("GET", redirect.path + "?" + urlencode({
                "state": query["state"][0], "code": "synthetic-code",
            }))
            reply = callback.getresponse()
            assert reply.status == 200
            reply.read()
            callback.close()
            output, errors = process.communicate(timeout=15)
            assert process.returncode == (1 if fail_persistence else 0)
            assert not any(secret.encode() in output + errors for secret in SECRETS)
            assert len(flow.upstream.tokens) == before + 1
            exchanged = flow.upstream.tokens[-1]
            assert exchanged["grant_type"] == "authorization_code"
            assert exchanged["state"] == query["state"][0]
            assert exchanged["redirect_uri"] == query["redirect_uri"][0]
            challenge = base64.urlsafe_b64encode(
                hashlib.sha256(exchanged["code_verifier"].encode()).digest()
            ).decode().rstrip("=")
            assert query["code_challenge"] == [challenge]
            assert exchanged["code_verifier"] not in announced + output.decode() + errors.decode()
            with socket.socket() as probe:
                assert probe.connect_ex(("127.0.0.1", redirect.port)) != 0
        finally:
            flow.state.chmod(0o700)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    flow.cli("credential", "status", str(flow.config), "selected")


def kimi_checks(flow, mode, domain):
    upstream = flow.upstream
    settings = json.loads(flow.config.read_text())
    account = {
        "provider": "kimi", "auth_mode": mode, "id": "selected", "origin": flow.origin,
        "base_path": "/operator/kimi", "models": [KIMI_MODEL],
    }
    if mode == "oauth":
        account["oauth"] = {
            "domain": domain,
            "device_url": flow.origin + "/api/oauth/device_authorization",
            "token_url": flow.origin + "/api/oauth/token",
        }
    settings["accounts"] = [dict(account, id="absent", origin="http://127.0.0.1:1",
                                 base_path="/wrong"), account]
    flow.config.write_text(json.dumps(settings))
    credential = ({"api_key": "synthetic-kimi-key"} if mode == "api_key"
                  else flow.grant())
    credential_path = private(flow.directory / "kimi-grant", json.dumps(credential))
    flow.cli("credential", "import", str(flow.config), "selected", credential_path)
    payload = {"model": KIMI_MODEL, "input": "synthetic", "stream": False}
    if mode == "oauth":
        upstream.token_release.clear()
        with flow.running(), ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(call, flow.port, payload, "/v1/responses")
            assert upstream.token_entered.wait(5)
            second = pool.submit(call, flow.port, payload, "/v1/responses")
            time.sleep(0.15)
            assert len(upstream.tokens) == 1
            upstream.token_release.set()
            assert first.result(timeout=10)[0] == second.result(timeout=10)[0] == 200
    for _ in range(2):
        with flow.running():
            before = len(upstream.requests)
            ambiguous_http_denied(flow.port, payload, "/v1/responses")
            assert len(upstream.requests) == before
            status, raw, _ = call(flow.port, payload, "/v1/responses")
            assert status == 200 and json.loads(raw) == KIMI_RESPONSE
            streaming = dict(payload, stream=True)
            status, raw, incomplete = call(flow.port, streaming, "/v1/responses")
            assert status == 200 and "event: response.completed" in raw and not incomplete
            chat = {"model": KIMI_MODEL, "messages": [{"role": "user", "content": "synthetic"}]}
            status, raw, _ = call(flow.port, chat, "/v1/chat/completions")
            assert status == 200 and json.loads(raw)["choices"][0]["message"]["content"] == "synthetic"
            before = len(upstream.requests)
            for path, rejected in [
                ("/v1/chat/completions", dict(chat, stream=True)),
                ("/v1/responses", dict(payload, tools=[])),
                ("/v1/responses", dict(payload, previous_response_id="unscoped")),
                ("/v1/responses/compact", payload),
                ("/v1/messages", dict(chat, max_tokens=16)),
            ]:
                assert call(flow.port, rejected, path)[0] == 422
                assert len(upstream.requests) == before
            for stream_mode in ("malformed", "disconnect"):
                upstream.stream_mode = stream_mode
                status, raw, incomplete = call(flow.port, streaming, "/v1/responses", allow_incomplete=True)
                assert status == 200 and "event: response.created" in raw
                assert "event: response.completed" not in raw and incomplete
            upstream.stream_mode = "good"
    assert len(upstream.tokens) == (1 if mode == "oauth" else 0)
    for path, headers, body in upstream.requests:
        assert path in ("/operator/kimi/v1/responses", "/operator/kimi/v1/chat/completions")
        assert headers["Host"] == flow.origin.removeprefix("http://")
        assert headers["Authorization"] == ("Bearer synthetic-new-access" if mode == "oauth"
                                            else "Bearer synthetic-kimi-key")
        assert body["model"] == "kimi-for-coding"
        assert CLIENT not in str(headers)
        if mode == "oauth":
            assert headers["X-Msh-Device-Id"] == "a" * 64
    if mode == "oauth":
        assert upstream.token_headers[0]["X-Msh-Device-Id"] == "a" * 64
        assert upstream.tokens[0]["grant_type"] == "refresh_token"
        identity = private(flow.directory / "kimi-identity", json.dumps({"device_id": "b" * 64}))
        flow.cli("credential", "login", str(flow.config), "selected", identity)
        assert len(upstream.devices) == 1
        assert upstream.devices[0][0]["X-Msh-Device-Id"] == "b" * 64
        assert upstream.tokens[-1]["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
        with flow.running():
            assert call(flow.port, payload, "/v1/responses")[0] == 200
            assert upstream.requests[-1][1]["X-Msh-Device-Id"] == "b" * 64
        for failure_mode in ("duplicate", "duplicate429", "disconnect"):
            flow.seed()
            upstream.token_mode = failure_mode
            before_tokens = len(upstream.tokens)
            before_requests = len(upstream.requests)
            for _ in range(2):
                with flow.running():
                    assert call(flow.port, payload, "/v1/responses")[0] == 503
            assert len(upstream.tokens) == before_tokens + 1
            assert len(upstream.requests) == before_requests
        upstream.token_mode = "success"
        upstream.token_entered.clear()
        upstream.token_release.clear()
        flow.seed()
        before = len(upstream.requests)
        with flow.running(), ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(call, flow.port, payload, "/v1/responses")
            assert upstream.token_entered.wait(5)
            flow.cli("credential", "delete", str(flow.config), "selected")
            upstream.token_release.set()
            assert pending.result(timeout=10)[0] == 503
            assert len(upstream.requests) == before
        flow.seed(expired=False)
    with flow.running():
        upstream.stream_mode = "cancel"
        upstream.cancel_seen.clear()
        connection = http.client.HTTPConnection("127.0.0.1", flow.port, timeout=10)
        connection.request("POST", "/v1/responses", json.dumps(dict(payload, stream=True)), {
            "Authorization": f"Bearer {CLIENT}", "Content-Type": "application/json",
        })
        response = connection.getresponse()
        assert response.read(16).startswith(b"event: response.")
        response.close()
        connection.close()
        assert upstream.cancel_seen.wait(5)
        upstream.stream_mode = "good"
        for status in (401, 429):
            upstream.status = status
            before = len(upstream.requests)
            assert call(flow.port, payload, "/v1/responses")[0] == 503
            assert len(upstream.requests) == before + 1
            upstream.status = 200
            if mode == "api_key":
                flow.cli("credential", "import", str(flow.config), "selected", credential_path)
            else:
                flow.seed(expired=False)
        before = len(upstream.requests)
        flow.cli("key", "revoke", str(flow.config), "client")
        assert call(flow.port, payload, "/v1/responses")[0] == 401
        assert len(upstream.requests) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"] if args.shipment
               else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="http-providers-", dir=ROOT / "build/integration") as temp:
        directory = Path(temp)
        directory.chmod(0o700)
        flow = Workflow(directory, command, args.shipment)
        try:
            claude_checks(flow)
            login_checks(flow)
        finally:
            flow.close()
    for mode, domain in (("api_key", "kimi.com"), ("oauth", "kimi.com"), ("oauth", "kimi.ai")):
        with tempfile.TemporaryDirectory(prefix="kimi-http-", dir=ROOT / "build/integration") as temp:
            directory = Path(temp)
            directory.chmod(0o700)
            flow = Workflow(directory, command, args.shipment)
            try:
                kimi_checks(flow, mode, domain)
            finally:
                flow.close()
    print(json.dumps({
        "scope": "assembled_http_provider_cli", "synthetic": True,
        "claude_oauth_sse": True, "refresh_singleflight_restart_cas": True,
        "claude_configured_pkce_login": True,
        "kimi_native_chat_responses_sse_device_refresh_restart": True,
        "byte_boundaries_prefix_cancel": True, "live_provider": False,
        "shipment": bool(args.shipment),
    }))


if __name__ == "__main__":
    main()
