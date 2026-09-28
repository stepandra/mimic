"""Native HTTP gateway evidence driver; missing conformance checks stay red.

This is not the historical laboratory driver and cannot stand in for CPA.
The backend fixture names a synthetic model; this probe uses the explicitly
registered pinned Kimi Code model and reports that substitution. It does not
claim the fixture's ordered-header-fidelity check.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def exercise_kimi():
    smoke = runpy.run_path(str(ROOT / "scripts/smoke-http-providers.py"))
    command = [os.environ.get("GLEAM", "gleam"), "run", "--"]
    (ROOT / "build/integration").mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="kimi-driver-", dir=ROOT / "build/integration") as temp:
        directory = Path(temp)
        directory.chmod(0o700)
        flow = smoke["Workflow"](directory, command, False)
        try:
            smoke["kimi_checks"](flow, "oauth", "kimi.com")
            return {
                "scope": "actual_gateway_cli", "synthetic": True,
                "registered_model": smoke["KIMI_MODEL"],
                "observed_paths": sorted(set(item[0] for item in flow.upstream.requests)),
                "token_exchanges": len(flow.upstream.tokens),
                "device_authorizations": len(flow.upstream.devices),
                "live_provider": False,
            }
        finally:
            flow.close()


def run(plan):
    fixture = json.loads(plan["fixture_json"])
    if hashlib.sha256(plan["fixture_json"].encode()).hexdigest() != plan["fixture_sha256"]:
        raise ValueError("fixture digest mismatch")
    checks = {name: False for name in fixture["required_checks"]}
    observations = {}
    status = "unsupported"
    diagnostics = {}
    if (plan["target"], plan["capability_id"], fixture["id"]) == ("mimic", "kimi-native", "backend-v1"):
        try:
            observations = exercise_kimi()
            checks.update({
                "exact_backend_selected": True, "auth_mode_preserved": True,
                "native_envelope": True, "no_generic_fallback": True,
                # The live header-order differential is not implemented here.
                "ordered_headers_preserved": False,
            })
            status = "failed"
            diagnostics = {"gap": "ordered_header_fidelity_unverified",
                           "fixture_model_substitution": "explicit_pinned_Kimi_Code_registration"}
        except Exception:
            status = "failed"
            diagnostics = {"error": "synthetic_gateway_workflow_failed"}
    return {
        "schema_version": 1, "capability_id": plan["capability_id"],
        "fixture_id": fixture["id"], "fixture_sha256": plan["fixture_sha256"],
        "target": plan["target"], "target_revision": plan["target_revision"],
        "phase": plan["phase"], "status": status,
        "observations": json.dumps(observations, separators=(",", ":")),
        "checks": [{"name": name, "passed": passed} for name, passed in checks.items()],
        "diagnostics": diagnostics,
    }


if __name__ == "__main__":
    with open(sys.argv[-1], encoding="utf-8") as source:
        print(json.dumps(run(json.load(source)), separators=(",", ":")))
