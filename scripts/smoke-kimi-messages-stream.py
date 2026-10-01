#!/usr/bin/env python3
"""F14 synthetic native Messages SSE at actual CLI/shipment; no live/CPA calls."""

import argparse
import contextlib
import copy
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


ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
CLIENT = BASE["CLIENT_KEY"]
CLIENT_B = "synthetic-f14-second-client-0001"
KEY_A = "synthetic-f14-native-api-key-a"
KEY_B = "synthetic-f14-native-api-key-b"
SECRETS = [CLIENT, CLIENT_B, KEY_A, KEY_B]
MODEL_A, MODEL_B = "kimi-k2.8", "kimi-k2.7-code"
UPSTREAM_MODEL = "kimi-for-coding"  # Both aliases map here; restore per request.
UPSTREAM_PATH = "/tenant/native/v1/messages?beta=true"


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def frame(value, start_fields=False):
    fields = f"event: {value['type']}\n"
    if start_fields:
        fields += "id: synthetic-shared-id\n: synthetic-comment\nretry: 123\nx-synthetic: keep\n"
    return fields.encode() + b"data: " + encoded(value) + b"\n\n"


def fixture(model, name):
    """Synthetic native tools/thinking/signatures/usage and opaque documents."""
    return [
        {"type": "message_start", "model": UPSTREAM_MODEL, "message": {
            "id": "msg_synthetic_shared", "type": "message", "role": "assistant",
            "model": model, "content": [], "stop_reason": None,
            "usage": {"input_tokens": 3, "output_tokens": 0,
                      "cache_creation_input_tokens": 1, "cache_read_input_tokens": 2,
                      "vendor": {"model": UPSTREAM_MODEL}},
            "vendor": {"model": UPSTREAM_MODEL}},
         "vendor": {"message": {"model": UPSTREAM_MODEL}}},
        {"type": "content_block_start", "index": 0, "content_block": {
            "type": "thinking", "thinking": "", "signature": "synthetic-initial"}},
        {"type": "content_block_delta", "index": 0, "delta": {
            "type": "thinking_delta", "thinking": "synthetic 思考🌍"}},
        {"type": "content_block_delta", "index": 0, "delta": {
            "type": "signature_delta", "signature": "synthetic-signed-byte-string"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "content_block_start", "index": 1, "content_block": {
            "type": "redacted_thinking", "data": "synthetic-redacted"}},
        {"type": "content_block_stop", "index": 1},
        {"type": "content_block_start", "index": 2, "content_block": {
            "type": "tool_use", "id": "call_synthetic_shared", "name": name,
            "input": {}, "vendor": {"model": UPSTREAM_MODEL}}},
        {"type": "content_block_delta", "index": 2, "delta": {
            "type": "input_json_delta", "partial_json": '{"model":'}},
        {"type": "content_block_delta", "index": 2, "delta": {
            "type": "input_json_delta", "partial_json": '"kimi-for-coding"}'}},
        {"type": "content_block_stop", "index": 2},
        {"type": "content_block_start", "index": 3, "content_block": {
            "type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 3, "delta": {
            "type": "text_delta", "text": "synthetic 你好🌍"}},
        {"type": "content_block_stop", "index": 3},
        {"type": "synthetic_future", "message": {"model": UPSTREAM_MODEL},
         "opaque": [None, True, 42]},
        {"type": "message_delta", "delta": {
            "stop_reason": "tool_use", "stop_sequence": None}, "usage": {
            "output_tokens": 7, "cache_read_input_tokens": 4,
            "vendor": {"model": UPSTREAM_MODEL}}},
        {"type": "message_stop"},
    ]


def buffered(model):
    return {"id": "msg_synthetic_buffered", "type": "message", "role": "assistant",
            "model": model, "content": [
                {"type": "thinking", "thinking": "synthetic 思考",
                 "signature": "synthetic-signature"},
                {"type": "tool_use", "id": "call_synthetic", "name": "lookup",
                 "input": {"model": UPSTREAM_MODEL}}],
            "stop_reason": "tool_use", "stop_sequence": None,
            "usage": {"input_tokens": 3, "output_tokens": 7},
            "vendor": {"model": UPSTREAM_MODEL}}


def payload(model=MODEL_A, scene="good"):
    return {
        "model": model, "stream": True, "max_tokens": 128,
        "thinking": {"type": "enabled", "budget_tokens": 32},
        "system": [{"type": "text", "text": "synthetic system"}],
        "messages": [
            {"role": "assistant", "content": [
                {"type": "thinking", "thinking": "synthetic history",
                 "signature": "synthetic-history-signature"},
                {"type": "tool_use", "id": "call_history", "name": "lookup",
                 "input": {"model": UPSTREAM_MODEL}}]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "call_history",
                 "content": '{"model":"kimi-for-coding"}'},
                {"type": "text", "text": "synthetic hello 思考🌍"}]},
        ],
        "tools": [{"name": "lookup", "input_schema": {
            "type": "object", "properties": {"model": {"type": "string"}}}}],
        "vendor": {"model": UPSTREAM_MODEL, "signature": "synthetic-vendor"},
        "synthetic_scene": scene,
    }


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_bytes(self, data, one_byte=False):
        parts = (bytes([byte]) for byte in data) if one_byte else [data]
        for part in parts:
            self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
        self.wfile.flush()

    def do_POST(self):
        self.close_connection = True
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        scene = body.get("synthetic_scene", "good")
        key = KEY_B if scene == "isolation-b" else KEY_A
        with self.server.lock:
            self.server.observations.append({
                "path": self.path, "body": body,
                "key_ok": self.headers.get("Authorization") == "Bearer " + key,
                "accept": self.headers.get("Accept"),
                "encoding": self.headers.get("Accept-Encoding"),
                "version": self.headers.get("anthropic-version"),
                "no_device": not any(n.lower().startswith("x-msh-") for n in self.headers),
                "no_client": all(s not in json.dumps(body) for s in (CLIENT, CLIENT_B)),
            })
        if not body.get("stream"):
            data = encoded(buffered(body["model"]))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        media = {
            "bad-media": "application/json",
            "bad-charset": "text/event-stream; charset=latin1",
            "bad-media-suffix": "text/event-stream-bogus",
        }.get(scene, "text/event-stream; charset=utf-8")
        self.send_header("Content-Type", media)
        if scene == "duplicate-media":
            self.send_header("content-type", "text/event-stream")
        if scene == "gzip":
            self.send_header("Content-Encoding", "gzip")
        if scene == "duplicate-encoding":
            self.send_header("Content-Encoding", "identity")
            self.send_header("content-encoding", "identity")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        documents = fixture(body["model"], scene)
        try:
            if scene in ("wrong-model", "missing-model", "duplicate-model",
                         "duplicate-model-literal"):
                # A ping is a valid prefix; no mismatched start may be emitted.
                self.send_bytes(frame({"type": "ping", "model": UPSTREAM_MODEL}))
                wrong = copy.deepcopy(documents[0])
                if scene == "wrong-model":
                    wrong["message"]["model"] = MODEL_A
                elif scene == "missing-model":
                    del wrong["message"]["model"]
                raw = frame(wrong, True)
                if scene in ("duplicate-model", "duplicate-model-literal"):
                    # Duplicate only message.model, not the opaque root model.
                    message = encoded(wrong["message"])
                    assert raw.count(message) == 1
                    key = (b'"\\u006dodel"' if scene == "duplicate-model"
                           else b'"model"')
                    malformed = message.replace(
                        b'"model":"kimi-for-coding"',
                        b'"model":"kimi-for-coding",' + key + b':"hidden"', 1)
                    assert malformed != message
                    raw = raw.replace(message, malformed, 1)
                self.send_bytes(raw)
            else:
                self.send_bytes(frame(documents[0], True), one_byte=True)
                if scene in self.server.gates and not self.server.gates[scene].wait(8):
                    self.server.gate_timeouts.append(scene)
                    return
                if scene == "cancel":
                    for _ in range(1000):
                        self.send_bytes(frame({"type": "ping", "synthetic": True}))
                        time.sleep(0.01)
                    self.server.cancel_timeout = True
                    return
                if scene == "malformed":
                    self.send_bytes(b"event: message_delta\ndata: {broken}\n\n")
                elif scene == "invalid-utf8":
                    self.send_bytes(b"data: \xff\n\n")
                elif scene == "bad-usage":
                    self.send_bytes(frame({"type": "message_delta", "usage": {"output_tokens": -1}}))
                elif scene == "eof":
                    pass
                elif scene == "remote-error":
                    self.send_bytes(frame({"type": "error", "error": {
                        "type": "overloaded_error", "message": "synthetic error",
                        "opaque": [1, 2]}, "vendor": {"model": UPSTREAM_MODEL}}))
                elif scene not in {
                    "bad-media", "bad-charset", "bad-media-suffix",
                    "duplicate-media", "gzip", "duplicate-encoding",
                }:
                    for document in documents[1:]:
                        self.send_bytes(frame(document), one_byte=True)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            if scene == "cancel":
                self.server.cancel_closed.set()


@contextlib.contextmanager
def upstream():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    server.daemon_threads = True
    server.observations, server.lock = [], threading.Lock()
    server.gates = {scene: threading.Event()
                    for scene in ("good", "isolation-a", "isolation-b", "cancel")}
    server.gate_timeouts = []
    server.cancel_closed, server.cancel_timeout = threading.Event(), False
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        for gate in server.gates.values():
            gate.set()
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


class ChunkBody:
    """Fixture-side raw HTTP chunks: zero chunk != TCP EOF != timeout."""

    def __init__(self, file):
        self.file, self.clean = file, None

    def read(self):
        if self.clean is not None:
            return None
        try:
            line = self.file.readline(128)
            if not line:
                self.clean = False
                return None
            assert line.endswith(b"\r\n"), "invalid HTTP chunk size line"
            size = int(line[:-2].split(b";", 1)[0], 16)
            assert 0 <= size <= 1_048_576, "HTTP chunk exceeds harness bound"
            if size == 0:
                # A zero chunk is clean only after its trailer terminator.
                for _ in range(64):
                    trailer = self.file.readline(8192)
                    if trailer == b"\r\n":
                        self.clean = True
                        return None
                    if not trailer:
                        self.clean = False
                        return None
                    assert trailer.endswith(b"\r\n"), "invalid HTTP trailer"
                raise AssertionError("too many HTTP trailers")
            data = self.file.read(size)
            if len(data) != size:
                self.clean = False
                return None
            suffix = self.file.read(2)
            if len(suffix) != 2:
                self.clean = False
                return None
            assert suffix == b"\r\n", "invalid HTTP chunk delimiter"
            return data
        except (ConnectionResetError, BrokenPipeError):
            self.clean = False
            return None
        except socket.timeout:
            raise AssertionError("timeout is not evidence of HTTP closure") from None


class Response:
    """Small synthetic HTTP client, never used by production MIMIC."""

    def __init__(self, sock):
        self.sock, self.file = sock, sock.makefile("rb")
        status = self.file.readline(8192)
        assert status.startswith(b"HTTP/1.1 "), "missing HTTP/1.1 response"
        self.status = int(status.split(b" ", 2)[1])
        self.headers = {}
        for _ in range(64):
            line = self.file.readline(8192)
            if line == b"\r\n":
                break
            assert line.endswith(b"\r\n") and b":" in line, "invalid HTTP header"
            name, value = line[:-2].split(b":", 1)
            self.headers.setdefault(name.decode().lower(), []).append(value.strip().decode())
        else:
            raise AssertionError("too many HTTP headers")
        self.chunks, self.pending = ChunkBody(self.file), b""

    def next_frame(self):
        assert self.headers.get("transfer-encoding") == ["chunked"]
        while b"\n\n" not in self.pending:
            chunk = self.chunks.read()
            if chunk is None:
                assert not self.pending, "HTTP ended within downstream SSE frame"
                return None
            self.pending += chunk
            assert len(self.pending) <= 1_048_576, "SSE fixture exceeds bound"
        raw, self.pending = self.pending.split(b"\n\n", 1)
        data, name = [], ""
        for line in raw.decode().split("\n"):
            if line.startswith("event:"):
                name = line[6:].removeprefix(" ")
            elif line.startswith("data:"):
                data.append(line[5:].removeprefix(" "))
        assert data, "fixture frame has no JSON data"
        return name, json.loads("\n".join(data)), raw + b"\n\n"

    def all_frames(self):
        frames = []
        while True:
            item = self.next_frame()
            if item is None:
                return frames
            frames.append(item)

    def body(self):
        if self.headers.get("transfer-encoding") == ["chunked"]:
            result = []
            while True:
                chunk = self.chunks.read()
                if chunk is None:
                    assert self.chunks.clean, "truncated non-SSE response"
                    return b"".join(result)
                result.append(chunk)
        length = self.headers.get("content-length")
        assert length is not None and len(length) == 1, "unbounded HTTP response"
        size = int(length[0])
        assert 0 <= size <= 1_048_576
        result = self.file.read(size)
        assert len(result) == size, "truncated HTTP response"
        return result

    def close(self, cancel=False):
        if cancel:
            self.sock.shutdown(socket.SHUT_RDWR)
        self.file.close()
        self.sock.close()


def connect(port, body, key=CLIENT, path="/v1/messages"):
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    raw = encoded(body)
    try:
        sock.sendall((
            f"POST {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
            f"Authorization: Bearer {key}\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(raw)}\r\nConnection: close\r\n"
            "X-Client-Request-Id: synthetic-shared-hint\r\n\r\n"
        ).encode() + raw)
        return Response(sock)
    except BaseException:
        sock.close()
        raise


def assert_no_secrets(data):
    assert all(secret.encode() not in data for secret in SECRETS)


def complete(port, server, model=MODEL_A, scene="good", key=CLIENT,
             path="/v1/messages", direct_fixture=False):
    response = connect(port, payload(model, scene), key, path)
    expected = fixture(model, scene)
    try:
        assert response.status == 200, f"{scene}: expected SSE, got {response.status}"
        first = response.next_frame()
        assert first[:2] == ("message_start", expected[0])
        for field in (b"id: synthetic-shared-id\n", b": synthetic-comment\n",
                      b"retry: 123\n", b"x-synthetic: keep\n"):
            assert field in first[2], "start SSE metadata changed"
        if scene in server.gates:
            server.gates[scene].set()
        rest = response.all_frames()
        assert response.chunks.clean is True, f"{scene}: valid stream truncated"
        assert [(n, v) for n, v, _ in rest] == [(v["type"], v) for v in expected[1:]]
        assert [r for _, _, r in rest] == [frame(v) for v in expected[1:]], (
            "non-start raw frames changed")
        assert_no_secrets(b"".join(r for _, _, r in [first, *rest]))
        if not direct_fixture:
            assert response.headers.get("content-type") == ["text/event-stream"]
    finally:
        response.close()


def exercises(port, server):
    complete(port, server)
    # Same upstream model/msg/tool IDs/hint, concurrent distinct clients/accounts.
    opened = []
    try:
        for model, scene, key in [(MODEL_A, "isolation-a", CLIENT),
                                  (MODEL_B, "isolation-b", CLIENT_B)]:
            response = connect(port, payload(model, scene), key)
            opened.append((response, model, scene))
            assert response.status == 200
            assert response.next_frame()[:2] == ("message_start", fixture(model, scene)[0])
        for response, model, scene in reversed(opened):
            server.gates[scene].set()
            assert [(n, v) for n, v, _ in response.all_frames()] == [
                (v["type"], v) for v in fixture(model, scene)[1:]]
            assert response.chunks.clean is True
    finally:
        for response, _, _ in opened:
            response.close()
    for scene in ("wrong-model", "missing-model", "duplicate-model",
                  "duplicate-model-literal", "malformed",
                  "invalid-utf8", "bad-usage", "eof"):
        response = connect(port, payload(scene=scene))
        try:
            assert response.status == 200, (scene, response.status)
            frames = response.all_frames()
            assert len(frames) == 1, (scene, frames)
            expected = ({"type": "ping", "model": UPSTREAM_MODEL} if scene in {
                "wrong-model", "missing-model", "duplicate-model",
                "duplicate-model-literal"}
                else fixture(MODEL_A, scene)[0])
            assert frames[0][:2] == (expected["type"], expected)
            assert response.chunks.clean is False, f"{scene}: protocol error looked clean"
        finally:
            response.close()
    response = connect(port, payload(scene="remote-error"))
    try:
        assert response.status == 200
        frames = response.all_frames()
        assert response.chunks.clean is True
        assert [(n, v) for n, v, _ in frames] == [
            ("message_start", fixture(MODEL_A, "remote-error")[0]),
            ("error", {"type": "error", "error": {
                "type": "overloaded_error", "message": "synthetic error", "opaque": [1, 2]},
                "vendor": {"model": UPSTREAM_MODEL}})]
    finally:
        response.close()
    for scene, expected_status in (
        ("bad-media", 502), ("bad-charset", 503), ("bad-media-suffix", 503),
        ("duplicate-media", 503), ("gzip", 503), ("duplicate-encoding", 503),
    ):
        before = len(server.observations)
        response = connect(port, payload(scene=scene))
        try:
            # Egress rejects malformed headers before gateway's SSE gate.
            assert response.status == expected_status, (scene, response.status)
            assert_no_secrets(response.body())
            assert len(server.observations) == before + 1, "header error retried"
        finally:
            response.close()
    response = connect(port, payload(scene="cancel"))
    try:
        assert response.status == 200
        assert response.next_frame()[:2] == ("message_start", fixture(MODEL_A, "cancel")[0])
    finally:
        response.close(cancel=True)
        server.gates["cancel"].set()
    assert server.cancel_closed.wait(8), "downstream close did not close upstream"
    assert not server.cancel_timeout
    complete(port, server, scene="after-cancel")
    before = len(server.observations)
    for replacement in [
        {"messages": [{"role": "assistant", "content": [
            {"type": "thinking", "thinking": "synthetic unsigned"}]}]},
        {"messages": [{"role": "user", "content": [{"type": "audio", "data": "synthetic"}]}]},
        {"previous_response_id": "synthetic-unsupported"},
    ]:
        body = payload(scene="unsupported")
        body.update(replacement)
        response = connect(port, body)
        try:
            assert response.status == 422, response.status
            assert_no_secrets(response.body())
        finally:
            response.close()
    assert len(server.observations) == before, "unsupported request reached upstream"
    body = payload(scene="buffered")
    body["stream"] = False
    response = connect(port, body)
    try:
        assert response.status == 200
        data = response.body()
        assert json.loads(data) == buffered(MODEL_A), "existing buffered semantics changed"
        assert_no_secrets(data)
    finally:
        response.close()
    for observed in server.observations:
        scene = observed["body"]["synthetic_scene"]
        expected = payload(MODEL_B if scene == "isolation-b" else MODEL_A, scene)
        expected["model"] = UPSTREAM_MODEL
        if scene == "buffered":
            expected["stream"] = False
        assert observed["body"] == expected, "native request/tool/thinking semantics changed"
        assert observed["path"] == UPSTREAM_PATH
        assert observed["key_ok"] and observed["no_device"] and observed["no_client"]
        assert observed["encoding"] == "identity"
        assert observed["version"] == "2023-06-01"
        assert observed["accept"] == ("text/event-stream" if expected["stream"] else "application/json")
    assert not server.gate_timeouts, "prefix was not delivered incrementally"


def reader_controls():
    """Real-socket controls prove a zero chunk, close and timeout differ."""
    for wire, expected, clean in [
        (b"3\r\nabc\r\n0\r\n\r\n", [b"abc"], True),
        (b"3\r\nabc\r\n", [b"abc"], False),
        (b"3\r\nab", [], False),
        (b"0\r\n", [], False),
    ]:
        reader, writer = socket.socketpair()
        with reader, writer:
            writer.sendall(wire)
            writer.shutdown(socket.SHUT_WR)
            with reader.makefile("rb") as file:
                body, received = ChunkBody(file), []
                while True:
                    chunk = body.read()
                    if chunk is None:
                        break
                    received.append(chunk)
                assert received == expected and body.clean is clean
    reader, writer = socket.socketpair()
    with reader, writer:
        reader.settimeout(0.02)
        with reader.makefile("rb") as file:
            try:
                ChunkBody(file).read()
            except AssertionError as error:
                assert "timeout is not evidence" in str(error)
            else:
                raise AssertionError("reader accepted timeout as stream closure")


def self_test():
    # Fixture/client checks only. No actual CLI, gateway or shipment execution.
    reader_controls()
    with upstream() as server:
        complete(server.server_port, server, key=KEY_A, path=UPSTREAM_PATH,
                 direct_fixture=True)
        assert len(server.observations) == 1 and not server.gate_timeouts
    print(json.dumps({"scope": "f14_harness_self_test", "synthetic": True,
                      "real_sockets": True, "clean_close_timeout_controls": True,
                      "mimic_executed": False}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path,
                        help="exported Erlang shipment, executed from a different cwd")
    parser.add_argument("--self-test", action="store_true",
                        help="fixture/reader controls only, not MIMIC")
    args = parser.parse_args()
    if args.self_test:
        assert args.shipment is None
        self_test()
        return
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else
               [os.environ.get("GLEAM", "gleam"), "run", "--"])
    reader_controls()
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f14-kimi-messages-",
                                     dir=ROOT / "build/integration") as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        cwd = directory if args.shipment else ROOT
        with upstream() as server:
            config = directory / "providers.json"
            config.write_text(json.dumps({
                "version": 1, "state_dir": str(state), "listen_port": port,
                "accounts": [{
                    "provider": "kimi", "auth_mode": "api_key",
                    "id": "synthetic-native-" + suffix,
                    "origin": f"http://127.0.0.1:{server.server_port}",
                    "base_path": "/tenant/native/v1", "models": [model],
                } for suffix, model in [("a", MODEL_A), ("b", MODEL_B)]],
            }))

            def cli(*arguments):
                result = subprocess.run([*command, *arguments], cwd=cwd,
                                        capture_output=True, timeout=60, check=False)
                output = result.stdout + result.stderr
                assert_no_secrets(output)
                assert result.returncode == 0, (
                    f"CLI {arguments[:3]} failed: " + output.decode(errors="replace"))

            for suffix, key in [("a", KEY_A), ("b", KEY_B)]:
                credential = BASE["private_file"](
                    directory / f"synthetic-{suffix}.json", json.dumps({"api_key": key}))
                cli("providers", "credential", "import", str(config),
                    "synthetic-native-" + suffix, credential)
            for suffix, key in [("a", CLIENT), ("b", CLIENT_B)]:
                key_file = BASE["private_file"](
                    directory / f"client-{suffix}.txt", key + "\n")
                cli("providers", "key", "import", str(config),
                    "synthetic-client-" + suffix, key_file)
            log_path = directory / "gateway.log"
            with log_path.open("wb") as log:
                process = BASE["start"](command, config, port, log, state, cwd)
                try:
                    exercises(port, server)
                finally:
                    BASE["stop"](process, state)
            assert_no_secrets(log_path.read_bytes())
            print(json.dumps({
                "scope": "f14_shipment_cli" if args.shipment else "f14_source_cli",
                "synthetic": True, "provider": "kimi",
                "incremental_utf8_byte_splits": True,
                "tools_thinking_signatures_usage": True,
                "protocol_owned_model_restoration": True,
                "valid_prefix_before_error": True, "downstream_cancel": True,
                "concurrent_client_account_alias_isolation": True,
                "clean_close_timeout_controls": True, "buffered_semantics_preserved": True,
                "upstream_requests": len(server.observations),
                "different_working_directory": cwd != ROOT,
                "native_live_cpa_differential_qualification": False,
            }, sort_keys=True))


if __name__ == "__main__":
    main()
