#!/usr/bin/env python3
"""F17 actual source/shipment HTTP enforcement; synthetic numeric loopback only."""

import argparse
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
CLIENTS = ("synthetic-f17-client-one-0001", "synthetic-f17-client-two-0002")
ACCOUNTS = (
    ("synthetic-f17-legacy-api", "grok-4.7", "api_key"),
    ("synthetic-f17-configured-api", "grok-4.6", "api_key"),
    ("synthetic-f17-oauth-proxy", "grok-4.5", "oauth"),
    ("synthetic-f17-oauth-api", "grok-4.3", "oauth"),
)
ACCESS = {model: f"synthetic-f17-access-{index}" for index, (_, model, _) in enumerate(ACCOUNTS)}
REFRESH = {model: f"synthetic-f17-refresh-{index}" for index, (_, model, _) in enumerate(ACCOUNTS)}
ROTATED = {model: f"synthetic-f17-rotated-{index}" for index, (_, model, _) in enumerate(ACCOUNTS)}
SECRETS = (*CLIENTS, *ACCESS.values(), *REFRESH.values(), *ROTATED.values())
PRIOR = "resp_synthetic_f17"
COMPACT = "compact_synthetic_f17"
ARGUMENTS = '{"previous_response_id":"user-content","literal":"clientfn_web_search"}'


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def no_secrets(raw):
    assert all(secret.encode() not in raw for secret in SECRETS), "synthetic credential exposed"


def native_sse(model):
    response = {"object": "response", "id": PRIOR, "model": model,
                "status": "in_progress", "output": []}
    item = {"type": "function_call", "id": "item_synthetic_f17",
            "call_id": "call_synthetic_f17", "name": "clientfn_web_search",
            "arguments": ARGUMENTS, "status": "completed"}
    events = [
        {"type": "response.created", "response": response},
        {"type": "response.output_item.added", "output_index": 0, "item": item},
        {"type": "response.function_call_arguments.done", "output_index": 0,
         "item_id": item["id"], "arguments": ARGUMENTS},
        {"type": "response.output_item.done", "output_index": 0, "item": item},
        {"type": "response.completed", "response": dict(
            response, status="completed", output=[item],
            usage={"input_tokens": 3, "output_tokens": 2, "total_tokens": 5})},
    ]
    return b"".join(b"event: " + event["type"].encode() + b"\ndata: "
                    + encoded(event) + b"\n\n" for event in events)


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        with self.server.lock:
            self.server.requests.append({"path": self.path})
            self.server.errors.append("unexpected discovery or provider GET")
        self.reply(500, {"error": "unexpected synthetic GET"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            if self.server.role == "token":
                self.refresh(raw)
            else:
                self.inference(raw)
        except (AssertionError, KeyError, ValueError):
            with self.server.lock:
                self.server.errors.append("synthetic request contract failed")
            self.reply(500, {"error": "synthetic request contract failed"})

    def refresh(self, raw):
        model = self.path.removeprefix("/token/")
        fields = parse_qs(raw.decode(), strict_parsing=True)
        with self.server.lock:
            # Never retain token form values, authorization or raw headers.
            self.server.requests.append({"path": self.path, "refresh": True})
        assert model in REFRESH and self.path == "/token/" + model
        assert fields["grant_type"] == ["refresh_token"]
        assert fields["refresh_token"] == [REFRESH[model]]
        assert set(fields) == {"client_id", "grant_type", "refresh_token"}
        assert self.headers.get("Authorization") is None
        self.server.fixture.accepted[model] = ROTATED[model]
        self.reply(200, {"access_token": ROTATED[model],
                         "refresh_token": REFRESH[model], "expires_in": 3600})

    def inference(self, raw):
        body = json.loads(raw)
        model = body["model"]
        key_ok = self.headers.get("Authorization") == "Bearer " + self.server.fixture.accepted[model]
        assert key_ok
        assert model in self.server.models
        assert self.path in ("/v1/responses", "/v1/responses/compact")
        with self.server.lock:
            self.server.requests.append({
                "path": self.path, "body": body, "key_ok": key_ok,
                "accept": self.headers.get("Accept"),
                "conversation": self.headers.get("x-grok-conv-id"),
                "proxy_identity": self.headers.get("X-XAI-Token-Auth") is not None,
            })
        assert "previous_response_id" not in body
        if self.path == "/v1/responses/compact":
            assert self.server.role != "proxy"
            assert all(key not in body for key in ("stream", "tools", "tool_choice"))
            self.reply(200, {"object": "response.compaction", "id": COMPACT, "output": [],
                             "usage": {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5}})
        else:
            assert body["stream"] is True
            self.reply(200, native_sse(model), "text/event-stream")

    def reply(self, status, value, media="application/json"):
        self.close_connection = True
        data = value if isinstance(value, bytes) else encoded(value)
        self.send_response(status)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


class Peer(ThreadingHTTPServer):
    """Count TCP accepts as well as HTTP requests, including refresh traffic."""
    daemon_threads = True

    def __init__(self, fixture, role, models=()):
        self.fixture, self.role, self.models = fixture, role, models
        self.lock = threading.Lock()
        self.connections, self.requests, self.errors = 0, [], []
        super().__init__(("127.0.0.1", 0), Upstream)

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"

    def get_request(self):
        peer = super().get_request()
        with self.lock:
            self.connections += 1
        return peer

    def snapshot(self):
        with self.lock:
            return self.connections, len(self.requests)


def payload(model, streaming=False):
    return {
        "model": model, "input": "synthetic first turn", "stream": streaming,
        "tools": [{"type": "function", "name": "web_search",
                   "parameters": {"type": "object"}}],
        "tool_choice": {"type": "function", "name": "web_search"},
    }


def call(port, body, path="/v1/responses", key=CLIENTS[0], session="synthetic-session"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if key is not None:
        headers["Authorization"] = "Bearer " + key
    if session is not None:
        headers["x-client-request-id"] = session
    try:
        connection.request("POST", path, body if isinstance(body, bytes) else encoded(body), headers)
        response = connection.getresponse()
        raw = response.read()
        no_secrets(raw)
        return response.status, response.getheader("Content-Type", ""), raw
    finally:
        connection.close()


def assert_denied(status, media, raw, before, after, expected=422):
    """Neither an accepting fixture nor an HTTP-only counter is denial proof."""
    assert status == expected, f"expected sanitized {expected}, got {status}"
    assert "application/json" in media and "text/event-stream" not in media
    error = json.loads(raw)
    assert "error" in error and "output" not in error
    assert after == before, "denial connected to inference or OAuth"


class Fixture:
    def __init__(self, directory, command, source):
        self.directory, self.command = directory, command
        self.cwd = ROOT if source else directory
        self.env = {"PATH": os.environ["PATH"], "HOME": str(directory),
                    "TMPDIR": str(directory), "ERL_FLAGS": "+S 2:2 +A 2"}
        self.accepted = dict(ACCESS)
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        self.config = directory / "providers.json"
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        self.legacy = Peer(self, "legacy-api", ["grok-4.7"])
        self.api = Peer(self, "configured-api", ["grok-4.6", "grok-4.5"])
        self.proxy = Peer(self, "proxy", ["grok-4.5"])
        self.oauth_api = Peer(self, "oauth-api", ["grok-4.3"])
        self.token = Peer(self, "token")
        self.peers = [self.legacy, self.api, self.proxy, self.oauth_api, self.token]
        self.workers = []
        self.denials, self.expired_denials, self.positives = 0, 0, 0
        accounts = []
        for index, (account, model, mode) in enumerate(ACCOUNTS):
            ordinary = [self.legacy, self.api, self.proxy, self.oauth_api][index]
            compact = self.api if ordinary is self.proxy else ordinary
            value = {"provider": "xai", "auth_mode": mode, "id": account,
                     "origin": ordinary.origin if mode == "api_key" else self.token.origin,
                     "models": [model]}
            if index != 0:
                value["xai_operations"] = [
                    {"protocol": "responses", "operation": "responses",
                     "base": ordinary.origin + "/v1", "using_api": ordinary is not self.proxy},
                    {"protocol": "responses", "operation": "responses/compact",
                     "base": compact.origin + "/v1", "using_api": True},
                ]
            if mode == "oauth":
                value["oauth"] = {"discovery_url": self.token.origin + "/discovery/" + model}
            accounts.append(value)
        self.config.write_text(json.dumps({
            "version": 1, "state_dir": str(self.state), "listen_port": self.port,
            "accounts": accounts,
        }))
        self.config.chmod(0o600)

    def cli(self, *arguments):
        completed = subprocess.run([*self.command, *arguments], cwd=self.cwd, env=self.env,
                                   capture_output=True, timeout=90, check=False)
        output = completed.stdout + completed.stderr
        no_secrets(output)
        assert completed.returncode == 0, (
            "synthetic CLI command failed: " + " ".join(arguments[:3])
            + "\n" + output.decode(errors="replace")
        )

    def seed(self):
        for account, model, mode in ACCOUNTS:
            value = {"api_key": ACCESS[model]} if mode == "api_key" else {
                "access_token": ACCESS[model], "refresh_token": REFRESH[model],
                "expires_at_ms": int(time.time() * 1000) - 60_000,
                "token_endpoint": self.token.origin + "/token/" + model,
            }
            private = BASE["private_file"](self.directory / (account + ".json"), json.dumps(value))
            self.cli("providers", "credential", "import", str(self.config), account, private)
        for index, key in enumerate(CLIENTS):
            private = BASE["private_file"](self.directory / f"client-{index}.txt", key + "\n")
            self.cli("providers", "key", "import", str(self.config), f"synthetic-client-{index}", private)
        assert all(peer.snapshot() == (0, 0) for peer in self.peers), "seeding used network"

    def snapshot(self):
        return [peer.snapshot() for peer in self.peers]

    def deny(self, body, path="/v1/responses", key=CLIENTS[0],
             session="synthetic-session", expected=422):
        before = self.snapshot()
        status, media, raw = call(self.port, body, path, key, session)
        assert_denied(status, media, raw, before, self.snapshot(), expected)
        self.denials += 1

    @contextlib.contextmanager
    def gateway(self, phase):
        path = self.directory / f"gateway-{phase}.log"
        with path.open("xb") as log:
            process = subprocess.Popen(
                [*self.command, "serve", "providers", str(self.config)], cwd=self.cwd,
                env=self.env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 90
                while True:
                    assert process.poll() is None, "gateway exited before readiness"
                    try:
                        if call(self.port, {}, "/v1/responses", key=None)[0] == 401:
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    assert time.monotonic() < deadline, "gateway readiness deadline"
                    time.sleep(0.05)
                yield
            finally:
                try:
                    BASE["stop"](process, self.state)
                finally:
                    log.flush()
                    no_secrets(path.read_bytes())

    def positive(self, model, streaming=False, history=None, extension=False, compact=False):
        index = next(index for index, (_, candidate, _) in enumerate(ACCOUNTS) if model == candidate)
        peer = [self.legacy, self.api, self.proxy, self.oauth_api][index]
        body = {"model": model, "input": "synthetic compact"} if compact else payload(model, streaming)
        if history is not None:
            body["input"] = history
        if extension:
            body["vendor_extension"] = {"previous_response_id": {"synthetic-user-data": True}}
        if compact and peer is self.proxy:
            peer = self.api
        path = "/v1/responses/compact" if compact else "/v1/responses"
        before = peer.snapshot()
        status, media, raw = call(self.port, body, path)
        assert status == 200, f"stateless positive failed: status {status}"
        if streaming:
            assert "text/event-stream" in media
            events = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith(b"data: ")]
            assert events[-1]["type"] == "response.completed"
            response = events[-1]["response"]
        else:
            assert "application/json" in media
            response = json.loads(raw)
        assert response["id"] == (COMPACT if compact else PRIOR)
        if not compact:
            item = response["output"][0]
            assert item["name"] == "web_search" and item["arguments"] == ARGUMENTS
            assert response["model"] == model
            assert response["usage"]["total_tokens"] == 5
        assert peer.snapshot() == (before[0] + 1, before[1] + 1)
        wire = peer.requests[-1]
        assert wire["path"] == path and wire["key_ok"] and not wire["proxy_identity"]
        # A loopback proxy role is an operation-policy fixture, not official
        # CLI proxy hostname/header or TLS fingerprint qualification.
        assert wire["conversation"] == wire["body"]["prompt_cache_key"]
        scope = json.loads(wire["body"]["prompt_cache_key"])
        assert json.loads(scope[0]) == ["xai", ACCOUNTS[index][2], ACCOUNTS[index][0]]
        assert scope[1].endswith(":synthetic-session"), "actual session hint was ignored"
        if history is not None:
            expected = [dict(history[0], name="clientfn_web_search"), history[1]]
            assert wire["body"]["input"] == expected
        if extension:
            assert wire["body"]["vendor_extension"] == body["vendor_extension"]
        self.positives += 1
        if not compact:
            return [response["output"][0], {
                "type": "function_call_output", "call_id": "call_synthetic_f17",
                "output": "synthetic result",
            }]

    def exercise(self):
        # Expired OAuth credentials exist durably before the first request.
        # Negative requests must not acquire them, refresh or contact a peer.
        with self.gateway("first"):
            for _, model, mode in ACCOUNTS:
                if mode != "oauth":
                    continue
                for previous in (None, "", PRIOR, "resp_synthetic_ws"):
                    for streaming in (False, True):
                        self.deny(dict(payload(model, streaming), previous_response_id=previous))
                        self.expired_denials += 1
                    self.deny({"model": model, "input": "synthetic compact",
                               "previous_response_id": previous}, "/v1/responses/compact")
                    self.expired_denials += 1
            time.sleep(0.1)
            assert all(peer.snapshot() == (0, 0) for peer in self.peers), "expired denial refreshed"

            histories = {}
            for _, model, _ in ACCOUNTS:
                histories[model] = self.positive(model)
                self.positive(model, streaming=True)
                self.positive(model, history=histories[model], extension=True)
                self.positive(model, compact=True)
            assert self.token.snapshot() == (2, 2), "expired stateless controls must actually refresh"

            for _, model, _ in ACCOUNTS:
                for key in CLIENTS:
                    for previous in (PRIOR, COMPACT, "resp_synthetic_ws", "unknown", None, "", 1, {}):
                        for streaming in (False, True):
                            self.deny(dict(payload(model, streaming), previous_response_id=previous), key=key)
                        self.deny({"model": model, "input": "synthetic compact",
                                   "previous_response_id": previous}, "/v1/responses/compact", key=key)
                    for hint in (None, "changed-session"):
                        self.deny(dict(payload(model), input=histories[model],
                                       previous_response_id=PRIOR, continuation={
                                           "tenant": "client-claim", "account": "client-claim",
                                           "revision": "client-claim", "history": histories[model],
                                       }), key=key, session=hint)
                duplicate = (b'{"model":' + encoded(model)
                             + b',"input":"synthetic","previous_response_id":"one",'
                             + b'"\\u0070revious_response_id":"two"}')
                self.deny(duplicate, expected=400)
                escaped = (b'{"model":' + encoded(model)
                           + b',"input":"synthetic","\\u0070revious_response_id":null}')
                self.deny(escaped)
                self.deny(dict(payload(model), previous_response_id=PRIOR), key=None, expected=401)
                self.deny(dict(payload(model), input=[{
                    "type": "function_call_output", "call_id": "orphan",
                    "output": "synthetic result",
                }], previous_response_id=PRIOR))
                self.deny(payload(model, True), "/v1/responses/compact")
                self.deny(payload(model), "/v1/chat/completions")
                self.positive(model, history=histories[model])

        # Restart the actual root VM without reseeding. Old ids are still
        # denied before a new first turn; they are never receipt authority.
        with self.gateway("restart"):
            for _, model, _ in ACCOUNTS:
                self.deny(dict(payload(model), previous_response_id=PRIOR))
                self.positive(model, history=histories[model])
                self.positive(model, compact=True)
        assert self.token.snapshot() == (2, 2), "denials or restart triggered another refresh"
        assert all(not peer.errors for peer in self.peers), "synthetic peer contract failed"

    def __enter__(self):
        for peer in self.peers:
            worker = threading.Thread(target=peer.serve_forever, daemon=True)
            worker.start()
            self.workers.append(worker)
        return self

    def __exit__(self, *_):
        for peer in self.peers:
            peer.shutdown()
            peer.server_close()
        for worker in self.workers:
            worker.join(timeout=5)
            assert not worker.is_alive(), "synthetic peer did not shut down"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path, help="exported shipment, run from a different cwd")
    args = parser.parse_args()
    if args.shipment:
        command = ["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
    else:
        gleam = os.environ.get("GLEAM", "gleam")
        version = subprocess.run([gleam, "--version"], capture_output=True, check=True, timeout=10)
        assert version.stdout.decode().strip() == "gleam 1.18.1", "use pinned Gleam 1.18.1"
        command = [gleam, "run", "--"]
    integration = ROOT / "build/integration"
    integration.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f17-http-", dir=integration) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        with Fixture(directory, command, source=args.shipment is None) as fixture:
            fixture.seed()
            fixture.exercise()
            print(json.dumps({
                "scope": "F17 actual shipment HTTP enforcement" if args.shipment else "F17 actual source HTTP enforcement",
                "synthetic_only": True, "http_continuation_supported": False,
                "denied_requests": fixture.denials, "expired_oauth_zero_io_denials": fixture.expired_denials,
                "stateless_positive_requests": fixture.positives,
                "inference_tcp_connections": sum(peer.snapshot()[0] for peer in fixture.peers[:-1]),
                "inference_http_requests": sum(peer.snapshot()[1] for peer in fixture.peers[:-1]),
                "oauth_refresh_tcp_connections": fixture.token.snapshot()[0],
                "oauth_refresh_http_requests": fixture.token.snapshot()[1],
                "negative_tcp_or_http_delta": 0, "restart_without_reseed": True,
                "differential": False, "native_client": False, "live": False,
                "real_ws_receipt_exercised": False,
            }))


if __name__ == "__main__":
    main()
