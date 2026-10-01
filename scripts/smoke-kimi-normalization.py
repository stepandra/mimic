#!/usr/bin/env python3
"""F16 synthetic native normalization at real CLI/shipment; no CPA/live calls."""

import argparse
import contextlib
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
from pathlib import Path
import runpy
import socket
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
BASE = runpy.run_path(str(ROOT / "scripts/smoke-gateway.py"))
FIXTURES = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
MODEL, UPSTREAM = "kimi-k2.8", "kimi-for-coding"
GENERIC = "synthetic-f16-generic"
CLIENT = BASE["CLIENT_KEY"]
KEY, GENERIC_KEY = "synthetic-f16-key", "synthetic-f16-generic-key"
SECRETS = [CLIENT, KEY, GENERIC_KEY]
OPAQUE = {"$ref": "file:///synthetic-not-a-resolver", "$defs": {"literal": True},
          "model": MODEL, "type": "input_audio", "$id": "opaque"}
ARGUMENTS = '{ "$ref": "file:///synthetic", "model": "kimi-k2.8", "type": "input_audio" }'


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def parameters():
    return {
        "$defs": {"leaf": {"type": "string", "minLength": 1}},
        "definitions": {"root": {"properties": {
            "q": {"$ref": "#/$defs/leaf", "description": "synthetic override"}}}},
        "$ref": "#/definitions/root", "required": ["q"],
        "additionalProperties": False, "default": copy.deepcopy(OPAQUE),
        "enum": [copy.deepcopy(OPAQUE)], "examples": [copy.deepcopy(OPAQUE)],
        "x-vendor": {"properties": copy.deepcopy(OPAQUE)},
    }


def normalized_parameters():
    return {
        "type": "object", "properties": {"q": {
            "type": "string", "minLength": 1, "description": "synthetic override"}},
        "required": ["q"], "additionalProperties": False,
        "default": copy.deepcopy(OPAQUE), "enum": [copy.deepcopy(OPAQUE)],
        "examples": [copy.deepcopy(OPAQUE)],
        "x-vendor": {"properties": copy.deepcopy(OPAQUE)},
    }


def payload(protocol, streaming=False):
    function = {"name": "synthetic_lookup", "parameters": parameters(),
                "x-vendor": copy.deepcopy(OPAQUE)}
    result = {"model": MODEL, "stream": streaming, "temperature": 1,
              "x-vendor": {"thinking": {"type": "disabled"}, "temperature": 0.2,
                           "conversation": "opaque", "schema": copy.deepcopy(OPAQUE)}}
    if protocol == "chat":
        result.update({
            "tools": [{"type": "function", "function": function}],
            "reasoning_effort": "high",
            "messages": [
                {"role": "assistant", "content": "  "},
                {"role": "assistant", "reasoning_content": "  synthetic 思考🌍  ",
                 "tool_calls": [{"id": "explicit-synthetic-call", "type": "function",
                                 "function": {"name": "synthetic_lookup",
                                              "arguments": ARGUMENTS}}]},
                {"role": "tool", "tool_call_id": "explicit-synthetic-call",
                 "content": '{"model":"user","$ref":"opaque"}'},
                {"role": "user", "content": [
                    {"type": "text", "text": 'synthetic "$ref" 思考🌍'},
                    {"type": "image_url", "image_url": {
                        "url": "https://synthetic.invalid/image.png"}}]},
            ],
        })
    else:
        result.update({
            "tools": [dict(function, type="function")],
            "reasoning": {"effort": "max", "summary": "auto", "x-vendor": OPAQUE},
            "input": [
                {"type": "reasoning", "id": "reason_synthetic",
                 "summary": [{"type": "summary_text", "text": "  synthetic 思考🌍  "}],
                 "encrypted_content": "synthetic-opaque-string", "x-vendor": OPAQUE},
                {"type": "function_call", "call_id": "explicit-synthetic-call",
                 "name": "synthetic_lookup", "arguments": ARGUMENTS},
                {"type": "function_call_output", "call_id": "explicit-synthetic-call",
                 "output": '{"model":"user","$ref":"opaque"}'},
                {"role": "user", "content": [
                    {"type": "input_text", "text": 'synthetic "$ref" 思考🌍'},
                    {"type": "input_image", "image_url":
                     "data:image/png;base64,c3ludGhldGlj"}]},
            ],
        })
    return result


def tool_function(body, protocol):
    tool = body["tools"][0]
    return tool["function"] if protocol == "chat" else tool


def expected(body, protocol):
    result = copy.deepcopy(body)
    result["model"] = UPSTREAM
    tool_function(result, protocol)["parameters"] = normalized_parameters()
    if protocol == "chat":
        if "reasoning_effort" in result:
            effort = result.pop("reasoning_effort")
            result["thinking"] = {"type": "enabled", "effort": effort}
        if result["stream"]:
            result["stream_options"] = {"include_usage": True}
    return result


def no_secrets(data):
    assert not any(secret.encode() in data for secret in SECRETS), "credential in output"


class UpstreamHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw)
        generic = self.path == "/f16/generic/chat/completions"
        chat = self.path.endswith("/chat/completions")
        key = GENERIC_KEY if generic else KEY
        with self.server.lock:
            self.server.observations.append({
                "path": self.path, "body": body, "raw": raw,
                "auth_ok": self.headers.get("Authorization") == "Bearer " + key,
                "encoding": self.headers.get("Accept-Encoding"),
                "accept": self.headers.get("Accept"),
                "no_device": not any(name.lower().startswith("x-msh-")
                                     for name in self.headers),
            })
        if body.get("stream"):
            # Reuse the existing synthetic protocol fixtures, not a new codec.
            data = (FIXTURES["kimi_chat_sse"]() if chat else FIXTURES["kimi_sse"]()).encode()
            media = "text/event-stream"
        elif chat:
            data = encoded({
                "id": "chat_synthetic", "object": "chat.completion", "created": 1,
                "model": body["model"],
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "synthetic"},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 3, "completion_tokens": 1},
            })
            media = "application/json"
        else:
            data = encoded(FIXTURES["KIMI_RESPONSE"])
            media = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True


@contextlib.contextmanager
def upstream():
    server = ThreadingHTTPServer(("127.0.0.1", 0), UpstreamHandler)
    server.daemon_threads = True
    server.observations, server.lock = [], threading.Lock()
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def call(port, path, body):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
    try:
        connection.request("POST", path, body if isinstance(body, bytes) else encoded(body), {
            "Authorization": "Bearer " + CLIENT, "Content-Type": "application/json"})
        response = connection.getresponse()
        raw = response.read()  # Actual complete HTTP body; timeout/truncation is an error.
        no_secrets(raw)
        return response.status, raw
    finally:
        connection.close()


def path_for(protocol):
    return "/v1/chat/completions" if protocol == "chat" else "/v1/responses"


def expansion(kind):
    if kind == "depth":
        definitions = {"d" + str(i): {"$ref": "#/$defs/d" + str(i + 1)}
                       for i in range(66)}
        definitions["d65"] = {"type": "object"}
        return {"$ref": "#/$defs/d0", "$defs": definitions}
    if kind == "nodes":
        definitions = {"d" + str(i): {"anyOf": [
            {"$ref": "#/$defs/d" + str(i + 1)},
            {"$ref": "#/$defs/d" + str(i + 1)}]} for i in range(13)}
        definitions["d12"] = {"type": "object"}
        return {"$ref": "#/$defs/d0", "$defs": definitions}
    return {"$defs": {"leaf": {"type": "string", "description": "🌍" * 1024}},
            "properties": {"p" + str(i): {"$ref": "#/$defs/leaf"} for i in range(70)}}


def exercise(port, server):
    accepted = denied = 0

    def success(protocol, body):
        nonlocal accepted
        count = len(server.observations)
        status, raw = call(port, path_for(protocol), body)
        assert status == 200, ("admitted fixture rejected", protocol, status)
        assert len(server.observations) == count + 1, "unexpected upstream sends"
        seen = server.observations[-1]
        assert seen["path"] == "/f16/native" + path_for(protocol)
        assert seen["auth_ok"] and seen["encoding"] == "identity" and seen["no_device"]
        assert seen["accept"] == ("text/event-stream" if body["stream"] else "application/json")
        assert seen["body"] == expected(body, protocol), ("normalization/preservation mismatch", protocol)
        if body["stream"]:
            assert (b"data: [DONE]" if protocol == "chat" else b"response.completed") in raw
            assert MODEL.encode() in raw
        else:
            assert json.loads(raw)["model"] == MODEL
        accepted += 1

    def denial(protocol, body, path=None):
        nonlocal denied
        count = len(server.observations)
        status, _ = call(port, path or path_for(protocol), body)
        assert status != 200, ("denied fixture accepted", protocol)
        assert len(server.observations) == count, ("denial sent upstream", protocol)
        denied += 1

    for protocol in ("chat", "responses"):
        for streaming in (False, True):
            success(protocol, payload(protocol, streaming))
            schemas = [
                {"$ref": "https://synthetic.invalid/schema"},
                {"$ref": "file:///synthetic/schema"},
                {"$ref": "#/$defs/missing"},
                {"$defs": {"x": {"$ref": "#/$defs/x"}}, "$ref": "#/$defs/x"},
                {"$ref": "#/default", "default": {"type": "object"}},
                {"$id": "https://synthetic.invalid/schema"},
                {"$ref": "#/$defs/%78", "$defs": {"x": {"type": "object"}}},
                *(expansion(kind) for kind in ("depth", "nodes", "bytes")),
            ]
            for schema in schemas:
                body = payload(protocol, streaming)
                tool_function(body, protocol)["parameters"] = schema
                denial(protocol, body)
            # Individually valid schemas cannot expand the combined request
            # beyond its admission ceiling. This is not just a per-tool limit.
            body = payload(protocol, streaming)
            tool_function(body, protocol)["parameters"] = {
                "$defs": {"leaf": {"type": "string", "description": "s" * 4096}},
                "properties": {"p" + str(i): {"$ref": "#/$defs/leaf"} for i in range(50)},
            }
            body["tools"] = [copy.deepcopy(body["tools"][0]) for _ in range(6)]
            denial(protocol, body)
            for key, value in [("temperature", 0.2), ("previous_response_id", "opaque-synthetic"),
                               ("conversation", "opaque-synthetic")]:
                body = payload(protocol, streaming)
                body[key] = value
                denial(protocol, body)
            for kind in ("input_audio", "video", "file", "synthetic_future_media"):
                body = payload(protocol, streaming)
                content = [{"type": kind, "data": "synthetic"}]
                if protocol == "chat":
                    body["messages"][-1]["content"] = content
                else:
                    body["input"][-1]["content"] = content
                denial(protocol, body)
            # Tool-result media cannot escape the same protocol-position policy.
            body = payload(protocol, streaming)
            if protocol == "chat":
                body["messages"][2]["content"] = [{"type": "input_audio", "data": "synthetic"}]
            else:
                body["input"][2]["output"] = [{"type": "input_audio", "data": "synthetic"}]
            denial(protocol, body)
            raw = encoded(payload(protocol, streaming))
            duplicate = raw.replace(b'"$ref":"#/$defs/leaf"',
                                    b'"$ref":"#/$defs/leaf","\\u0024ref":"opaque"', 1)
            assert duplicate != raw
            denial(protocol, duplicate)

    body = payload("chat")
    body.pop("reasoning_effort")
    body.update(thinking={"type": "disabled", "keep": True}, temperature=0.6)
    body["messages"][1].pop("reasoning_content")
    success("chat", body)
    body = payload("responses")
    body["reasoning"]["effort"] = "none"
    success("responses", body)  # Native reasoning.none does not rewrite temperature to 0.6.
    body["temperature"] = 0.6
    denial("responses", body)
    body = payload("chat")
    body["messages"][1].pop("reasoning_content")
    denial("chat", body)  # Never use prior/content reasoning or a fabricated placeholder.
    body = payload("chat")
    body["messages"][2]["call_id"] = body["messages"][2].pop("tool_call_id")
    denial("chat", body)
    for streaming in (False, True):
        denial("responses", payload("responses", streaming), "/v1/responses/compact")

    # A separately configured generic provider retains raw bytes and parameters.
    body = payload("chat")
    body["model"], body["temperature"], body["reasoning_effort"] = GENERIC, 0.2, "medium"
    raw = b" \n" + json.dumps(body, ensure_ascii=False, indent=2).encode() + b"\n "
    count = len(server.observations)
    status, reply = call(port, path_for("chat"), raw)
    assert status == 200 and json.loads(reply)["model"] == GENERIC
    assert len(server.observations) == count + 1
    seen = server.observations[-1]
    assert seen["path"] == "/f16/generic/chat/completions" and seen["auth_ok"]
    assert seen["raw"] == raw and seen["body"] == body
    accepted += 1
    return accepted, denied


def self_test():
    with upstream() as server:
        body = payload("chat")
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        try:
            connection.request("POST", "/f16/native/v1/chat/completions", encoded(body), {
                "Authorization": "Bearer " + KEY})
            response = connection.getresponse()
            assert response.status == 200 and json.loads(response.read())["model"] == MODEL
        finally:
            connection.close()
        assert server.observations[0]["body"] == body
    assert normalized_parameters()["default"] == OPAQUE
    assert expected(payload("responses"), "responses")["reasoning"]["effort"] == "max"
    print(json.dumps({"scope": "f16_fixture_self_test", "synthetic": True,
                      "real_sockets": True, "mimic_executed": False}, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path,
                        help="exported Erlang shipment; runs from a different cwd")
    parser.add_argument("--self-test", action="store_true", help="fixture only, not MIMIC")
    args = parser.parse_args()
    if args.self_test:
        assert args.shipment is None
        self_test()
        return
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"] if args.shipment else
               ["mise", "exec", "gleam@1.18.1", "--", "gleam", "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f16-kimi-normalization-",
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
            origin = f"http://127.0.0.1:{server.server_port}"
            config = directory / "providers.json"
            accounts = [
                {"provider": "kimi", "auth_mode": "api_key", "id": "absent",
                 "origin": "http://127.0.0.1:1", "base_path": "/unused", "models": [MODEL]},
                {"provider": "kimi", "auth_mode": "api_key", "id": "native",
                 "origin": origin, "base_path": "/f16/native/v1", "models": [MODEL]},
                {"provider": "openai-compatible-kimi", "auth_mode": "api_key", "id": "generic",
                 "origin": origin, "base_path": "/f16/generic", "models": [GENERIC]},
            ]
            config.write_text(json.dumps({
                "version": 1, "state_dir": str(state), "listen_port": port, "accounts": accounts}))

            def cli(*arguments):
                result = subprocess.run([*command, *arguments], cwd=cwd, capture_output=True,
                                        timeout=60, check=False)
                output = result.stdout + result.stderr
                no_secrets(output)
                assert result.returncode == 0, ("CLI failure", arguments[:3], result.returncode,
                                                 output.decode(errors="replace"))

            for account, key in (("native", KEY), ("generic", GENERIC_KEY)):
                grant = BASE["private_file"](directory / (account + ".json"),
                                              json.dumps({"api_key": key}))
                cli("providers", "credential", "import", str(config), account, grant)
            client = BASE["private_file"](directory / "client.txt", CLIENT + "\n")
            cli("providers", "key", "import", str(config), "synthetic-f16-client", client)
            log_path = directory / "gateway.log"
            with log_path.open("wb") as log:
                process = BASE["start"](command, config, port, log, state, cwd)
                try:
                    accepted, denied = exercise(port, server)
                finally:
                    BASE["stop"](process, state)
            no_secrets(log_path.read_bytes())
            print(json.dumps({
                "scope": "f16_shipment_cli" if args.shipment else "f16_source_cli",
                "synthetic": True, "mimic_executed": True,
                "chat_responses_buffered_streaming": True,
                "same_bounded_schema_rule": True, "before_after_whole_document": True,
                "arguments_history_vendor_media_preserved": True,
                "generic_raw_bytes_unchanged": True, "pre_io_denials": denied,
                "accepted_upstream_requests": accepted,
                "different_working_directory": cwd != ROOT,
                "compact_continuation_denied": True,
                "native_live_cpa_differential_qualification": False,
            }, sort_keys=True))


if __name__ == "__main__":
    main()
