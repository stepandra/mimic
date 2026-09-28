#!/usr/bin/env python3
"""Exercise the assembled CLI over real localhost HTTP, with synthetic secrets."""

import argparse
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time


CLIENT_KEY = "synthetic-client-key-for-local-smoke-0001"
UPSTREAM_KEY = "synthetic-provider-key-for-local-smoke-0001"
MODEL = "synthetic-claude"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        request = json.loads(body)
        self.server.observations.append(
            {
                "path": self.path,
                "host": self.headers.get("Host"),
                "key_ok": self.headers.get("x-api-key") == UPSTREAM_KEY,
                "no_client_auth": self.headers.get("Authorization") is None,
                "model_ok": request.get("model") == MODEL,
            }
        )
        if self.path.split("?")[0] == "/v1/messages/count_tokens":
            value = {"input_tokens": 7}
        else:
            value = {
                "id": "msg_synthetic",
                "type": "message",
                "role": "assistant",
                "model": MODEL,
                "content": [{"type": "text", "text": "synthetic reply"}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 7, "output_tokens": 2},
            }
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def private_file(path, value):
    path.write_text(value)
    path.chmod(0o600)
    return str(path)


def request(port, method, path, payload=None, authorized=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Content-Type": "application/json"}
    if authorized:
        headers["Authorization"] = f"Bearer {CLIENT_KEY}"
    body = None if payload is None else json.dumps(payload)
    try:
        connection.request(method, path, body, headers)
        response = connection.getresponse()
        raw = response.read()
        assert CLIENT_KEY.encode() not in raw
        assert UPSTREAM_KEY.encode() not in raw
        return response.status, json.loads(raw)
    finally:
        connection.close()


def stop(process, state):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise AssertionError("gateway did not shut down on SIGTERM")
    deadline = time.monotonic() + 10
    while (state / ".provider-runtime-owner").exists():
        if time.monotonic() >= deadline:
            raise AssertionError("normal shutdown left the runtime owner guard")
        time.sleep(0.05)


def start(command, config, port, log, state, cwd):
    process = subprocess.Popen(
        [*command, "serve", "providers", str(config)],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        cwd=cwd,
    )
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError("gateway exited before readiness")
            try:
                if request(port, "GET", "/v1/models", authorized=False)[0] == 401:
                    return process
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.05)
        raise AssertionError("gateway startup deadline exceeded")
    except BaseException:
        stop(process, state)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--shipment", type=Path, help="exported shipment directory; otherwise use Gleam"
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.shipment:
        # Gleam exports a POSIX script without a shebang. Invoke its
        # interpreter explicitly; subprocess does not provide shell fallback.
        command = ["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
    else:
        command = [os.environ.get("GLEAM", "gleam"), "run", "--"]
    (root / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="gateway-smoke-", dir=root / "build/integration"
    ) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        upstream.observations = []
        worker = threading.Thread(target=upstream.serve_forever, daemon=True)
        worker.start()
        origin = f"127.0.0.1:{upstream.server_port}"
        config = directory / "providers.json"
        config.write_text(
            json.dumps(
                {
                    "version": 1,
                    "state_dir": str(state),
                    "listen_port": port,
                    "accounts": [
                        {
                            "provider": "claude",
                            "auth_mode": "api_key",
                            "id": "synthetic-account",
                            "origin": f"http://{origin}",
                            "models": [MODEL],
                        }
                    ],
                }
            )
        )
        credential = private_file(
            directory / "credential.json", json.dumps({"api_key": UPSTREAM_KEY})
        )
        client_key = private_file(directory / "client-key.txt", CLIENT_KEY + "\n")
        cwd = directory if args.shipment else root

        def cli(*arguments):
            result = subprocess.run(
                [*command, *arguments],
                capture_output=True,
                timeout=60,
                check=False,
                cwd=cwd,
            )
            combined = result.stdout + result.stderr
            assert CLIENT_KEY.encode() not in combined
            assert UPSTREAM_KEY.encode() not in combined
            assert result.returncode == 0, (
                f"CLI {arguments[:3]} failed with exit {result.returncode}: "
                + combined.decode(errors="replace")
            )
            return result.stdout

        try:
            cli("providers", "credential", "import", str(config), "synthetic-account", credential)
            cli("providers", "key", "import", str(config), "synthetic-client", client_key)
            payload = {
                "model": MODEL,
                "max_tokens": 16,
                "messages": [{"role": "user", "content": "synthetic hello"}],
            }
            # Restart the actual CLI against persisted state without reseeding.
            for index in range(2):
                log_path = directory / f"gateway-{index}.log"
                with log_path.open("wb") as log:
                    process = start(command, config, port, log, state, cwd)
                    try:
                        status, models = request(port, "GET", "/v1/models")
                        assert status == 200 and any(
                            model["id"] == MODEL for model in models["data"]
                        )
                        status, response = request(port, "POST", "/v1/messages", payload)
                        assert status == 200 and response["content"][0]["text"] == "synthetic reply"
                        status, count = request(
                            port, "POST", "/v1/messages/count_tokens", payload
                        )
                        assert status == 200 and count["input_tokens"] == 7
                        assert request(port, "GET", "/unsupported")[0] in (404, 422)
                        if index == 1:
                            before = len(upstream.observations)
                            cli("providers", "key", "revoke", str(config), "synthetic-client")
                            assert request(port, "POST", "/v1/messages", payload)[0] == 401
                            assert len(upstream.observations) == before
                    finally:
                        stop(process, state)
                output = log_path.read_bytes()
                assert CLIENT_KEY.encode() not in output and UPSTREAM_KEY.encode() not in output
            assert len(upstream.observations) == 4
            for observed in upstream.observations:
                assert observed["host"] == origin
                assert observed["key_ok"] and observed["no_client_auth"] and observed["model_ok"]
            print(json.dumps({
                "scope": "assembled_gateway_cli",
                "synthetic": True,
                "messages": True,
                "count_tokens": True,
                "models": True,
                "restart_without_reseed": True,
                "revocation": True,
                "secret_isolation": True,
                "live_provider": False,
            }))
        finally:
            upstream.shutdown()
            upstream.server_close()
            worker.join(timeout=5)


if __name__ == "__main__":
    main()
