#!/usr/bin/env python3
"""F15 synthetic real-socket CLI/shipment Chat SSE checks; no live/CPA calls."""

import argparse
import contextlib
import copy
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
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
CLIENT_B = "synthetic-f15-second-client-0001"
KEY_A = "synthetic-f15-generic-api-key-a"
KEY_B = "synthetic-f15-generic-api-key-b"
SECRETS = [CLIENT, CLIENT_B, KEY_A, KEY_B]
MODEL_A = "kimi-k2.8"
MODEL_B = "synthetic-generic-kimi-alternate"
UPSTREAM_PATH = "/tenant/generic/v1/chat/completions"


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def frame(value, name=""):
    prefix = f"event: {name}\n" if name else ""
    data = "[DONE]" if value == "[DONE]" else encoded(value).decode()
    return (prefix + "data: " + data + "\n\n").encode()


def fixture(model, name):
    """Full native documents, including values that native transforms would alter."""
    def chunk(delta, finish=None, choices=None, **extra):
        return {
            "id": "chat_synthetic_shared_id",
            "object": "chat.completion.chunk",
            "created": 1,
            "model": model,
            "choices": choices if choices is not None else [
                {"index": 0, "delta": delta, "finish_reason": finish,
                 "logprobs": {"content": []}, "opaque": {"audio": [1, None]}}
            ],
            "system_fingerprint": "fp_synthetic",
            "vendor": {"model": "kimi-for-coding", "thinking": {"opaque": True}},
            **extra,
        }
    return [
        chunk({"role": "assistant", "content": "你好🌍",
               "reasoning_content": "synthetic 思考", "refusal": None,
               "vendor": {"model": "kimi-for-coding"}}),
        chunk({"tool_calls": [
            {"index": 0, "id": "call_synthetic_shared_id", "type": "function",
             "function": {"name": name, "arguments": '{"model":'},
             "vendor": {"audio": {"type": "input_audio"}}}
        ]}),
        chunk({"tool_calls": [
            {"index": 0, "function": {"arguments": '"kimi-for-coding"}'}}
        ]}, "tool_calls", opaque=[None, True, {"synthetic": 42}]),
        chunk({}, choices=[], usage={
            "prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7,
            "completion_tokens_details": {"reasoning_tokens": 2},
            "prompt_tokens_details": {"cached_tokens": 1}, "vendor": [1, 2],
        }),
        "[DONE]",
    ]


def buffered(model):
    return {
        "id": "chat_synthetic_buffered", "object": "chat.completion",
        "created": 1, "model": model,
        "choices": [{"index": 0, "message": {
            "role": "assistant", "content": "synthetic reply",
            "reasoning_content": "synthetic thinking", "refusal": None,
            "vendor": {"model": "kimi-for-coding"},
        }, "finish_reason": "stop", "logprobs": None}],
        "usage": {"prompt_tokens": 3, "completion_tokens": 1, "total_tokens": 4},
        "vendor": {"opaque": [None, "kimi-for-coding"]},
    }


def payload(model=MODEL_A, scenario="good"):
    return {
        "model": model, "stream": True, "stream_options": {"include_usage": True},
        "temperature": 0.2, "top_p": 0.8, "max_tokens": 64,
        "parallel_tool_calls": False, "tool_choice": "auto",
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "user", "content": [
                {"type": "text", "text": "synthetic hello 思考🌍"},
                {"type": "image_url", "image_url": {
                    "url": "data:image/png;base64,AA==", "detail": "low"}},
            ]},
            {"role": "assistant", "content": None,
             "reasoning_content": "synthetic history",
             "tool_calls": [{"id": "call_history", "type": "function",
                             "function": {"name": "audio", "arguments": "{}"}}]},
            {"role": "tool", "tool_call_id": "call_history",
             "content": '{"audio":"synthetic result"}'},
        ],
        "tools": [{"type": "function", "function": {
            "name": "audio", "parameters": {"type": "object", "properties": {
                "audio": {"type": "string"}, "content": {"type": "array"}}}}}],
        "thinking": {"type": "opaque"},
        "vendor": {"model": "kimi-for-coding", "audio": {"type": "input_audio"}},
        "synthetic_scenario": scenario,
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
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw)
        scene = body.get("synthetic_scenario", "good")
        key = KEY_A if body["model"] == MODEL_A else KEY_B
        with self.server.lock:
            self.server.observations.append({
                "path": self.path, "body": body, "raw": raw,
                "key_ok": self.headers.get("Authorization") == "Bearer " + key,
                "accept": self.headers.get("Accept"),
                "encoding": self.headers.get("Accept-Encoding"),
                "no_device": not any(
                    name.lower().startswith("x-msh-") for name in self.headers),
                "no_client_key": CLIENT.encode() not in raw
                    and CLIENT_B.encode() not in raw,
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
            self.send_bytes(frame(documents[0]), one_byte=True)
            if scene in self.server.gates:
                # The client must observe the prefix before the server finishes.
                if not self.server.gates[scene].wait(8):
                    self.server.gate_timeouts.append(scene)
                    return
            if scene == "cancel":
                for _ in range(1000):
                    self.send_bytes(frame(documents[0]))
                    time.sleep(0.01)
                self.server.cancel_timeout = True
                return
            if scene == "malformed":
                self.send_bytes(b"data: {broken}\n\n")
            elif scene == "wrong-model":
                wrong = copy.deepcopy(documents[1])
                wrong["model"] = "kimi-for-coding"
                self.send_bytes(frame(wrong))
            elif scene == "wrong-tool":
                self.send_bytes(frame(documents[1]))
                wrong = copy.deepcopy(documents[2])
                wrong["choices"][0]["delta"]["tool_calls"][0]["id"] = "changed_id"
                self.send_bytes(frame(wrong))
            elif scene == "invalid-utf8":
                self.send_bytes(b"data: \xff\n\n")
            elif scene == "eof":
                pass
            elif scene == "remote-error":
                self.send_bytes(frame({
                    "error": {"message": "synthetic error", "code": "vendor_code",
                              "opaque": [1, 2]},
                    "vendor": {"model": "kimi-for-coding"},
                }, "error"))
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
    server.observations = []
    server.lock = threading.Lock()
    server.gates = {scene: threading.Event()
                    for scene in ("good", "isolation-a", "isolation-b", "cancel")}
    server.gate_timeouts = []
    server.cancel_closed = threading.Event()
    server.cancel_timeout = False
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


def connect(port, body, key=CLIENT, path="/v1/chat/completions"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("POST", path, encoded(body), {
        "Authorization": "Bearer " + key, "Content-Type": "application/json",
        "X-Client-Request-Id": "synthetic-shared-request-id",
    })
    return connection, connection.getresponse()


def read_frame(response):
    """Only decode downstream fixture frames; production uses shared Gleam SSE."""
    data, name = [], ""
    while True:
        # HTTPResponse.readline uses peek(), which can turn a missing terminal
        # HTTP chunk into ordinary EOF. read() preserves IncompleteRead.
        raw = bytearray()
        while len(raw) <= 1_048_576:
            byte = response.read(1)
            if not byte:
                assert not raw, "downstream ended within an SSE line"
                break
            raw.extend(byte)
            if byte == b"\n":
                break
        if raw == b"":
            return None
        assert len(raw) <= 1_048_576, "downstream frame exceeds bound"
        line = raw.decode().rstrip("\r\n")
        if line == "":
            if not data:
                continue
            value = "\n".join(data)
            return name, "[DONE]" if value == "[DONE]" else json.loads(value)
        if line.startswith("data:"):
            data.append(line[5:].removeprefix(" "))
        elif line.startswith("event:"):
            name = line[6:].removeprefix(" ")
        elif not line.startswith(":"):
            raise AssertionError("unexpected downstream SSE field")


def read_all(response):
    frames, closed_abnormally = [], False
    try:
        while True:
            next_frame = read_frame(response)
            if next_frame is None:
                return frames, closed_abnormally
            frames.append(next_frame)
    except socket.timeout:
        raise AssertionError("downstream timeout is not evidence of closure") from None
    except (http.client.IncompleteRead, http.client.RemoteDisconnected,
            ConnectionResetError):
        return frames, True


def assert_no_secrets(data):
    assert all(secret.encode() not in data for secret in SECRETS)


def complete(port, server, model=MODEL_A, scene="good", key=CLIENT, path=None,
             media="text/event-stream"):
    body = payload(model, scene)
    connection, response = connect(port, body, key, path or "/v1/chat/completions")
    try:
        assert response.status == 200, (
            f"{scene}: expected SSE admission, got {response.status}")
        assert response.getheader("content-type") == media
        first = read_frame(response)
        assert first == ("", fixture(model, scene)[0])
        if scene in server.gates:
            server.gates[scene].set()
        rest, interrupted = read_all(response)
        assert not interrupted, f"{scene}: valid stream closed abnormally"
        assert [first, *rest] == [("", value) for value in fixture(model, scene)]
        assert_no_secrets(encoded([first, *rest]))
    finally:
        response.close()
        connection.close()


def exercises(port, server):
    complete(port, server)
    # Keep both streams open: reused chat/tool IDs belong to separate requests.
    connections = []
    try:
        for model, scene, key in [
            (MODEL_A, "isolation-a", CLIENT),
            (MODEL_B, "isolation-b", CLIENT_B),
        ]:
            connection, response = connect(port, payload(model, scene), key)
            connections.append((connection, response, model, scene))
            assert response.status == 200
            assert read_frame(response) == ("", fixture(model, scene)[0])
        for _, response, model, scene in reversed(connections):
            server.gates[scene].set()
            frames, interrupted = read_all(response)
            assert not interrupted
            assert frames == [("", value) for value in fixture(model, scene)[1:]]
    finally:
        for connection, response, _, _ in connections:
            response.close()
            connection.close()
    for scene, expected_count in [
        ("malformed", 1), ("wrong-model", 1), ("wrong-tool", 2),
        ("invalid-utf8", 1), ("eof", 1),
    ]:
        connection, response = connect(port, payload(scenario=scene))
        try:
            assert response.status == 200
            frames, interrupted = read_all(response)
            assert len(frames) == expected_count, (scene, frames)
            assert frames[0] == ("", fixture(MODEL_A, scene)[0])
            assert all(value != "[DONE]" for _, value in frames)
            assert interrupted, f"{scene}: protocol failure looked like clean completion"
        finally:
            response.close()
            connection.close()
    connection, response = connect(port, payload(scenario="remote-error"))
    try:
        frames, interrupted = read_all(response)
        assert response.status == 200 and not interrupted
        assert frames == [
            ("", fixture(MODEL_A, "remote-error")[0]),
            ("error", {"error": {"message": "synthetic error", "code": "vendor_code",
                                "opaque": [1, 2]},
                       "vendor": {"model": "kimi-for-coding"}}),
        ]
    finally:
        response.close()
        connection.close()
    # JSON is valid egress media but not SSE (gateway 502). The remaining
    # malformed headers are rejected by egress before Opened exists; its
    # Unavailable/Uncertain result maps to the existing gateway 503.
    for scene, expected_status in (
        ("bad-media", 502), ("bad-charset", 503), ("bad-media-suffix", 503),
        ("duplicate-media", 503), ("gzip", 503), ("duplicate-encoding", 503),
    ):
        before = len(server.observations)
        connection, response = connect(port, payload(scenario=scene))
        try:
            assert response.status == expected_status, (scene, response.status)
            assert_no_secrets(response.read())
            assert len(server.observations) == before + 1, "header failure retried"
        finally:
            response.close()
            connection.close()
    connection, response = connect(port, payload(scenario="cancel"))
    try:
        assert response.status == 200
        assert read_frame(response) == ("", fixture(MODEL_A, "cancel")[0])
        # If HTTPConnection still owns TCP, shut it down explicitly. Otherwise
        # response.close() below closes the last holder of a close-delimited TCP.
        if connection.sock is not None:
            connection.sock.shutdown(socket.SHUT_RDWR)
    finally:
        response.close()
        connection.close()
        server.gates["cancel"].set()
    assert server.cancel_closed.wait(8), "downstream close did not cancel upstream"
    assert not server.cancel_timeout
    complete(port, server, scene="after-cancel")
    before = len(server.observations)
    for role in ("system", "developer", "user", "assistant", "tool"):
        for part in [
            {"type": "input_audio", "input_audio": {"data": "AA==", "format": "wav"}},
            {"type": "video_url", "video_url": {"url": "https://synthetic.invalid/v"}},
            {"type": "input_file", "file_id": "synthetic-file"},
            {"type": "image_url", "image_url": {"url": "data:audio/wav;base64,AA=="}},
        ]:
            body = payload(scenario="unsupported-media")
            body["messages"] = [{"role": role, "tool_call_id": "synthetic",
                                 "content": [part]}]
            connection, response = connect(port, body)
            try:
                assert response.status == 422, (role, part["type"], response.status)
                assert_no_secrets(response.read())
            finally:
                response.close()
                connection.close()
    body = payload(scenario="unsupported-message-audio")
    body["messages"] = [{"role": "assistant", "content": None,
                         "audio": {"id": "synthetic-audio"}}]
    connection, response = connect(port, body)
    try:
        assert response.status == 422
        assert_no_secrets(response.read())
    finally:
        response.close()
        connection.close()
    assert len(server.observations) == before, "unsupported media reached upstream"
    body = payload(scenario="buffered")
    body["stream"] = False
    connection, response = connect(port, body)
    try:
        assert response.status == 200
        raw = response.read()
        assert raw == encoded(buffered(MODEL_A)), "buffered response changed"
        assert_no_secrets(raw)
    finally:
        response.close()
        connection.close()
    for observed in server.observations:
        assert observed["path"] == UPSTREAM_PATH
        assert observed["key_ok"] and observed["no_device"] and observed["no_client_key"]
        expected = payload(observed["body"]["model"],
                           observed["body"]["synthetic_scenario"])
        if expected["synthetic_scenario"] == "buffered":
            expected["stream"] = False
        assert observed["raw"] == encoded(expected), "native request bytes changed"
        assert observed["encoding"] == "identity"
        assert observed["accept"] == (
            "text/event-stream" if expected["stream"] else "application/json")
    assert not server.gate_timeouts, "prefix was not forwarded incrementally"


def reader_self_test():
    """Prove HTTP EOF is not confused with a valid zero chunk or a timeout."""
    class BufferedSocket:
        def __init__(self, wire):
            self.wire = wire

        def makefile(self, *_):
            return io.BufferedReader(io.BytesIO(self.wire))

    document = {"synthetic": True}
    data = frame(document)
    head = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
    chunk = f"{len(data):x}\r\n".encode() + data + b"\r\n"
    for terminal in (False, True):
        wire = head + chunk + (b"0\r\n\r\n" if terminal else b"")
        response = http.client.HTTPResponse(BufferedSocket(wire))
        response.begin()
        try:
            frames, interrupted = read_all(response)
            assert frames == [("", document)]
            assert interrupted == (not terminal)
        finally:
            response.close()

    class TimeoutResponse:
        def read(self, _):
            raise socket.timeout("synthetic timeout")

    try:
        read_all(TimeoutResponse())
    except AssertionError as error:
        assert str(error) == "downstream timeout is not evidence of closure"
    else:
        raise AssertionError("timeout was accepted as stream closure")


def cli_command(shipment, gleam):
    if shipment is not None:
        return ["sh", str(shipment.resolve() / "entrypoint.sh"), "run"]
    return [gleam, "run", "--"]


def self_test():
    # Verify fixture framing and the incremental gate against real local sockets.
    # This is intentionally NOT a MIMIC/root or shipment result.
    reader_self_test()
    assert cli_command(None, "/synthetic toolchain/gleam") == [
        "/synthetic toolchain/gleam", "run", "--",
    ]
    assert cli_command(ROOT / "build/erlang-shipment", "unused") == [
        "sh", str((ROOT / "build/erlang-shipment/entrypoint.sh").resolve()), "run",
    ]
    with upstream() as server:
        complete(server.server_port, server, key=KEY_A, path=UPSTREAM_PATH,
                 media="text/event-stream; charset=utf-8")
        assert len(server.observations) == 1 and not server.gate_timeouts
    print(json.dumps({"scope": "f15_harness_self_test", "synthetic": True,
                      "local_sockets": True, "mimic_executed": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path,
                        help="exported Erlang shipment; run from a different cwd")
    parser.add_argument("--self-test", action="store_true",
                        help="test the synthetic harness only, not MIMIC")
    args = parser.parse_args()
    if args.self_test:
        assert args.shipment is None
        self_test()
        return
    command = cli_command(args.shipment, os.environ.get("GLEAM", "gleam"))
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f15-kimi-compat-",
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
                    "provider": "openai-compatible-kimi", "auth_mode": "api_key",
                    "id": "synthetic-generic-" + suffix,
                    "origin": f"http://127.0.0.1:{server.server_port}",
                    "base_path": "/tenant/generic/v1", "models": [model],
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
                    directory / f"synthetic-{suffix}.json",
                    json.dumps({"api_key": key}))
                cli("providers", "credential", "import", str(config),
                    "synthetic-generic-" + suffix, credential)
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
                "scope": "f15_shipment_cli" if args.shipment else "f15_source_cli",
                "synthetic": True, "provider": "openai-compatible-kimi",
                "incremental_utf8_byte_splits": True, "native_documents": True,
                "valid_prefix_before_error": True, "downstream_cancel": True,
                "concurrent_client_account_isolation": True,
                "media_rejected_before_send": True, "buffered_unchanged": True,
                "upstream_requests": len(server.observations),
                "different_working_directory": cwd != ROOT,
                "native_live_cpa_qualification": False,
            }, sort_keys=True))


if __name__ == "__main__":
    main()
