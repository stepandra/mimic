#!/usr/bin/env python3
"""F23 SYNTHETIC actual-root Chat SSE workflow; never CPA/native-client/live."""

import argparse
import base64
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[2]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
MODEL = "devin/swe-1-7"
TOKEN = "synthetic-f23-cli-permanent-session"
TEXT = "synthetic F23 prefix"
CLIENT_KEY = BASE["CLIENT_KEY"]
SECRETS = [TOKEN.encode(), CLIENT_KEY.encode()]


def varint(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def number(tag, value):
    return varint(tag << 3) + varint(value)


def field(tag, value):
    if isinstance(value, str):
        value = value.encode()
    return varint((tag << 3) | 2) + varint(len(value)) + value


def frame(flag, value):
    return bytes([flag]) + len(value).to_bytes(4, "big") + value


def data(value):
    return frame(0, value)


EOS = frame(2, b"{}")
PREFIX = data(field(3, TEXT))
NEGATIVES = (
    "error-trailer", "malformed-trailer", "missing-eos", "post-eos-data",
    "truncated-trailer", "truncated-http", "custom-tool",
)


def fixture_frames(mode):
    if mode == "valid":
        first_tool = field(1, "synthetic-call") + field(2, "lookup") + field(3, b'{"q":"\xe2')
        last_tool = field(1, "synthetic-call") + field(3, b'\x82\xac"}')
        partial = number(3, 2)
        header = field(1, "x-request-id") + field(2, "synthetic-f23-request")
        exact = number(2, 8) + number(4, 4) + number(5, 3) + number(6, 200) + field(8, header) + field(9, "swe-1-7")
        return [
            PREFIX,
            data(field(9, "synthetic reasoning") + field(10, b"\xff\x00") + field(21, "synthetic-type")),
            data(field(6, first_tool) + field(7, partial)),
            data(field(6, last_tool) + field(7, exact) + number(5, 10)),
            EOS,
        ]
    if mode in ("length", "filtered"):
        return [PREFIX, data(number(5, 1 if mode == "length" else 11)), EOS]
    if mode == "error-trailer":
        # The private-looking message deliberately echoes ONLY our synthetic
        # fixture token. The public client error must not echo it.
        trailer = json.dumps({"error": {"code": "unauthenticated", "message": TOKEN}}).encode()
        return [PREFIX, frame(2, trailer)]
    if mode == "malformed-trailer":
        return [PREFIX, frame(2, b"{")]
    if mode == "missing-eos":
        return [PREFIX]
    if mode == "post-eos-data":
        return [PREFIX, EOS + b"\x00"]
    if mode == "truncated-trailer":
        return [PREFIX, b"\x02\x00\x00\x00\x02{"]
    if mode == "truncated-http":
        return [PREFIX, EOS]
    if mode == "custom-tool":
        tool = field(1, "synthetic-custom") + field(2, "custom") + number(6, 1)
        return [PREFIX, data(field(6, tool))]
    if mode == "disconnect":
        return [PREFIX]
    raise AssertionError("unknown synthetic mode")


class Fixture(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.mode = "valid"
        self.accepts = self.requests = self.peer_eofs = 0
        self.wire_ok = True
        self.release = threading.Event()
        self.worker = threading.Thread(target=self.serve_forever)
        self.worker.start()

    def get_request(self):
        result = super().get_request()
        result[0].settimeout(5)
        self.accepts += 1
        return result

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"

    def close(self):
        self.release.set()
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "F23 fixture survived teardown"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        checks = [
            self.request_version == "HTTP/1.1",
            self.path == "/exa.api_server_pb.ApiServerService/GetChatMessage",
            self.headers.get_all("Host") == [self.server.origin[7:]],
            self.headers.get_all("Authorization") == [f"Basic {TOKEN}-{TOKEN}"],
            self.headers.get_all("Content-Type") == ["application/connect+proto"],
            self.headers.get_all("Connect-Protocol-Version") == ["1"],
            all(self.headers.get(name) is None for name in
                ("User-Agent", "Accept-Encoding", "Transfer-Encoding")),
            body[:1] == b"\x00",
            int.from_bytes(body[1:5], "big") == len(body) - 5,
            field(3, TOKEN) in body,
        ]
        self.server.wire_ok &= all(checks)
        self.server.requests += 1
        mode = self.server.mode
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+proto")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for value in fixture_frames(mode):
                self.write_chunk(value)
            if mode == "disconnect":
                assert self.server.release.wait(5), "downstream close was not released"
                # Wake the synchronous shared pull so its client send observes
                # an actual downstream RST; do not claim idle-close monitoring.
                self.write_chunk(data(field(3, "synthetic late data" * 256)))
            if mode in ("disconnect", "custom-tool"):
                # A recv timeout is NOT accepted as cancellation evidence.
                if self.connection.recv(1) == b"":
                    self.server.peer_eofs += 1
                return
            if mode != "truncated-http":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Reset is also an actual closed peer, never fixture teardown.
            self.server.peer_eofs += 1
        finally:
            self.close_connection = True

    def write_chunk(self, value):
        self.wfile.write(f"{len(value):x}\r\n".encode() + value + b"\r\n")
        self.wfile.flush()


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def no_secrets(output):
    assert not any(secret in output for secret in SECRETS), "secret in F23 output"


def parse_sse(raw):
    no_secrets(raw)
    text = raw.decode("utf-8")
    frames = []
    for block in text.split("\n\n"):
        if not block:
            continue
        lines = block.splitlines()
        name = next((line[7:] for line in lines if line.startswith("event: ")), "")
        value = "\n".join(line[6:] for line in lines if line.startswith("data: "))
        assert value, "not client SSE"
        frames.append((name, "[DONE]" if value == "[DONE]" else json.loads(value)))
    return frames


def read_stream(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    payload = {"model": MODEL, "stream": True,
               "messages": [{"role": "user", "content": "synthetic F23 hello"}]}
    connection.request("POST", "/v1/chat/completions", json.dumps(payload), {
        "Content-Type": "application/json", "Authorization": f"Bearer {CLIENT_KEY}",
    })
    try:
        response = connection.getresponse()
        assert response.status == 200, (
            "F23 root Chat SSE admission required; provider-only checkpoint is not DONE",
            response.status,
        )
        assert response.getheader("Content-Type") == "text/event-stream"
        return connection, response
    except BaseException:
        connection.close()
        raise


def read_all(response):
    raw = bytearray()
    clean = True
    try:
        while True:
            part = response.read1(4096)
            if not part:
                break
            raw.extend(part)
    except http.client.IncompleteRead as error:
        raw.extend(error.partial)
        clean = False
    return bytes(raw), clean


def inspect_stream(raw, mode, clean):
    frames = parse_sse(raw)
    documents = [value for _, value in frames if isinstance(value, dict)]
    deltas = [choice["delta"] for value in documents for choice in value.get("choices", [])]
    assert "".join(delta.get("content", "") for delta in deltas) == TEXT
    role = [delta for delta in deltas if delta.get("role") == "assistant"]
    assert len(role) == 1, "role/prefix replay"
    errors = [(name, value) for name, value in frames if isinstance(value, dict) and "error" in value]
    finishes = [choice["finish_reason"] for value in documents for choice in value.get("choices", [])
                if choice["finish_reason"] is not None]
    dones = [value for _, value in frames if value == "[DONE]"]
    if mode in NEGATIVES:
        assert not clean and not dones and not finishes, "late success after failure"
        assert len(errors) == 1 and errors[0][0] == "error", "missing/duplicate safe failure"
        assert errors[0][1]["devin_delivery"] == "started"
        return
    assert clean and not errors and len(dones) == 1 and frames[-1][1] == "[DONE]"
    expected = {"valid": "tool_calls", "length": "length", "filtered": "content_filter"}[mode]
    assert finishes == [expected]
    ids = {value["id"] for value in documents}
    assert len(ids) == 1
    assert all(value["model"] == MODEL and isinstance(value["created"], int) for value in documents)
    if mode == "valid":
        assert "".join(delta.get("reasoning_content", "") for delta in deltas) == "synthetic reasoning"
        signatures = [delta["devin_signature_delta"] for delta in deltas if "devin_signature_delta" in delta]
        assert b"".join(base64.b64decode(value + "=" * (-len(value) % 4), validate=True)
                        for value in signatures) == b"\xff\x00"
        calls = [call for delta in deltas for call in delta.get("tool_calls", [])]
        assert calls[0]["id"] == "synthetic-call" and calls[0]["function"]["name"] == "lookup"
        assert {call["index"] for call in calls} == {0}
        assert "".join(call["function"].get("arguments", "") for call in calls) == '{"q":"€"}'
        usage = [value["usage"] for value in documents if "usage" in value]
        assert len(usage) == 2
        assert usage[0]["devin_usage_partial"] and "prompt_tokens" not in usage[0]
        assert "total_tokens" not in usage[0]
        assert usage[-1]["total_tokens"] == 10 and not usage[-1]["devin_usage_partial"]
        assert usage[-1]["devin_usage_source"] == "native_accounting"
        native = usage[-1]["devin_usage"]
        assert native["cache_write_tokens"] == 4 and native["cached_input_tokens"] == 3
        assert native["devin_request_id"] == "synthetic-f23-request"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    began = time.monotonic()
    root = ROOT / "build/f23"
    root.mkdir(parents=True, exist_ok=True)
    # This is the actual root, not a provider facade server or a source overlay.
    with tempfile.TemporaryDirectory(prefix="root-cli-", dir=root) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        cwd = directory if args.shipment else ROOT
        config = directory / "providers.json"
        key = BASE["private_file"](directory / "client-key", CLIENT_KEY)
        grant = BASE["private_file"](directory / "session.json", json.dumps({"session_token": TOKEN}))
        port = free_port()
        primary, fallback = Fixture(), Fixture()
        try:
            settings = {
                "version": 1, "state_dir": str(state), "listen_port": port,
                "accounts": [
                    {"provider": "devin", "auth_mode": "session_token", "id": name,
                     "origin": fixture.origin, "models": [MODEL]}
                    for name, fixture in [("one", primary), ("two", fallback)]
                ],
            }
            config.write_text(json.dumps(settings))
            for name in ("one", "two"):
                result = subprocess.run([*command, "providers", "credential", "import", str(config), name, grant],
                                        cwd=cwd, capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert result.returncode == 0, "synthetic grant import failed"
            result = subprocess.run([*command, "providers", "key", "import", str(config), "synthetic-f23-client", key],
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

            modes = ("valid", "valid", "length", "filtered", *NEGATIVES)
            for index, mode in enumerate(modes):
                primary.mode = mode
                # Fresh runtime preserves the per-request no-failover assertion
                # without assuming fleet cursor stickiness across requests.
                with running(index):
                    before = primary.requests
                    before_eof = primary.peer_eofs
                    connection, response = read_stream(port)
                    try:
                        raw, clean = read_all(response)
                        inspect_stream(raw, mode, clean)
                    finally:
                        connection.close()
                    assert primary.requests == before + 1 and fallback.accepts == 0
                    if mode == "custom-tool":
                        deadline = time.monotonic() + 3
                        while primary.peer_eofs == before_eof and time.monotonic() < deadline:
                            time.sleep(0.01)
                        assert primary.peer_eofs > before_eof, "projection failure did not cancel native socket"
            primary.mode = "disconnect"
            primary.release.clear()
            before_eof = primary.peer_eofs
            with running(len(modes)):
                connection, response = read_stream(port)
                raw = bytearray()
                while TEXT.encode() not in raw:
                    raw.extend(response.read1(4096))
                    assert raw and len(raw) <= 65_536
                sock = connection.sock
                assert sock is not None
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                response.close()
                connection.close()
                primary.release.set()
                deadline = time.monotonic() + 3
                while primary.peer_eofs == before_eof and time.monotonic() < deadline:
                    time.sleep(0.01)
                assert primary.peer_eofs > before_eof, "client disconnect did not cancel native socket"
                assert fallback.accepts == 0
            assert primary.wire_ok and fallback.wire_ok
            assert primary.requests == len(modes) + 1
            requests, cancels = primary.requests, primary.peer_eofs
        finally:
            try:
                primary.close()
            finally:
                fallback.close()
    assert not directory.exists(), "F23 private synthetic state survived cleanup"
    print(json.dumps({
        "slice": "F23", "synthetic": True, "actual_root_cli": True,
        "chat_sse_positive": 4, "started_failure_negative": len(NEGATIVES),
        "client_disconnect": True, "native_requests": requests,
        "fallback_accepts": 0, "observed_peer_eofs": cancels, "cleanup": True,
        "shipment": bool(args.shipment), "seconds": round(time.monotonic() - began, 3),
        "cpa_differential": False, "native_client": False, "remote": False, "live": False,
    }, sort_keys=True))


if __name__ == "__main__":
    def bounded(_signal, _frame):
        raise TimeoutError("F23 actual-root CLI bounded at 120 seconds")
    signal.signal(signal.SIGALRM, bounded)
    signal.alarm(120)
    main()
