#!/usr/bin/env python3
"""F27 SYNTHETIC actual-root catalog/model/account workflow after parent wiring.

Adapted from exact prior F27 63a0096eadf23e5632a8a86bcd18d1bd294f61ab.
No source overlay, real/ambient grants, remote endpoints, CPA or live discovery.
The current F24 source-derived consumer is reused without changing its source.
Shipment mode is provided for the parent; a source pass is not shipment proof.
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
import socket
import subprocess
import tempfile
import threading
import time

import f23_local_cli as helpers
import f24_local_cli as messages

ROOT = Path(__file__).resolve().parents[2]
BASE = helpers.BASE
CANONICAL = "devin/synthetic-canonical"
ALIAS = "devin/synthetic-alias-high"
UNLISTED = "devin/synthetic-unlisted"
IMAGE_ALIAS = "devin/synthetic-image-alias"
UID = "exact-synthetic-UID:no-effort-inference"
IMAGE_UID = "exact-synthetic-image-UID"
OTHER_MODEL = "synthetic-f27-other-provider"
TOKENS = {"one": "synthetic-f27-cli-one", "two": "synthetic-f27-cli-two"}
OTHER_TOKEN = "synthetic-f27-cli-other-provider-key"
TEXT = "synthetic F27 root reply"
SECRETS = [*(value.encode() for value in TOKENS.values()),
           OTHER_TOKEN.encode(), BASE["CLIENT_KEY"].encode()]


def no_secrets(value):
    assert not any(secret in value for secret in SECRETS), "secret in output"


def fields(value):
    """Prior F27 source-backed synthetic protobuf inspection, never a capture."""
    offset = 0

    def number():
        nonlocal offset
        result = 0
        for shift in range(0, 70, 7):
            assert offset < len(value)
            byte = value[offset]
            offset += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result
        raise AssertionError("invalid synthetic varint")

    result = []
    while offset < len(value):
        tag = number()
        assert tag >> 3 > 0
        kind = tag & 7
        if kind == 0:
            data = number()
        else:
            size = number() if kind == 2 else {1: 8, 5: 4}[kind]
            assert offset + size <= len(value)
            data = value[offset:offset + size]
            offset += size
        result.append((tag >> 3, kind, data))
    return result


def observed_wire(body, token, uid, limit):
    assert body[:1] == b"\x00"
    assert int.from_bytes(body[1:5], "big") == len(body) - 5
    root = fields(body[5:])
    assert [data for tag, kind, data in root if (tag, kind) == (21, 2)] == [uid.encode()]
    configs = [data for tag, kind, data in root if (tag, kind) == (8, 2)]
    assert len(configs) == 1
    assert [data for tag, kind, data in fields(configs[0])
            if (tag, kind) == (2, 0)] == [limit]
    metadata = [data for tag, kind, data in root if (tag, kind) == (1, 2)]
    assert len(metadata) == 1
    assert [data for tag, kind, data in fields(metadata[0])
            if (tag, kind) == (3, 2)] == [token.encode()]
    assert all(other.encode() not in body for other in TOKENS.values() if other != token)


class Fixture(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, name):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.name = name
        self.accepts = self.requests = 0
        self.wire_ok = True
        self.expected_uid = UID
        self.expected_limit = 2048
        self.mode = "text"
        self.reject = False
        self.worker = threading.Thread(target=self.serve_forever)
        self.worker.start()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"

    def get_request(self):
        result = super().get_request()
        result[0].settimeout(5)
        self.accepts += 1
        return result

    def close(self):
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "fixture survived cleanup"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        assert 0 < length <= 8_388_608
        body = self.rfile.read(length)
        token = TOKENS[self.server.name]
        try:
            assert len(body) == length
            assert self.request_version == "HTTP/1.1"
            assert self.path == "/exa.api_server_pb.ApiServerService/GetChatMessage"
            assert self.headers.get_all("Host") == [self.server.origin[7:]]
            assert self.headers.get_all("Authorization") == [f"Basic {token}-{token}"]
            assert self.headers.get_all("Content-Type") == ["application/connect+proto"]
            assert self.headers.get_all("Connect-Protocol-Version") == ["1"]
            assert all(self.headers.get(name) is None for name in
                       ("User-Agent", "Accept-Encoding", "Transfer-Encoding"))
            observed_wire(body, token, self.server.expected_uid, self.server.expected_limit)
        except (AssertionError, KeyError, ValueError):
            self.server.wire_ok = False
        # Only boolean/counters survive this handler, not the secret wire plan.
        self.server.requests += 1
        if self.server.reject:
            self.send_response(429)
            self.send_header("Retry-After", "1")
            payload = b""
        else:
            self.send_response(200)
            if self.server.mode == "messages":
                payload = b"".join(messages.fixture("valid"))
            else:
                payload = helpers.data(helpers.field(3, TEXT) +
                                       helpers.field(7, helpers.number(2, 8) +
                                                     helpers.number(3, 5)))
                payload += helpers.EOS
        self.send_header("Content-Type", "application/connect+proto")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True


def payload(model, streaming):
    # No client-origin/UID/auth/account fields are accepted.
    return {"model": model, "stream": streaming,
            "messages": [{"role": "user", "content": "synthetic F27 input"}]}


def call(port, route, model, streaming, auth=True, edit=None):
    value = payload(model, streaming)
    if route == "/v1/messages":
        value["max_tokens"] = 32
    if edit:
        edit(value)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=12)
    try:
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {BASE['CLIENT_KEY']}"
        connection.request("POST", route, json.dumps(value), headers)
        response = connection.getresponse()
        raw = response.read()
        no_secrets(raw)
        return response.status, response.getheader("Content-Type"), raw
    finally:
        connection.close()


def chat(port, model, streaming):
    status, media, raw = call(port, "/v1/chat/completions", model, streaming)
    assert status == 200
    if not streaming:
        assert media == "application/json"
        value = json.loads(raw)
        assert value["model"] == model
        assert value["choices"][0]["message"]["content"] == TEXT
        return
    assert media == "text/event-stream"
    events = []
    for block in raw.decode().replace("\r\n", "\n").split("\n\n"):
        if not block.strip():
            continue
        assert not block.startswith("event: error")
        value = "\n".join(line[6:] for line in block.splitlines()
                          if line.startswith("data: "))
        assert value
        events.append(value)
    assert events[-1] == "[DONE]" and events.count("[DONE]") == 1
    documents = [json.loads(value) for value in events[:-1]]
    assert documents and all(value["model"] == model for value in documents)
    assert len({value["id"] for value in documents}) == 1
    choices = [choice for value in documents for choice in value["choices"]]
    assert "".join(choice["delta"].get("content", "") for choice in choices) == TEXT
    assert [choice["finish_reason"] for choice in choices
            if choice["finish_reason"] is not None] == ["stop"]


def message(port, model, streaming):
    status, media, raw = call(port, "/v1/messages", model, streaming)
    assert status == 200
    if not streaming:
        assert media == "application/json"
        value = json.loads(raw)
    else:
        assert media == "text/event-stream"
        # The unchanged current F24 oracle has a fixed expected model. This
        # single-threaded test binding supplies the selected public alias only;
        # its construction, callback and terminal rules are left untouched.
        original = messages.MODEL
        try:
            messages.MODEL = model
            value = messages.consume(raw)
        finally:
            messages.MODEL = original
    assert value["model"] == model and value["type"] == "message"
    # Corrected F24 retains exact native cache accounting without inventing
    # equivalence to Anthropic cache-creation/cache-read semantics.
    assert value["usage"] == {
        "input_tokens": 8, "output_tokens": 5,
        "devin_usage_source": "native_accounting",
        "devin_usage": {"cache_write_tokens": 4, "cached_input_tokens": 3},
    }
    assert value["content"][1]["id"] == "first"
    assert value["content"][1]["input"] == {"x": "€"}
    return value


def listing(port, expected):
    status, value = BASE["request"](port, "GET", "/v1/models")
    no_secrets(json.dumps(value).encode())
    assert status == 200 and value["object"] == "list"
    rows = {row["id"]: row for row in value["data"]}
    assert len(rows) == len(value["data"]) and set(rows) == {*expected, OTHER_MODEL}
    assert rows[OTHER_MODEL] == {"id": OTHER_MODEL, "object": "model"}
    for public_id, (canonical, uid, limit, images, source) in expected.items():
        row, metadata = rows[public_id], rows[public_id]["devin"]
        assert row["object"] == "model" and row["owned_by"] == "devin"
        assert metadata["canonical_id"] == canonical and metadata["native_uid"] == uid
        assert metadata["max_tokens"] == limit and metadata["images"] is images
        assert metadata["metadata_source"] == source and metadata["live_discovery"] is False
        # F25 adds an actual protocol to the same configured registration; it
        # does not add another model, operation or continuation capability.
        assert metadata["protocols"] == [
            "openai-chat", "anthropic-messages", "openai-responses"
        ]
        assert metadata["operations"] == ["generate"]
        assert set(metadata["capabilities"]) == {
            "buffer", "stream", "tools", *({"images"} if images else set())
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    began = time.monotonic()
    root = ROOT / "build/f27"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="root-cli-", dir=root) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        cwd = directory if args.shipment else ROOT
        config = directory / "providers.json"
        grants = {name: BASE["private_file"](directory / f"{name}.json",
                  json.dumps({"session_token": token})) for name, token in TOKENS.items()}
        other_grant = BASE["private_file"](directory / "other.json",
                                          json.dumps({"api_key": OTHER_TOKEN}))
        key = BASE["private_file"](directory / "client-key", BASE["CLIENT_KEY"])
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with contextlib.ExitStack() as resources:
            primary, secondary = Fixture("one"), Fixture("two")
            resources.callback(primary.close)
            resources.callback(secondary.close)
            settings = {
                "version": 1, "state_dir": str(state), "listen_port": port,
                "devin_catalog": {"models": [
                    {"id": CANONICAL, "uid": UID, "max_tokens": 2048, "images": False,
                     "aliases": [ALIAS, UNLISTED]},
                    {"id": "devin/synthetic-image", "uid": IMAGE_UID,
                     "max_tokens": 4096, "images": True, "aliases": [IMAGE_ALIAS]},
                ]},
                "accounts": [
                    {"provider": "devin", "auth_mode": "session_token", "id": "one",
                     "origin": primary.origin, "models": [ALIAS]},
                    {"provider": "devin", "auth_mode": "session_token", "id": "two",
                     "origin": secondary.origin, "models": [ALIAS, IMAGE_ALIAS]},
                    {"provider": "claude", "auth_mode": "api_key", "id": "other",
                     "origin": secondary.origin, "models": [OTHER_MODEL]},
                ],
            }
            config.write_text(json.dumps(settings))

            def cli(*arguments, success=True):
                result = subprocess.run([*command, *map(str, arguments)], cwd=cwd,
                                        capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert (result.returncode == 0) == success, "unexpected root CLI outcome"
                if not success:
                    assert result.returncode == 1 and b"mimic: " in result.stderr

            for name, grant in grants.items():
                cli("providers", "credential", "import", config, name, grant)
            cli("providers", "credential", "import", config, "other", other_grant)
            cli("providers", "key", "import", config, "synthetic-f27-client", key)

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

            with running(1):
                listing(port, {
                    ALIAS: (CANONICAL, UID, 2048, False, "operator_config"),
                    IMAGE_ALIAS: ("devin/synthetic-image", IMAGE_UID, 4096, True, "operator_config"),
                })
                assert (primary.accepts, secondary.accepts) == (0, 0)
                chat(port, ALIAS, False)
                chat(port, ALIAS, True)
                # Both accounts are eligible: the fleet round-robins new
                # sessions. Each selected peer must supply the same scenario
                # while independently checking its own credential and mapping.
                assert (primary.requests, secondary.requests) == (1, 1)
                for fixture in (primary, secondary):
                    fixture.mode, fixture.expected_limit = "messages", 32
                buffered = message(port, ALIAS, False)
                streamed = message(port, ALIAS, True)
                streamed["id"] = buffered["id"]
                assert streamed == buffered, "current F24 JSON/SSE reconstruction drift"
                assert (primary.requests, secondary.requests) == (2, 2)
                for fixture in (primary, secondary):
                    fixture.mode, fixture.expected_limit = "text", 2048
                before = (primary.accepts, secondary.accepts)
                for unknown in ("devin/unknown", ALIAS + "-xhigh", UNLISTED, CANONICAL):
                    for route in ("/v1/chat/completions", "/v1/messages"):
                        assert call(port, route, unknown, True)[0] == 422
                        assert (primary.accepts, secondary.accepts) == before
                assert call(port, "/v1/messages/count_tokens", ALIAS, False)[0] == 422
                assert call(port, "/v1/responses", ALIAS, False)[0] == 422
                assert call(port, "/v1/chat/completions", ALIAS, False, auth=False)[0] == 401
                assert call(port, "/v1/messages", ALIAS, False, edit=lambda v: v.update(max_tokens=2049))[0] == 422
                assert call(port, "/v1/chat/completions", ALIAS, False, edit=lambda v: v.update(
                    messages=[{"role": "user", "content": [{"type": "image_url",
                    "image_url": {"url": "https://example.invalid/never-fetch"}}]}]))[0] == 422
                assert (primary.accepts, secondary.accepts) == before
                secondary.expected_uid, secondary.expected_limit = IMAGE_UID, 4096
                chat(port, IMAGE_ALIAS, False)
                assert (primary.requests, secondary.requests) == (2, 3)

            # Same persisted synthetic grants, omission retains original baseline.
            # Do this before the deliberate quota rejection below: a fresh VM
            # does not erase the account's persisted cooldown.
            legacy = copy.deepcopy(settings)
            del legacy["devin_catalog"]
            for account in legacy["accounts"]:
                if account["provider"] == "devin":
                    account["models"] = ["devin/swe-1-7"]
            config.write_text(json.dumps(legacy))
            for fixture in (primary, secondary):
                fixture.expected_uid, fixture.expected_limit = "swe-1-7", 64_000
            with running(2):
                listing(port, {
                    "devin/swe-1-7": ("devin/swe-1-7", "swe-1-7", 64_000, True, "baseline"),
                })
                chat(port, "devin/swe-1-7", False)
                chat(port, "devin/swe-1-7", True)
                assert (primary.requests, secondary.requests) == (3, 4)

            # Fresh runtime: force a safe rejection to verify the selected second
            # account's credential and mapping, rather than dispatch's first row.
            config.write_text(json.dumps(settings))
            for fixture in (primary, secondary):
                fixture.expected_uid, fixture.expected_limit = UID, 2048
            primary.reject = True
            with running(3):
                chat(port, ALIAS, False)
                assert (primary.requests, secondary.requests) == (4, 5)
            primary.reject = False

            invalids = []
            for edit in ("null", "duplicate-alias", "collision", "duplicate-uid",
                         "limit", "uid", "unknown-field", "shape", "unknown-enabled",
                         "boolean-limit", "images-type", "uid-control", "id-control",
                         "wrong-auth"):
                invalid = copy.deepcopy(settings)
                entry = invalid["devin_catalog"]["models"][0]
                if edit == "null":
                    invalid["devin_catalog"] = None
                elif edit == "duplicate-alias":
                    entry["aliases"] = [ALIAS, ALIAS]
                elif edit == "collision":
                    entry["aliases"].append("devin/synthetic-image")
                elif edit == "duplicate-uid":
                    invalid["devin_catalog"]["models"][1]["uid"] = UID
                elif edit == "limit":
                    entry["max_tokens"] = 0
                elif edit == "uid":
                    entry["uid"] = "invalid synthetic UID with spaces"
                elif edit == "unknown-field":
                    entry["discovery"] = True
                elif edit == "shape":
                    entry["aliases"] = {"id": ALIAS}
                elif edit == "unknown-enabled":
                    invalid["accounts"][0]["models"] = ["devin/unknown"]
                elif edit == "boolean-limit":
                    entry["max_tokens"] = True
                elif edit == "images-type":
                    entry["images"] = "false"
                elif edit == "uid-control":
                    entry["uid"] = "u\n"
                elif edit == "id-control":
                    entry["id"] = "devin/x\u0000"
                elif edit == "wrong-auth":
                    invalid["accounts"][0]["auth_mode"] = "api_key"
                invalids.append(json.dumps(invalid))
            raw = json.dumps(settings)
            invalids += [raw.replace('"uid":', '"uid":"conflicting","uid":', 1),
                         raw.replace('"devin_catalog":', '"devin_catalog":null,"devin_catalog":', 1)]
            before = (primary.accepts, secondary.accepts)
            for invalid in invalids:
                config.write_text(invalid)
                cli("providers", "key", "import", config, "synthetic-f27-client", key, success=False)
                assert (primary.accepts, secondary.accepts) == before
            assert primary.wire_ok and secondary.wire_ok
    assert not directory.exists(), "synthetic state survived cleanup"
    print(json.dumps({
        "slice": "F27", "scope": "actual_root_cli_current_f24", "synthetic": True,
        "source_or_shipment": "shipment" if args.shipment else "source",
        "configured_chat_json_sse": True, "corrected_messages_json_sse_equal": True,
        "selected_account_credential_and_model": True, "safe_rejection_failover": True,
        "baseline_chat_json_sse": True, "unknown_or_not_enabled_pre_io": 8,
        "route_capability_auth_pre_io": 5, "invalid_config_pre_io": len(invalids),
        "other_provider_listing_unchanged": True, "native_requests": 9,
        "fixture_cleanup": True, "live_discovery": False, "remote_enabled": False,
        "cpa_differential": False, "native_client": False, "live_verified": False,
        "elapsed_ms": int((time.monotonic() - began) * 1000),
    }, sort_keys=True))


if __name__ == "__main__":
    def bounded(_signum, _frame):
        raise TimeoutError("F27 root workflow exceeded 180-second wall budget")

    signal.signal(signal.SIGALRM, bounded)
    signal.alarm(180)
    main()
