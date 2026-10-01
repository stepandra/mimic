#!/usr/bin/env python3
"""F25 SYNTHETIC authenticated actual-root source/shipment Responses workflow.

No root overlays, facade, SDK execution, ambient grants, remote endpoints, CPA
or live Devin calls. Imported helpers are existing fixture/CLI primitives only.
JSON/SSE equality is reconstructed from deltas independently of the producer.
"""
import argparse
import base64
import contextlib
import copy
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import tempfile
import threading
import time

import f23_local_cli as helpers
import f24_local_cli as messages
import f27_local_cli as catalog_helpers

ROOT = Path(__file__).resolve().parents[2]
BASE = helpers.BASE
MODEL = "devin/f25-alias"
OTHER = "devin/f25-other"
UID = "synthetic-f25-native"
OTHER_UID = "synthetic-f25-other-native"
TOKENS = {name: f"synthetic-f25-cli-{name}" for name in ("one", "two")}
KEYS = {name: f"synthetic-f25-client-key-{name}" for name in ("tenant-a", "tenant-b")}
SECRETS = [value.encode() for value in (*TOKENS.values(), *KEYS.values())]
field, number, data, frame = helpers.field, helpers.number, helpers.data, helpers.frame
EOS = helpers.EOS
# Transport shape only: no signature validity/decryption assertion.
ENCRYPTED = base64.urlsafe_b64encode(b"\x80" + bytes(72)).decode()
POSITIVES = ("text", "zero", "length", "filtered", "tools", "summary", "signed")
NEGATIVES = (
    "missing-eos", "post-eos", "truncated-http", "nativefail", "malformed",
    "unknown-field", "partial-usage", "estimated-usage", "custom", "opaque",
    "missing-reason", "invalid-tool",
)


def no_secrets(raw):
    assert not any(secret in raw for secret in SECRETS), "F25 secret echo"


def fixture(mode):
    text = data(field(3, "synthetic F25 reply"))
    exact = field(7, number(2, 8) + number(3, 5))
    reason = number(5, {"length": 1, "filtered": 11, "tools": 10}.get(mode, 2))
    if mode == "zero":
        exact = field(7, number(2, 0) + number(3, 0))
    if mode in ("text", "zero", "length", "filtered", "regression"):
        return [text, data(exact + reason), EOS]
    if mode == "tools":
        return [
            data(field(6, field(1, "first") + field(3, b'{"x":"\xe2'))),
            text,
            data(field(6, field(1, "second") + field(2, "two") + field(3, b"{}"))),
            data(field(3, "B")),
            data(field(6, field(1, "first") + field(2, "one") + field(3, b'\x82\xac"}'))),
            data(field(3, "C")),
            data(field(7, number(3, 5))),
            data(field(7, number(2, 8) + number(5, 3)) + reason), EOS,
        ]
    if mode in ("summary", "signed"):
        return [
            data(field(9, "synthetic reasoning")),
            *([data(field(10, ENCRYPTED) + field(21, "openai"))] if mode == "signed" else []),
            text, data(exact + reason), EOS,
        ]
    if mode in ("hold", "missing-eos"):
        return [text]
    if mode == "post-eos":
        return [text, data(exact + reason), EOS + b"\x00"]
    if mode == "truncated-http":
        return [text, data(exact + reason), EOS]
    if mode == "nativefail":
        return [text, frame(2, json.dumps({"error": {
            "code": "unauthenticated", "message": TOKENS["one"],
        }}).encode())]
    if mode == "malformed":
        return [text, b"\x02\x00\x00\x00\x02{"]
    if mode == "unknown-field":
        return [text, data(field(99, b"unsupported"))]
    if mode == "partial-usage":
        return [text, data(field(7, number(3, 5)) + reason), EOS]
    if mode == "estimated-usage":
        def metric(name, n):
            return field(2, field(5, name) + field(4, helpers.varint(21) + struct.pack("<f", n)))
        estimate = field(28, field(1, "Token Usage") + metric("input_tokens", 8.0)
                         + metric("output_tokens", 5.0))
        return [text, data(estimate + reason), EOS]
    if mode == "custom":
        return [data(field(6, field(1, "custom") + field(2, "run") + number(6, 1)))]
    if mode == "opaque":
        return [data(field(9, "reason") + field(10, b"\xff\x00") + field(21, "sealed")),
                data(exact + reason), EOS]
    if mode == "missing-reason":
        return [text, data(exact), EOS]
    if mode == "invalid-tool":
        return [data(field(6, field(1, "bad") + field(2, "run") + field(3, "{"))),
                data(exact + number(5, 10)), EOS]
    raise AssertionError("unknown synthetic mode")


class Fixture(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, name):
        super().__init__(("127.0.0.1", 0), Upstream)
        self.name, self.mode, self.reject = name, "text", False
        self.expected_uid, self.history = UID, True
        self.accepts = self.requests = self.peer_eofs = 0
        self.wire_ok = True
        self.ready = threading.Event()
        self.worker = threading.Thread(target=self.serve_forever)
        self.worker.start()

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server_port}"

    def get_request(self):
        pair = super().get_request()
        pair[0].settimeout(13)
        self.accepts += 1
        return pair

    def close(self):
        self.shutdown()
        self.server_close()
        self.worker.join(timeout=5)
        assert not self.worker.is_alive(), "F25 fixture survived teardown"


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        server = self.server
        token = TOKENS[server.name]
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            assert self.request_version == "HTTP/1.1"
            assert self.path == "/exa.api_server_pb.ApiServerService/GetChatMessage"
            assert self.headers.get_all("Authorization") == [f"Basic {token}-{token}"]
            assert self.headers.get_all("Host") == [server.origin[7:]]
            assert self.headers.get_all("Content-Type") == ["application/connect+proto"]
            assert self.headers.get_all("Connect-Protocol-Version") == ["1"]
            assert all(self.headers.get(name) is None for name in
                       ("User-Agent", "Accept-Encoding", "Transfer-Encoding"))
            assert body[:1] == b"\x00" and int.from_bytes(body[1:5], "big") == len(body) - 5
            root = catalog_helpers.fields(body[5:])
            assert [v for tag, kind, v in root if (tag, kind) == (21, 2)] == [server.expected_uid.encode()]
            assert field(3, token) in body
            assert all(v.encode() not in body for v in TOKENS.values() if v != token)
            if server.history:
                assert field(10, field(1, "aGk=") + field(2, "image/png")) in body
                assert field(7, "history-call") in body
                assert field(11, "synthetic history reasoning") in body
                assert field(12, ENCRYPTED) in body and field(18, "openai") in body
        except (AssertionError, KeyError):
            server.wire_ok = False  # Persist only a boolean, never raw request.
        server.requests += 1
        if server.reject:
            self.send_response(429)
            self.send_header("Retry-After", "1")
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.close_connection = True
            return
        mode = server.mode
        self.send_response(200)
        self.send_header("Content-Type", "application/connect+proto")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for value in fixture(mode):
                self.wfile.write(f"{len(value):x}\r\n".encode() + value + b"\r\n")
                self.wfile.flush()
            server.ready.set()
            if mode == "hold":
                # Valid slow trickle defeats the transport's per-pull 5s idle
                # timeout. Only the ORIGINAL request-wide deadline (or owner/
                # explicit cancel) may end this native operation successfully.
                end = time.monotonic() + 14
                while time.monotonic() < end:
                    if select.select([self.connection], [], [], 0.2)[0]:
                        assert self.connection.recv(1) == b"", "expected upstream peer EOF"
                        server.peer_eofs += 1
                        break
                    value = data(field(3, "."))
                    self.wfile.write(f"{len(value):x}\r\n".encode() + value + b"\r\n")
                    self.wfile.flush()
                else:
                    raise AssertionError("F25 original deadline did not close upstream")
            elif mode != "truncated-http":
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # A projection can explicitly cancel as soon as unsupported input
            # is seen. Do not confuse socket.timeout/teardown with peer EOF.
            server.peer_eofs += 1
        finally:
            self.close_connection = True


def payload(streaming=False, model=MODEL):
    value = {"model": model, "max_output_tokens": 32, "stream": streaming}
    if model == OTHER:
        return {**value, "input": "synthetic other model"}
    return {**value, "instructions": "synthetic instructions", "input": [
        {"role": "user", "content": [{"type": "input_image", "image_url": "data:image/png;base64,aGk="}]},
        {"type": "reasoning", "summary": [{"type": "summary_text", "text": "synthetic history reasoning"}],
         "encrypted_content": ENCRYPTED},
        {"type": "function_call", "call_id": "history-call", "name": "lookup", "arguments": '{"x":1}'},
        {"type": "function_call_output", "call_id": "history-call", "output": "synthetic result"},
        {"role": "user", "content": "next"},
    ], "tools": [{"type": "function", "name": name, "parameters": {"type": "object"},
                 "strict": False} for name in ("lookup", "one", "two")]}


def exact_usage(value):
    assert isinstance(value, dict)
    assert all(type(value.get(k)) is int and value[k] >= 0
               for k in ("input_tokens", "output_tokens", "total_tokens"))
    assert value["total_tokens"] == value["input_tokens"] + value["output_tokens"]


def consume(raw):
    """Independent append-based strict reconstruction, not an installed SDK."""
    created, output, terminal, error = None, [], None, False
    item_open, part_open, text_done, args_done = False, False, False, False
    last_sequence = -1
    for name, value in helpers.parse_sse(raw):
        assert name == value["type"] and terminal is None and not error
        if name == "error":
            # Actual pinned SDK ErrorEvent is flat, with a real sequence.
            assert set(value) == {"type", "code", "message", "param", "sequence_number"}
            assert value["code"] == "provider_unavailable"
            assert value["message"] == "Devin Responses stream failed" and value["param"] is None
            assert type(value["sequence_number"]) is int and value["sequence_number"] == last_sequence + 1
            error = True
            continue
        assert type(value["sequence_number"]) is int and value["sequence_number"] == last_sequence + 1
        last_sequence = value["sequence_number"]
        if name == "response.created":
            assert created is None
            created = copy.deepcopy(value["response"])
            assert created["object"] == "response" and created["status"] == "in_progress"
            assert created["id"] and created["output"] == [] and created["error"] is None
            assert isinstance(created["tools"], list) and type(created["parallel_tool_calls"]) is bool
            assert created["tool_choice"] in ("auto", "none")
            exact_usage(created["usage"])
        elif name == "response.output_item.added":
            assert created is not None and not item_open and not part_open
            assert value["output_index"] == len(output)
            item = copy.deepcopy(value["item"])
            assert item["id"] and all(item["id"] != prior["id"] for prior in output)
            if item["type"] == "function_call":
                assert item["call_id"] and item["name"] and item["arguments"] == ""
                assert all(item["call_id"] != prior.get("call_id") for prior in output)
            elif item["type"] == "message":
                assert item["role"] == "assistant" and item["content"] == []
            else:
                assert item["type"] == "reasoning" and item["summary"] == []
            output.append(item)
            item_open, text_done, args_done = True, False, False
        elif name in ("response.completed", "response.incomplete"):
            assert created is not None and not item_open and not part_open
            terminal = value["response"]
            assert terminal["status"] == name.removeprefix("response.")
            assert terminal["output"] == output, "terminal silently repaired emitted content"
            exact_usage(terminal["usage"])
            assert all(created[k] == terminal[k] for k in
                       ("id", "created_at", "model", "usage", "devin", "tools", "tool_choice", "parallel_tool_calls"))
        else:
            assert item_open and value["output_index"] == len(output) - 1
            item = output[-1]
            if name == "response.output_item.done":
                assert not part_open
                if item["type"] == "function_call":
                    assert args_done
                if "status" in value["item"]:
                    item["status"] = value["item"]["status"]
                assert item == value["item"], "item snapshot repaired malformed deltas"
                item_open = False
                continue
            assert value["item_id"] == item["id"]
            if name.startswith("response.function_call_arguments."):
                assert item["type"] == "function_call" and not args_done
                assert value["name"] == item["name"] and value["call_id"] == item["call_id"]
                if name.endswith(".delta"):
                    item["arguments"] += value["delta"]
                else:
                    assert item["arguments"] == value["arguments"] and isinstance(json.loads(item["arguments"]), dict)
                    args_done = True
                continue
            group = "summary" if item["type"] == "reasoning" else "content"
            assert value[group + "_index"] == 0
            if name.endswith("_part.added"):
                assert not part_open and item[group] == []
                item[group].append(copy.deepcopy(value["part"]))
                part_open = True
            elif name.endswith("_text.delta"):
                assert part_open and not text_done
                item[group][0]["text"] += value["delta"]
            elif name.endswith("_text.done"):
                assert part_open and not text_done and value["text"] == item[group][0]["text"]
                text_done = True
            elif name.endswith("_part.done"):
                assert part_open and text_done and value["part"] == item[group][0]
                part_open = False
            else:
                raise AssertionError("unsupported Responses event")
    assert (terminal is not None) != error
    return terminal


def normalize(value):
    value = copy.deepcopy(value)
    value["id"], value["created_at"] = "<request-local>", 0
    for index, item in enumerate(value["output"]):
        item["id"] = f"<request-local-item-{index}>"
    return value


def call(port, value, key="tenant-a", path="/v1/responses"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=13)
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + KEYS[key]
    connection.request("POST", path, json.dumps(value), headers)
    try:
        response = connection.getresponse()
        raw, clean = helpers.read_all(response)
        no_secrets(raw)
        return response.status, response.getheader("Content-Type"), raw, clean
    finally:
        connection.close()


def wait_for(check, budget=3):
    end = time.monotonic() + budget
    while not check() and time.monotonic() < end:
        time.sleep(0.02)
    assert check(), "bounded cleanup/selection check failed"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    began = time.monotonic()
    root = ROOT / "build/f25"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="root-cli-", dir=root) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        state = directory / "state"
        state.mkdir(mode=0o700)
        cwd = directory if args.shipment else ROOT
        config = directory / "providers.json"
        port = helpers.free_port()
        one, two = Fixture("one"), Fixture("two")
        try:
            settings = {"version": 1, "state_dir": str(state), "listen_port": port,
                "devin_catalog": {"models": [
                    {"id": "devin/f25", "uid": UID, "max_tokens": 2048, "images": True,
                     "aliases": [MODEL, "devin/f25-not-enabled"]},
                    {"id": OTHER, "uid": OTHER_UID, "max_tokens": 1024, "images": False, "aliases": []},
                ]},
                "accounts": [
                    {"provider": "devin", "auth_mode": "session_token", "id": server.name,
                     "origin": server.origin, "models": [MODEL] + ([OTHER] if server is two else [])}
                    for server in (one, two)
                ]}
            config.write_text(json.dumps(settings))
            for name, token in TOKENS.items():
                grant = BASE["private_file"](directory / f"session-{name}.json", json.dumps({"session_token": token}))
                result = subprocess.run([*command, "providers", "credential", "import", str(config), name, grant],
                                        cwd=cwd, capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert result.returncode == 0, "synthetic grant import failed"
            for name, value in KEYS.items():
                key = BASE["private_file"](directory / name, value)
                result = subprocess.run([*command, "providers", "key", "import", str(config), name, key],
                                        cwd=cwd, capture_output=True, timeout=30)
                no_secrets(result.stdout + result.stderr)
                assert result.returncode == 0, "synthetic client key import failed"

            @contextlib.contextmanager
            def running(index):
                log_path = directory / f"gateway-{index}.log"
                with log_path.open("wb") as log:
                    process = BASE["start"](command, config, port, log, state, cwd)
                    try:
                        yield process
                    finally:
                        BASE["stop"](process, state)
                no_secrets(log_path.read_bytes())
                assert not (state / ".provider-runtime-owner").exists()

            # Fresh runtime per row: no prior sticky selection conceals first-account
            # or replay defects. IDs/time differ by request; all semantic data must not.
            expected = {}
            for mode in (*POSITIVES, *NEGATIVES):
                for streaming in (False, True):
                    one.mode = two.mode = mode
                    with running(f"{mode}-{streaming}"):
                        before = one.requests
                        status, media, raw, clean = call(port, payload(streaming))
                        if streaming:
                            assert status == 200 and media == "text/event-stream", "actual F25 root admission required"
                            value = consume(raw)
                            if mode in NEGATIVES:
                                assert value is None and not clean
                            else:
                                assert clean and value is not None
                                assert expected[mode] == normalize(value), "JSON/SSE reconstruction mismatch"
                        elif mode in NEGATIVES:
                            assert status == 503 and media == "application/json"
                        else:
                            assert status == 200 and media == "application/json" and clean
                            value = json.loads(raw)
                            assert value["object"] == "response" and "choices" not in value
                            exact_usage(value["usage"])
                            expected[mode] = normalize(value)
                        assert one.requests == before + 1 and two.accepts == 0, "incorrect selection or replay after Started"

            one.mode = two.mode = "text"
            with running("isolation-denials"):
                before = one.requests + two.requests
                assert call(port, payload(), key=None)[0] == 401
                for model in ("devin/f25", "devin/f25-not-enabled", "devin/unknown"):
                    assert call(port, payload(model=model))[0] == 422
                assert call(port, payload(), path="/v1/responses/compact")[0] == 422
                response = json.loads(call(port, payload(), key="tenant-a")[2])
                for tenant in KEYS:
                    bad = {**payload(), "previous_response_id": response["id"]}
                    assert call(port, bad, key=tenant)[0] == 422
                for extra in (
                    {"store": True}, {"reasoning": {"effort": "high"}},
                    {"input": [{"type": "function_call_output", "call_id": "orphan", "output": "x"}]},
                    {"input": [{"type": "item_reference", "id": "other-tenant"}]},
                    {"input": [{"role": "user", "content": [{"type": "input_image", "image_url": "https://invalid.example/x"}]}]},
                ):
                    assert call(port, {**payload(), **extra})[0] == 422
                assert one.requests + two.requests == before + 1, "denial performed native I/O"

            one.reject = True
            with running("429-failover"):
                before = one.requests, two.requests
                status, _, raw, clean = call(port, payload(True), key="tenant-b")
                assert status == 200 and clean and consume(raw) is not None
                assert (one.requests, two.requests) == (before[0] + 1, before[1] + 1)
            one.reject = False
            one.history = two.history = False
            two.expected_uid = OTHER_UID
            with running("model-isolation"):
                before = one.requests, two.requests
                status, _, raw, clean = call(port, payload(True, model=OTHER))
                assert status == 200 and clean and consume(raw)["model"] == OTHER
                assert one.requests == before[0] and two.requests == before[1] + 1
            two.expected_uid = UID

            # Ordinary/default Chat and Messages keep their original schemas.
            one.mode = two.mode = "regression"
            for path in ("/v1/chat/completions", "/v1/messages"):
                for streaming in (False, True):
                    with running(f"regression-{path.rsplit('/', 1)[1]}-{streaming}"):
                        value = {"model": MODEL, "stream": streaming, "max_tokens": 32,
                                 "messages": [{"role": "user", "content": "synthetic default"}]}
                        status, media, raw, clean = call(port, value, path=path)
                        assert status == 200 and clean
                        if path == "/v1/messages":
                            message = messages.consume(raw) if streaming else json.loads(raw)
                            assert message["type"] == "message" and "output" not in message
                        elif streaming:
                            assert helpers.parse_sse(raw)[0][0] in ("", "message")
                            assert raw.rstrip().endswith(b"data: [DONE]")
                        else:
                            assert "choices" in json.loads(raw) and "output" not in json.loads(raw)

            one.history = two.history = True
            one.mode = two.mode = "hold"
            one.ready.clear()
            before = one.peer_eofs
            with running("cleanup-json-deadline"):
                began_deadline = time.monotonic()
                status, media, raw, clean = call(port, payload(False))
                elapsed = time.monotonic() - began_deadline
                assert status == 503 and media == "application/json"
                assert 8 <= elapsed <= 12, "request-wide deadline was not exercised"
                wait_for(lambda: one.peer_eofs == before + 1)
            for action in ("deadline", "downstream-close", "owner-vm-stop"):
                one.ready.clear()
                before = one.peer_eofs
                with running(f"cleanup-{action}") as process:
                    began_deadline = time.monotonic()
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=13)
                    connection.request("POST", "/v1/responses", json.dumps(payload(True)),
                                       {"Content-Type": "application/json", "Authorization": "Bearer " + KEYS["tenant-a"]})
                    response = connection.getresponse()
                    assert response.status == 200
                    assert one.ready.wait(3)
                    if action == "deadline":
                        raw, clean = helpers.read_all(response)
                        assert consume(raw) is None and not clean
                        assert 8 <= time.monotonic() - began_deadline <= 12
                    elif action == "downstream-close":
                        connection.close()
                    else:
                        BASE["stop"](process, state)
                    # No idle downstream watcher claim. Explicit disconnect during
                    # delayed construction is bounded by the original 10s deadline.
                    wait_for(lambda: one.peer_eofs == before + 1, budget=12)
                    connection.close()
            assert one.wire_ok and two.wire_ok, "selected native account/model/history/header mismatch"
            requests = one.requests + two.requests
        finally:
            try:
                one.close()
            finally:
                two.close()
    assert not directory.exists(), "F25 private state survived cleanup"
    print(json.dumps({
        "slice": "F25", "synthetic": True, "actual_root_cli": True, "shipment": bool(args.shipment),
        "responses_json_positive": len(POSITIVES), "responses_sse_positive": len(POSITIVES),
        "json_started_failures": len(NEGATIVES), "sse_started_failures": len(NEGATIVES),
        "json_sse_equal": True, "selected_context_failover": True, "default_chat_messages_regressions": 4,
        "model_account_tenant_isolation": True, "cleanup_variants": 4, "native_requests": requests,
        "seconds": round(time.monotonic() - began, 3),
        "incremental_streaming": False, "sdk_execution": False, "cpa_differential": False,
        "native_client": False, "remote": False, "live": False,
    }, sort_keys=True))


if __name__ == "__main__":
    def bounded(_signal, _frame):
        raise TimeoutError("F25 actual-root workflow bounded at 240 seconds")
    signal.signal(signal.SIGALRM, bounded)
    signal.alarm(240)
    main()
