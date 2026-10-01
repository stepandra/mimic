#!/usr/bin/env python3
"""Cancel-only actual root/shipment F12 lane. Synthetic loopback, no live calls."""

import argparse
import json
import os
from pathlib import Path
import runpy
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LITE = runpy.run_path(str(ROOT / "scripts/smoke-codex-http-lite.py"))
HTTP = LITE["HTTP"]


def exercise(flow):
    peer = flow.upstream
    peer.RequestHandlerClass = LITE["CodexLiteUpstream"]
    peer.codex_requests, peer.codex_mode = [], "cancel"
    peer.codex_lock = threading.Lock()
    peer.cancel_seen.clear()
    model = LITE["MODEL"]
    flow.config.write_text(json.dumps({
        "version": 1,
        "state_dir": str(flow.state),
        "listen_port": flow.port,
        "accounts": [{
            "provider": "codex", "auth_mode": "oauth", "id": "selected",
            "origin": flow.origin, "models": [model],
        }],
        "codex_catalog": {"models": [{
            "slug": model,
            "context_window": 272000,
            "supported_reasoning_levels": [{"effort": "low"}],
            "default_reasoning_level": "low",
            "input_modalities": ["text", "image"],
            "prefer_websockets": True,
            "use_responses_lite": True,
            "supports_parallel_tool_calls": True,
        }]},
    }))
    LITE["grant"](flow, "selected", "synthetic-old-access",
                  "synthetic-old-refresh", "synthetic-codex-selected")
    with flow.running():
        client, reply = LITE["connection"](flow, {
            "model": model, "input": "synthetic cancellation probe", "stream": True,
        })
        try:
            assert reply.status == 200
            assert LITE["read_event"](reply)["type"] == "codex.response.metadata"
        finally:
            started = time.monotonic()
            reply.close()
            client.close()
        # Exactly the existing root assertion; not a timeout-cleanup substitute.
        assert peer.cancel_seen.wait(5), "downstream close did not cancel upstream socket"
        elapsed_ms = round((time.monotonic() - started) * 1000)
        assert len(peer.codex_requests) == 1, "cancel probe performed extra upstream I/O"
    return elapsed_ms


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="codex-cancel-",
                                     dir=ROOT / "build/integration") as directory:
        flow = HTTP["Workflow"](Path(directory), command, args.shipment)
        try:
            elapsed_ms = exercise(flow)
        finally:
            flow.close()
    print(json.dumps({
        "scope": "actual_root_codex_http_cancel_only",
        "synthetic": True,
        "shipment": bool(args.shipment),
        "upstream_peer_eof": True,
        "cancel_elapsed_ms": elapsed_ms,
        "lease_zero": "not exposed by this CLI lane; dedicated runtime test required",
        "live_provider": False,
        "cpa_executed": False,
        "native_client_executed": False,
    }, separators=(",", ":")))


if __name__ == "__main__":
    main()
