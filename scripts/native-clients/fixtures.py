"""Deterministic SYNTHETIC provider fixtures, not provider measurements."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
import time

MARKER = "NATIVE_LOCAL_OK"
CANARY = "SYNTHETIC_FILE_CANARY_731"
CLIENT_KEY = "synthetic-native-client-key-00000001"
UPSTREAM_KEY = "synthetic-native-upstream-key-000001"


def event(kind, data):
    return f"event: {kind}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()


def claude_frames(tool=False):
    message = {"id": "msg_synthetic", "type": "message", "role": "assistant",
               "model": "claude-sonnet-4-5", "content": [], "stop_reason": None,
               "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 0}}
    frames = [event("message_start", {"type": "message_start", "message": message})]
    block = ({"type": "tool_use", "id": "tool_synthetic", "name": "Read", "input": {}}
             if tool else {"type": "text", "text": ""})
    frames.append(event("content_block_start", {
        "type": "content_block_start", "index": 0, "content_block": block}))
    deltas = ([{"type": "input_json_delta", "partial_json":
                json.dumps({"file_path": "/work/project/canary.txt"})}] if tool else
              [{"type": "text_delta", "text": char} for char in MARKER])
    for delta in deltas:
        frames.append(event("content_block_delta", {
            "type": "content_block_delta", "index": 0, "delta": delta}))
    frames.extend([
        event("content_block_stop", {"type": "content_block_stop", "index": 0}),
        event("message_delta", {"type": "message_delta", "delta": {
            "stop_reason": "tool_use" if tool else "end_turn", "stop_sequence": None},
            "usage": {"output_tokens": 10}}),
        event("message_stop", {"type": "message_stop"}),
    ])
    return frames


def codex_frames(tool=False, tool_name="exec_command"):
    item = ({"type": "function_call", "id": "fc_synthetic", "call_id": "call_synthetic",
             "name": tool_name, "arguments": json.dumps({
                 "cmd": "cat /work/project/canary.txt", "max_output_tokens": 100})}
            if tool else {"type": "message", "id": "msg_synthetic", "role": "assistant",
                          "status": "completed", "content": [
                              {"type": "output_text", "text": MARKER, "annotations": []}]})
    response = {"id": "resp_synthetic", "object": "response", "created_at": 1,
                "model": "gpt-5.5", "status": "completed", "output": [item],
                "usage": {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}}
    frames = []

    def add(kind, **data):
        frames.append(event(kind, {"type": kind, "sequence_number": len(frames), **data}))

    add("response.created", response=dict(response, status="in_progress", output=[]))
    add("response.output_item.added", output_index=0, item=dict(item, status="in_progress"))
    if not tool:
        add("response.content_part.added", item_id=item["id"], output_index=0,
            content_index=0, part={"type": "output_text", "text": "", "annotations": []})
        for char in MARKER:
            add("response.output_text.delta", item_id=item["id"], output_index=0,
                content_index=0, delta=char)
        add("response.output_text.done", item_id=item["id"], output_index=0,
            content_index=0, text=MARKER)
        add("response.content_part.done", item_id=item["id"], output_index=0,
            content_index=0, part=item["content"][0])
    else:
        add("response.function_call_arguments.done", item_id=item["id"], output_index=0,
            arguments=item["arguments"])
    add("response.output_item.done", output_index=0, item=item)
    add("response.completed", response=response)
    return frames


class Fixture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, client, workflow):
        super().__init__(("127.0.0.1", 0), Handler)
        self.client, self.workflow = client, workflow
        self.observations = []
        self.token_count = 0
        self.started = threading.Event()
        self.disconnected = threading.Event()
        self.worker = threading.Thread(target=self.serve_forever, daemon=True)

    def __enter__(self):
        self.worker.start()
        return self

    def __exit__(self, *_):
        self.shutdown()
        self.server_close()
        self.worker.join(5)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 2 * 1024 * 1024 or len(self.server.observations) >= 12:
            self.send_error(429)
            return
        raw = self.rfile.read(size)
        if self.path == "/token":
            self.server.token_count += 1
            self.reply(json.dumps({"access_token": UPSTREAM_KEY,
                                   "refresh_token": "synthetic-refresh",
                                   "expires_in": 3600}).encode())
            return
        body = json.loads(raw)
        if self.path.split("?")[0].endswith("/count_tokens"):
            self.reply(b'{"input_tokens":10}')
            return
        is_claude = self.server.client == "claude"
        expected = "/v1/messages" if is_claude else "/backend-api/codex/responses"
        if self.path.split("?")[0] != expected:
            self.send_error(404)
            return
        items = body.get("messages" if is_claude else "input", [])
        tool_results = ([part for item in items for part in item.get("content", [])
                         if isinstance(part, dict) and part.get("type") == "tool_result"]
                        if is_claude else
                        [item for item in items if item.get("type") == "function_call_output"])
        tool_ok = any(CANARY in json.dumps(item) for item in tool_results)
        self.server.observations.append({
            "path": self.path.split("?")[0], "stream": body.get("stream") is True,
            "model_ok": body.get("model") == ("claude-sonnet-4-5" if is_claude else "gpt-5.5"),
            "upstream_auth_ok": (self.headers.get("x-api-key") == UPSTREAM_KEY if is_claude
                                 else self.headers.get("Authorization") == f"Bearer {UPSTREAM_KEY}"),
            "client_credential_not_forwarded": CLIENT_KEY not in str(self.headers),
            "tool_result_canary": tool_ok,
            "history_items": len(items),
        })
        wants_tool = self.server.workflow == "tool" and not tool_results
        frames = claude_frames(wants_tool) if is_claude else codex_frames(wants_tool)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.server.started.set()
        try:
            for frame in frames:
                # Deliberately split bytes independently of SSE frame boundaries.
                for offset in range(0, len(frame), 17):
                    chunk = frame[offset:offset + 17]
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.05)
                if self.server.workflow == "cancel" and (
                        b"content_block_delta" in frame or b"response.output_text.delta" in frame):
                    # Remain in-progress; terminal event must never precede cancellation.
                    for _ in range(200):
                        ping = b": synthetic keepalive\n\n"
                        self.wfile.write(f"{len(ping):x}\r\n".encode() + ping + b"\r\n")
                        self.wfile.flush()
                        time.sleep(0.1)
                    return
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            self.server.disconnected.set()
