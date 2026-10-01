"""F30 SYNTHETIC Claude preparation only; no target launch or comparison.

Provider payloads are not the F01 contract. Nothing in this module admits
dependencies, qualifies an endpoint, evaluates assertions, or returns a pass.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "test/parity/final/f30_claude.json"
DRIVER = "scripts/parity/f30_claude.py"
BASE = "ca86b531cea7e1a509ac8e6038604fe91819ac07"
CPA_REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
SCHEMA = "mimic.f30-claude-fixtures/v1"
APPROVAL = "pending_f01_mapping_and_qualification"
DEPENDENCIES = ("F03", "F08", "F09", "F10")
# Claude IDs only, from the unchanged historical v2 manifest; not a new matrix.
ROW_IDS = (
    "claude-models", "claude-messages", "claude-chat", "claude-count",
    "claude-oauth", "claude-tools", "claude-thinking", "claude-image",
    "claude-reject-media",
)
HASH_ROLES = (
    "source", "driver", "fixture", "dependency", "executable", "shipment",
    "contract",
)
COMPARISON = {
    "headers": "ordered_case_sensitive_pairs",
    "target": "exact",
    "body": "utf8_exact_text",
    "sse": "exact_chunks_frames_and_terminal",
    "normalization": "none",
    "differences": "decision_required_never_match",
}
REQUIRED_OBSERVATIONS = (
    "assembled_ingress", "target_identity", "upstream_observations",
    "raw_request_target", "ordered_cased_duplicate_headers", "utf8_body_exact",
    "identical_paired_stimulus", "credential_isolation",
)
# Same sourceV3 facts as reference_driver.CPA_STARTUP_BLOCKER and
# candidate.DESCENDANT_CONTAINMENT_BLOCKER. Do not import launch/exercise code.
HARD_BLOCKERS = (
    "pinned_cpa_unconditionally_starts_antigravity_version_updater",
    "candidate_descendant_containment_unavailable",
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, expected):
    _require(isinstance(value, dict) and set(value) == set(expected),
             "unknown or missing F30 payload fields")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate F30 envelope key")
        result[key] = value
    return result


def _text(value):
    _require(isinstance(value, str), "unsupported non-text F30 body")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValueError("unsupported non-UTF-8 F30 text") from error


def _headers(value):
    _require(isinstance(value, list), "headers must be ordered pairs")
    for pair in value:
        _require(isinstance(pair, list) and len(pair) == 2
                 and all(isinstance(part, str) for part in pair),
                 "headers must be ordered text pairs")
        _require(pair[0] and not any(c in pair[0] for c in "\r\n:")
                 and not any(c in pair[1] for c in "\r\n"),
                 "invalid F30 header framing")
        for part in pair:
            _text(part)
        _require(pair[0].lower() != "content-encoding"
                 or pair[1].lower() == "identity",
                 "unsupported F30 content encoding")


def _validate(value):
    """Narrow provider payload guard, not a contract/result verifier."""
    _fields(value, (
        "schema", "slice", "provider", "provenance", "approval",
        "mimic_base_revision", "cpa_revision", "dependencies", "comparison",
        "required_future_hashes", "cases",
    ))
    _require((value["schema"], value["slice"], value["provider"],
              value["provenance"], value["approval"])
             == (SCHEMA, "F30", "claude", "SYNTHETIC", APPROVAL),
             "unsupported or non-preparatory F30 payload")
    _require(value["mimic_base_revision"] == BASE
             and value["cpa_revision"] == CPA_REVISION,
             "stale F30 source pin")
    _require(value["dependencies"] == {
        dependency: "not_admitted" for dependency in DEPENDENCIES
    }, "F30 cannot admit dependencies")
    _require(value["comparison"] == COMPARISON,
             "unsupported F30 normalization")
    _require(value["required_future_hashes"] == list(HASH_ROLES),
             "missing F30 future result hash requirements")
    _require(isinstance(value["cases"], list) and value["cases"],
             "missing F30 cases")
    ids = set()
    for case in value["cases"]:
        _fields(case, (
            "id", "row_id", "primary_case_id", "source_refs", "stimulus",
            "assertions", "expected", "difference",
        ))
        _require(isinstance(case["id"], str)
                 and case["id"].startswith("final-v1-claude-")
                 and case["id"] not in ids, "invalid or duplicate F30 case ID")
        ids.add(case["id"])
        _require(case["row_id"] in ROW_IDS
                 and case["primary_case_id"] == case["row_id"] + ".final-v1",
                 "unknown Claude row or primary F01 mapping")
        _require(isinstance(case["source_refs"], list) and case["source_refs"]
                 and all(isinstance(ref, str) and ref for ref in case["source_refs"]),
                 "missing F30 source references")
        _require(isinstance(case["assertions"], list) and case["assertions"]
                 and all(isinstance(name, str) and name for name in case["assertions"]),
                 "missing F30 planned assertions")
        stimulus = case["stimulus"]
        _fields(stimulus, (
            "transport", "body_encoding", "content_encoding", "auth_mode",
            "credential_slots", "selected_model", "clock_ms", "operator_policy",
            "request", "responses", "refresh",
        ))
        _require((stimulus["transport"], stimulus["body_encoding"],
                  stimulus["content_encoding"])
                 == ("http/1.1", "utf-8", "identity"),
                 "unsupported F30 transport or encoding")
        _require(stimulus["auth_mode"] in ("api_key", "oauth"),
                 "unsupported Claude authentication mode")
        _require(isinstance(stimulus["credential_slots"], list)
                 and stimulus["credential_slots"]
                 and all(slot in ("synthetic-a", "synthetic-b")
                         for slot in stimulus["credential_slots"]),
                 "only explicit synthetic credential slots are supported")
        _require(stimulus["selected_model"] == "synthetic-model",
                 "unsupported F30 selected model")
        _require(type(stimulus["clock_ms"]) is int and stimulus["clock_ms"] >= 0,
                 "invalid F30 synthetic clock")
        policy = stimulus["operator_policy"]
        _fields(policy, ("input", "turn", "cache", "profile"))
        _require(policy["input"] in ("native_messages", "translated_messages")
                 and policy["turn"] in ("conversation", "subagent", "helper")
                 and policy["cache"] in (
                     "preserve", "default_5m", "approved_1h")
                 and policy["profile"] == "none",
                 "unsupported or unqualified Claude operator policy")
        request = stimulus["request"]
        _fields(request, ("method", "target", "headers", "body"))
        _require(request["method"] == "POST" and request["target"] in (
            "/v1/messages", "/v1/messages?beta=true",
            "/v1/messages/count_tokens",
        ), "unsupported Claude request target or method")
        _headers(request["headers"])
        _text(request["body"])  # Never decode/re-encode raw provider JSON.
        _require(isinstance(stimulus["responses"], list),
                 "missing F30 synthetic response script")
        for response in stimulus["responses"]:
            _fields(response, ("endpoint", "status", "headers", "body_chunks"))
            _require(response["endpoint"] in (
                "messages", "count_tokens", "oauth_refresh")
                and type(response["status"]) is int
                and 100 <= response["status"] <= 599,
                "unsupported F30 response endpoint or status")
            _headers(response["headers"])
            _require(isinstance(response["body_chunks"], list),
                     "unsupported F30 response chunks")
            for chunk in response["body_chunks"]:
                _text(chunk)
        refresh = stimulus["refresh"]
        if refresh is not None:
            _fields(refresh, ("parallel_requests", "expires_at_ms", "barriers"))
            _require(stimulus["auth_mode"] == "oauth"
                     and type(refresh["parallel_requests"]) is int
                     and refresh["parallel_requests"] in (1, 2)
                     and type(refresh["expires_at_ms"]) is int
                     and refresh["expires_at_ms"] >= 0
                     and isinstance(refresh["barriers"], list)
                     and all(isinstance(item, str) for item in refresh["barriers"]),
                     "unsupported F30 refresh stimulus")
        expected = case["expected"]
        _fields(expected, ("kind", "scope", "failure", "send_state",
                           "downstream_status", "quota_effect", "retry"))
        _require(expected["kind"] in (
            "observation", "rejection", "decision_required")
            and expected["scope"] in (
                "none", "request", "credential", "credential_refresh",
                "ambiguous_response")
            and expected["failure"] in (
                None, "Unsupported", "CredentialUnavailable",
                "InvalidGrant", "RefreshUnavailable", "RefreshRateLimited")
            and expected["send_state"] in (None, "NotSent", "Rejected")
            and (expected["downstream_status"] is None
                 or type(expected["downstream_status"]) is int)
            and expected["quota_effect"] == "none"
            and (expected["retry"] is False
                 or (expected["retry"] is True
                     and expected["scope"] == "credential"
                     and expected["failure"] == "CredentialUnavailable")),
            "unsupported F30 error scope or quota/failover claim")
        difference = case["difference"]
        _fields(difference, ("status", "note", "normalization"))
        _require(difference["status"] in ("none", "decision_required")
                 and isinstance(difference["note"], str)
                 and difference["normalization"] == "none",
                 "F30 differences cannot be normalized into matches")
    return value


def load_fixture(root=ROOT):
    """Read only the explicit provider fixture; no common-contract invention."""
    raw = (Path(root) / FIXTURE).read_bytes()
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
    return _validate(value)


def _blockers():
    return [
        "f30_nonexecuting_adapter",
        "f01_contract_mapping_and_fixture_approval_pending",
        *("dependency_not_admitted:" + name for name in DEPENDENCIES),
        "paired_cpa_mimic_driver_bindings_unqualified",
        "existing_localhost_8317_identity_unqualified_do_not_contact",
        "future_result_hash_bindings_missing",
        *HARD_BLOCKERS,
    ]


def case_plan(value, scenario_id):
    """Deep-copy identical inputs for future paired targets; never run either."""
    _validate(value)
    selected = next((case for case in value["cases"]
                     if case["id"] == scenario_id), None)
    _require(selected is not None, "unknown F30 Claude scenario")
    return {
        "schema": "mimic.f30-claude-preparation/v1",
        "status": "blocked", "provider": "claude", "approval": APPROVAL,
        "scenario_id": selected["id"], "row_id": selected["row_id"],
        "primary_case_id": selected["primary_case_id"],
        "f01_mapping": "pending",
        "cpa_revision": CPA_REVISION, "mimic_base_revision": BASE,
        "paired_stimuli": {
            target: deepcopy(selected["stimulus"]) for target in ("cpa", "mimic")
        },
        "source_refs": deepcopy(selected["source_refs"]),
        "comparison": deepcopy(COMPARISON),
        "planned_assertions": [
            *REQUIRED_OBSERVATIONS, *selected["assertions"],
        ],
        "assertion_execution": "not_run",
        "expected": deepcopy(selected["expected"]),
        "difference": deepcopy(selected["difference"]),
        "required_future_hashes": list(HASH_ROLES),
        "blockers": _blockers(),
    }


def blocked_report(root=ROOT, scenario_id=None):
    value = load_fixture(root)
    ids = [scenario_id] if scenario_id is not None else [
        case["id"] for case in value["cases"]
    ]
    return {
        "schema": "mimic.f30-claude-readiness/v1", "slice": "F30",
        "status": "blocked", "evidence_class": "preparatory_synthetic",
        "paired_execution": "not_run", "cpa_execution": "not_run",
        "mimic_execution": "not_run", "live_verified": "not_run",
        "historical_strict37": "0/37_unchanged",
        # Actual local bytes only, not verified shipment/dependency evidence.
        "local_file_sha256": {
            name: hashlib.sha256((Path(root) / name).read_bytes()).hexdigest()
            for name in (FIXTURE, DRIVER)
        },
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified",
        "blockers": _blockers(),
        "cases": [case_plan(value, case_id) for case_id in ids],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", help="prepare one known synthetic scenario")
    args = parser.parse_args(argv)
    try:
        report = blocked_report(scenario_id=args.case)
    except (OSError, UnicodeError, ValueError):
        print(json.dumps({"status": "rejected", "paired_execution": "not_run",
                          "error": "invalid or unavailable F30 payload"}))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 2  # Preparation is not a successful execution or parity result.


if __name__ == "__main__":
    sys.exit(main())
