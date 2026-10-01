#!/usr/bin/env python3
"""F24 SYNTHETIC actual-root authenticated Messages workflow, not a facade.

Requires the parent-applied F24_ROOT.patch. No source overlays, ambient grants,
remote endpoints, CPA, provider discovery, or SDK installation/execution.
Consumer construction follows pinned SDK source, and additionally fails closed
on invalid block lifecycle, missing exact usage and unsigned thinking.
"""

import argparse
import contextlib
import copy
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time

import f23_local_cli as helpers

ROOT = Path(__file__).resolve().parents[2]
BASE = helpers.BASE
MODEL = "devin/swe-1-7"
TOKEN = "synthetic-f24-cli-permanent-session"
CLIENT_KEY = BASE["CLIENT_KEY"]
field, number, data, frame = helpers.field, helpers.number, helpers.data, helpers.frame
EOS = helpers.EOS
NEGATIVES = (
    "error-trailer", "missing-eos", "post-eos-data", "truncated-http",
    "unknown-usage", "unsigned-thinking", "opaque-thinking", "custom-tool",
)


def no_secrets(raw):
    assert TOKEN.encode() not in raw and CLIENT_KEY.encode() not in raw, "F24 secret echo"


def fixture(mode):
    prefix = data(field(3, "synthetic F24 prefix"))
    exact = field(7, number(2, 8) + number(3, 5) + number(4, 4) + number(5, 3))
    if mode == "valid":
        return [
            data(field(9, "synthetic reasoning")),
            data(field(6, field(1, "first") + field(3, b'{"x":"\xe2'))),
            prefix,
            data(field(6, field(1, "second") + field(2, "two") + field(3, b"{}"))),
            data(field(3, "B")),
            data(field(6, field(1, "first") + field(2, "one") + field(3, b'\x82\xac"}'))),
            data(field(3, "C")),
            data(field(10, "CAQSsynthetic-not-verified") + field(21, "anthropic")),
            data(exact + number(5, 10)), EOS,
        ]
    if mode == "length":
        return [prefix, data(exact + number(5, 1)), EOS]
    if mode == "error-trailer":
        return [prefix, frame(2, json.dumps({"error": {"code": "unauthenticated", "message": TOKEN}}).encode())]
    if mode == "missing-eos":
        return [prefix]
    if mode == "post-eos-data":
        return [prefix, EOS + b"\x00"]
    if mode == "truncated-http":
        return [prefix, data(exact), EOS]
    if mode == "unknown-usage":
        return [prefix, data(field(7, number(3, 5))), EOS]
    if mode == "unsigned-thinking":
        return [data(field(9, "synthetic reasoning")), prefix, data(exact), EOS]
    if mode == "opaque-thinking":
        return [data(field(9, "synthetic reasoning") + field(10, b"\xff\x00") + field(21, "sealed")), data(exact), EOS]
    if mode == "custom-tool":
        return [prefix, data(field(6, field(1, "custom") + field(2, "custom") + number(6, 1)))]
    raise AssertionError("unknown synthetic mode")


class Fixture(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.mode = "valid"
        self.accepts = self.requests = self.peer_eofs = 0
        self.wire_ok = True
        self.worker = threading.Thread(target=self.serve_forever)
        self.worker.start()

    def get_request(self):
        pair = super().get_request()
        pair[0].settimeout(5)
        self.accepts += 1
        return pair

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"

    def close(self):
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "F24 fixture survived teardown"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.server.wire_ok &= all([
            self.request_version == "HTTP/1.1",
            self.path == "/exa.api_server_pb.ApiServerService/GetChatMessage",
            self.headers.get_all("Authorization") == [f"Basic {TOKEN}-{TOKEN}"],
            self.headers.get_all("Host") == [self.server.origin[7:]],
            self.headers.get_all("Content-Type") == ["application/connect+proto"],
            self.headers.get_all("Connect-Protocol-Version") == ["1"],
            body[:1] == b"\x00",
            int.from_bytes(body[1:5], "big") == len(body) - 5,
            field(3, TOKEN) in body,
            field(21, "swe-1-7") in body,
            field(10, field(1, "aGk=") + field(2, "image/png")) in body,
            field(7, "history-call") in body,
            field(11, "synthetic history reasoning") in body,
            field(12, "CAISsynthetic-history") in body,
        ])
        self.server.requests += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+proto")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for value in fixture(self.server.mode):
                self.wfile.write(f"{len(value):x}\r\n".encode() + value + b"\r\n")
                self.wfile.flush()
            if self.server.mode == "custom-tool":
                if self.connection.recv(1) == b"":
                    self.server.peer_eofs += 1
            elif self.server.mode != "truncated-http":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.server.peer_eofs += 1
        finally:
            self.close_connection = True


def payload(streaming):
    return {"model": MODEL, "max_tokens": 32, "stream": streaming, "messages": [
        {"role": "user", "content": [{"type": "image", "source": {
            "type": "base64", "media_type": "image/png", "data": "aGk=",
        }}]},
        {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "synthetic history reasoning", "signature": "CAISsynthetic-history"},
            {"type": "tool_use", "id": "history-call", "name": "lookup", "input": {"q": "x"}},
        ]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "history-call", "content": "synthetic result"}]},
        {"role": "user", "content": "next"},
    ]}


def exact_usage(value):
    assert isinstance(value, dict), "usage must be initialized"
    assert all(type(value.get(key)) is int and value[key] >= 0
               for key in ("input_tokens", "output_tokens")), "usage must be exact"


def consume(raw):
    """Independent source-derived strict accumulator AND TS callback oracle."""
    message, opened, terminal, failed = None, None, False, False
    saw_delta = False
    callbacks = []
    for name, value in helpers.parse_sse(raw):
        assert name == value["type"] and not terminal and not failed, "invalid terminal/event"
        if name == "error":
            assert value["error"] == {"type": "api_error", "message": "Devin Messages stream failed"}
            failed = True
        elif name == "message_start":
            assert message is None
            message = copy.deepcopy(value["message"])
            assert message["type"] == "message" and message["role"] == "assistant"
            assert message["id"] and message["model"] == MODEL
            assert message["content"] == [] and message["stop_reason"] is None
            assert message["stop_sequence"] is None
            exact_usage(message["usage"])
        elif name == "content_block_start":
            assert message is not None and opened is None and not saw_delta
            opened = value["index"]
            assert type(opened) is int and opened == len(message["content"]), "nonsequential start"
            block = copy.deepcopy(value["content_block"])
            assert block["type"] in ("text", "tool_use", "thinking")
            if block["type"] == "tool_use":
                assert block["id"] and block["name"] and isinstance(block["input"], dict)
            if block["type"] == "thinking":
                assert isinstance(block["signature"], str)
            message["content"].append(block)
        elif name == "content_block_delta":
            assert message is not None and value["index"] == opened == len(message["content"]) - 1
            block, delta = message["content"][-1], value["delta"]
            kind = delta["type"]
            if kind in ("text_delta", "thinking_delta"):
                key = "text" if kind == "text_delta" else "thinking"
                assert block["type"] == key and isinstance(delta[key], str)
                block[key] += delta[key]
            elif kind == "signature_delta":
                assert block["type"] == "thinking" and isinstance(delta["signature"], str)
                block["signature"] = delta["signature"]
            elif kind == "input_json_delta":
                assert block["type"] == "tool_use"
                block["input"] = json.loads(delta["partial_json"])
                assert isinstance(block["input"], dict)
            else:
                raise AssertionError("unknown delta")
        elif name == "content_block_stop":
            assert message is not None and value["index"] == opened
            block = message["content"][-1]  # Actual TS callback lookup.
            if block["type"] == "thinking":
                assert block["signature"], "unsigned thinking success"
            callbacks.append(copy.deepcopy(block))
            opened = None
        elif name == "message_delta":
            assert message is not None and opened is None and not saw_delta
            saw_delta = True
            exact_usage(value["usage"])
            for key in ("input_tokens", "output_tokens"):
                message["usage"][key] = value["usage"][key]  # Cumulative overwrite.
            message.update(value["delta"])
        elif name == "message_stop":
            assert message is not None and opened is None and saw_delta
            assert message["stop_reason"] in ("end_turn", "max_tokens", "tool_use")
            assert callbacks == message["content"], "TS callbacks differ from indexed content"
            terminal = True
        else:
            raise AssertionError("unknown event")
    assert terminal != failed, "must have exactly one terminal outcome"
    return None if failed else message


def call(port, value, streaming, auth=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=12)
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {CLIENT_KEY}"
    connection.request("POST", "/v1/messages", json.dumps(value), headers)
    try:
        response = connection.getresponse()
        raw, clean = helpers.read_all(response)
        no_secrets(raw)
        return response.status, response.getheader("Content-Type"), raw, clean
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    began = time.monotonic()
    root = ROOT / "build/f24"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="root-cli-", dir=root) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        cwd = directory if args.shipment else ROOT
        config = directory / "providers.json"
        key = BASE["private_file"](directory / "client-key", CLIENT_KEY)
        grant = BASE["private_file"](directory / "session.json", json.dumps({"session_token": TOKEN}))
        port = helpers.free_port()
        primary, fallback = Fixture(), Fixture()
        try:
            settings = {
                "version": 1, "state_dir": str(state), "listen_port": port,
                "accounts": [
                    {"provider": "devin", "auth_mode": "session_token", "id": name,
                     "origin": server.origin, "models": [MODEL]}
                    for name, server in [("one", primary), ("two", fallback)]
                ],
            }
            config.write_text(json.dumps(settings))
            for name in ("one", "two"):
                result = subprocess.run([*command, "providers", "credential", "import", str(config), name, grant],
                                        cwd=cwd, capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert result.returncode == 0, "synthetic grant import failed"
            result = subprocess.run([*command, "providers", "key", "import", str(config), "synthetic-f24-client", key],
                                    cwd=cwd, capture_output=True, timeout=30)
            no_secrets(result.stdout + result.stderr)
            assert result.returncode == 0, "synthetic client key import failed"

            @contextlib.contextmanager
            def running(index):
                log_path = directory / f"gateway-{index}.log"
                with log_path.open("wb") as log:
                    process = BASE["start"](command, config, port, log, state, cwd)
                    try:
                        yield
                    finally:
                        BASE["stop"](process, state)
                no_secrets(log_path.read_bytes())
                assert not (state / ".provider-runtime-owner").exists()

            expected = {}
            for index, (mode, streaming) in enumerate(
                (mode, streaming) for mode in ("valid", "length", *NEGATIVES) for streaming in (False, True)
            ):
                primary.mode = mode
                with running(index):
                    before = primary.requests
                    status, media, raw, clean = call(port, payload(streaming), streaming)
                    if streaming:
                        assert status == 200 and media == "text/event-stream", "actual F24 root admission required"
                        message = consume(raw)
                        if mode in NEGATIVES:
                            assert not clean and message is None
                            assert not any(name != "error" for name, _ in helpers.parse_sse(raw)), "invalid success prefix on failure"
                        else:
                            assert clean and message is not None
                            expected[mode]["id"] = message["id"]  # Request-local IDs legitimately differ.
                            assert expected[mode] == message, "buffered/SSE reconstruction mismatch"
                    elif mode in NEGATIVES:
                        assert status == 503 and media == "application/json"
                    else:
                        assert status == 200 and media == "application/json"
                        expected[mode] = json.loads(raw)
                        exact_usage(expected[mode]["usage"])
                    assert primary.requests == before + 1 and fallback.accepts == 0, "incorrect authenticated selection/replay"
            with running("preflight"):
                before = primary.requests
                assert call(port, payload(True), True, auth=False)[0] == 401
                bad = payload(True)
                bad["model"] = "devin/unknown"
                assert call(port, bad, True)[0] == 422
                bad = payload(True)
                bad["messages"] = [{"role": "user", "content": [{"type": "audio", "data": "synthetic"}]}]
                assert call(port, bad, True)[0] == 422
                assert primary.requests == before and fallback.accepts == 0, "denial performed I/O"
            assert primary.wire_ok and fallback.wire_ok, "native history mapping/header failure"
            requests = primary.requests
        finally:
            try:
                primary.close()
            finally:
                fallback.close()
    assert not directory.exists(), "F24 private synthetic state survived cleanup"
    print(json.dumps({
        "slice": "F24", "synthetic": True, "actual_root_cli": True,
        "messages_json_positive": 2, "messages_sse_positive": 2,
        "reconstruction_equal": True, "strict_source_derived_sdk_oracle": True,
        "json_started_failures": len(NEGATIVES), "sse_started_failures": len(NEGATIVES),
        "preflight_denials": 3, "native_requests": requests, "fallback_accepts": 0,
        "cleanup": True, "shipment": bool(args.shipment),
        "seconds": round(time.monotonic() - began, 3), "incremental_streaming": False,
        "sdk_execution": False, "cpa_differential": False, "native_client": False,
        "remote": False, "live": False,
    }, sort_keys=True))


if __name__ == "__main__":
    def bounded(_signal, _frame):
        raise TimeoutError("F24 actual-root CLI bounded at 120 seconds")
    signal.signal(signal.SIGALRM, bounded)
    signal.alarm(120)
    main()
