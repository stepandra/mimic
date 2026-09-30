#!/usr/bin/env python3
"""Actual root CLI enrollment races; synthetic loopback credentials only."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HTTP = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))


def records(state):
    # Compare exact synthetic credential generations without printing records.
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in state.glob("runtime-*") if path.is_file()}


def race(command, shipment, existing, mutation):
    directory = ROOT / "build/integration/enrollment"
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="kimi-", dir=directory) as temporary:
        private = Path(temporary)
        private.chmod(0o700)
        flow = HTTP["Workflow"](private, command, shipment)
        login = None
        try:
            settings = json.loads(flow.config.read_text())
            settings["accounts"] = [{
                "provider": "kimi", "auth_mode": "oauth", "id": "selected",
                "origin": flow.origin, "models": [HTTP["KIMI_MODEL"]],
                "base_path": "/operator/kimi",
                "oauth": {
                    "domain": "kimi.com",
                    "device_url": flow.origin + "/api/oauth/device_authorization",
                    "token_url": flow.origin + "/api/oauth/token",
                },
            }]
            flow.config.write_text(json.dumps(settings))
            material = {
                "access_token": "synthetic-old-access",
                "refresh_token": "synthetic-old-refresh",
                "expires_at_ms": 9_000_000_000_000,
                "device_id": "a" * 64,
            }
            initial = HTTP["private"](private / "initial", json.dumps(material))
            replacement = HTTP["private"](
                private / "replacement",
                json.dumps(dict(material, access_token="synthetic-admin-access")),
            )
            identity = HTTP["private"](
                private / "identity", json.dumps({"device_id": "b" * 64})
            )
            if existing:
                flow.cli("credential", "import", str(flow.config), "selected", initial)
            flow.upstream.token_entered.clear()
            flow.upstream.token_release.clear()
            login = subprocess.Popen(
                [*command, "providers", "credential", "login",
                 str(flow.config), "selected", str(identity)],
                cwd=flow.cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            assert flow.upstream.token_entered.wait(15), "enrollment never reached token gate"
            def mutate(*args):
                result = subprocess.run(
                    [*command, "providers", *args], cwd=flow.cwd,
                    capture_output=True, timeout=30,
                )
                assert not any(secret.encode() in result.stdout + result.stderr
                               for secret in HTTP["SECRETS"])
                return result.returncode == 0

            accepted = True
            if mutation in ("replace", "same", "insert_delete"):
                path = initial if mutation == "same" else replacement
                accepted = mutate("credential", "import", str(flow.config), "selected", path)
            if mutation in ("delete", "insert_delete"):
                deleted = mutate("credential", "delete", str(flow.config), "selected")
                accepted = accepted and deleted
            expected = records(flow.state)
            if accepted and mutation != "none":
                if mutation in ("delete", "insert_delete"):
                    assert not expected
                else:
                    assert expected
            flow.upstream.token_release.set()
            stdout, stderr = login.communicate(timeout=30)
            assert not flow.upstream.token_gate_timeout, "synthetic token gate timed out"
            assert not any(secret.encode() in stdout + stderr for secret in HTTP["SECRETS"])
            if mutation == "none":
                assert login.returncode == 0, "uncontended enrollment failed"
                flow.cli("credential", "status", str(flow.config), "selected")
                with flow.running():
                    status, _, _ = HTTP["call"](
                        flow.port, {"model": HTTP["KIMI_MODEL"], "input": "synthetic"},
                        "/v1/responses",
                    )
                    assert status == 200
                headers = flow.upstream.requests[-1][1]
                assert headers["Authorization"] == "Bearer synthetic-new-access"
                assert headers["X-Msh-Device-Id"] == "b" * 64
                return {"existing": existing, "mutation": mutation,
                        "login_succeeded": True, "credential_usable": True}
            return {
                "existing": existing,
                "mutation": mutation,
                "admin_mutation_accepted": accepted,
                "login_rejected": login.returncode != 0,
                "admin_preserved": records(flow.state) == expected,
            }
        finally:
            flow.upstream.token_release.set()
            if login is not None and login.poll() is None:
                login.terminate()
                try:
                    login.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    login.kill()
                    login.communicate(timeout=5)
            flow.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shipment", type=Path)
    args = parser.parse_args()
    command = (["sh", str(args.shipment.resolve() / "entrypoint.sh"), "run"]
               if args.shipment else [os.environ.get("GLEAM", "gleam"), "run", "--"])
    observations = [
        race(command, args.shipment, existing, mutation)
        for existing, mutations in (
            (True, ("replace", "same", "delete", "none")),
            (False, ("replace", "delete", "insert_delete", "none")),
        )
        for mutation in mutations
    ]
    print(json.dumps({
        "scope": "root_kimi_enrollment_cas", "synthetic": True,
        "observations": observations, "shipment": bool(args.shipment),
        "live_provider": False,
    }))
    assert all(
        item["login_succeeded"] and item["credential_usable"] if item["mutation"] == "none"
        else item["admin_mutation_accepted"] and item["login_rejected"] and item["admin_preserved"]
        for item in observations
    ), (
        "enrollment overwrote concurrent admin state"
    )


if __name__ == "__main__":
    main()
