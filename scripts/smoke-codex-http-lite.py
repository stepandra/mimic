#!/usr/bin/env python3
"""F12 synthetic loopback root CLI/gateway workflow; no CPA, live or native client."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import runpy
import select
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
CLIENT = HTTP["CLIENT"]
SECOND = "synthetic-f12-other-client"
MODEL = "gpt-5.6-sol"
MARKER = "ws_request_header_x_openai_internal_codex_responses_lite"
LITE_HEADER = "X-OpenAI-Internal-Codex-Responses-Lite"
HINT = "synthetic-f12-stable-thread"
HTTP["SECRETS"].extend([SECOND, "synthetic-f12-backup-access",
                        "synthetic-f12-backup-refresh"])

# Literal synthetic strings from CPA acdace936 codex_native_fidelity_test.go:31-33.
METADATA = '{"type":"codex.response.metadata","headers":{"x-models-etag":"models-v1","x-codex-turn-state":"turn-1","x-codex-safety-buffering-enabled":"true","x-codex-safety-buffering-faster-model":"fixture-model"},"future":{"ok":true}}'
DONE = '{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}'
COMPLETED = '{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[],"future":{"ok":true},"usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}'
SOURCE_SHA256 = (
    "6baffc27198461b901fc896c0654063ccb1863c79d7150402e035d04cd40662b",
    "87653f7cca05963cb2b49bcdb9f53d288397a99b8e818f0801dc3d3a230ee5a0",
    "d67cb80dc6ae32c97a73a97570859c77b12c6e7b1d8b57ca3fd1322fbfa41f97",
)


def compact_json(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def sse(events):
    return "".join("data: " + data + "\n\n" for data in events)


def events(mode, receipt):
    if mode == "native":
        return [METADATA, DONE, COMPLETED]
    terminal = json.loads(COMPLETED)
    terminal["response"]["id"] = receipt
    created = compact_json({"type": "response.created", "response": {"id": receipt}})
    if mode == "strict":
        item = json.loads(DONE)["item"]
        created = compact_json({"type": "response.created", "response": {
            "id": receipt, "object": "response", "status": "in_progress",
            "model": MODEL, "output": []}})
        terminal["response"].update(object="response", model=MODEL, output=[item])
        added = json.loads(DONE)
        added["type"] = "response.output_item.added"
        return [created, compact_json(added), DONE, compact_json(terminal)]
    if mode == "empty":
        return [created, compact_json(terminal)]
    if mode == "idless":
        done = json.loads(DONE)
        del done["item"]["id"]
        return [created, compact_json(done), compact_json(terminal)]
    if mode == "open":
        done = json.loads(DONE)
        done["type"] = "response.output_item.added"
        return [created, compact_json(done), compact_json(terminal)]
    if mode == "extension":
        done = {"type": "response.output_item.done", "output_index": 0,
                "item": {"id": "future_1", "type": "future_native",
                         "payload": "synthetic-opaque"}}
        return [created, compact_json(done), compact_json(terminal)]
    if mode == "model-mismatch":
        terminal["response"]["model"] = "different"
    if mode == "id-mismatch":
        terminal["response"]["id"] = "different"
    if mode in ("failed", "incomplete", "cancelled"):
        terminal["type"] = "response." + mode
        terminal["response"]["status"] = mode
    if mode == "error":
        return [created, '{"type":"error","error":{"message":"SYNTHETIC failure"}}']
    if mode == "encrypted-custom":
        items = [
            {"id": "rs_1", "type": "reasoning", "summary": [],
             "encrypted_content": "synthetic-opaque-reasoning"},
            {"id": "ct_1", "type": "custom_tool_call", "call_id": "call_1",
             "name": "shell.exec", "input": "synthetic command"},
        ]
        return [METADATA, *(compact_json({"type": "response.output_item.done",
                "output_index": index, "item": item}) for index, item in enumerate(items)),
                compact_json(terminal)]
    result = [created, DONE, compact_json(terminal)]
    if mode == "trailing":
        result.append("{bad}")
    return result


class CodexLiteUpstream(HTTP["Upstream"]):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        with self.server.codex_lock:
            self.server.codex_requests.append((self.path, dict(self.headers), body))
            receipt = f"resp_f12_{len(self.server.codex_requests)}"
            mode = self.server.codex_mode
            self.server.last_receipt = receipt
        assert self.path in ("/backend-api/codex/responses",
                             "/backend-api/codex/responses/compact"), self.path
        if self.path.endswith("/compact"):
            self.reply(200, '{"id":"cmp_f12","object":"response.compaction"}')
            return
        if mode == "cancel":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self.chunk(sse([METADATA]).encode())
            ready, _, _ = select.select([self.connection], [], [], 10)
            if ready and self.connection.recv(1) == b"":
                self.server.cancel_seen.set()
            return
        result = sse(events(mode, receipt)).encode()
        if mode == "eof-gated":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self.chunk(result)
            self.server.eof_ready.set()
            assert self.server.eof_release.wait(10), "EOF gate never released"
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        self.reply(200, result.decode(), "text/event-stream")

    def chunk(self, data):
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()


def connection(flow, payload, *, path="/v1/responses", hint=HINT, lite="header",
               key=CLIENT, extra=None):
    headers = {"Authorization": "Bearer " + key, "Content-Type": "application/json"}
    if hint is not None:
        headers.update({"thread-id": hint, "x-client-request-id": hint})
    if lite == "header":
        headers[LITE_HEADER] = " TRUE "
    if extra:
        headers.update(extra)
    if lite == "metadata":
        payload = dict(payload, client_metadata={MARKER: "true"})
    client = http.client.HTTPConnection("127.0.0.1", flow.port, timeout=10)
    client.request("POST", path, compact_json(payload), headers)
    return client, client.getresponse()


def call(flow, payload, *, allow_incomplete=False, **kwargs):
    client, reply = connection(flow, payload, **kwargs)
    try:
        incomplete = False
        try:
            raw = reply.read()
        except http.client.IncompleteRead as failure:
            assert allow_incomplete
            raw, incomplete = failure.partial, True
        for secret in HTTP["SECRETS"]:
            assert secret.encode() not in raw
        return reply.status, raw.decode(), incomplete
    finally:
        client.close()


def discover(flow, path):
    client = http.client.HTTPConnection("127.0.0.1", flow.port, timeout=10)
    try:
        client.request("GET", path, headers={"Authorization": "Bearer " + CLIENT})
        reply = client.getresponse()
        raw = reply.read()
        assert reply.status == 200, (path, reply.status)
        return json.loads(raw)
    finally:
        client.close()


def terminal(data):
    data_events = [json.loads(line[6:]) for line in data.splitlines()
                   if line.startswith("data: ")]
    return next(item["response"] for item in data_events
                if item["type"] == "response.completed")


def no_upstream(flow, payload, **kwargs):
    before = len(flow.upstream.codex_requests)
    status, _, _ = call(flow, payload, **kwargs)
    assert status != 200, "unsupported continuation/request was accepted"
    assert len(flow.upstream.codex_requests) == before, "rejected request reached upstream"


def read_event(reply):
    raw = bytearray()
    while len(raw) < 16384:
        byte = reply.read(1)
        assert byte, "SSE disconnected before event"
        raw.extend(byte)
        if raw.endswith(b"\n\n"):
            data = [line[6:] for line in raw.decode().splitlines()
                    if line.startswith("data: ")]
            return json.loads("\n".join(data))
    raise AssertionError("synthetic SSE event exceeded bound")


def grant(flow, account, access, refresh, provider_id):
    path = HTTP["private"](flow.directory / ("grant-" + account), compact_json({
        "access_token": access, "refresh_token": refresh,
        "expires_at_ms": 9000000000000, "chatgpt_account_id": provider_id}))
    flow.cli("credential", "import", str(flow.config), account, path)
    return path


def exercise(flow):
    assert tuple(hashlib.sha256(data.encode()).hexdigest()
                 for data in (METADATA, DONE, COMPLETED)) == SOURCE_SHA256
    peer = flow.upstream
    peer.RequestHandlerClass = CodexLiteUpstream
    peer.codex_requests, peer.codex_mode = [], "native"
    peer.codex_lock = threading.Lock()
    peer.eof_ready, peer.eof_release = threading.Event(), threading.Event()
    usual = ["low", "medium", "high", "xhigh"]
    models = [{"slug": slug, "context_window": 272000,
               "supported_reasoning_levels": [{"effort": effort} for effort in efforts],
               "default_reasoning_level": default, "input_modalities": ["text", "image"],
               "prefer_websockets": True, "use_responses_lite": lite,
               "supports_parallel_tool_calls": True}
              for slug, lite, default, efforts in [
                  (MODEL, True, "low", usual + ["max", "ultra"]),
                  ("gpt-5.5", False, "medium", usual),
                  ("not-configured", True, "medium", ["medium"])]]
    account = {"provider": "codex", "auth_mode": "oauth", "id": "selected",
               "origin": flow.origin, "models": [MODEL, "gpt-5.5"]}
    settings = {"version": 1, "state_dir": str(flow.state), "listen_port": flow.port,
                "accounts": [dict(account, id="absent", origin="http://127.0.0.1:1"),
                             account, dict(account, id="backup"),
                             {"provider": "kimi", "auth_mode": "api_key", "id": "kimi-negative",
                              "origin": flow.origin, "models": ["kimi-k2.7-code"]}],
                "codex_catalog": {"models": models}}
    flow.config.write_text(compact_json(settings))
    selected_grant = grant(flow, "selected", "synthetic-old-access",
                           "synthetic-old-refresh", "synthetic-codex-selected")
    kimi = HTTP["private"](flow.directory / "kimi-negative-grant",
                           '{"api_key":"synthetic-kimi-key"}')
    flow.cli("credential", "import", str(flow.config), "kimi-negative", kimi)
    other = HTTP["private"](flow.directory / "other-client", SECOND)
    flow.cli("key", "import", str(flow.config), "other", other)
    first = {"model": MODEL, "input": "synthetic first"}
    follow = dict(first, input="synthetic next", previous_response_id="resp_1")

    # Default-off HTTP continuation, even if a source-qualified receipt is possible.
    with flow.running():
        for path in ("/models", "/backend-api/codex/models"):
            catalog = discover(flow, path)["models"]
            assert {item["slug"] for item in catalog} == {MODEL, "gpt-5.5"}
            assert all(item["prefer_websockets"] is False for item in catalog)
            assert next(item for item in catalog if item["slug"] == MODEL)["use_responses_lite"]
        assert {item["id"] for item in discover(flow, "/v1/models")["data"]} == {
            MODEL, "gpt-5.5", "kimi-k2.7-code"}
        for path in ("/responses", "/backend-api/codex/responses",
                     "/responses/compact", "/backend-api/codex/responses/compact"):
            no_upstream(flow, dict(first, model="kimi-k2.7-code"), path=path, lite=None)
        source_request = {"model": MODEL, "input": [], "parallel_tool_calls": False}
        for path, selector in [("/v1/responses", "header"), ("/responses", "metadata"),
                               ("/backend-api/codex/responses", "header")]:
            for streaming in (False, True):
                status, data, incomplete = call(flow, dict(source_request, stream=streaming),
                                                path=path, lite=selector)
                assert status == 200 and not incomplete
                sent = peer.codex_requests[-1]
                assert sent[2]["input"] == [] and sent[2]["parallel_tool_calls"] is False
                assert "instructions" not in sent[2] and sent[2]["stream"] is True
                assert "reasoning.encrypted_content" in sent[2]["include"]
                assert sent[1][LITE_HEADER] == "true"
                document = terminal(data) if streaming else json.loads(data)
                assert document["output"] == [json.loads(DONE)["item"]]
                assert document["usage"] == json.loads(COMPLETED)["response"]["usage"]
                assert document["future"] == {"ok": True} and "object" not in document
                if streaming:
                    assert METADATA in data and DONE in data
                    assert "response.created" not in data
        status, data, _ = call(flow, dict(first, client_metadata={MARKER: True}), lite=None)
        assert status == 200 and json.loads(data)["output"] == [json.loads(DONE)["item"]]
        declarations = [{"type": "additional_tools", "role": "developer",
                         "tools": [{"type": "namespace", "name": "shell",
                                    "tools": [{"type": "custom", "name": "exec"}]}]},
                        {"role": "user", "content": [{"type": "input_image",
                         "image_url": "https://example.invalid/synthetic.png"}]}]
        assert call(flow, dict(first, input=declarations, parallel_tool_calls=True))[0] == 200
        sent = peer.codex_requests[-1][2]
        assert sent["input"] == declarations and sent["parallel_tool_calls"] is False
        assert "tools" not in sent and "instructions" not in sent
        peer.codex_mode = "eligible"
        status, data, _ = call(flow, first)
        assert status == 200
        no_upstream(flow, dict(follow, previous_response_id=json.loads(data)["id"]))
        no_upstream(flow, dict(first, model="gpt-5.5"))
        no_upstream(flow, first, extra={LITE_HEADER: "yes"})
        no_upstream(flow, dict(first, client_metadata={MARKER: 1}), lite=None)
        no_upstream(flow, first, path="/responses/lite")
        no_upstream(flow, first, path="/responses/compact")
        peer.codex_mode = "strict"
        assert call(flow, first, lite=None)[0] == 200
        assert call(flow, first, path="/backend-api/codex/responses/compact", lite=None)[0] == 200

    settings["codex_http_continuation"] = True
    flow.config.write_text(compact_json(settings))
    with flow.running():
        for mode in ("native", "empty", "idless", "open", "extension",
                     "failed", "incomplete", "cancelled", "encrypted-custom"):
            peer.codex_mode = mode
            status, data, _ = call(flow, first, hint="no-receipt-" + mode)
            assert status == 200, (mode, status, data)
            document = json.loads(data)
            if mode == "encrypted-custom":
                assert document["output"][0]["encrypted_content"] == "synthetic-opaque-reasoning"
                assert document["output"][1]["input"] == "synthetic command"
            no_upstream(flow, dict(follow, previous_response_id=document["id"]),
                        hint="no-receipt-" + mode)
        for mode in ("trailing", "model-mismatch", "id-mismatch", "error"):
            peer.codex_mode = mode
            status, _, _ = call(flow, first)
            assert status == 502, (mode, status)
            no_upstream(flow, dict(follow, previous_response_id=peer.last_receipt))
            status, data, incomplete = call(flow, dict(first, stream=True), allow_incomplete=True)
            if mode == "error":
                assert status == 200 and '"type":"error"' in data and not incomplete
            else:
                assert status == 200 and incomplete
                assert "response.output_item.done" in data
                assert ("response.completed" in data) == (mode == "trailing")
            no_upstream(flow, dict(follow, previous_response_id=peer.last_receipt))

        # A terminal event is visible, but continuation is unavailable until actual EOF.
        peer.codex_mode = "eof-gated"
        client, reply = connection(flow, dict(first, stream=True))
        try:
            assert reply.status == 200 and peer.eof_ready.wait(5)
            observed = [read_event(reply) for _ in range(3)]
            assert observed[-1]["type"] == "response.completed"
            receipt = observed[-1]["response"]["id"]
            no_upstream(flow, dict(follow, previous_response_id=receipt))
            peer.eof_release.set()
            assert reply.read() == b""
        finally:
            peer.eof_release.set()
            client.close()
        peer.codex_mode = "eligible"
        next_request = dict(follow, previous_response_id=receipt)
        for kwargs in ({"key": SECOND}, {"hint": "other-thread"}, {"hint": None},
                       {"path": "/v1/responses/compact", "lite": None}, {"lite": None}):
            no_upstream(flow, next_request, **kwargs)
        status, data, _ = call(flow, next_request, lite="metadata")
        assert status == 200
        sent = peer.codex_requests[-1]
        assert "previous_response_id" not in sent[2] and len(sent[2]["input"]) == 3
        assert sent[2]["input"][1] == json.loads(DONE)["item"]
        assert sent[1]["Chatgpt-Account-Id"] == "synthetic-codex-selected"
        assert sent[1]["Authorization"] == "Bearer synthetic-old-access"
        flow.cli("credential", "import", str(flow.config), "selected", selected_grant)
        no_upstream(flow, next_request)
        # New eligible selected-account receipt cannot cross to the available backup.
        status, data, _ = call(flow, first)
        assert status == 200
        restart_request = dict(follow, previous_response_id=json.loads(data)["id"])
        grant(flow, "backup", "synthetic-f12-backup-access",
              "synthetic-f12-backup-refresh", "synthetic-codex-backup")
        flow.cli("credential", "delete", str(flow.config), "selected")
        no_upstream(flow, restart_request)
        assert call(flow, first)[0] == 200
        assert peer.codex_requests[-1][1]["Chatgpt-Account-Id"] == "synthetic-codex-backup"
        grant(flow, "selected", "synthetic-old-access", "synthetic-old-refresh",
              "synthetic-codex-selected")
        # Real downstream close cancels the upstream owned socket, never a receipt.
        peer.codex_mode = "cancel"
        client, reply = connection(flow, dict(first, stream=True))
        assert read_event(reply)["type"] == "codex.response.metadata"
        reply.close()
        client.close()
        assert peer.cancel_seen.wait(5), "downstream close did not cancel upstream socket"
        no_upstream(flow, dict(follow, previous_response_id=peer.last_receipt))
        peer.codex_mode = "eligible"
        status, data, _ = call(flow, first)
        assert status == 200
        restart_request = dict(follow, previous_response_id=json.loads(data)["id"])

    with flow.running():
        no_upstream(flow, restart_request)
        # Headerless standalone remains cache-free even with continuation configured.
        status, data, _ = call(flow, first, hint=None)
        assert status == 200
        no_upstream(flow, dict(follow, previous_response_id=json.loads(data)["id"]))
        flow.cli("key", "revoke", str(flow.config), "client")
        before = len(peer.codex_requests)
        assert call(flow, first)[0] == 401
        assert len(peer.codex_requests) == before
    return len(peer.codex_requests)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="codex-f12-",
                                     dir=ROOT / "build/integration") as directory:
        flow = HTTP["Workflow"](Path(directory), command, args.shipment)
        try:
            requests = exercise(flow)
        finally:
            if hasattr(flow.upstream, "eof_release"):
                flow.upstream.eof_release.set()
            flow.close()
    print(compact_json({"scope": "actual_root_gateway_codex_http_lite",
                        "synthetic": True, "shipment": bool(args.shipment),
                        "upstream_requests": requests, "source_fixture_hashes": "3/3",
                        "live_provider": False, "cpa_executed": False,
                        "native_client_executed": False}))


if __name__ == "__main__":
    main()
