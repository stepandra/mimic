#!/usr/bin/env python3
"""Synthetic fresh-process root CLI WS dispatch smoke, not a transport test suite."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import socketserver
import struct
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
CLIENT = HTTP["CLIENT"]
CREATE = {"type": "response.create", "model": "gpt-5.5", "input": []}


def frame(value, masked):
    data = json.dumps(value, separators=(",", ":")).encode()
    mark = 128 if masked else 0
    prefix = bytes([129, mark | len(data)]) if len(data) < 126 else bytes([129, mark | 126]) + struct.pack("!H", len(data))
    if not masked:
        return prefix + data
    mask = b"\x01\x02\x03\x04"
    return prefix + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))


class Reader:
    def __init__(self, sock):
        self.sock, self.pending = sock, b""

    def take(self, size):
        while len(self.pending) < size:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.pending += chunk
        result, self.pending = self.pending[:size], self.pending[size:]
        return result

    def headers(self):
        while b"\r\n\r\n" not in self.pending:
            assert len(self.pending) <= 65536
            self.pending += self.take_from_socket()
        result, self.pending = self.pending.split(b"\r\n\r\n", 1)
        return result.decode()

    def take_from_socket(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise EOFError
        return chunk

    def event(self, masked):
        first, second = self.take(2)
        assert bool(second & 128) == masked
        size = second & 127
        if size == 126:
            size = struct.unpack("!H", self.take(2))[0]
        assert size < 65536
        mask = self.take(4) if masked else b""
        payload = self.take(size)
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        return first & 15, payload


class Upstream(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        reader = Reader(self.request)
        try:
            raw = reader.headers()
            headers = dict(line.split(": ", 1) for line in raw.split("\r\n")[1:])
            self.server.handshakes.append((raw.split("\r\n")[0], headers))
            key = headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                  "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
            while True:
                opcode, payload = reader.event(True)
                if opcode == 8:
                    return
                if opcode != 1:
                    continue
                self.server.creates.append(json.loads(payload))
                response = {"id": "resp_synthetic_ws", "object": "response",
                            "status": "in_progress", "output": []}
                self.request.sendall(frame({"type": "response.created", "response": response}, False)
                                     + frame({"type": "response.completed",
                                              "response": dict(response, status="completed")}, False))
        except (EOFError, OSError):
            pass
        finally:
            self.server.closed.set()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def connect(port, auth=CLIENT, extras="", version="1.1", create=None):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    request = (f"GET /v1/responses HTTP/{version}\r\nHost: 127.0.0.1\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
               "Sec-WebSocket-Version: 13\r\n"
               f"Authorization: Bearer {auth}\r\n{extras}\r\n")
    sock.sendall(request.encode() + (frame(create, True) if create else b""))
    reader = Reader(sock)
    try:
        head = reader.headers()
    except (EOFError, OSError):
        head = "closed"
    return sock, reader, head


def exercise(flow):
    with Server(("127.0.0.1", 0), Upstream) as upstream:
        upstream.handshakes, upstream.creates = [], []
        upstream.closed = threading.Event()
        worker = threading.Thread(target=upstream.serve_forever, daemon=True)
        worker.start()
        account = {"provider": "codex", "auth_mode": "oauth", "id": "selected",
                   "origin": f"http://127.0.0.1:{upstream.server_address[1]}", "models": ["gpt-5.5"]}
        settings = {
            "version": 1, "state_dir": str(flow.state), "listen_port": flow.port,
            "accounts": [dict(account, id="absent", origin="http://127.0.0.1:1"), account],
            "codex_catalog": {"models": [{
                "slug": "gpt-5.5", "context_window": 272000,
                "supported_reasoning_levels": [{"effort": "medium"}],
                "default_reasoning_level": "medium", "input_modalities": ["text"],
                "prefer_websockets": True, "use_responses_lite": False,
            }]},
        }
        flow.config.write_text(json.dumps(settings))
        grant = HTTP["private"](flow.directory / "ws-grant", json.dumps({
            "access_token": "synthetic-old-access", "refresh_token": "synthetic-old-refresh",
            "expires_at_ms": 9000000000000, "chatgpt_account_id": "synthetic-codex-account",
        }))
        flow.cli("credential", "import", str(flow.config), "selected", grant)
        with flow.running():
            sock, _, response = connect(flow.port, create=CREATE)
            sock.close()
            assert "404" in response and not upstream.handshakes
        settings["codex_websocket"] = True
        flow.config.write_text(json.dumps(settings))
        with flow.running():
            for auth, extras, version in [
                ("wrong", "", "1.1"),
                ("wrong", f"authorization: Bearer {CLIENT}\r\n", "1.1"),
                (CLIENT, "Authorization: Bearer wrong\r\n", "1.1"),
                (CLIENT, "sEc-WeBsOcKeT-kEy: invalid\r\n", "1.1"),
                (CLIENT, "Sec-WebSocket-Version: 12\r\n", "1.1"),
                (CLIENT, "", "1.0"),
                (CLIENT, "Origin: https://synthetic.invalid\r\n", "1.1"),
            ]:
                sock, _, response = connect(flow.port, auth, extras, version, CREATE)
                sock.close()
                assert "101" not in response and not upstream.handshakes
            sock, reader, response = connect(flow.port, create=CREATE)
            try:
                assert "101" in response
                first = json.loads(reader.event(False)[1])
                terminal = json.loads(reader.event(False)[1])
                assert first["type"] == "response.created"
                assert terminal["type"] == "response.completed"
                assert terminal["response"]["id"] == "resp_synthetic_ws"
                method, headers = upstream.handshakes[0]
                assert method == "GET /backend-api/codex/responses HTTP/1.1"
                assert headers["Host"] == f"127.0.0.1:{upstream.server_address[1]}"
                assert headers["Authorization"] == "Bearer synthetic-old-access"
                assert headers["Chatgpt-Account-Id"] == "synthetic-codex-account"
                assert CLIENT not in str(headers)
                assert upstream.creates[0]["model"] == "gpt-5.5"
                flow.cli("key", "revoke", str(flow.config), "client")
                before = len(upstream.creates)
                sock.sendall(frame(CREATE, True))
                opcode, payload = reader.event(False)
                value = json.loads(payload) if opcode == 1 else {}
                assert opcode == 8 or value.get("type") == "error", (
                    "revoked live connection accepted another request"
                )
                assert len(upstream.creates) == before
                assert upstream.closed.wait(5), "revoked upstream connection not cancelled"
            finally:
                sock.close()
            sock, _, response = connect(flow.port, create=CREATE)
            sock.close()
            assert "401" in response and len(upstream.handshakes) == 1
        upstream.shutdown()
        worker.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"] if args.shipment
               else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ws-cli-", dir=ROOT / "build/integration") as temp:
        flow = HTTP["Workflow"](Path(temp), command, args.shipment)
        try:
            exercise(flow)
        finally:
            flow.close()
    print(json.dumps({"scope": "actual_root_gateway_ws_cli", "synthetic": True,
                      "opt_in_auth_raw_handshake_coalesced_create": True,
                      "selected_account": True, "revocation": True,
                      "live_connection_revocation_before_send": True,
                      "shipment": bool(args.shipment), "live_provider": False}))


if __name__ == "__main__":
    main()
