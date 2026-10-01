#!/usr/bin/env python3
"""F18 actual authenticated root WS/WSS source/shipment gate, synthetic only.

Requires parent-owned root dispatch/terminal integration and qualified F13
transport. No CPA, native client, live provider, enrollment, or host trust edits.
"""

import argparse
import base64
import contextlib
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
F13 = runpy.run_path(str(ROOT / "scripts/smoke-codex-ws-lite.py"))
Reader, frame = F13["Reader"], F13["frame"]
CLIENT = "synthetic-f18-client-one"
SECOND = "synthetic-f18-client-two"
ACCESS = "synthetic-f18-provider-access"
ROTATED = "synthetic-f18-provider-rotated"
REFRESH = "synthetic-f18-provider-refresh"
CODEX_ACCESS = "synthetic-f18-codex-access"
CODEX_REFRESH = "synthetic-f18-codex-refresh"
SECRETS = (CLIENT, SECOND, ACCESS, ROTATED, REFRESH, CODEX_ACCESS, CODEX_REFRESH)
API_MODEL, OAUTH_MODEL, PROXY_MODEL = "grok-4.7", "grok-4.6", "grok-4.5"
CODEX_MODEL = "gpt-5.5"
ARGUMENTS = '{"literal":"shell__run and clientfn_web_search"}'


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def no_secrets(raw):
    assert all(value.encode() not in raw for value in SECRETS), "credential exposure"


def create(model=API_MODEL, previous=None, tools=False, **extra):
    value = {"type": "response.create", "model": model, "input": []}
    if previous is not None:
        value["previous_response_id"] = previous
    if tools:
        value["tools"] = [
            {"type": "namespace", "name": namespace, "tools": [
                {"type": "function", "name": "run", "parameters": {"type": "object"}},
            ]} for namespace in ("shell", "other")
        ] + [{"type": "function", "name": "web_search", "parameters": {"type": "object"}}]
    return dict(value, **extra)


def events(body, receipt, mode):
    response = {"object": "response", "id": receipt, "model": body["model"],
                "status": "in_progress", "output": []}
    result = [{"type": "response.created", "response": response}]
    output = []
    if body.get("tools"):
        names = ("shell__run", "clientfn_web_search")
        for index, name in enumerate(names):
            item = {"type": "function_call", "id": f"item_{receipt}_{index}",
                    "call_id": f"call_{receipt}_{index}", "name": name,
                    "arguments": "", "status": "in_progress"}
            result.append({"type": "response.output_item.added",
                           "output_index": index, "item": dict(item)})
            result.append({"type": "response.function_call_arguments.done",
                           "output_index": index, "item_id": item["id"],
                           "call_id": item["call_id"],
                           "name": "other__run" if mode == "identity" and index == 0 else name,
                           "arguments": ARGUMENTS})
            item.update(arguments=ARGUMENTS, status="completed")
            result.append({"type": "response.output_item.done",
                           "output_index": index, "item": dict(item)})
            output.append(item)
    if mode == "error":
        result.append({"type": "error", "error": {"message": ACCESS, "code": "synthetic"}})
    elif mode in ("failed", "incomplete", "cancelled"):
        result.append({"type": "response." + mode, "response": dict(
            response, status=mode, output=output, error={"message": ACCESS})})
    else:
        result.append({"type": "response.completed", "response": dict(
            response, status="completed", output=output,
            usage={"input_tokens": 3, "output_tokens": 2, "total_tokens": 5})})
    encoded = [compact(event) for event in result]
    if mode == "malformed":
        encoded = encoded[:-1] + ['{"type":"response.completed","type":"error"}']
    return encoded


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        peer, reader = self.server, Reader(self.request)
        self.request.settimeout(10)
        socket_id = None
        observed_close = False
        try:
            raw = reader.headers()
            lines = raw.split("\r\n")
            pairs = [line.split(":", 1) for line in lines[1:]]
            headers = {name.lower(): value.strip() for name, value in pairs}
            assert lines[0] == "GET /v1/responses HTTP/1.1"
            assert len(headers) == len(pairs), "duplicate upstream header"
            assert headers.get("authorization") == "Bearer " + peer.accepted
            assert all(name not in headers for name in (
                "origin", "sec-websocket-extensions", "sec-websocket-protocol",
                "x-xai-token-auth",
            )), "wrong provider identity or unsupported negotiation"
            if peer.provider == "xai":
                assert "chatgpt-account-id" not in headers, "Codex identity sent to xAI"
            else:
                assert headers.get("chatgpt-account-id") == "synthetic-f18-codex-account"
            with peer.lock:
                socket_id = len(peer.handshakes)
                closed = threading.Event()
                # Never retain authorization, raw headers or credential values.
                peer.handshakes.append({"closed": closed, "auth_ok": True,
                                        "path": lines[0], "conversation":
                                        headers.get("x-grok-conv-id")})
                mode, gate = peer.mode, peer.gate
            if mode == "acquire":
                peer.entered.set()
                assert gate.wait(10), "synthetic acquisition gate deadline"
            accept = base64.b64encode(hashlib.sha1(
                (headers["sec-websocket-key"] +
                 "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if mode == "bad-accept":
                accept = "synthetic-invalid"
            extra = ("Sec-WebSocket-Extensions: permessage-deflate\r\n"
                     if mode == "compression" else "")
            self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                                 "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                 f"Sec-WebSocket-Accept: {accept}\r\n{extra}\r\n").encode())
            while True:
                opcode, payload = reader.event(True)
                if opcode == 8:
                    observed_close = True
                    return
                body = json.loads(payload)
                assert body["type"] == "response.create"
                assert body["store"] is (peer.provider == "xai")
                assert "stream" not in body and "background" not in body
                with peer.lock:
                    mode, gate = peer.mode, peer.gate
                    receipt = "resp_synthetic_f18_" + str(len(peer.creates))
                    peer.creates.append((socket_id, body, receipt))
                data = events(body, receipt, mode)
                if mode in ("hold", "cancel"):
                    self.request.sendall(frame(data[0]))
                    peer.entered.set()
                    assert gate.wait(10), "synthetic terminal gate deadline"
                    if mode == "cancel":
                        # Cancellation must close; timeout is a gate failure.
                        opcode, _ = reader.event(True)
                        assert opcode == 8, "cancelled provider received another create"
                        observed_close = True
                        return
                    data = data[1:]
                # One physical write deliberately contains a valid prefix and
                # a later malformed event when that scenario is selected.
                self.request.sendall(b"".join(frame(value) for value in data))
        except (EOFError, ConnectionResetError, BrokenPipeError):
            observed_close = True
        except Exception as error:
            with peer.lock:
                peer.errors.append(type(error).__name__)
        finally:
            if socket_id is not None and observed_close:
                peer.handshakes[socket_id]["closed"].set()


class Peer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = False

    def __init__(self, tls=None, provider="xai"):
        self.tls = tls
        self.provider = provider
        self.lock = threading.Lock()
        self.handshakes, self.creates, self.errors = [], [], []
        self.connections = 0
        self.accepted = ACCESS if provider == "xai" else CODEX_ACCESS
        self.mode = "normal"
        self.gate, self.entered = threading.Event(), threading.Event()
        self.gate.set()
        super().__init__(("127.0.0.1", 0), Handler)

    @property
    def origin(self):
        return ("https" if self.tls else "http") + f"://127.0.0.1:{self.server_address[1]}"

    def get_request(self):
        sock, address = super().get_request()
        with self.lock:
            self.connections += 1
        if self.tls:
            try:
                sock = self.tls.wrap_socket(sock, server_side=True)
            except Exception:
                sock.close()
                raise
        return sock, address

    def select(self, mode):
        with self.lock:
            self.mode = mode
            self.entered.clear()
            self.gate = threading.Event()
            if mode not in ("hold", "cancel", "acquire"):
                self.gate.set()

    def snapshot(self):
        with self.lock:
            return self.connections, len(self.handshakes), len(self.creates)


class TokenHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        self.server.errors.append("unexpected-discovery")
        self.reply(500, {"error": "synthetic unexpected discovery"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            fields = parse_qs(raw.decode(), strict_parsing=True)
            assert self.path == "/token"
            assert fields["grant_type"] == ["refresh_token"]
            assert fields["refresh_token"] == [REFRESH]
            self.server.refreshes += 1
            self.reply(200, {"access_token": ACCESS, "refresh_token": REFRESH,
                             "expires_in": 3600})
        except (AssertionError, ValueError, KeyError):
            self.server.errors.append("unexpected-http-fallback")
            self.reply(500, {"error": "synthetic HTTP contract"})

    def reply(self, status, value):
        raw = compact(value).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True


class Fixture:
    def __init__(self, directory, command, shipment, peer, codex):
        self.directory, self.command = directory, command
        self.peers = peer, codex
        self.cwd = directory if shipment else ROOT
        self.env = {"PATH": os.environ["PATH"], "HOME": str(directory),
                    "TMPDIR": str(directory),
                    "ERL_FLAGS": os.environ.get("ERL_FLAGS", "+S 2:2 +A 2")}
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            self.port = reservation.getsockname()[1]
        self.config = directory / "providers.json"
        self.token = ThreadingHTTPServer(("127.0.0.1", 0), TokenHandler)
        self.token.connections, self.token.refreshes, self.token.errors = 0, 0, []
        token_get_request = self.token.get_request

        def counted():
            result = token_get_request()
            self.token.connections += 1
            return result

        self.token.get_request = counted
        self.worker = threading.Thread(target=self.token.serve_forever, daemon=True)
        self.worker.start()
        token_origin = f"http://127.0.0.1:{self.token.server_port}"
        self.settings = {
            "version": 1, "state_dir": str(self.state), "listen_port": self.port,
            "accounts": [
                self.account("absent", API_MODEL, "api_key", "http://127.0.0.1:1"),
                self.account("api", API_MODEL, "api_key", peer.origin),
                self.account("oauth", OAUTH_MODEL, "oauth", peer.origin, token_origin),
                self.account("proxy", PROXY_MODEL, "oauth", peer.origin, token_origin, proxy=True),
                {"provider": "codex", "auth_mode": "oauth", "id": "codex",
                 "origin": codex.origin, "models": [CODEX_MODEL]},
            ],
            "codex_catalog": {"models": [
                {"slug": CODEX_MODEL, "context_window": 272000,
                 "supported_reasoning_levels": [{"effort": "low"}],
                 "default_reasoning_level": "low", "input_modalities": ["text"],
                 "prefer_websockets": True, "use_responses_lite": False},
            ]},
        }
        self.write()
        self.phase = 0

    @staticmethod
    def account(account, model, mode, origin, token_origin=None, proxy=False):
        value = {"provider": "xai", "auth_mode": mode, "id": account,
                 "origin": token_origin or origin, "models": [model],
                 "xai_operations": [
                     {"protocol": "responses",
                      "operation": "responses" if proxy else "responses/websocket",
                      "base": origin + "/v1", "using_api": not proxy},
                 ]}
        if not proxy:
            value["xai_operations"].append({
                "protocol": "responses", "operation": "responses",
                "base": origin + "/v1", "using_api": True,
            })
        if mode == "oauth":
            value["oauth"] = {"discovery_url": token_origin + "/discovery"}
        return value

    def write(self):
        self.config.write_text(compact(self.settings))
        self.config.chmod(0o600)

    def cli(self, *args):
        result = subprocess.run([*self.command, "providers", *args],
                                cwd=self.cwd, env=self.env,
                                capture_output=True, timeout=90)
        output = result.stdout + result.stderr
        no_secrets(output)
        assert result.returncode == 0, "synthetic CLI failure:\n" + output.decode(errors="replace")
        return result.stdout

    def grant(self, account="api", mode="api_key", access=ACCESS, expired=False):
        value = {"api_key": access} if mode == "api_key" else {
            "access_token": access, "refresh_token": REFRESH,
            "expires_at_ms": 1 if expired else int(time.time() * 1000) + 3600000,
            "token_endpoint": f"http://127.0.0.1:{self.token.server_port}/token",
        }
        path = BASE["private_file"](self.directory / f"{account}-grant.json", compact(value))
        self.cli("credential", "import", str(self.config), account, path)

    def client(self, account="client", key=CLIENT):
        path = BASE["private_file"](self.directory / (account + ".key"), key)
        self.cli("key", "import", str(self.config), account, path)

    def codex_grant(self):
        path = BASE["private_file"](self.directory / "codex-grant.json", compact({
            "access_token": CODEX_ACCESS, "refresh_token": CODEX_REFRESH,
            "expires_at_ms": 9000000000000, "chatgpt_account_id": "synthetic-f18-codex-account",
        }))
        self.cli("credential", "import", str(self.config), "codex", path)

    def snapshot(self):
        return (tuple(peer.snapshot() for peer in self.peers),
                self.token.connections, self.token.refreshes)

    @contextlib.contextmanager
    def running(self):
        self.phase += 1
        path = self.directory / f"gateway-{self.phase}.log"
        with path.open("xb") as log:
            process = subprocess.Popen(
                [*self.command, "serve", "providers", str(self.config)],
                cwd=self.cwd, env=self.env, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 90
                while True:
                    assert process.poll() is None, "gateway exited before readiness"
                    try:
                        if http_call(self.port, {}, key=None)[0] == 401:
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    assert time.monotonic() < deadline, "synthetic readiness deadline"
                    time.sleep(0.05)
                yield
            finally:
                BASE["stop"](process, self.state)
                log.flush()
                no_secrets(path.read_bytes())

    def close(self):
        self.token.shutdown()
        self.token.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "synthetic token fixture did not stop"
        assert not self.token.errors, self.token.errors


def http_call(port, value, key=CLIENT):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        headers = {"Content-Type": "application/json"}
        if key is not None:
            headers["Authorization"] = "Bearer " + key
        connection.request("POST", "/v1/responses", compact(value), headers)
        response = connection.getresponse()
        data = response.read()
        no_secrets(data)
        return response.status, data
    finally:
        connection.close()


def connect(flow, value, key=CLIENT, extras="", path="/v1/responses"):
    sock = socket.create_connection(("127.0.0.1", flow.port), timeout=10)
    request = (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{flow.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
               "Sec-WebSocket-Version: 13\r\n")
    if key is not None:
        request += f"Authorization: Bearer {key}\r\n"
    try:
        sock.sendall((request + extras + "\r\n").encode() + frame(compact(value), masked=True))
        reader = Reader(sock)
        head = reader.headers()
        return sock, reader, head
    except BaseException:
        sock.close()
        raise


def text(reader):
    opcode, data = reader.event()
    assert opcode == 1, "root closed before expected event"
    no_secrets(data)
    return json.loads(data)


def completed(reader):
    result = []
    for _ in range(24):
        event = text(reader)
        result.append(event)
        if event["type"] == "response.completed":
            return result[-1]["response"]
    raise AssertionError("synthetic terminal bound")


def closed(reader):
    try:
        opcode, data = reader.event()
    except (EOFError, ConnectionResetError):
        return
    # socket.timeout is deliberately NOT closure/cancellation evidence.
    no_secrets(data)
    assert opcode == 8, "terminal policy emitted raw/generic data instead of close"
    assert len(data) >= 2, "terminal close omitted required local policy code"
    code = int.from_bytes(data[:2], "big")
    assert code in (1008, 1011), "terminal close used an unapproved policy code"
    assert data[2:] == b"", "terminal close exposed an unapproved reason"


def physical_closed(peer, socket_id):
    assert peer.handshakes[socket_id]["closed"].wait(5), "physical provider close deadline"


def deny(flow, peer, value, **kwargs):
    before = flow.snapshot()
    sock, reader, head = connect(flow, value, **kwargs)
    try:
        if " 101 " in head.split("\r\n")[0]:
            closed(reader)
        else:
            assert head.startswith(("HTTP/1.1 400 ", "HTTP/1.1 401 ", "HTTP/1.1 404 ",
                                    "HTTP/1.1 422 ")), "unexpected handshake denial"
    finally:
        sock.close()
    assert before == flow.snapshot(), (
        "pre-I/O denial opened inference or refresh transport"
    )


def checks(flow, peer, codex):
    flow.client()
    flow.client("second", SECOND)
    flow.grant()
    flow.grant("oauth", "oauth")
    flow.grant("proxy", "oauth", expired=True)
    flow.codex_grant()
    with flow.running():
        deny(flow, peer, create())
    flow.settings["codex_websocket"] = True
    flow.write()
    with flow.running():
        deny(flow, peer, create())  # Codex enablement is not xAI authority.
    flow.settings["xai_websocket"] = True
    flow.write()
    with flow.running():
        for kwargs in ({"key": None}, {"key": "synthetic-invalid"},
                       {"extras": "Origin: https://synthetic.invalid\r\n"},
                       {"extras": "Origin: https://synthetic.invalid\r\norigin: https://other.invalid\r\n"},
                       {"extras": "Sec-WebSocket-Extensions: permessage-deflate\r\n"},
                       {"extras": "Sec-WebSocket-Protocol: synthetic\r\n"},
                       {"extras": "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"},
                       {"path": "/v1/responses?model=synthetic"}):
            deny(flow, peer, create(), **kwargs)
        for value in (create(model="unconfigured"), create(model=PROXY_MODEL),
                      create(previous="resp_untrusted"), create(generate=False),
                      create(background=True)):
            deny(flow, peer, value)

        codex.select("normal")
        sock, reader, head = connect(flow, create(model=CODEX_MODEL))
        try:
            assert head.startswith("HTTP/1.1 101 ")
            response = completed(reader)
            assert response["model"] == CODEX_MODEL
            socket_id = codex.creates[-1][0]
            before = flow.snapshot()
            sock.sendall(frame(compact(create()), masked=True))
            closed(reader)
            assert flow.snapshot() == before, "Codex socket switched to xAI"
        finally:
            sock.close()
        physical_closed(codex, socket_id)

        for model in (API_MODEL, OAUTH_MODEL):
            peer.select("normal")
            sock, reader, head = connect(flow, create(model=model, tools=True))
            try:
                assert head.startswith("HTTP/1.1 101 ")
                response = completed(reader)
                assert response["model"] == model
                assert response["usage"]["total_tokens"] == 5
                assert [(item["name"], item.get("namespace")) for item in response["output"]] == [
                    ("run", "shell"), ("web_search", None),
                ]
                assert all(item["arguments"] == ARGUMENTS for item in response["output"])
                socket_id = peer.creates[-1][0]
                first = peer.creates[-1][1]
                assert [tool["name"] for tool in first["tools"]] == [
                    "shell__run", "other__run", "clientfn_web_search",
                ]
                follow = create(model=model, previous=response["id"], input=[
                    {"type": "function_call_output", "call_id": item["call_id"],
                     "output": "synthetic-result"} for item in response["output"]
                ])
                sock.sendall(frame(compact(follow), masked=True))
                assert completed(reader)["model"] == model
                assert peer.creates[-1][0] == socket_id
                sock.sendall(frame(compact(create(model=model)), masked=True))
                receipt = completed(reader)["id"]
                assert peer.creates[-1][0] == socket_id
                assert "previous_response_id" not in peer.creates[-1][1]
                flow.old_receipt = model, receipt
                before = flow.snapshot()
                other = OAUTH_MODEL if model == API_MODEL else API_MODEL
                sock.sendall(frame(compact(create(model=other)), masked=True))
                closed(reader)
                assert flow.snapshot() == before, "same socket switched configured model/auth"
            finally:
                sock.close()
            physical_closed(peer, socket_id)
            deny(flow, peer, create(model=model, previous=receipt))
            deny(flow, peer, create(model=model, previous=receipt), key=SECOND)
            # F17 guards the separately explicit HTTP operation before acquire;
            # a same-socket WS receipt is never HTTP continuation authority.
            before = flow.snapshot()
            status, _ = http_call(flow.port, {"model": model, "input": [],
                                             "previous_response_id": receipt})
            assert status == 422
            assert before == flow.snapshot()
            sock, reader, _ = connect(flow, create(model=model))
            try:
                completed(reader)
                socket_id = peer.creates[-1][0]
                before = flow.snapshot()
                sock.sendall(frame(compact(create(model=CODEX_MODEL)), masked=True))
                closed(reader)
                assert flow.snapshot() == before, "xAI socket switched to Codex"
            finally:
                sock.close()
            physical_closed(peer, socket_id)

        for mode in ("malformed", "identity", "error", "failed", "incomplete", "cancelled"):
            peer.select(mode)
            sock, reader, _ = connect(flow, create(tools=mode == "identity"))
            try:
                assert text(reader)["type"] == "response.created"
                if mode == "identity":
                    assert text(reader)["item"]["namespace"] == "shell"
                closed(reader)
                socket_id = peer.creates[-1][0]
                physical_closed(peer, socket_id)
                before = peer.snapshot()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    sock.sendall(frame(compact(create()), masked=True))
                assert peer.snapshot() == before, "terminal error authorized replay"
            finally:
                sock.close()

        for mode in ("bad-accept", "compression"):
            peer.select(mode)
            before = len(peer.creates)
            sock, reader, _ = connect(flow, create())
            try:
                closed(reader)
                physical_closed(peer, len(peer.handshakes) - 1)
                assert len(peer.creates) == before
            finally:
                sock.close()

        for mutation in ("same-value", "rotate", "delete", "client"):
            flow.grant()
            flow.client()
            peer.accepted = ACCESS
            peer.select("hold")
            sock, reader, _ = connect(flow, create())
            try:
                assert text(reader)["type"] == "response.created"
                assert peer.entered.wait(5)
                before, socket_id = peer.snapshot(), peer.creates[-1][0]
                if mutation == "same-value":
                    flow.grant()
                elif mutation == "rotate":
                    flow.grant(access=ROTATED)
                elif mutation == "delete":
                    flow.cli("credential", "delete", str(flow.config), "api")
                else:
                    flow.cli("key", "revoke", str(flow.config), "client")
                peer.gate.set()
                closed(reader)
                physical_closed(peer, socket_id)
                assert peer.snapshot() == before, "mutation reconnected/replayed"
            finally:
                peer.gate.set()
                sock.close()

        flow.client()
        flow.grant()
        peer.select("acquire")
        sock, reader, _ = connect(flow, create())
        try:
            assert peer.entered.wait(5)
            before = len(peer.creates)
            flow.cli("key", "revoke", str(flow.config), "client")
            peer.gate.set()
            closed(reader)
            physical_closed(peer, len(peer.handshakes) - 1)
            assert len(peer.creates) == before, "revoked acquisition sent first inference"
        finally:
            peer.gate.set()
            sock.close()
        flow.client()
        peer.select("cancel")
        sock, reader, _ = connect(flow, create())
        try:
            assert text(reader)["type"] == "response.created"
            before, socket_id = peer.snapshot(), peer.creates[-1][0]
            sock.sendall(frame(b"\x03\xe8", masked=True, opcode=8))
            peer.gate.set()
            physical_closed(peer, socket_id)
            assert peer.snapshot() == before, "cancellation replayed an uncertain turn"
        finally:
            peer.gate.set()
            sock.close()
    # Actual independent VM restart cannot restore a physical-socket receipt.
    with flow.running():
        model, receipt = flow.old_receipt
        deny(flow, peer, create(model=model, previous=receipt))
    assert flow.token.refreshes == 0, "fresh/denied WS paths refreshed OAuth"
    assert not peer.errors, peer.errors
    assert not codex.errors, codex.errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    parser.add_argument("--transport", choices=("both", "ws", "wss"), default="both")
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    directory = ROOT / "build/integration"
    directory.mkdir(parents=True, exist_ok=True)
    transports = (False, True) if args.transport == "both" else (args.transport == "wss",)
    for secure in transports:
        with tempfile.TemporaryDirectory(prefix="f18-wss-" if secure else "f18-ws-", dir=directory) as temp:
            temp = Path(temp)
            ca, tls = F13["certificates"](temp) if secure else (None, None)
            with F13["trust_only_in_child_vms"](ca), Peer(tls) as peer, Peer(tls, "codex") as codex:
                workers = [threading.Thread(target=p.serve_forever, daemon=True)
                           for p in (peer, codex)]
                for worker in workers:
                    worker.start()
                flow = Fixture(temp, command, args.shipment, peer, codex)
                try:
                    checks(flow, peer, codex)
                finally:
                    try:
                        flow.close()
                    finally:
                        for p, worker in zip((peer, codex), workers):
                            p.gate.set()
                            p.shutdown()
                            worker.join(timeout=5)
                            assert not worker.is_alive(), "synthetic WS fixture did not stop"
    print(compact({
        "scope": "actual_authenticated_root_xai_ws", "synthetic": True,
        "source": not bool(args.shipment), "shipment": bool(args.shipment),
        "transports": ["wss" if secure else "ws" for secure in transports],
        "same_socket_continuation_reset": True, "raw_validation_before_alias": True,
        "client_provider_revision_fence": True, "close_only_terminal_policy": True,
        "cpa_execution": False, "native_client": False, "live_provider": False,
        "source_chain_parity": False,
    }))


if __name__ == "__main__":
    main()
