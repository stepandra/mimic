#!/usr/bin/env python3
"""F22-only synthetic real-root CLI smoke. No CPA/provider/native-client calls."""

import argparse
import contextlib
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


ROOT = Path(__file__).resolve().parents[2]
# Reuse the existing actual-root startup/shutdown/authenticated HTTP contract.
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
MODEL = "devin/swe-1-7"
TOKEN = "synthetic-f22-cli-permanent-session"
TEXT = "synthetic F22 root reply"
SECRETS = [TOKEN.encode(), BASE["CLIENT_KEY"].encode()]


def frame(flag, body):
    return bytes([flag]) + len(body).to_bytes(4, "big") + body


DATA = frame(0, b"\x1a" + bytes([len(TEXT)]) + TEXT.encode())
EOS = frame(2, b"{}")
SUFFIXES = {
    "valid": EOS,
    "malformed-trailer": frame(2, b"{"),
    "truncated-header": b"\x00\x00\x00",
    "truncated-payload": b"\x00\x00\x00\x00\x04\x01\x02",
    "missing-eos": b"",
    "oversized-data": b"\x00" + (8_388_609).to_bytes(4, "big"),
    "post-eos-data": EOS + b"\x00",
}


class Fixture(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.mode = "valid"
        self.accepts = 0
        self.requests = 0
        self.wire_ok = True
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
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "fixture survived teardown"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        assert 0 < length <= 8_388_608
        body = self.rfile.read(length)
        checks = [
            self.request_version == "HTTP/1.1",
            self.path == "/exa.api_server_pb.ApiServerService/GetChatMessage",
            self.headers.get_all("Host") == [self.server.origin[7:]],
            self.headers.get_all("Authorization") == [f"Basic {TOKEN}-{TOKEN}"],
            self.headers.get_all("Content-Type") == ["application/connect+proto"],
            self.headers.get_all("Connect-Protocol-Version") == ["1"],
            all(self.headers.get(name) is None for name in
                ("User-Agent", "Accept-Encoding", "Transfer-Encoding")),
            len(body) == length,
            body[:1] == b"\x00",
            int.from_bytes(body[1:5], "big") == length - 5,
            TOKEN.encode() in body[5:],
        ]
        # Only booleans/counters survive the handler. No wire plan/body capture.
        self.server.wire_ok &= all(checks)
        self.server.requests += 1
        payload = DATA + SUFFIXES[self.server.mode]
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+proto")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def no_secrets(output):
    assert not any(secret in output for secret in SECRETS), "secret in output"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    began = time.monotonic()
    root = ROOT / "build/f22"
    root.mkdir(parents=True, exist_ok=True)
    # No arbitrary origin/config/credential input: all material created here.
    with tempfile.TemporaryDirectory(prefix="root-cli-", dir=root) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        cwd = directory if args.shipment else ROOT
        config = directory / "providers.json"
        key = BASE["private_file"](directory / "client-key", BASE["CLIENT_KEY"])
        grant = BASE["private_file"](
            directory / "session.json", json.dumps({"session_token": TOKEN}))
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

            def cli(*arguments, success=True):
                result = subprocess.run(
                    [*command, *arguments], cwd=cwd, capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert (result.returncode == 0) == success, (
                    "unexpected CLI outcome", arguments[:3], result.returncode)
                if not success:
                    # Actual root failure, not a compiler/launcher error. The
                    # origin guard owns its diagnostic, not this fixture.
                    assert result.returncode == 1 and b"mimic: " in result.stderr
                return result

            for account in ("one", "two"):
                cli("providers", "credential", "import", str(config), account, grant)
            cli("providers", "key", "import", str(config), "synthetic-f22-client", key)

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

            payload = {"model": MODEL, "stream": False,
                       "messages": [{"role": "user", "content": "synthetic F22 hello"}]}

            def call(body=payload):
                status, value = BASE["request"](
                    port, "POST", "/v1/chat/completions", body)
                no_secrets(json.dumps(value).encode())
                return status, value

            with running(1):
                status, value = call()
                assert status == 200 and value["choices"][0]["message"]["content"] == TEXT
                assert (primary.requests, fallback.accepts) == (1, 0)
                # Root remains buffered only; registry/native opt-in is not SSE.
                before = primary.accepts
                assert call(dict(payload, stream=True))[0] == 422
                assert primary.accepts == before and fallback.accepts == 0
            # Account selection is fair across different requests. A healthy
            # backup on a later call is NOT a replay of the preceding call.
            # Start a fresh root runtime for each independent framing case.
            for index, mode in enumerate(
                (mode for mode in SUFFIXES if mode != "valid"), start=2
            ):
                primary.mode = mode
                with running(index):
                    before = primary.requests
                    status, value = call()
                    assert status == 503 and TEXT not in json.dumps(value), (
                        mode, status, primary.requests, fallback.accepts)
                    assert primary.requests == before + 1 and fallback.accepts == 0
            primary.mode = "valid"
            # Fresh root VM restores our permanent grant without re-import.
            with running(8):
                status, value = call()
                assert status == 200 and value["choices"][0]["message"]["content"] == TEXT
                assert (primary.requests, fallback.accepts) == (8, 0)

            # Actual root config/CLI rejects these before any socket is opened.
            # The .invalid host is never resolved/contacted.
            for origin in (
                "http://127.0.0.1:0", "http://127.0.0.1:65536",
                "http://synthetic-f22.invalid:12345",
                f"https://127.0.0.1:{primary.server_port}",
            ):
                invalid = dict(settings, accounts=[
                    dict(settings["accounts"][0], origin=origin)])
                config.write_text(json.dumps(invalid))
                before = (primary.accepts, fallback.accepts)
                cli("providers", "key", "import", str(config),
                    "synthetic-f22-client", key, success=False)
                assert (primary.accepts, fallback.accepts) == before
            assert primary.wire_ok and fallback.wire_ok
        finally:
            try:
                primary.close()
            finally:
                fallback.close()
    assert not directory.exists(), "synthetic state survived cleanup"
    print(json.dumps({
        "slice": "F22", "scope": "real_root_cli_local_http1", "synthetic": True,
        "source_or_shipment": "shipment" if args.shipment else "source",
        "positive": 2, "framing_negative": 6, "stream_pre_io_negative": 1,
        "config_pre_io_negative": 4, "primary_sends": 8, "fallback_accepts": 0,
        "fixture_cleanup": True, "root_tls": False, "remote_enabled": False,
        "h2_qualified": False, "cpa_differential": False,
        "native_client": False, "live_verified": False,
        "elapsed_ms": int((time.monotonic() - began) * 1000),
    }, sort_keys=True))


if __name__ == "__main__":
    def deadline(_signum, _frame):
        raise TimeoutError("F22 root workflow exceeded 120-second wall budget")

    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(120)
    try:
        main()
    finally:
        signal.alarm(0)
