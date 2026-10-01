#!/usr/bin/env python3
"""Opt-in F28 actual-root CLI smoke. SYNTHETIC state and numeric loopback only.

The parent runs this after wiring status_cli.cli in the real root dispatch.
No source overlay, alternate CLI, credentials from home, CPA or Devin service.
"""
import argparse
import contextlib
import http.client
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
KEY = "synthetic-f28-local-operator-key"
TOKEN = "synthetic-f28-permanent-session"
BACKUP = "synthetic-f28-explicit-second-session"
TARGET = "/exa.seat_management_pb.SeatManagementService/GetUserStatus"
MODEL = "devin/swe-1-7"


def varint(n):
    value = bytearray()
    while n >= 128:
        value.append((n & 127) | 128)
        n >>= 7
    value.append(n)
    return bytes(value)


def message(tag, data):
    return varint(tag * 8 + 2) + varint(len(data)) + data


def integer(tag, n):
    return varint(tag * 8) + varint(n)


def fields(data):
    position = 0

    def number():
        nonlocal position
        result, shift = 0, 0
        while position < len(data) and shift < 70:
            byte = data[position]
            position += 1
            result |= (byte & 127) << shift
            if not byte & 128:
                return result
            shift += 7
        raise ValueError("invalid synthetic request varint")

    values = []
    while position < len(data):
        tag = number()
        assert tag & 7 == 2
        length = number()
        assert length <= len(data) - position
        values.append((tag >> 3, data[position:position + length]))
        position += length
    return values


class Fixture(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, token):
        self.token = token
        self.mode = "ok"
        self.accepts = self.valid = 0
        self.lock = threading.Lock()
        super().__init__(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_address[1]}"

    def inspect(self, head, body):
        # Private bytes are transient. Retain only counters/booleans.
        rows = head.split(b"\r\n")
        pairs = [row.split(b": ", 1) for row in rows[1:]]
        headers = dict(pairs)
        assert len(headers) == len(pairs)
        assert rows[0] == f"POST {TARGET} HTTP/1.1".encode()
        assert headers[b"Host"] == f"127.0.0.1:{self.server_address[1]}".encode()
        assert headers[b"Authorization"] == f"Basic {self.token}-{self.token}".encode()
        assert headers[b"Content-Type"] == b"application/proto"
        assert headers[b"Connect-Protocol-Version"] == b"1"
        assert headers[b"Accept"] == b"*/*"
        assert int(headers[b"Content-Length"]) == len(body)
        assert set(headers) == {
            b"Host", b"Authorization", b"Content-Type", b"Connect-Protocol-Version",
            b"Content-Length", b"Accept",
        }
        root = fields(body)
        assert len(root) == 1 and root[0][0] == 1
        metadata = fields(root[0][1])
        assert [tag for tag, _ in metadata] == [1, 2, 3, 4, 5, 7, 12, 31]
        values = dict(metadata)
        assert values[1] == values[12] == b"chisel"
        assert values[2] == values[7] == b"3000.10.21"
        assert values[3] == self.token.encode() and values[4] == b"en"
        assert values[5] in (b"linux", b"darwin", b"windows")
        assert len(values[31]) == 732 and all(byte in b"0123456789abcdef" for byte in values[31])

    def reply(self):
        quota = (
            integer(14, 0) + integer(15, 100) + integer(17, 1_789_200_000)
            + integer(18, 1_789_300_000) + message(2, integer(1, 1))
            + message(3, integer(1, 1_789_100_000))
        )
        if self.mode == "absent":
            quota = integer(14, 0) + integer(17, 0)
        body = message(1, message(3, self.token.encode()) + message(7, KEY.encode()) + message(13, quota))
        code, media, extra = 200, "application/proto", ""
        if self.mode.startswith("http-"):
            code, body = int(self.mode[5:]), self.token.encode()
        if self.mode == "redirect":
            code, body, extra = 302, b"", "Location: https://example.invalid/private\r\n"
        if self.mode == "malformed":
            body = b"\x0a\x14\x01"
        if self.mode == "connect":
            body = b"\0" + len(body).to_bytes(4, "big") + body
        if self.mode == "media":
            media = "application/json"
        if self.mode == "compression":
            extra = "Content-Encoding: gzip\r\n"
        length = len(body)
        if self.mode == "oversized":
            length, body = 4_194_305, b""
        if self.mode == "truncated":
            length = len(body) + 1
        head = (
            f"HTTP/1.1 {code} Synthetic\r\nContent-Type: {media}\r\n"
            f"Content-Length: {length}\r\n{extra}Connection: close\r\n\r\n"
        ).encode()
        return head + body

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)
        assert not self.thread.is_alive()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(2)
        with self.server.lock:
            self.server.accepts += 1
        data = b""
        while b"\r\n\r\n" not in data and len(data) <= 16384:
            chunk = self.request.recv(8192)
            if not chunk:
                return
            data += chunk
        head, body = data.split(b"\r\n\r\n", 1)
        length = int(dict(row.split(b": ", 1) for row in head.split(b"\r\n")[1:])[b"Content-Length"])
        assert 0 < length <= 8192
        while len(body) < length:
            chunk = self.request.recv(length - len(body))
            if not chunk:
                return
            body += chunk
        self.server.inspect(head, body)
        with self.server.lock:
            self.server.valid += 1
        self.request.sendall(self.server.reply())


def safe(data):
    assert all(secret.encode() not in data for secret in (KEY, TOKEN, BACKUP)), "secret reflected in CLI output"


def run(command, args, env, expected=0):
    result = subprocess.run(
        [*command, *map(str, args)], cwd=ROOT, env=env, capture_output=True,
        timeout=45, check=False,
    )
    safe(result.stdout + result.stderr)
    assert result.returncode == expected, "actual root CLI exit differs"
    return result.stdout, result.stderr


def private(path, value):
    path.write_text(value)
    path.chmod(0o600)


def snapshot(state):
    result = {path.name: path.read_bytes() for path in state.glob("runtime-*.json")}
    assert len(result) == 2, "synthetic grant records missing"
    return result


def models(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
    try:
        connection.request("GET", "/v1/models", headers={"Authorization": f"Bearer {KEY}"})
        response = connection.getresponse()
        assert response.status == 200
        data = response.read()
        safe(data)
        return json.loads(data)
    finally:
        connection.close()


@contextlib.contextmanager
def gateway(command, config, port, env, log_path):
    with log_path.open("wb") as log:
        log_path.chmod(0o600)
        process = subprocess.Popen(
            [*command, "serve", "providers", str(config)], cwd=ROOT, env=env,
            stdout=log, stderr=log, start_new_session=True,
        )
        try:
            until = time.monotonic() + 20
            while True:
                assert process.poll() is None, "synthetic gateway exited"
                try:
                    models(port)
                    break
                except OSError:
                    assert time.monotonic() < until, "synthetic gateway did not start"
                    time.sleep(0.05)
            yield
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
                raise AssertionError("synthetic gateway failed graceful shutdown")
    safe(log_path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, help="explicit actual shipment CLI executable")
    args = parser.parse_args()
    command = (
        [str(args.executable.resolve())] if args.executable
        else ["mise", "exec", "gleam@1.18.1", "--", "gleam", "run", "--"]
    )
    env = dict(os.environ, ERL_FLAGS="+S 2:2 +A 2", MIMIC_INGRESS_KEY=KEY)
    (ROOT / "build" / "f28").mkdir(parents=True, exist_ok=True)
    primary, backup = Fixture(TOKEN), Fixture(BACKUP)
    try:
        with tempfile.TemporaryDirectory(prefix="smoke-", dir=ROOT / "build" / "f28") as directory:
            directory = Path(directory).resolve()
            directory.chmod(0o700)
            state = directory / "state"
            state.mkdir(mode=0o700)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]
            config = directory / "config.json"
            private(config, json.dumps({
                "version": 1, "state_dir": str(state), "listen_port": port,
                "accounts": [
                    {"provider": "devin", "auth_mode": "session_token", "id": account,
                     "origin": fixture.origin, "models": [MODEL]}
                    for account, fixture in (("selected", primary), ("backup", backup))
                ],
            }))
            for account, token in (("selected", TOKEN), ("backup", BACKUP)):
                credential = directory / f"{account}.json"
                private(credential, json.dumps({"session_token": token}))
                run(command, ["providers", "credential", "import", config, account, credential], env)
            key_file = directory / "key.txt"
            private(key_file, KEY)
            run(command, ["providers", "key", "import", config, "synthetic-f28", key_file], env)
            before = snapshot(state)

            def status(account="selected", error=None, authorized=True):
                previous = primary.accepts + backup.accepts
                local_env = dict(env)
                if not authorized:
                    local_env.pop("MIMIC_INGRESS_KEY")
                output, diagnostic = run(
                    command, ["providers", "status", config, account], local_env,
                    1 if error else 0,
                )
                assert snapshot(state) == before, "permanent grant bytes/revision/metadata changed"
                assert not (state / ".provider-runtime-owner").exists(), "status left store ownership"
                if error:
                    assert error.encode() in diagnostic and not output
                    return primary.accepts + backup.accepts - previous
                assert len(output) < 2048
                value = json.loads(output)
                assert value["account"] == account and value["observed_at_ms"] > 0
                assert value["grant_rotated"] is False and value["quota_enforcement"] is False
                return value

            for _ in range(2):
                value = status()
                assert value["daily_remaining_percent"] == 0
                assert value["weekly_remaining_percent"] == 100
                assert value["daily_reset_seconds"] == 1_789_200_000
                assert value["weekly_reset_seconds"] == 1_789_300_000
                assert value["plan_start_seconds"] == 1
                assert value["plan_end_seconds"] == 1_789_100_000
            status("backup")
            primary.mode = "absent"
            value = status()
            assert value["weekly_remaining_percent"] is None and value["daily_reset_seconds"] is None
            failures = [
                ("http-201", "Devin status HTTP 201"), ("http-401", "Devin status HTTP 401"),
                ("http-403", "Devin status HTTP 403"), ("http-503", "Devin status HTTP 503"),
                ("redirect", "Devin status HTTP 302"), ("malformed", "Invalid Devin status observation"),
                ("connect", "Invalid Devin status observation"), ("media", "Devin status unavailable"),
                ("compression", "Devin status unavailable"), ("oversized", "Invalid Devin status response"),
                ("truncated", "Invalid Devin status response"),
            ]
            for mode, error in failures:
                primary.mode = mode
                assert status(error=error) == 1, "error retried or changed origin"
                assert backup.accepts == 1, "pinned status fell back"
            assert status(authorized=False, error="Devin status unauthorized") == 0
            assert status("unknown", authorized=False, error="Devin status unauthorized") == 0
            assert status("unknown", error="Devin status account is not uniquely configured") == 0
            with gateway(command, config, port, env, directory / "gateway.log"):
                previous = primary.accepts + backup.accepts
                _, diagnostic = run(command, ["providers", "status", config, "selected"], env, 1)
                assert b"store busy or unavailable" in diagnostic
                assert primary.accepts + backup.accepts == previous
                listing = json.dumps(models(port))
                assert all(name not in listing for name in ("devin-status", "remaining_percent", "email", "reset_seconds"))
                assert snapshot(state) == before
            primary.mode = "http-429"
            assert status(error="Devin status HTTP 429") == 1
            assert status(error="Devin status account unavailable") == 0
            run(command, ["providers", "key", "revoke", config, "synthetic-f28"], env)
            assert status(error="Devin status unauthorized") == 0
            assert primary.accepts == primary.valid and backup.accepts == backup.valid == 1
            receipt = {
                "slice": "F28", "synthetic": True, "actual_root_cli": True,
                "positives": 4, "failure_cases": len(failures) + 1,
                "fallback_requests": 0, "grant_bytes_unchanged": True,
                "busy_gateway_preserved": True, "remote_enabled": False, "live_verified": False,
            }
        assert not directory.exists()
    finally:
        primary.close()
        backup.close()
    print(json.dumps(dict(receipt, cleanup_confirmed=True), sort_keys=True))


if __name__ == "__main__":
    main()
