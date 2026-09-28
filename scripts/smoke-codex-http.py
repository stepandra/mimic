#!/usr/bin/env python3
"""Synthetic fresh-process root CLI Codex HTTP continuation smoke; no live provider."""

import argparse
import http.client
import json
import os
from pathlib import Path
import runpy
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
CLIENT = HTTP["CLIENT"]
SECOND = "synthetic-second-client-key"
MODEL = "gpt-5.5"
HINT = "synthetic-stable-thread"


def frame(name, response, sequence):
    return (f"event: {name}\ndata: "
            + json.dumps({"type": name, "sequence_number": sequence,
                          "response": response}, separators=(",", ":")) + "\n\n")


def response_sse(receipt, first):
    base = {"id": receipt, "object": "response", "model": MODEL, "output": []}
    created = frame("response.created", dict(base, status="in_progress"), 0)
    if first:
        reasoning = {"type": "reasoning", "id": "rs_synthetic",
                     "encrypted_content": "synthetic-opaque", "summary": []}
        added = {"type": "reasoning", "id": "rs_synthetic", "summary": []}
        item_events = "".join(
            f"event: response.output_item.{action}\ndata: "
            + json.dumps({"type": f"response.output_item.{action}",
                          "sequence_number": sequence, "output_index": 0,
                          "item": item}, separators=(",", ":")) + "\n\n"
            for action, sequence, item in [("added", 1, added), ("done", 2, reasoning)])
        return created + item_events + frame(
            "response.completed", dict(base, status="completed", output=[reasoning]), 3)
    return created + frame("response.completed", dict(base, status="completed"), 1)


class CodexUpstream(HTTP["Upstream"]):
    def do_POST(self):
        assert self.path == "/backend-api/codex/responses", self.path
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        with self.server.codex_lock:
            self.server.codex_requests.append((self.path, dict(self.headers), body))
            count = len(self.server.codex_requests)
        self.reply(200, response_sse(f"resp_synthetic_{count}", count == 1),
                   "text/event-stream")


def call(flow, payload, *, key=CLIENT, hint=HINT, path="/v1/responses"):
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    if hint is not None:
        headers.update({"thread-id": hint, "x-client-request-id": hint})
    connection = http.client.HTTPConnection("127.0.0.1", flow.port, timeout=10)
    try:
        connection.request("POST", path, json.dumps(payload), headers)
        reply = connection.getresponse()
        body = reply.read()
        for secret in [CLIENT, SECOND, "synthetic-old-access", "synthetic-old-refresh"]:
            assert secret.encode() not in body
        return reply.status, body.decode()
    finally:
        connection.close()


def exercise(flow):
    flow.upstream.RequestHandlerClass = CodexUpstream
    flow.upstream.codex_requests = []
    flow.upstream.codex_lock = threading.Lock()
    account = {
        "provider": "codex", "auth_mode": "oauth", "id": "selected",
        "origin": flow.origin, "models": [MODEL],
    }
    settings = {
        "version": 1, "state_dir": str(flow.state), "listen_port": flow.port,
        "accounts": [dict(account, id="absent", origin="http://127.0.0.1:1"), account],
        "codex_catalog": {"models": [{
            "slug": MODEL, "context_window": 272000,
            "supported_reasoning_levels": [{"effort": "medium"}],
            "default_reasoning_level": "medium", "input_modalities": ["text"],
            "prefer_websockets": False, "use_responses_lite": False,
        }]},
    }
    flow.config.write_text(json.dumps(settings))
    grant = HTTP["private"](flow.directory / "codex-grant", json.dumps({
        "access_token": "synthetic-old-access",
        "refresh_token": "synthetic-old-refresh", "expires_at_ms": 9000000000000,
        "chatgpt_account_id": "synthetic-codex-account",
    }))
    flow.cli("credential", "import", str(flow.config), "selected", grant)
    other = HTTP["private"](flow.directory / "second-client", SECOND)
    flow.cli("key", "import", str(flow.config), "other", other)
    first = {"model": MODEL, "input": "synthetic first"}
    prior = {"model": MODEL, "input": "synthetic next",
             "previous_response_id": "resp_synthetic_1"}

    # Default false is cache-free even with a stable hint.
    with flow.running():
        status, body = call(flow, first)
        assert status == 200 and json.loads(body)["id"] == "resp_synthetic_1"
        before = len(flow.upstream.codex_requests)
        status, _ = call(flow, prior)
        assert status != 200 and len(flow.upstream.codex_requests) == before

    settings["codex_http_continuation"] = True
    flow.config.write_text(json.dumps(settings))
    with flow.running():
        status, body = call(flow, first)
        assert status == 200
        receipt = json.loads(body)["id"]
        assert receipt == "resp_synthetic_2"
        next_request = dict(prior, previous_response_id=receipt)
        before = len(flow.upstream.codex_requests)
        for kwargs in [{"key": SECOND}, {"hint": "other-thread"}, {"hint": None}]:
            status, _ = call(flow, next_request, **kwargs)
            assert status != 200 and len(flow.upstream.codex_requests) == before
        status, _ = call(flow, next_request, path="/v1/responses/compact")
        assert status != 200 and len(flow.upstream.codex_requests) == before
        status, body = call(flow, next_request)
        assert status == 200 and json.loads(body)["id"] == "resp_synthetic_3"
        sent = flow.upstream.codex_requests[-1][2]
        assert "previous_response_id" not in sent
        history = sent["input"]
        assert len(history) == 3, history
        assert "synthetic first" in json.dumps(history[0])
        assert history[1]["encrypted_content"] == "synthetic-opaque"
        assert "synthetic next" in json.dumps(history[2])
        before = len(flow.upstream.codex_requests)
        # Same-value import still issues a new authoritative credential revision.
        flow.cli("credential", "import", str(flow.config), "selected", grant)
        status, _ = call(flow, next_request)
        assert status != 200 and len(flow.upstream.codex_requests) == before

    with flow.running():
        before = len(flow.upstream.codex_requests)
        status, _ = call(flow, next_request)
        assert status != 200 and len(flow.upstream.codex_requests) == before
        # Headerless standalone remains the existing cache-free path.
        status, body = call(flow, first, hint=None)
        assert status == 200 and json.loads(body)["id"] == "resp_synthetic_4"
        before = len(flow.upstream.codex_requests)
        status, _ = call(flow, dict(prior, previous_response_id="resp_synthetic_4"))
        assert status != 200 and len(flow.upstream.codex_requests) == before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="codex-http-cli-",
                                     dir=ROOT / "build/integration") as temp:
        flow = HTTP["Workflow"](Path(temp), command, args.shipment)
        try:
            exercise(flow)
        finally:
            flow.close()
    print(json.dumps({"scope": "actual_root_gateway_codex_http_cli",
                      "synthetic": True, "shipment": bool(args.shipment),
                      "live_provider": False}))


if __name__ == "__main__":
    main()
