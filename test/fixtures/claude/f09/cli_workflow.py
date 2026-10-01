#!/usr/bin/env python3
"""F09 actual root CLI workflow; synthetic loopback only, no provider/CPA calls.

Run --default before root policy admission. Without it, require the parent's
actual typed policy/config wiring. --shipment exercises an existing export;
this runner never builds/exports a shipment or launches another service.
"""

import argparse
from contextlib import contextmanager
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[4]
MODEL = "haiku-team/future-model"
CLIENTS = ("synthetic-f09-cli-client-a-123456", "synthetic-f09-cli-client-b-123456")
COUNT = {"input_tokens": 137, "future": "synthetic-endpoint-response"}
SOURCE = {
    "model": MODEL,
    "system": "synthetic",
    "messages": [{"role": "user", "content": "λ"}],
    "tools": [{"type": " Advisor_synthetic ", "future": True}],
    "thinking": {"type": "adaptive", "budget_tokens": 1024, "future": True},
    "tool_choice": {"type": "tool", "name": "synthetic"},
    "output_config": {"effort": "high", "future": 7},
    "temperature": 0.4,
    "top_p": 0.2,
    "top_k": 3,
    "speed": "fast",
    "betas": ["future-body"],
    "max_tokens": 20,
    "metadata": {"future": True},
    "context_management": {},
    "diagnostics": {},
}


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def private(path, value):
    path.write_bytes(value if isinstance(value, bytes) else encode(value))
    path.chmod(0o600)
    return path


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        # Synthetic observations stay in memory, never serialized into logs.
        self.server.observations.append((self.path, list(self.headers.items()), raw, body))
        if self.path == "/v1/messages/count_tokens?beta=true":
            payload, media = encode(COUNT), "application/json"
        elif body.get("stream"):
            payload = (
                b'event: message_start\ndata: {"type":"message_start","message":'
                + encode({"model": body["model"], "usage": {"input_tokens": 7}})
                + b'}\n\nevent: message_stop\ndata: {"type":"message_stop"}\n\n'
            )
            media = "text/event-stream"
        else:
            payload = encode({"type": "message", "content": [{"type": "text", "text": "synthetic"}]})
            media = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


@contextmanager
def upstream():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    server.daemon_threads = True
    server.observations = []
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        assert not worker.is_alive(), "synthetic upstream failed to stop"


class Runner:
    def __init__(self, command, evidence):
        self.command, self.evidence = command, evidence
        self.deadline, self.index = time.monotonic() + 180, 0

    def spawn(self, *args):
        self.index += 1
        log = self.evidence / f"process-{self.index:02d}.log"
        with log.open("wb") as output:
            process = subprocess.Popen(
                [*self.command, *map(str, args)], cwd=ROOT, stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True,
                env={**os.environ, "ERL_FLAGS": "+S 2:2 +A 2"},
            )
        return process

    def remaining(self):
        left = self.deadline - time.monotonic()
        assert left > 0, "F09 CLI workflow lifetime exceeded"
        return min(left, 45)

    @staticmethod
    def stop(process):
        # Kill the owned group even if a wrapper leader has already exited.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
            raise AssertionError("F09 child failed graceful shutdown")
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run(self, *args):
        process = self.spawn(*args)
        try:
            assert process.wait(timeout=self.remaining()) == 0, "root CLI command failed"
        finally:
            self.stop(process)

    @contextmanager
    def serving(self, config, port, state):
        process = self.spawn("serve", "providers", config)
        try:
            deadline = time.monotonic() + self.remaining()
            while time.monotonic() < deadline:
                assert process.poll() is None, "root CLI exited before readiness"
                try:
                    if request(port, "GET", "/v1/models", key=None)[0] == 401:
                        break
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.05)
            else:
                raise AssertionError("root CLI readiness deadline exceeded")
            yield
        finally:
            self.stop(process)
            deadline = time.monotonic() + 5
            while (state / ".provider-runtime-owner").exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            assert not (state / ".provider-runtime-owner").exists(), "runtime owner guard leaked"


def request(port, method, path, source=None, key=CLIENTS[0], hints=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json", "x-client-request-id": "synthetic-cli-correlation"}
    if key is not None:
        headers["Authorization"] = "Bearer " + key
    if hints:
        headers.update({
            "User-Agent": "synthetic-unapproved-client",
            "X-App": "synthetic-unapproved-app",
            "X-Claude-Code-Agent-Type": "synthetic-unapproved-helper",
            "Anthropic-Beta": "synthetic-unapproved-beta",
            "X-Claude-Code-Session-Id": "synthetic-unapproved-session",
        })
    try:
        connection.request(method, path, None if source is None else encode(source), headers)
        response = connection.getresponse()
        body = response.read()
        assert all(key.encode() not in body for key in CLIENTS), "client credential leaked"
        return response.status, body
    finally:
        connection.close()


def auth_prefix(auth, code=False):
    return ("claude-code-20250219," if code else "") + ("oauth-2025-04-20," if auth == "oauth" else "")


def check_wire(observation, auth, account, client, op, selected, configured):
    path, header_list, raw, body = observation
    headers = {k.lower(): v for k, v in header_list}
    expected = json.loads(encode(SOURCE))
    expected.pop("betas")
    if op == "count":
        for field in ("stream", "max_tokens", "metadata", "context_management", "diagnostics"):
            expected.pop(field, None)
    else:
        if op == "sse":
            expected["stream"] = True
        expected.pop("thinking")
        expected["output_config"].pop("effort")
        expected.pop("top_p")
        if selected != "native":
            expected.pop("temperature")
        if selected in ("5m", "1h"):
            control = {"type": "ephemeral"}
            if selected == "1h":
                control["ttl"] = "1h"
            expected["system"] = [{"type": "text", "text": "synthetic", "cache_control": control}]
            expected["messages"][0]["content"] = [{"type": "text", "text": "λ", "cache_control": control}]
    actual = json.loads(encode(body))
    if auth == "oauth" and op != "count":
        user = json.loads(actual["metadata"].pop("user_id"))
        assert user["device_id"] == account * 64
        assert user["account_uuid"] == "synthetic-account-" + account
        assert user["session_id"] == headers["x-claude-code-session-id"]
    assert actual == expected, "upstream body differs from fixed F09 expectation"
    identity, correlation = json.loads(headers["x-claude-code-session-id"])
    assert json.loads(identity) == ["claude", auth, account]
    assert correlation.endswith(":synthetic-cli-correlation")
    assert client not in raw.decode(), "downstream auth forwarded"
    assert headers.get("user-agent") != "synthetic-unapproved-client"
    assert headers.get("x-app") != "synthetic-unapproved-app"
    assert headers.get("x-claude-code-agent-type") != "synthetic-unapproved-helper"
    assert headers.get("x-claude-code-session-id") != "synthetic-unapproved-session"
    assert int(headers["content-length"]) == len(raw)
    token = "synthetic-provider-" + account
    assert headers.get("authorization") == ("Bearer " + token if auth == "oauth" else None)
    assert headers.get("x-api-key") == (token if auth == "api_key" else None)
    expected_beta = auth_prefix(auth)
    if configured and selected == "native":
        # P2: advisor positioned before fallback trailer, then P3 removes it.
        expected_beta += "future-header,advisor-tool-2026-03-01,future-b,fast-mode-2026-02-01,future-body"
    elif op == "count" and selected != "native":
        expected_beta = auth_prefix(auth, code=True) + "interleaved-thinking-2025-05-14,context-management-2025-06-27,token-counting-2024-11-01,advisor-tool-2026-03-01,future-approved,future-body"
    else:
        expected_beta += ("future-approved," if configured else "") + "advisor-tool-2026-03-01,fast-mode-2026-02-01,future-body"
    if op == "count" and selected == "native":
        expected_beta += ",token-counting-2024-11-01"
    if op != "count" and selected == "1h":
        expected_beta += ",extended-cache-ttl-2025-04-11"
    assert headers["anthropic-beta"] == expected_beta, "upstream beta stage order differs"
    assert path == ("/v1/messages/count_tokens?beta=true" if op == "count" else "/v1/messages?beta=true")
    return headers


def exercise(runner, state, auth, rows, servers, configured):
    state.mkdir(mode=0o700)
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    accounts = []
    for (account, selected), server in zip(rows, servers):
        origin = f"http://127.0.0.1:{server.server_port}"
        value = {"provider": "claude", "auth_mode": auth, "id": account, "origin": origin, "models": [MODEL]}
        if auth == "oauth":
            value["oauth"] = {"client_id": "synthetic", "authorize_url": origin + "/authorize", "token_url": origin + "/token", "redirect_uri": "http://127.0.0.1:9876/callback"}
        if configured:
            value["claude_policy"] = {"input": "native" if selected == "native" else "translated", "turn": "conversation", "cache": "preserve" if selected == "native" else selected}
            value["claude_client_headers"] = [["X-App", "synthetic-profile-" + account], ["anthropic-beta", "future-header,server-side-fallback-2026-06-01,future-b,advisor-tool-2026-03-01" if selected == "native" else "future-approved"]]
        accounts.append(value)
    config = private(state / "config.json", {"version": 1, "state_dir": str(state), "listen_port": port, "accounts": accounts})
    for account, _ in rows:
        grant = {"api_key": "synthetic-provider-" + account} if auth == "api_key" else {
            "access_token": "synthetic-provider-" + account, "refresh_token": "synthetic-refresh-" + account,
            "expires_at_ms": 4102444800000, "account_uuid": "synthetic-account-" + account, "device_id": account * 64,
        }
        credential = private(state / (account + ".json"), grant)
        runner.run("providers", "credential", "import", config, account, credential)
    for index, client in enumerate(CLIENTS[:len(rows)]):
        runner.run("providers", "key", "import", config, "client-" + str(index), private(state / f"client-{index}.key", client.encode()))
    successes, negatives = 0, 0
    sessions, request_ids = {}, set()
    with runner.serving(config, port, state):
        for op in ("messages", "sse", "count"):
            path = "/v1/messages/count_tokens" if op == "count" else "/v1/messages"
            source = {**SOURCE, **({"stream": True} if op == "sse" else {})}
            before = sum(len(s.observations) for s in servers)
            assert request(port, "POST", path, source, key=None)[0] == 401
            assert sum(len(s.observations) for s in servers) == before
            negatives += 1
            for index in ([0, 1, 0] if len(rows) == 2 else [0, 0]):
                account, selected = rows[index]
                server, client = servers[index], CLIENTS[index]
                before = [len(s.observations) for s in servers]
                status, payload = request(port, "POST", path, source, key=client, hints=successes % 2 == 0)
                assert status == 200, "root inference route did not succeed"
                if op == "count":
                    assert json.loads(payload) == COUNT, "count did not return configured upstream response"
                elif op == "sse":
                    assert b"message_start" in payload and b"message_stop" in payload
                    assert MODEL.encode() in payload, "F14 selected model seam not preserved"
                assert [len(s.observations) for s in servers] == [n + (i == index) for i, n in enumerate(before)]
                headers = check_wire(server.observations[-1], auth, account, client, op, selected, configured)
                if configured:
                    assert headers["x-app"] == "synthetic-profile-" + account
                session = headers["x-claude-code-session-id"]
                assert sessions.setdefault(account, session) == session
                assert headers["x-client-request-id"] not in request_ids
                request_ids.add(headers["x-client-request-id"])
                successes += 1
        if len(rows) == 2:
            assert sessions[rows[0][0]] != sessions[rows[1][0]]
    return successes, negatives


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--default", action="store_true", help="native/default gate only; no root policy admission claim")
    parser.add_argument("--shipment", type=Path, help="already exported shipment to test")
    args = parser.parse_args()
    command = ["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"] if args.shipment else [os.environ.get("GLEAM") or "gleam", "run", "--"]
    (ROOT / "build/f09").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cli-", dir=ROOT / "build/f09") as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        # Keep sanitized process logs outside private credential state.
        evidence = ROOT / "build/f09" / ("cli-default" if args.default else "cli-configured")
        evidence.mkdir(exist_ok=True)
        runner = Runner(command, evidence)
        successes, negatives = 0, 0
        for auth in ("api_key", "oauth"):
            with upstream() as a, upstream() as b:
                rows = [("a", "native")] if args.default else [("a", "native"), ("b", "5m")]
                counts = exercise(runner, directory / auth, auth, rows, [a, b][:len(rows)], not args.default)
                successes += counts[0]
                negatives += counts[1]
        if not args.default:
            with upstream() as a:
                counts = exercise(runner, directory / "one-hour", "oauth", [("a", "1h")], [a], True)
                successes += counts[0]
                negatives += counts[1]
        for log in evidence.glob("process-*.log"):
            text = log.read_bytes()
            for marker in (*CLIENTS, "synthetic-provider-a", "synthetic-provider-b", "synthetic-refresh-a", "synthetic-refresh-b"):
                assert marker.encode() not in text, "synthetic credential leaked to CLI logs"
        print(f"PASS F09 actual {'shipment' if args.shipment else 'source'} CLI: {successes} successful, {negatives} unauthenticated pre-I/O rejections; {'default only' if args.default else 'configured policy + selected-account isolation'}; synthetic only")


if __name__ == "__main__":
    main()
