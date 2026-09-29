"""Container-only native workflows. Never invoke this directly on the host."""

import argparse
import contextlib
import hashlib
import http.client
import json
import os
from pathlib import Path
import resource
import signal
import socket
import subprocess
import tempfile
import time

from fixtures import CANARY, CLIENT_KEY, MARKER, UPSTREAM_KEY, Fixture

BASE_ENV = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/work/home",
            "TMPDIR": "/tmp", "LANG": "C.UTF-8", "TERM": "dumb",
            "LD_LIBRARY_PATH": "/usr/local/lib", "ERL_FLAGS": "+S 2:2 +A 2"}
GATEWAY = ["/bin/sh", "/shipment/entrypoint.sh", "run"]


def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_FSIZE, (8 * 1024 * 1024, 8 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
    resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))


def kill_group(process):
    # Also clean descendants after a parent exits. Docker removal is the final fence.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


@contextlib.contextmanager
def child(argv, env=BASE_ENV, cwd="/work", stdin=None):
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=stdin or subprocess.DEVNULL,
                                   stdout=output, stderr=errors,
                                   start_new_session=True, preexec_fn=limits)
        try:
            yield process, output
        finally:
            kill_group(process)


def run(argv, env=BASE_ENV, cwd="/work", timeout=45):
    with child(argv, env, cwd) as (process, output):
        process.wait(timeout=timeout)
        output.seek(0)
        return process.returncode, output.read(8 * 1024 * 1024)


def successful_output(client, output):
    """Require native success events, not echoed markers or error/log strings."""
    try:
        if client == "claude":
            value = json.loads(output)
            return (value.get("type") == "result" and value.get("subtype") == "success"
                    and value.get("is_error") is False and
                    value.get("result", "").strip() == MARKER)
        events = [json.loads(line) for line in output.splitlines() if line.strip()]
        if any(item.get("type") in ("error", "turn.failed") for item in events):
            return False
        messages = [item.get("item", {}) for item in events
                    if item.get("type") == "item.completed"]
        return (any(item.get("type") == "turn.completed" for item in events)
                and any(item.get("type") == "agent_message" and
                        item.get("text", "").strip() == MARKER for item in messages))
    except (ValueError, AttributeError, TypeError):
        return False


def native_stream_event_seen(client, output):
    """Observe a native event; no rendered text or incremental latency claim."""
    for line in output.splitlines():
        try:
            value = json.loads(line)
            if client == "claude" and value.get("type") == "stream_event":
                if value.get("event", {}).get("type") == "content_block_delta":
                    return True
            if client == "codex" and value.get("type") in ("item.started", "item.updated"):
                if value.get("item", {}).get("type") == "agent_message":
                    return True
        except (ValueError, AttributeError, TypeError):
            continue
    return False


def containment():
    # Fail closed even if someone bypasses the outer CLI.
    if not Path("/.dockerenv").exists() or os.getuid() != 10001:
        raise RuntimeError("container_required")
    interfaces = set(os.listdir("/sys/class/net"))
    if interfaces != {"lo"}:
        raise RuntimeError("network_namespace_not_isolated")
    status = Path("/proc/self/status").read_text()
    if "NoNewPrivs:\t1" not in status or "CapEff:\t0000000000000000" not in status:
        raise RuntimeError("privilege_containment_missing")
    mounts = Path("/proc/mounts").read_text().splitlines()
    root = next(line.split() for line in mounts if line.split()[1] == "/")
    if "ro" not in root[3].split(","):
        raise RuntimeError("readonly_root_required")


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def private(path, value):
    path.write_text(value)
    path.chmod(0o600)
    return str(path)


def settings(client, fixture, gateway_port, work):
    origin = f"http://127.0.0.1:{fixture.server_port}"
    account = {"provider": client, "id": "synthetic", "origin": origin,
               "auth_mode": "api_key" if client == "claude" else "oauth",
               "models": ["claude-sonnet-4-5" if client == "claude" else "gpt-5.5"]}
    credential = {"api_key": UPSTREAM_KEY}
    if client == "codex":
        account["oauth"] = {"client_id": "synthetic", "authorize_url": origin + "/authorize",
                            "token_url": origin + "/token",
                            "redirect_uri": "http://127.0.0.1:1455/auth/callback"}
        credential = {"access_token": UPSTREAM_KEY, "refresh_token": "synthetic-refresh",
                      "expires_at_ms": 9000000000000,
                      "chatgpt_account_id": "synthetic-native-account"}
    config = private(work / "providers.json", json.dumps({
        "version": 1, "state_dir": str(work / "state"),
        "listen_port": gateway_port, "accounts": [account]}))
    grant = private(work / "grant.json", json.dumps(credential))
    key = private(work / "key", CLIENT_KEY)
    for args in [("credential", "import", config, "synthetic", grant),
                 ("key", "import", config, "synthetic", key)]:
        code, _ = run([*GATEWAY, "providers", *args])
        if code:
            raise RuntimeError("gateway_provision_failed")
    return config


def client_command(client, gateway_port, workflow, resume=False):
    env = dict(BASE_ENV)
    prompt = ("Read canary.txt with your file tool then report the result."
              if workflow == "tool" else "Reply with the synthetic fixture marker.")
    if client == "claude":
        env.update(ANTHROPIC_BASE_URL=f"http://127.0.0.1:{gateway_port}",
                   ANTHROPIC_API_KEY=CLIENT_KEY, CLAUDE_CONFIG_DIR="/work/home/.claude",
                   DISABLE_TELEMETRY="1", DISABLE_ERROR_REPORTING="1",
                   DISABLE_AUTOUPDATER="1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
        argv = ["/clients/claude", "-p", prompt, "--model", "claude-sonnet-4-5",
                "--output-format", "stream-json" if workflow == "cancel" else "json",
                "--max-turns", "3",
                "--allowedTools", "Read", "--strict-mcp-config",
                "--mcp-config", '{"mcpServers":{}}']
        if workflow == "cancel":
            argv += ["--verbose", "--include-partial-messages"]
        if resume:
            argv.append("--continue")
    else:
        env.update(CODEX_HOME="/work/home/.codex", MIMIC_SYNTHETIC_KEY=CLIENT_KEY)
        argv = ["/clients/codex/bin/codex", "exec"]
        if resume:
            argv += ["resume", "--last"]
        argv += ["--skip-git-repo-check", "--json", "-m", "gpt-5.5",
                 "-c", 'model_provider="synthetic"',
                 "-c", 'model_providers.synthetic.name="MIMIC local fixture"',
                 "-c", f'model_providers.synthetic.base_url="http://127.0.0.1:{gateway_port}/v1"',
                 "-c", 'model_providers.synthetic.env_key="MIMIC_SYNTHETIC_KEY"',
                 "-c", 'model_providers.synthetic.wire_api="responses"',
                 "-c", "model_providers.synthetic.supports_websockets=false",
                 "-c", "check_for_update_on_startup=false",
                 "-c", "analytics.enabled=false", "-c", "feedback.enabled=false",
                 "-c", 'sandbox_mode="danger-full-access"', prompt]
        # The outer network-none/read-only/container fence is mandatory. Nested
        # client sandboxes vary across kernels; never use this argv on the host.
    return argv, env


def ready(process, gateway_port):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("gateway_exited")
        connection = http.client.HTTPConnection("127.0.0.1", gateway_port, timeout=1)
        try:
            connection.request("GET", "/v1/models")
            if connection.getresponse().status == 401:
                return
        except OSError:
            pass
        finally:
            connection.close()
        time.sleep(0.05)
    raise RuntimeError("gateway_readiness_timeout")


def workflow(client, name):
    work = Path("/work")
    for path in ["home/.claude", "home/.codex", "project", "state"]:
        (work / path).mkdir(parents=True, exist_ok=True)
    private(work / "project/canary.txt", CANARY)
    result = {"client": client, "workflow": name, "status": "failed",
              "client_exits": [], "output_marker": False, "observations": []}
    with Fixture(client, name) as fixture:
        try:
            gateway_port = port()
            config = settings(client, fixture, gateway_port, work)
            with child([*GATEWAY, "serve", "providers", config]) as (gateway, _):
                ready(gateway, gateway_port)
                argv, env = client_command(client, gateway_port, name)
                if name == "cancel":
                    with child(argv, env, "/work/project") as (process, output):
                        if not fixture.started.wait(20):
                            raise RuntimeError("client_never_started_stream")
                        deadline = time.monotonic() + 10
                        while not native_stream_event_seen(
                                client, os.pread(output.fileno(), 8 * 1024 * 1024, 0)):
                            if process.poll() is not None or time.monotonic() > deadline:
                                raise RuntimeError("native_stream_event_not_observed")
                            time.sleep(0.05)
                        result["native_stream_event_observed"] = True
                        os.killpg(process.pid, signal.SIGINT)
                        process.wait(timeout=5)
                        result["client_exits"].append(process.returncode)
                        result["upstream_disconnect"] = fixture.disconnected.wait(5)
                        if not result["upstream_disconnect"] or process.returncode == 0:
                            raise RuntimeError("cancellation_not_observed")
                else:
                    for turn in range(2 if name == "continuation" else 1):
                        argv, env = client_command(client, gateway_port, name, resume=turn > 0)
                        code, output = run(argv, env, "/work/project")
                        result["client_exits"].append(code)
                        result["output_marker"] = successful_output(client, output)
                        # Do not emit native logs, prompts, headers or credentials.
                        if code or not result["output_marker"]:
                            raise RuntimeError("client_exit_or_output_assertion")
                    if name == "tool" and not any(
                            item["tool_result_canary"] for item in fixture.observations):
                        raise RuntimeError("native_tool_result_not_observed")
                    if name == "continuation" and (
                            len(fixture.observations) < 2 or
                            fixture.observations[-1]["history_items"] <=
                            fixture.observations[0]["history_items"]):
                        raise RuntimeError("continuation_history_not_observed")
                if not fixture.observations or not all(
                        item["upstream_auth_ok"] and item["client_credential_not_forwarded"]
                        and item["stream"] and item["model_ok"] for item in fixture.observations):
                    raise RuntimeError("gateway_protocol_assertion")
                result["status"] = "passed"
        except subprocess.TimeoutExpired:
            result["reason"] = "deadline_exceeded"
        except RuntimeError as error:
            result["reason"] = str(error)
        except Exception:
            result["reason"] = "harness_error"
        result["observations"] = fixture.observations
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--client", choices=["claude", "codex"], required=True)
    parser.add_argument("--workflow", choices=["sse", "tool", "continuation", "cancel"], required=True)
    args = parser.parse_args()
    try:
        containment()
    except RuntimeError as error:
        print(json.dumps({"status": "blocked", "reason": str(error)}))
        return 2
    result = workflow(args.client, args.workflow)
    result["fixture_sha256"] = hashlib.sha256(Path("/qa/fixtures.py").read_bytes()).hexdigest()
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
