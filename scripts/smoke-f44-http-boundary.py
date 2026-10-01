#!/usr/bin/env python3
"""F44: synthetic raw HTTP/1 framing through the root CLI or exported shipment.

No live endpoints, real credentials, or HTTP client header canonicalization.
Defaults to every two-part byte split of GET/GET and fixed-body POST/GET.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import signal
import socket
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
# Reuse the assembled CLI's existing synthetic provisioning/shutdown helpers,
# not another credential manager or an alternative gateway entrypoint.
SMOKE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
CLIENT_KEY = SMOKE["CLIENT_KEY"]
UPSTREAM_KEY = SMOKE["UPSTREAM_KEY"]
MODEL = SMOKE["MODEL"]


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers["Content-Length"])
        raw = self.rfile.read(length)
        value = json.loads(raw)
        assert self.path == "/v1/messages/count_tokens?beta=true"
        assert value["model"] == MODEL
        assert value["messages"][0]["content"] == "synthetic F44"
        assert self.headers["x-api-key"] == UPSTREAM_KEY
        assert self.headers.get("Authorization") is None
        self.server.observations.append(raw)
        payload = b'{"input_tokens":7}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


class RawClient:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.pending = b""

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.socket.close()

    def receive(self):
        value = self.socket.recv(65536)
        assert value, "closed before the expected response"
        self.pending += value
        assert len(self.pending) <= 2 * 1024 * 1024, "unbounded response"

    def response(self):
        while b"\r\n\r\n" not in self.pending:
            self.receive()
        headers, self.pending = self.pending.split(b"\r\n\r\n", 1)
        status, *fields = headers.split(b"\r\n")
        version, code, _ = status.split(b" ", 2)
        lengths = [
            int(field.split(b":", 1)[1].strip())
            for field in fields
            if field.split(b":", 1)[0].lower() == b"content-length"
        ]
        assert len(lengths) == 1 and 0 <= lengths[0] <= 1024 * 1024
        size = lengths[0]
        while len(self.pending) < size:
            self.receive()
        body, self.pending = self.pending[:size], self.pending[size:]
        assert CLIENT_KEY.encode() not in body and UPSTREAM_KEY.encode() not in body
        return version.decode(), int(code), json.loads(body)

    def closed(self):
        assert self.pending == b"", "trailing bytes after the expected responses"
        try:
            assert self.socket.recv(1) == b"", "unexpected response after closure"
        except ConnectionResetError:
            pass


def wire(method, path, headers=b"", body=b"", close=False, version="1.1"):
    return (
        f"{method} {path} HTTP/{version}\r\nHost: localhost\r\n".encode()
        + f"Authorization: Bearer {CLIENT_KEY}\r\n".encode()
        + (b"Connection: close\r\n" if close else b"")
        + headers
        + b"\r\n"
        + body
    )


def padded_head(size):
    """Synthetic cumulative head limit probe; individual lines stay small."""
    fields = (b"X-Fill: " + b"a" * 1000 + b"\r\n") * 64
    base = wire("GET", "/v1/models", fields + b"X-End: \r\n")
    assert size >= len(base)
    result = wire("GET", "/v1/models", fields + b"X-End: " + b"b" * (size - len(base)) + b"\r\n")
    assert len(result) == size
    return result


def exchange(port, parts, expected):
    with RawClient(port) as client:
        for part in parts:
            client.socket.sendall(part)
            if len(parts) > 1:
                # Make the split reach passive receive, not just two sends.
                time.sleep(0.002)
        result = [client.response() for _ in range(expected)]
        client.closed()
        return result


def sequential(port, first, second):
    with RawClient(port) as client:
        client.socket.sendall(first)
        result = [client.response()]
        client.socket.sendall(second)
        result.append(client.response())
        client.closed()
        return result


def main():
    def interrupted(number, _frame):
        # Let finally stop our synthetic child even when a gate is interrupted.
        raise SystemExit(128 + number)

    for number in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(number, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path, help="exported shipment directory")
    parser.add_argument(
        "--boundary-splits-only", action="store_true",
        help="fast smoke; focused Gleam tests still exercise every byte split",
    )
    args = parser.parse_args()
    command = (
        ["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
        if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"]
    )
    integration = ROOT / "build/integration"
    integration.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f44-", dir=integration) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        upstream.observations = []
        thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        thread.start()
        config = directory / "providers.json"
        config.write_text(json.dumps({
            "version": 1, "state_dir": str(state), "listen_port": port,
            "accounts": [{
                "provider": "claude", "auth_mode": "api_key",
                "id": "synthetic-f44",
                "origin": f"http://127.0.0.1:{upstream.server_port}",
                "models": [MODEL],
            }],
        }))
        credential = SMOKE["private_file"](
            directory / "credential.json", json.dumps({"api_key": UPSTREAM_KEY}),
        )
        client_key = SMOKE["private_file"](
            directory / "client-key.txt", CLIENT_KEY + "\n",
        )
        cwd = directory if args.shipment else ROOT

        def cli(*arguments):
            result = subprocess.run(
                [*command, *arguments], cwd=cwd, capture_output=True, timeout=60,
            )
            combined = result.stdout + result.stderr
            assert CLIENT_KEY.encode() not in combined
            assert UPSTREAM_KEY.encode() not in combined
            assert result.returncode == 0, combined.decode(errors="replace")

        process = None
        cases = 0
        try:
            cli("providers", "credential", "import", str(config), "synthetic-f44", credential)
            cli("providers", "key", "import", str(config), "synthetic-client", client_key)
            with (directory / "gateway.log").open("wb") as log:
                process = SMOKE["start"](command, config, port, log, state, cwd)
                payload = json.dumps({
                    "model": MODEL,
                    "messages": [{"role": "user", "content": "synthetic F44"}],
                }, separators=(",", ":")).encode()
                post_headers = (
                    b"Content-Type: application/json\r\n"
                    + f"Content-Length: {len(payload)}\r\n".encode()
                )
                models = wire("GET", "/v1/models")
                missing = wire("GET", "/f44-missing", close=True)
                post = wire("POST", "/v1/messages/count_tokens", post_headers, payload)
                last = wire("GET", "/v1/models", close=True)
                for name, first, second in [("GET/GET", models, missing), ("POST/GET", post, last)]:
                    before = len(upstream.observations)
                    control = sequential(port, first, second)
                    assert control[0][0:2] == ("HTTP/1.1", 200)
                    assert control[1][1] == (404 if name == "GET/GET" else 200)
                    if name == "POST/GET":
                        assert control[0][2] == {"input_tokens": 7}
                        assert len(upstream.observations) == before + 1
                        normalized_body = upstream.observations[-1]
                    cases += 1
                    joined = first + second
                    positions = range(1, len(joined))
                    if args.boundary_splits_only:
                        boundary = first.index(b"\r\n\r\n") + 4
                        positions = sorted({
                            1, boundary - 1, boundary, boundary + 1,
                            len(first) - 1, len(first), len(first) + 1, len(joined) - 1,
                        })
                    variants = [[joined], *[[joined[:i], joined[i:]] for i in positions]]
                    for parts in variants:
                        before = len(upstream.observations)
                        assert exchange(port, parts, 2) == control, f"{name} response/order changed"
                        if name == "POST/GET":
                            assert upstream.observations[before:] == [normalized_body], "handler body changed"
                        else:
                            assert len(upstream.observations) == before
                        cases += 1
                    print(f"F44 {name}: sequential, coalesced and {len(variants) - 1} splits passed")
                # Duplicate Connection fields are one token list: close wins
                # in either order, including with a retained next request.
                for headers in [
                    b"Connection: Close\r\nConnection: keep-alive\r\n",
                    b"Connection: keep-alive\r\nConnection: \tclose\t \r\n",
                ]:
                    joined = wire("GET", "/v1/models", headers) + missing
                    for parts in [[joined], [joined[:1], joined[1:]]]:
                        before = len(upstream.observations)
                        result = exchange(port, parts, 1)
                        assert result[0][0:2] == ("HTTP/1.1", 200)
                        assert result[0][2]["data"][0]["id"] == MODEL
                        assert len(upstream.observations) == before
                        cases += 1
                # A models response rejects WS handoff. Its OWS Upgrade value
                # must still prevent reinterpretation of the coalesced tail.
                for upgrade in [b"websocket", b"websocket\t", b" \tWeBsOcKeT \t"]:
                    before = len(upstream.observations)
                    rejected = wire(
                        "GET", "/v1/models", b"Connection: Upgrade\r\nUpgrade: " + upgrade + b"\r\n",
                    )
                    result = exchange(port, [rejected + missing], 1)
                    assert result[0][0:2] == ("HTTP/1.1", 200)
                    assert result[0][2]["data"][0]["id"] == MODEL
                    assert len(upstream.observations) == before
                    cases += 1
                # Exactly 64 KiB or 100 raw fields still permits a following
                # request. Host + Authorization are two fields in wire().
                for first in [
                    padded_head(65536),
                    wire("GET", "/v1/models", b"X-Test: a\r\n" * 98),
                ]:
                    joined = first + missing
                    for parts in [[joined], [joined[:1024], joined[1024:]]]:
                        before = len(upstream.observations)
                        result = exchange(port, parts, 2)
                        assert result[0][0:2] == ("HTTP/1.1", 200)
                        assert result[1][0:2] == ("HTTP/1.1", 404)
                        assert len(upstream.observations) == before
                        cases += 1
                for first in [
                    padded_head(65537),
                    wire("GET", "/v1/models", b"X-Test: a\r\n" * 99),
                ]:
                    joined = first + post
                    for parts in [[joined], [joined[:1024], joined[1024:]]]:
                        before = len(upstream.observations)
                        assert exchange(port, parts, 0) == []
                        assert len(upstream.observations) == before
                        cases += 1
                # Chunked HTTP framing reaches the same assembled JSON route.
                encoded = f"{len(payload):x};synthetic=yes\r\n".encode() + payload
                encoded += b"\r\n0\r\nX-Test: synthetic\r\n\r\n"
                before = len(upstream.observations)
                chunked = wire(
                    "POST", "/v1/messages/count_tokens",
                    b"Content-Type: application/json\r\nTransfer-Encoding: Chunked\r\n", encoded,
                )
                result = exchange(port, [chunked + last], 2)
                assert result[0] == ("HTTP/1.1", 200, {"input_tokens": 7})
                assert result[1][2]["data"][0]["id"] == MODEL
                assert upstream.observations[before:] == [normalized_body]
                cases += 1
                bad_headers = [
                    b"Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
                    b"Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
                    b"Content-Length: 0\r\ncontent-length: 0\r\n",
                    b"Transfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n",
                    b"Content-Length: -1\r\n", b"Content-Length: 0, 0\r\n",
                    b"Content-Length: invalid\r\n", b"Transfer-Encoding: gzip, chunked\r\n",
                ]
                for name in ["Origin", "X-CSRF-Token", "Cookie"]:
                    for first, second in [("synthetic-a", "synthetic-b"), ("synthetic-b", "synthetic-a")]:
                        bad_headers.append(
                            f"{name}: {first}\r\n{name.lower()}: {second}\r\n".encode(),
                        )
                for headers in bad_headers:
                    before = len(upstream.observations)
                    assert exchange(port, [wire("GET", "/v1/models", headers) + post], 0) == []
                    assert len(upstream.observations) == before
                    cases += 1
                legacy = wire("GET", "/v1/models", version="1.0")
                assert exchange(port, [legacy + post], 1)[0][0:2] == ("HTTP/1.0", 200)
                cases += 1
                # A size guard must reply without waiting for an unchecked body.
                before = len(upstream.observations)
                guarded = wire(
                    "POST", "/v1/messages/count_tokens",
                    b"Content-Type: application/json\r\nContent-Length: 1000000000\r\n",
                )
                assert exchange(port, [guarded + post], 1)[0][1] == 413
                assert len(upstream.observations) == before
                cases += 1
                SMOKE["stop"](process, state)
                process = None
            raw_log = (directory / "gateway.log").read_bytes()
            assert CLIENT_KEY.encode() not in raw_log and UPSTREAM_KEY.encode() not in raw_log
            assert b"FunctionClause" not in raw_log and b"Caught error in user handler" not in raw_log
            print(json.dumps({
                "slice": "F44", "mode": "shipment" if args.shipment else "root",
                "cases": cases, "synthetic_localhost_only": True,
                "exact_normalized_upstream_body": True, "ordered_responses": True,
                "ambiguous_raw_headers_zero_response": True, "normal_shutdown": True,
                "close_token_precedence": True, "rejected_ows_upgrade_closure": True,
                "bounded_request_heads": True,
            }, sort_keys=True))
        finally:
            if process is not None:
                SMOKE["stop"](process, state)
            upstream.shutdown()
            upstream.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    main()
