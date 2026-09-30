#!/usr/bin/env python3
"""Kimi-only, synthetic HTTP/1.1 loopback observations of the assembled CLI.

No provider traffic: both the gateway and its configured upstream bind 127.0.0.1.
The fixture is a redacted observation, not a claim about a live Kimi endpoint.
"""

import contextlib
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import tempfile
import threading
import unittest
from urllib.parse import parse_qs


ROOT = Path(__file__).resolve().parents[1]
SMOKE = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
GATEWAY = SMOKE["BASE"]
CLIENT = SMOKE["CLIENT"]
MODEL = SMOKE["KIMI_MODEL"]
RESPONSE = SMOKE["KIMI_RESPONSE"]
UPSTREAM_MODEL = "kimi-for-coding"
DOWNSTREAM_RESPONSE = dict(RESPONSE, model=MODEL)
API_KEY = "synthetic-kimi-wire-api-key"
OLD_ACCESS = "synthetic-kimi-wire-old-access"
REFRESH = "synthetic-kimi-wire-refresh"
NEW_ACCESS = "synthetic-kimi-wire-new-access"
NEXT_REFRESH = "synthetic-kimi-wire-next-refresh"
DEVICE = "d" * 64
SECRETS = (CLIENT, API_KEY, OLD_ACCESS, REFRESH, NEW_ACCESS, NEXT_REFRESH, DEVICE)
FIXTURE = ROOT / "test/fixtures/kimi/v2/wire-snapshot.json"
MANIFEST = ROOT / "test/fixtures/kimi/v2/manifest.json"


def safe_text(value):
    for secret in SECRETS:
        value = value.replace(secret, "[REDACTED]")
    return value


def clean_headers(pairs, origin_port):
    """Preserve raw order, multiplicity and spelling; erase secret values first."""
    result = []
    for name, value in pairs:
        if name.lower() in ("authorization", "x-msh-device-id"):
            value = "[REDACTED]"
        elif name.lower() == "host" and value == f"127.0.0.1:{origin_port}":
            value = "127.0.0.1:<loopback-port>"
        else:
            value = safe_text(value)
        result.append([name, value])
    return result


def no_secrets(value):
    raw = value if isinstance(value, bytes) else str(value).encode()
    if any(secret.encode() in raw for secret in SECRETS):
        raise AssertionError("credential/device value escaped redaction")


class KimiUpstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, content, media="application/json"):
        raw = content.encode()
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)
        self.close_connection = True

    def do_POST(self):
        # raw_items(), unlike dict(self.headers), retains order, duplicates and
        # original case. Raw values only exist in this handler's local scope.
        raw_headers = list(self.headers.raw_items())
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        token = self.path == "/api/oauth/token"
        body = (
            {key: values[0] for key, values in parse_qs(raw.decode()).items()}
            if token else json.loads(raw)
        )
        expected_auth = (
            "Bearer " + (NEW_ACCESS if self.server.mode == "oauth" else API_KEY)
        )
        auth = [value for name, value in raw_headers if name.lower() == "authorization"]
        device = [value for name, value in raw_headers if name.lower() == "x-msh-device-id"]
        observation = {
            "http_version": self.request_version,
            "method": self.command,
            "path": self.path,
            "headers": clean_headers(raw_headers, self.server.server_port),
            "body": json.loads(safe_text(json.dumps(body, ensure_ascii=False))),
            # Only booleans, never raw credential values, enter an observation.
            "auth_matches_selected": not token and auth == [expected_auth],
            "device_matches_selected": device == ([DEVICE] if self.server.mode == "oauth" else []),
        }
        no_secrets(json.dumps(observation))
        self.server.observations.append(observation)
        if token:
            self.reply(json.dumps({
                "access_token": NEW_ACCESS, "refresh_token": NEXT_REFRESH,
                "expires_in": 3600,
            }))
        elif self.path == "/operator/kimi/v1/chat/completions":
            self.reply(json.dumps({
                "id": "chat_synthetic", "object": "chat.completion",
                "model": UPSTREAM_MODEL,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "synthetic"},
                             "finish_reason": "stop"}],
            }))
        elif body.get("stream"):
            self.reply(SMOKE["kimi_sse"](), "text/event-stream")
        else:
            self.reply(json.dumps(RESPONSE))


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Loopback:
    def __init__(self, directory, mode, domain):
        self.directory = directory
        self.mode = mode
        self.domain = domain
        self.state = directory / "state"
        self.state.mkdir(mode=0o700)
        self.port = available_port()
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), KimiUpstream)
        self.upstream.mode = mode
        self.upstream.observations = []
        self.worker = threading.Thread(target=self.upstream.serve_forever, daemon=True)
        self.worker.start()
        self.origin = f"http://127.0.0.1:{self.upstream.server_port}"
        self.config = directory / "providers.json"
        account = {
            "provider": "kimi", "auth_mode": mode, "id": "selected",
            "origin": self.origin, "base_path": "/operator/kimi", "models": [MODEL],
        }
        if mode == "oauth":
            account["oauth"] = {
                "domain": domain,
                "device_url": self.origin + "/api/oauth/device_authorization",
                "token_url": self.origin + "/api/oauth/token",
            }
        # The first account has neither a credential nor a reachable origin.
        absent = dict(account, id="absent", origin="http://127.0.0.1:1", base_path="/wrong")
        self.config.write_text(json.dumps({
            "version": 1, "state_dir": str(self.state), "listen_port": self.port,
            "accounts": [absent, account],
        }))
        self.command = [os.environ.get("GLEAM", "gleam"), "run", "--"]
        try:
            client_file = GATEWAY["private_file"](directory / "client-key", CLIENT + "\n")
            self.cli("key", "import", str(self.config), "client", client_file)
            credential = (
                {"api_key": API_KEY} if mode == "api_key" else {
                    "access_token": OLD_ACCESS, "refresh_token": REFRESH,
                    "expires_at_ms": 1, "device_id": DEVICE,
                    "account_uuid": "synthetic-account", "organization_uuid": "synthetic-org",
                }
            )
            credential_file = GATEWAY["private_file"](
                directory / "credential", json.dumps(credential)
            )
            self.cli("credential", "import", str(self.config), "selected", credential_file)
        except BaseException:
            self.close()
            raise

    def cli(self, *args):
        result = subprocess.run(
            [*self.command, "providers", *args], cwd=ROOT,
            capture_output=True, timeout=60, check=False,
        )
        output = result.stdout + result.stderr
        no_secrets(output)
        if result.returncode:
            raise AssertionError(f"Kimi CLI exit {result.returncode}: {safe_text(output.decode(errors='replace'))}")

    @contextlib.contextmanager
    def running(self):
        # The smoke startup contract accepts a file descriptor. Discard gateway
        # output rather than writing a potentially secret-bearing temporary log.
        process = GATEWAY["start"](
            self.command, self.config, self.port, subprocess.DEVNULL, self.state, ROOT
        )
        try:
            yield
        finally:
            GATEWAY["stop"](process, self.state)

    def call(self, path, body):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            connection.request("POST", path, json.dumps(body), {
                "Authorization": f"Bearer {CLIENT}", "Content-Type": "application/json",
            })
            response = connection.getresponse()
            raw = response.read()
            no_secrets(raw)
            headers = clean_headers(response.headers.raw_items(), self.upstream.server_port)
            headers = [[key, "<date>"] if key.lower() == "date" else [key, value]
                       for key, value in headers]
            return {
                "http_version": f"HTTP/{response.version // 10}.{response.version % 10}",
                "status": response.status,
                "headers": headers,
                "body": raw.decode(),
            }
        finally:
            connection.close()

    def close(self):
        self.upstream.shutdown()
        self.upstream.server_close()
        self.worker.join(timeout=5)


def events(body):
    frames = []
    for frame in body.split("\n\n"):
        if not frame:
            continue
        lines = frame.splitlines()
        assert len(lines) == 2 and lines[0].startswith("event: ") and lines[1].startswith("data: ")
        name = lines[0].removeprefix("event: ")
        payload = json.loads(lines[1].removeprefix("data: "))
        assert name == payload["type"]
        frames.append({"event": name, "data": payload})
    return frames


def observe(mode, domain):
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="kimi-wire-", dir=ROOT / "build/integration") as temp:
        directory = Path(temp)
        directory.chmod(0o700)
        flow = Loopback(directory, mode, domain)
        try:
            with flow.running():
                responses = flow.call(
                    "/v1/responses", {"model": MODEL, "input": "synthetic", "stream": False}
                )
                chat = flow.call("/v1/chat/completions", {
                    "model": MODEL, "messages": [{"role": "user", "content": "synthetic"}],
                })
                streaming = flow.call(
                    "/v1/responses", {"model": MODEL, "input": "synthetic", "stream": True}
                )
            observations = flow.upstream.observations
            inference = [item for item in observations if item["path"].startswith("/operator/")]
            tokens = [item for item in observations if item["path"] == "/api/oauth/token"]
            assert len(inference) == 3 and len(tokens) == (1 if mode == "oauth" else 0)
            for item in inference:
                assert item["http_version"] == "HTTP/1.1" and item["method"] == "POST"
                assert item["auth_matches_selected"] and item["device_matches_selected"]
                names = [name for name, _ in item["headers"]]
                # The exact wire order/case, not dictionary membership or a set.
                expected = ["Host", "Authorization", "Content-Type", "Accept",
                            "Accept-Encoding", "Content-Length"]
                if mode == "oauth":
                    expected.append("X-Msh-Device-Id")
                assert names[:len(expected)] == expected, names
                assert item["headers"][0][1] == "127.0.0.1:<loopback-port>"
                assert item["body"]["model"] == UPSTREAM_MODEL
            for reply in (responses, chat, streaming):
                assert reply["http_version"] == "HTTP/1.1" and reply["status"] == 200
            for reply in (responses, chat):
                lengths = [value for name, value in reply["headers"]
                           if name.lower() == "content-length"]
                assert lengths == [str(len(reply["body"].encode("utf-8")))]
            assert json.loads(responses["body"]) == DOWNSTREAM_RESPONSE
            chat_body = json.loads(chat["body"])
            assert chat_body["model"] == MODEL
            assert chat_body["choices"][0]["message"]["content"] == "synthetic"
            frames = events(streaming["body"])
            assert [frame["event"] for frame in frames] == [
                "response.created", "response.completed"
            ]
            assert frames[-1]["data"]["response"] == DOWNSTREAM_RESPONSE
            for frame in frames:
                response = frame["data"].get("response", {})
                if "model" in response:
                    assert response["model"] == MODEL
            assert [item["path"] for item in inference] == [
                "/operator/kimi/v1/responses", "/operator/kimi/v1/chat/completions",
                "/operator/kimi/v1/responses",
            ]
            if tokens:
                assert tokens[0]["body"]["grant_type"] == "refresh_token"
                assert tokens[0]["device_matches_selected"]
                assert tokens[0]["headers"] == [
                    ["Host", "127.0.0.1:<loopback-port>"],
                    ["Content-Length", "113"],
                    ["Connection", "close"],
                    ["Content-Type", "application/x-www-form-urlencoded"],
                    ["Accept", "application/json"],
                    ["X-Msh-Device-Id", "[REDACTED]"],
                ]
                assert tokens[0]["body"] == {
                    "client_id": "17e5f671-d194-4dfb-9706-5516cb48c098",
                    "grant_type": "refresh_token", "refresh_token": "[REDACTED]",
                }
            # Snapshot only sanitized observations and normalized response facts.
            result = {
                "scope": "synthetic-kimi-loopback-http-1.1", "mode": mode,
                "domain": domain if mode == "oauth" else None,
                "upstream": observations,
                "downstream": [
                    {"status": reply["status"], "headers": reply["headers"],
                     "body": json.loads(reply["body"]) if reply is not streaming else frames}
                    for reply in (responses, chat, streaming)
                ],
            }
            no_secrets(json.dumps(result))
            return result
        finally:
            flow.close()


class KimiWireTest(unittest.TestCase):
    def test_redacted_immutable_snapshot(self):
        expected_bytes = FIXTURE.read_bytes()
        manifest = json.loads(MANIFEST.read_text())
        self.assertEqual(hashlib.sha256(expected_bytes).hexdigest(), manifest["sha256"])
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(manifest["scope"], "synthetic-kimi-loopback-http-1.1")
        self.assertEqual(manifest["modes"], ["api_key", "oauth:kimi.com", "oauth:kimi.ai"])
        self.assertEqual(manifest["upstream_model"], UPSTREAM_MODEL)
        self.assertEqual(manifest["downstream_model"], MODEL)
        expected = json.loads(expected_bytes)
        actual = observe("api_key", None)
        # Neither side may contain a credential, device identity, or client key.
        no_secrets(expected_bytes)
        no_secrets(json.dumps(actual))
        self.assertEqual(actual, expected)
        for domain in ("kimi.com", "kimi.ai"):
            with self.subTest(domain=domain):
                oauth = observe("oauth", domain)
                no_secrets(json.dumps(oauth))
                self.assertEqual(oauth["mode"], "oauth")
                self.assertEqual(oauth["domain"], domain)
                self.assertEqual(len(oauth["upstream"]), 4)
                self.assertEqual(oauth["upstream"][0]["path"], "/api/oauth/token")
                # The only native inference header difference is the OAuth
                # device header; response bodies/events remain the same.
                for key, selected in zip(actual["upstream"], oauth["upstream"][1:]):
                    self.assertEqual(selected["headers"], key["headers"] + [
                        ["X-Msh-Device-Id", "[REDACTED]"]
                    ])
                    self.assertEqual(selected["body"], key["body"])
                    self.assertTrue(selected["auth_matches_selected"])
                self.assertEqual(oauth["downstream"], actual["downstream"])


if __name__ == "__main__":
    unittest.main()
