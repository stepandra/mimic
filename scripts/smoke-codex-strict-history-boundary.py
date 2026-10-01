#!/usr/bin/env python3
"""Synthetic root regression: strict SSE delivery is not a receipt-size gate."""

import argparse
import json
import os
from pathlib import Path
import runpy
import tempfile

ROOT = Path(__file__).resolve().parents[1]
F12 = runpy.run_path(str(ROOT / "scripts/smoke-codex-http-lite.py"))
HTTP = F12["HTTP"]
MODEL = "gpt-5.5"
TEXT = "s" * 200_000


class Upstream(HTTP["Upstream"]):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/backend-api/codex/responses"
        assert request["model"] == MODEL
        assert not self.headers.get(F12["LITE_HEADER"])
        self.server.strict_requests += 1
        response = {
            "id": "resp_strict_history", "object": "response",
            "model": MODEL, "status": "in_progress", "output": [],
        }
        item = {"id": "msg_strict_history", "type": "message", "role": "assistant",
                "content": [{"type": "output_text", "text": TEXT}]}
        events = [
            {"type": "response.created", "response": response},
            {"type": "response.output_item.added", "output_index": 0, "item": item},
            {"type": "response.output_item.done", "output_index": 0, "item": item},
            {"type": "response.completed", "response": dict(
                response, status="completed", output=[item],
                usage={"input_tokens": 1, "output_tokens": 1, "total_tokens": 2})},
        ]
        frames = [F12["compact_json"](event) for event in events]
        assert all(len(frame.encode()) < 1_048_576 for frame in frames)
        self.reply(200, F12["sse"](frames), "text/event-stream")


def exercise(flow, cached):
    flow.upstream.RequestHandlerClass = Upstream
    flow.upstream.strict_requests = 0
    settings = {
        "version": 1, "state_dir": str(flow.state), "listen_port": flow.port,
        "codex_http_continuation": cached,
        "accounts": [{"provider": "codex", "auth_mode": "oauth", "id": "selected",
                      "origin": flow.origin, "models": [MODEL]}],
        "codex_catalog": {"models": [{
            "slug": MODEL, "context_window": 272000,
            "supported_reasoning_levels": [{"effort": "medium"}],
            "default_reasoning_level": "medium", "input_modalities": ["text"],
            "prefer_websockets": False, "use_responses_lite": False,
            "supports_parallel_tool_calls": True,
        }]},
    }
    flow.config.write_text(F12["compact_json"](settings))
    F12["grant"](flow, "selected", "synthetic-old-access",
                 "synthetic-old-refresh", "synthetic-strict-account")
    with flow.running():
        # Small-history control establishes this is valid strict SSE first.
        for size in (10, 900_000):
            status, data, incomplete = F12["call"](
                flow, {"model": MODEL, "input": "u" * size, "stream": True},
                lite=None, hint=f"strict-history-{size}" if cached else None,
                allow_incomplete=True,
            )
            assert status == 200, (cached, size, status)
            names = [json.loads(line[6:])["type"] for line in data.splitlines()
                     if line.startswith("data: ")]
            print(json.dumps({"cached": cached, "input_chars": size,
                              "status": status, "incomplete": incomplete,
                              "events": names}), flush=True)
            assert "response.completed" in names, (cached, size, names)
            response = F12["terminal"](data)
            assert response["output"][0]["content"][0]["text"] == TEXT
            # Cached legacy emits the valid terminal before denying the oversized
            # receipt. Stateless delivery has no receipt and must complete cleanly.
            assert incomplete == (cached and size == 900_000), (
                cached, size, incomplete)
        if cached:
            before = flow.upstream.strict_requests
            status, _, _ = F12["call"](
                flow, {"model": MODEL, "input": "next",
                       "previous_response_id": "resp_strict_history"},
                lite=None, hint="strict-history-900000",
            )
            assert status == 422, status
            assert flow.upstream.strict_requests == before
    assert flow.upstream.strict_requests == 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM") or "gleam", "run", "--"])
    base = ROOT / "build/integration"
    base.mkdir(parents=True, exist_ok=True)
    for cached in (False, True):
        with tempfile.TemporaryDirectory(prefix="strict-history-", dir=base) as path:
            flow = HTTP["Workflow"](Path(path), command, args.shipment)
            try:
                exercise(flow, cached)
            finally:
                flow.close()
    print(json.dumps({"synthetic": True, "stateless_and_cached": "passed",
                      "upstream_requests": 4, "live": False}))


if __name__ == "__main__":
    main()
