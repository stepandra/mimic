"""OS/socket fixture driver for the assembled MIMIC baseline (not CPA).

Domain/gate orchestration is in Gleam. This boundary only launches the real
test target, serves synthetic HTTP, and records observations/checks. It never
fills in absent provider behavior. Standard library only, no live endpoints.
"""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import threading


def encode(value):
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def observe(port, fixture, authenticated=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=4)
    body = "" if fixture["request"] is None else encode(fixture["request"])
    try:
        connection.putrequest(fixture["method"], fixture["path"],
                              skip_accept_encoding=True)
        connection.putheader("Content-Type", "application/json")
        connection.putheader("Content-Length", str(len(body.encode())))
        if authenticated:
            connection.putheader("Authorization", "Bearer synthetic-client-key")
        connection.endheaders(body.encode())
        response = connection.getresponse()
        data = response.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("response exceeds bound")
        return {"status": response.status, "headers": response.getheaders(),
                "body": data.decode("utf-8")}
    finally:
        connection.close()


def launch_target(plan, origin):
    paths = sorted(str(p.resolve()) for p in Path("build/dev/erlang").glob("*/ebin"))
    if not paths:
        raise RuntimeError("run gleam test first")
    command = ["erl", "+S", "2:2", "-noshell", "-pa", *paths,
               "-eval", "'mimic@@main':run('parity@target').", "-extra",
               plan["phase"], plan["state_dir"], origin]
    child = subprocess.Popen(command, stdout=subprocess.PIPE,
                             stderr=sys.stderr, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(12):
                raise TimeoutError("target readiness deadline")
            line = child.stdout.readline(16384)
        ready = json.loads(line)
        if not (1 <= ready["port"] <= 65535):
            raise ValueError("invalid target port")
        return child, ready
    except BaseException:
        stop(child)
        raise


def stop(child):
    # The session can outlive its leader. Always signal the group, including
    # after an early leader exit, and kill residual descendants after grace.
    # This is same-PGID cleanup only: setsid/setpgid can escape it. Candidate
    # execution is blocked separately until OS descendant containment exists.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if child.stdout is not None:
            child.stdout.close()


def exercise(plan, fixture, launcher=launch_target):
    upstream = []

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def handle_fixture(self):
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 <= size <= 1024 * 1024:
                self.send_error(413)
                return
            body = self.rfile.read(size).decode("utf-8")
            upstream.append({"method": self.command, "path": self.path,
                             "headers": list(self.headers.raw_items()), "body": body})
            payload = encode(fixture["upstream_response"]).encode()
            # Fixed synthetic headers, deliberately retaining repeated/cased fields.
            self.send_response_only(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Synthetic", "first")
            self.send_header("X-Synthetic", "second")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_POST = handle_fixture
        do_GET = handle_fixture

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    child = None
    try:
        child, ready = launcher(plan, "http://127.0.0.1:" + str(server.server_port))
        unauthorized = observe(ready["port"], fixture, False)
        unauth_upstream = len(upstream)
        response = observe(ready["port"], fixture)
        checks = {name: False for name in fixture["required_checks"]}
        # Universal gate check: direct adapter calls cannot substitute for this.
        checks["assembled_ingress"] = True
        checks["authenticated_http"] = (
            unauthorized["status"] == 401 and unauth_upstream == 0
            and response["status"] == fixture["expected_status"])
        if upstream:
            headers = upstream[0]["headers"]
            checks["upstream_auth_isolation"] = (
                len(upstream) == 1
                and [v for k, v in headers if k.lower() == "x-api-key"]
                == ["synthetic-upstream-a"]
                and not any("synthetic-client-key" in v for _, v in headers)
                and not any(k.lower() == "authorization" for k, _ in headers))
            upstream_body = json.loads(upstream[0]["body"])
            if fixture["id"] in ("messages-v1", "chat-v1"):
                checks["upstream_body"] = (
                    upstream[0]["method"] == "POST"
                    and upstream[0]["path"] == "/v1/messages"
                    and upstream_body.get("model") == "synthetic-model"
                    and upstream_body.get("max_tokens") == 32
                    and upstream_body.get("messages") == fixture["request"]["messages"])
        if response["status"] == 200:
            payload = json.loads(response["body"])
            if fixture["id"] in ("messages-v1", "restart-v1"):
                checks["response_semantics"] = payload == fixture["upstream_response"]
            elif fixture["id"] == "chat-v1":
                checks["response_semantics"] = (
                    payload["choices"][0]["message"]["content"]
                    in ("pong", [{"type": "text", "text": "pong"}])
                    and payload["choices"][0]["finish_reason"] == "stop"
                    and payload["usage"]["prompt_tokens"] == 1
                    and payload["usage"]["completion_tokens"] == 1)
        if fixture["restart"]:
            for name in ("persisted_credentials", "credential_values_isolated",
                         "fresh_process_no_reseed"):
                checks[name] = ready[name] is True
        observation = {"unauthorized": unauthorized, "response": response,
                       "upstream": upstream}
        # No sorting or normalization. Raw header lists and body text survive.
        return observation, checks, {"target_pid": ready["pid"]}
    finally:
        if child is not None:
            stop(child)
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def main(plan):
    fixture = json.loads(plan["fixture_json"])
    if hashlib.sha256(plan["fixture_json"].encode()).hexdigest() != plan["fixture_sha256"]:
        raise ValueError("fixture digest mismatch")
    state = Path(plan["state_dir"])
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    checks, observations, diagnostics = {}, {}, {}
    status = "unsupported"
    if plan["target"] == "mimic" and fixture["driver_kind"] == "http":
        observations, checks, diagnostics = exercise(plan, fixture)
        status = "passed" if all(checks.get(n) is True
                                 for n in fixture["required_checks"]) else "failed"
    result = {
        "schema_version": 1, "capability_id": plan["capability_id"],
        "fixture_id": fixture["id"],
        "fixture_sha256": plan["fixture_sha256"], "target": plan["target"],
        "target_revision": plan["target_revision"], "phase": plan["phase"],
        "status": status, "observations": encode(observations),
        "checks": [{"name": n, "passed": v} for n, v in checks.items()],
        "diagnostics": diagnostics,
    }
    print(encode(result))


if __name__ == "__main__":
    with open(sys.argv[-1], encoding="utf-8") as source:
        main(json.load(source))
