#!/usr/bin/env python3
"""F13 actual authenticated root WS/WSS source/shipment workflow, synthetic only.

No CPA service, native binary, live provider, host trust-store changes, or real
credentials. WSS trusts a temporary synthetic CA only in the launched VMs.
"""

import argparse
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
F12 = runpy.run_path(str(ROOT / "scripts/smoke-codex-http-lite.py"))
CLIENT = HTTP["CLIENT"]
MODEL = F12["MODEL"]
MARKER = F12["MARKER"]
LITE_HEADER = F12["LITE_HEADER"]
SOURCE = tuple(F12[name] for name in ("METADATA", "DONE", "COMPLETED"))
FAULT = '{"type":"error","status":400,"error":{"type":"invalid_request_error","message":"synthetic invalid input","param":"input"},"future":{"ok":true}}'
PRIVATE_ERROR = '{"type":"error","status":503,"error":{"type":"server_error","message":"synthetic-private-diagnostic"}}'
SECOND = "synthetic-f13-second-client"
HTTP["SECRETS"].extend([SECOND, "synthetic-f13-rotated-access",
                        "synthetic-f13-rotated-refresh", "synthetic-private-diagnostic"])


def compact(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def frame(payload, *, masked=False, opcode=1, final=True):
    if isinstance(payload, str):
        payload = payload.encode()
    length = len(payload)
    flag = 128 if masked else 0
    prefix = bytes([(128 if final else 0) | opcode])
    if length < 126:
        prefix += bytes([flag | length])
    elif length < 65536:
        prefix += bytes([flag | 126]) + struct.pack("!H", length)
    else:
        prefix += bytes([flag | 127]) + struct.pack("!Q", length)
    if not masked:
        return prefix + payload
    mask = b"\x01\x02\x03\x04"
    return prefix + mask + bytes(byte ^ mask[index % 4]
                                 for index, byte in enumerate(payload))


class Reader:
    def __init__(self, sock):
        self.sock, self.pending = sock, b""

    def take(self, count):
        while len(self.pending) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.pending += chunk
        result, self.pending = self.pending[:count], self.pending[count:]
        return result

    def headers(self):
        while b"\r\n\r\n" not in self.pending:
            assert len(self.pending) < 65536
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.pending += chunk
        result, self.pending = self.pending.split(b"\r\n\r\n", 1)
        return result.decode()

    def raw_frame(self, masked):
        first, second = self.take(2)
        assert not first & 112 and bool(second & 128) == masked
        length = second & 127
        if length == 126:
            length = struct.unpack("!H", self.take(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.take(8))[0]
        assert length <= 1048576
        mask = self.take(4) if masked else b""
        payload = self.take(length)
        if masked:
            payload = bytes(byte ^ mask[index % 4]
                            for index, byte in enumerate(payload))
        return bool(first & 128), first & 15, payload

    def event(self, masked=False):
        pending = bytearray()
        while True:
            final, opcode, payload = self.raw_frame(masked)
            if opcode == 9:
                self.sock.sendall(frame(payload, masked=not masked, opcode=10))
                continue
            if opcode == 10:
                continue
            if opcode == 8:
                return opcode, payload
            assert opcode in (0, 1)
            assert opcode == (0 if pending else 1)
            pending.extend(payload)
            if final:
                return 1, bytes(pending)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        peer, reader = self.server, Reader(self.request)
        socket_id = None
        try:
            raw = reader.headers()
            headers = dict(line.split(": ", 1) for line in raw.split("\r\n")[1:])
            with peer.lock:
                socket_id = len(peer.handshakes)
                closed = threading.Event()
                peer.handshakes.append((raw.split("\r\n")[0], headers, closed))
            key = headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                                 "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                 f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            while True:
                opcode, payload = reader.event(True)
                if opcode == 8:
                    return
                body = json.loads(payload)
                with peer.lock:
                    peer.creates.append((socket_id, body))
                    receipt = "resp_f13_" + str(len(peer.creates))
                    peer.last_receipt = receipt
                    mode, gate = peer.mode, peer.gate
                events = F12["events"](mode if mode != "hold" else "eligible", receipt)
                if mode == "strict":
                    events = [data.replace(MODEL, body["model"]) for data in events]
                if mode == "custom":
                    events = [compact({"type": "response.created", "response": {"id": receipt}}),
                              *F12["events"]("encrypted-custom", receipt)]
                if mode == "malformed":
                    events = events[:2] + ["{broken}"]
                if mode == "model-mismatch":
                    events = F12["events"]("model-mismatch", receipt)
                if mode == "accepted":
                    events = events[:2] + ['{"type":"response.accepted"}']
                if mode in ("error", "request-fault", "credential-echo",
                            "credential-key", "escaped-key", "quota"):
                    error = PRIVATE_ERROR
                    if mode == "request-fault":
                        error = FAULT
                    elif mode == "credential-echo":
                        error = FAULT.replace("synthetic invalid input", "echo synthetic-old-access")
                    elif mode == "credential-key":
                        error = FAULT.replace('"param":"input"', '"x-synthetic-old-access":"diagnostic"')
                    elif mode == "escaped-key":
                        error = FAULT.replace('"param":"input"', '"synthetic-old-acc\\u0065ss":"diagnostic"')
                    elif mode == "quota":
                        error = FAULT.replace('"status":400', '"status":429')
                    events = events[:1] + [error]
                if mode == "cancel":
                    events = [SOURCE[0]]
                if mode == "hold":
                    self.request.sendall(b"".join(frame(data) for data in events[:-1]))
                    peer.hold_started.set()
                    assert gate.wait(10), "synthetic turn gate was not released"
                    self.request.sendall(frame(events[-1]))
                    continue
                wire = b"".join(frame(data) for data in events)
                if mode.startswith("stale-"):
                    stale = compact({"type": "response.created", "response": {"id": "stale"}})
                    if mode == "stale-fragment":
                        wire += frame(stale, final=False)
                    elif mode == "stale-header":
                        wire += b"\x81"
                    elif mode == "stale-payload":
                        wire += frame(stale)[:3]
                    elif mode == "stale-large":
                        wire += frame(compact({"type": "response.created", "response": {
                            "id": "stale", "future": "x" * 20000}}))
                    elif mode == "stale-flood":
                        wire += frame(b"", opcode=10) * 129
                if mode == "fragmented":
                    # Split a JSON message across fragments with interleaved ping.
                    first = events[0].encode()
                    mid = len(first) // 2
                    wire = (frame(first[:mid], final=False) + frame(b"f13", opcode=9)
                            + frame(first[mid:], opcode=0)
                            + b"".join(frame(data) for data in events[1:]))
                self.request.sendall(wire[:7])
                self.request.sendall(wire[7:])
        except (EOFError, OSError):
            pass
        except Exception as error:
            # Class only: never include a request, credential header or raw error.
            peer.errors.append(type(error).__name__)
        finally:
            if socket_id is not None:
                peer.handshakes[socket_id][2].set()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, tls_context=None):
        self.tls_context = tls_context
        self.handshakes, self.creates, self.errors = [], [], []
        self.lock = threading.Lock()
        self.mode, self.last_receipt = "native", ""
        self.gate, self.hold_started = threading.Event(), threading.Event()
        self.gate.set()
        super().__init__(("127.0.0.1", 0), Handler)

    def get_request(self):
        sock, address = super().get_request()
        if self.tls_context:
            try:
                sock = self.tls_context.wrap_socket(sock, server_side=True)
            except Exception:
                sock.close()
                raise
        return sock, address

    def select(self, mode):
        with self.lock:
            self.mode = mode
            self.hold_started.clear()
            self.gate = threading.Event()
            if mode != "hold":
                self.gate.set()


def create(previous=None, marker=True, model=MODEL, **extra):
    value = {"type": "response.create", "model": model, "input": []}
    if previous is not None:
        value["previous_response_id"] = previous
    if marker:
        value["client_metadata"] = {MARKER: True}
    return dict(value, **extra)


def connect(flow, value, *, key=CLIENT, header=None, extras="", path="/v1/responses"):
    sock = socket.create_connection(("127.0.0.1", flow.port), timeout=10)
    if header is not None:
        extras += f"{LITE_HEADER}: {header}\r\n"
    request = (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
               "Sec-WebSocket-Version: 13\r\n"
               f"Authorization: Bearer {key}\r\n{extras}\r\n")
    sock.sendall(request.encode() + frame(compact(value), masked=True))
    reader = Reader(sock)
    return sock, reader, reader.headers()


def next_text(reader):
    opcode, payload = reader.event()
    assert opcode == 1, "root WS closed before expected event"
    for secret in HTTP["SECRETS"]:
        assert secret.encode() not in payload
    return payload.decode()


def completed(reader):
    result = []
    while len(result) < 16:
        data = next_text(reader)
        result.append(data)
        if json.loads(data)["type"] in ("response.completed", "response.failed",
                                        "response.incomplete", "response.cancelled", "error"):
            return result
    raise AssertionError("synthetic event limit")


def failed(reader):
    try:
        opcode, payload = reader.event()
    except (EOFError, OSError):
        return
    assert opcode == 8 or (
        opcode == 1 and json.loads(payload).get("type") == "error"
    ), "failed socket delivered data or a terminal/continuation"
    for secret in HTTP["SECRETS"]:
        assert secret.encode() not in payload


def silent_close(reader):
    try:
        opcode, payload = reader.event()
    except (EOFError, ConnectionResetError, BrokenPipeError):
        return
    assert opcode == 8, "suppressed/finished native error emitted a text event"
    for secret in HTTP["SECRETS"]:
        assert secret.encode() not in payload


def closed(peer, socket_id):
    assert peer.handshakes[socket_id][2].wait(5), "upstream socket was not closed"


def reject_before_upstream(flow, peer, value, **kwargs):
    before = len(peer.handshakes), len(peer.creates)
    sock, reader, head = connect(flow, value, **kwargs)
    try:
        if "101" in head:
            failed(reader)
    finally:
        sock.close()
    assert before == (len(peer.handshakes), len(peer.creates)), (
        "rejected request opened/sent upstream"
    )


def grant(flow, *, rotated=False):
    return F12["grant"](
        flow, "selected",
        "synthetic-f13-rotated-access" if rotated else "synthetic-old-access",
        "synthetic-f13-rotated-refresh" if rotated else "synthetic-old-refresh",
        "synthetic-codex-account",
    )


def checks(flow, peer, secure):
    settings = {
        "version": 1, "state_dir": str(flow.state), "listen_port": flow.port,
        "accounts": [
            {"provider": "codex", "auth_mode": "oauth", "id": "absent",
             "origin": "http://127.0.0.1:1", "models": [MODEL, "gpt-5.5"]},
            {"provider": "codex", "auth_mode": "oauth", "id": "selected",
             "origin": ("https" if secure else "http") + "://127.0.0.1:"
                       + str(peer.server_address[1]), "models": [MODEL, "gpt-5.5"]},
        ],
        "codex_catalog": {"models": [
            {"slug": slug, "context_window": 272000,
             "supported_reasoning_levels": [{"effort": "low"}],
             "default_reasoning_level": "low", "input_modalities": ["text", "image"],
             "prefer_websockets": True, "use_responses_lite": lite}
            for slug, lite in [(MODEL, True), ("gpt-5.5", False)]
        ]},
    }
    flow.config.write_text(compact(settings))
    grant(flow)
    second = HTTP["private"](flow.directory / "second-client", SECOND)
    flow.cli("key", "import", str(flow.config), "second", second)
    with flow.running():
        sock, _, head = connect(flow, create())
        sock.close()
        assert "404" in head and not peer.handshakes
        assert all(not m["prefer_websockets"] for m in F12["discover"](flow, "/models")["models"])
    settings["codex_websocket"] = True
    flow.config.write_text(compact(settings))
    with flow.running():
        assert all(m["prefer_websockets"] for m in F12["discover"](flow, "/models")["models"])
        reject_before_upstream(flow, peer, create(), key="synthetic-wrong")
        reject_before_upstream(flow, peer, create(), extras=f"{LITE_HEADER}: true\r\n{LITE_HEADER.lower()}: false\r\n")
        reject_before_upstream(flow, peer, create(), header="invalid")
        reject_before_upstream(flow, peer, create(model="gpt-5.5"), header="true")
        reject_before_upstream(flow, peer, create(model="unconfigured"), header="true")
        reject_before_upstream(flow, peer, create(generate=False), header="true")
        reject_before_upstream(flow, peer, create(background=True), header="true")
        reject_before_upstream(flow, peer, create(), extras="Origin: https://synthetic.invalid\r\n")
        reject_before_upstream(flow, peer, create(client_metadata={MARKER: 1}))
        reject_before_upstream(flow, peer, create(client_metadata={MARKER: "invalid"}))
        for strict_model in ("gpt-5.5", MODEL):
            peer.select("strict")
            sock, reader, head = connect(flow, create(marker=False, model=strict_model))
            try:
                assert "101" in head
                data = completed(reader)
                assert json.loads(data[-1])["response"]["output"][0]["id"] == "msg_1"
                assert "X-OpenAI-Internal-Codex-Responses-Lite" not in peer.handshakes[-1][1]
                before = len(peer.creates)
                sock.sendall(frame(compact(create(model=strict_model)), masked=True))
                failed(reader)
                assert len(peer.creates) == before, "strict socket silently broadened to lite"
            finally:
                sock.close()
            closed(peer, peer.creates[-1][0])
        for header, metadata in ((None, True), (None, " TRUE "),
                                 (" TRUE ", None), ("false", True)):
            peer.select("native")
            request = create(marker=metadata is not None)
            if metadata is not None:
                request["client_metadata"][MARKER] = metadata
            header_enabled = header is not None and header.strip().lower() == "true"
            sock, reader, head = connect(flow, request, header=header)
            try:
                assert "101" in head
                data = completed(reader)
                assert tuple(data) == SOURCE, "native WS was hydrated or reserialized"
                socket_id, outbound = peer.creates[-1]
                method, headers, _ = peer.handshakes[socket_id]
                assert method == "GET /backend-api/codex/responses HTTP/1.1"
                assert headers["Authorization"] == "Bearer synthetic-old-access"
                assert headers["Chatgpt-Account-Id"] == "synthetic-codex-account"
                assert ("X-OpenAI-Internal-Codex-Responses-Lite" in headers) == header_enabled
                assert CLIENT not in str(headers) and "session_id" not in headers
                assert "instructions" not in outbound and "stream" not in outbound
                assert outbound["parallel_tool_calls"] is False
                before = len(peer.creates)
                sock.sendall(frame(compact(dict(request, previous_response_id="resp_1")), masked=True))
                failed(reader)
                closed(peer, socket_id)
                assert len(peer.creates) == before, "missing-created output manufactured cursor"
            finally:
                sock.close()
        # Qualified observations, incremental input only, resets on the same
        # physical upstream connection; no cached transcript or reconnect replay.
        peer.select("eligible")
        sock, reader, head = connect(flow, create())
        try:
            assert "101" in head
            terminal = completed(reader)[-1]
            assert json.loads(terminal)["response"]["output"] == []
            receipt, socket_id = peer.last_receipt, peer.creates[-1][0]
            for previous in (receipt, None):
                sock.sendall(frame(compact(create(previous)), masked=True))
                completed(reader)
                current_id, outbound = peer.creates[-1]
                assert current_id == socket_id and outbound["input"] == []
                assert outbound.get("previous_response_id") == previous
            before = len(peer.creates)
            sock.sendall(frame(compact(create(marker=False)), masked=True))
            failed(reader)
            closed(peer, socket_id)
            assert len(peer.creates) == before, "metadata omission silently switched mode"
        finally:
            sock.close()
        reject_before_upstream(flow, peer, create(receipt))
        reject_before_upstream(flow, peer, create(receipt), key=SECOND)
        peer.select("custom")
        sock, reader, _ = connect(flow, create())
        try:
            data = completed(reader)
            items = [json.loads(raw)["item"] for raw in data
                     if json.loads(raw)["type"] == "response.output_item.done"]
            assert items[0]["encrypted_content"] == "synthetic-opaque-reasoning"
            assert items[1]["name"] == "shell.exec" and items[1]["call_id"] == "call_1"
            assert json.loads(data[-1])["response"]["usage"] == {
                "input_tokens": 1, "output_tokens": 1, "total_tokens": 2}
            socket_id = peer.creates[-1][0]
            output = {"type": "custom_tool_call_output", "call_id": "call_1",
                      "output": "synthetic result"}
            sock.sendall(frame(compact(create(peer.last_receipt, input=[output])), masked=True))
            completed(reader)
            current_id, outbound = peer.creates[-1]
            assert current_id == socket_id and outbound["input"] == [output]
        finally:
            sock.close()
        closed(peer, socket_id)
        for mode in ("empty", "idless", "open", "extension", "failed",
                     "incomplete", "cancelled"):
            peer.select(mode)
            sock, reader, _ = connect(flow, create())
            try:
                completed(reader)
                receipt, socket_id = peer.last_receipt, peer.creates[-1][0]
                before = len(peer.creates)
                sock.sendall(frame(compact(create(receipt)), masked=True))
                failed(reader)
                closed(peer, socket_id)
                assert len(peer.creates) == before, mode + " minted cursor"
            finally:
                sock.close()
        for mode in ("error", "request-fault", "credential-echo",
                     "credential-key", "escaped-key", "quota"):
            peer.select(mode)
            sock, reader, _ = connect(flow, create())
            try:
                assert json.loads(next_text(reader))["type"] == "response.created"
                before, socket_id = len(peer.creates), peer.creates[-1][0]
                if mode == "request-fault":
                    assert next_text(reader) == FAULT
                    # A reset queued immediately after the exposed fault must
                    # lose even if a root tick races the terminal notification.
                    try:
                        sock.sendall(frame(compact(create()), masked=True))
                    except OSError:
                        pass
                silent_close(reader)
                closed(peer, socket_id)
                assert len(peer.creates) == before, "non-duplex error permitted fresh reset"
            finally:
                sock.close()
        for mode in ("stale-fragment", "stale-header", "stale-payload",
                     "stale-large", "stale-flood"):
            peer.select(mode)
            sock, reader, _ = connect(flow, create())
            try:
                completed(reader)
                before, socket_id = len(peer.creates), peer.creates[-1][0]
                sock.sendall(frame(compact(create(peer.last_receipt)), masked=True))
                failed(reader)
                closed(peer, socket_id)
                assert len(peer.creates) == before, "queued partial data admitted new create"
            finally:
                sock.close()
        for mode in ("malformed", "model-mismatch", "accepted", "trailing"):
            peer.select(mode)
            sock, reader, _ = connect(flow, create())
            try:
                assert json.loads(next_text(reader))["type"] == "response.created"
                assert next_text(reader) == SOURCE[1]
                if mode == "trailing":
                    next_text(reader)
                failed(reader)
                closed(peer, peer.creates[-1][0])
            finally:
                sock.close()
        for control in ("response.steer", "response.append", "response.cancel"):
            reject_before_upstream(flow, peer, dict(create(), type=control))
        peer.select("fragmented")
        sock, reader, _ = connect(flow, create())
        completed(reader)
        sock.close()
        closed(peer, peer.creates[-1][0])
        peer.select("cancel")
        sock, reader, _ = connect(flow, create())
        assert next_text(reader) == SOURCE[0]
        sock.sendall(frame(struct.pack("!H", 1000), masked=True, opcode=8))
        sock.close()
        closed(peer, peer.creates[-1][0])
        # Each administrative mutation is performed by the actual root CLI.
        # A held terminal must not cross the post-poll revision/client fence.
        for mutation in ("same-token", "rotate", "delete", "client"):
            grant(flow)
            peer.select("hold")
            sock, reader, _ = connect(flow, create())
            try:
                assert json.loads(next_text(reader))["type"] == "response.created"
                assert next_text(reader) == SOURCE[1]
                assert peer.hold_started.wait(5)
                before, socket_id = len(peer.creates), peer.creates[-1][0]
                if mutation == "same-token":
                    grant(flow)
                elif mutation == "rotate":
                    grant(flow, rotated=True)
                elif mutation == "delete":
                    flow.cli("credential", "delete", str(flow.config), "selected")
                else:
                    flow.cli("key", "revoke", str(flow.config), "client")
                peer.gate.set()
                failed(reader)
                closed(peer, socket_id)
                assert len(peer.creates) == before, "mutation retried an uncertain turn"
                # Same socket may never silently rebind to a new generation.
                try:
                    sock.sendall(frame(compact(create(peer.last_receipt)), masked=True))
                except OSError:
                    pass
                assert len(peer.creates) == before
            finally:
                peer.gate.set()
                sock.close()
        reject_before_upstream(flow, peer, create())
    assert not peer.errors, peer.errors


def certificates(directory):
    ca, ca_key = directory / "ca.pem", directory / "ca.key"
    cert, key = directory / "leaf.pem", directory / "leaf.key"
    request = directory / "leaf.csr"
    extensions = directory / "leaf.ext"
    extensions.write_text("subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n")
    commands = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=MIMIC Synthetic F13 CA", "-keyout", str(ca_key), "-out", str(ca)],
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=127.0.0.1",
         "-keyout", str(key), "-out", str(request)],
        ["openssl", "x509", "-req", "-in", str(request), "-CA", str(ca),
         "-CAkey", str(ca_key), "-CAcreateserial", "-days", "1",
         "-extfile", str(extensions), "-out", str(cert)],
    ]
    for command in commands:
        result = subprocess.run(command, capture_output=True, timeout=20)
        assert result.returncode == 0, "synthetic TLS certificate creation failed"
    for path in (ca_key, key):
        path.chmod(0o600)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    context.set_alpn_protocols(["http/1.1"])
    return ca, context


@contextlib.contextmanager
def trust_only_in_child_vms(ca):
    old = os.environ.get("ERL_FLAGS")
    flags = old or "+S 2:2 +A 2"
    if ca:
        assert not any(char in str(ca) for char in ("'", '"', "\\", "\n"))
        os.environ["ERL_FLAGS"] = flags + " -public_key cacerts_path '" + json.dumps(str(ca)) + "'"
    try:
        yield
    finally:
        if old is None:
            os.environ.pop("ERL_FLAGS", None)
        else:
            os.environ["ERL_FLAGS"] = old


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    parser.add_argument("--transport", choices=("both", "ws", "wss"), default="both")
    args = parser.parse_args()
    assert tuple(hashlib.sha256(data.encode()).hexdigest() for data in SOURCE) == F12["SOURCE_SHA256"]
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    base = ROOT / "build/integration"
    base.mkdir(parents=True, exist_ok=True)
    transports = (False, True) if args.transport == "both" else (args.transport == "wss",)
    for secure in transports:
        with tempfile.TemporaryDirectory(prefix="f13-wss-" if secure else "f13-ws-", dir=base) as temp:
            directory = Path(temp)
            ca, tls = certificates(directory) if secure else (None, None)
            with trust_only_in_child_vms(ca), Server(tls) as peer:
                worker = threading.Thread(target=peer.serve_forever, daemon=True)
                worker.start()
                flow = HTTP["Workflow"](directory, command, args.shipment)
                try:
                    checks(flow, peer, secure)
                finally:
                    flow.close()
                    peer.shutdown()
                    worker.join(timeout=5)
    print(json.dumps({
        "scope": "actual_authenticated_root_codex_ws_lite_cli",
        "synthetic": True, "source_derived_event_sha256": True,
        "source": not bool(args.shipment), "shipment": bool(args.shipment),
        "transports": ["wss" if secure else "ws" for secure in transports],
        "same_socket_continuation_reset": True, "sparse_cursor_gaps": True,
        "valid_prefix_cancel": True, "client_provider_revocation_revision": True,
        "no_reconnect_replay": True, "cpa_execution": False,
        "actual_native_client": False, "live_provider": False,
    }))


if __name__ == "__main__":
    main()
