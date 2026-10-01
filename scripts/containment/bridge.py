"""Thin existing-QA adapter to the compiled Gleam session ABI.

No policy, provider logic, acquisition, fallback launcher or qualification
engine here. One synchronous call owns the ENTIRE in-container fixture + gateway
+ native-client session. The compiled runner, not this glue, owns the lifetime.
"""
import json
import os
from pathlib import Path
import subprocess


class Blocked(Exception):
    pass


RUNNER = Path(__file__).resolve().with_name("run.sh")

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate containment receipt key")
        result[key] = value
    return result


def session(docker_path, socket_path, image, executable, args, bind_ports, connect_ports):
    if not docker_path or not socket_path:
        raise Blocked("explicit_containment_docker_executable_and_socket_required")

    def ports(values):
        return ",".join(str(value) for value in values) or "-"

    argv = [
        "/bin/sh", str(RUNNER), "run", str(docker_path), str(socket_path), image,
        ports(bind_ports), ports(connect_ports), executable, *args,
    ]
    try:
        result = subprocess.run(
            argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=180,
            env={"PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                 "HOME": "/nonexistent", "LANG": "C", "TZ": "UTC"},
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        # Killing this caller cannot keep a target alive: PID1 enforces the
        # independent lease/deadline. No raw stderr or credential-bearing output.
        raise Blocked("compiled_containment_unavailable_or_timed_out") from error
    try:
        if len(result.stdout) > 6400000:
            raise ValueError("bounded report required")
        receipt = json.loads(result.stdout, object_pairs_hook=unique_object)
        if receipt.get("schema") != "mimic.containment/v1":
            raise ValueError("schema")
        if receipt.get("status") == "blocked":
            reason = receipt.get("reason", "containment_blocked")
            if not isinstance(reason, str) or len(reason) > 256:
                raise ValueError("bounded blocking reason required")
            raise Blocked(reason)
        if (set(receipt) != {"schema", "code", "reason", "output"}
                or type(receipt["code"]) is not int
                or receipt["code"] != result.returncode
                or receipt["reason"] != "leader_exited"
                or not isinstance(receipt["output"], str)):
            raise ValueError("terminal owner/target result required")
    except (ValueError, TypeError, AttributeError, RecursionError) as error:
        raise Blocked("containment_session_receipt_invalid") from error
    return subprocess.CompletedProcess(
        argv, receipt["code"], receipt["output"].encode("utf-8"), b"",
    )
