"""F32 SYNTHETIC UNAPPROVED Kimi preparation; no launch, I/O or comparison.

This provider payload is not the F01 contract. A peer-reported F15 checkpoint
is not an imported dependency or a run-bound hash. Nothing here admits a route,
executes assertions, supplies credentials or returns a parity pass.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "test/parity/final/f32_kimi.json"
DRIVER = "scripts/parity/f32_kimi.py"
HISTORICAL = "test/parity/v2/manifest.json"
BASE = "ca86b531cea7e1a509ac8e6038604fe91819ac07"
CPA_REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
SCHEMA = "mimic.f32-kimi-fixtures/v1"
APPROVAL = "UNAPPROVED"
DEPENDENCIES = {
    "F03": "not_admitted",
    "F14": "coordinator_reported_admitted_not_imported",
    "F15": "peer_reported_admitted_not_imported",
    "F16": "not_admitted",
}
PEER_F15 = {
    "evidence_class": "peer_reported_checkpoint_not_independently_imported",
    "coordinator_status": "ACCEPTED",
    "coordinator_revision": "8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936",
    "coordinator_bookmark": "coordinator-f15-admitted",
    "provider_library_revision": "85f44ef07144a8a4433933b2f51f1972e4744039",
    "planned_route": "openai-compatible-kimi/api_key/chat/sse",
    "reported_gates": {
        "focused_tests": 22, "source_requests": 18,
        "shipment_requests": 18, "full_gleam_tests": 711, "review": "reported",
    },
    "reported_semantics": [
        "complete_ir.Value_preservation", "exact_protocol_model_validation",
        "no_native_alias_device_or_thinking_transformations",
        "nested_media_Unsupported_NotSent",
    ],
    "independent_import": "not_run", "f32_qualification": "not_admitted",
    "cpa_differential": "not_run", "native_acceptance": "not_run",
    "live_verified": "not_run",
}
# Provider identity intents, not an alternative common row/capability matrix.
REGISTRATIONS = {
    "kimi": {
        "auth_modes": ["api_key", "oauth"],
        "protocols": ["chat", "responses", "anthropic"],
        "operations": ["chat/completions", "responses", "messages"],
        "model_policy": "explicit_known_native_id",
        "default_base_path": "/coding",
        "transform_policy": "native_alias_thinking_and_oauth_device_binding",
    },
    "openai-compatible-kimi": {
        "auth_modes": ["api_key"], "protocols": ["chat"],
        "operations": ["chat/completions"],
        "model_policy": "explicit_exact_configured_id",
        "default_base_path": "/v1", "transform_policy": "none",
    },
}
HASH_ROLES = (
    "source", "driver", "fixture", "dependency", "executable", "shipment",
    "contract", "historical_manifest", "clients_lock",
)
COMPARISON = {
    "headers": "ordered_case_sensitive_pairs", "target": "exact_raw",
    "body": "utf8_exact_text", "sse": "raw_chunks_and_frame_bytes_separately",
    "normalization": [], "differences": "decision_required_never_match",
}
REQUIRED_OBSERVATIONS = (
    "assembled_ingress", "qualified_target_identity", "actual_selected_registration",
    "actual_upstream_observations", "raw_request_target",
    "ordered_cased_duplicate_headers", "utf8_body_exact",
    "identical_paired_stimulus", "independent_credential_and_manager_state",
    "no_generic_or_old_local_fixture_as_cpa_execution",
)
# Unconditional sourceV3 facts; do not import any launch/exercise module.
HARD_BLOCKERS = (
    "pinned_cpa_unconditionally_starts_antigravity_version_updater",
    "candidate_descendant_containment_unavailable",
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, names):
    _require(isinstance(value, dict) and set(value) == set(names),
             "unknown or missing F32 payload fields")


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value, "duplicate F32 envelope key")
        value[key] = item
    return value


def _text(value):
    _require(isinstance(value, str), "unsupported non-text F32 wire data")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValueError("unsupported non-UTF-8 F32 text") from error


def _headers(headers):
    _require(isinstance(headers, list), "headers must be ordered text pairs")
    for pair in headers:
        _require(isinstance(pair, list) and len(pair) == 2
                 and all(isinstance(part, str) for part in pair),
                 "headers must be ordered text pairs")
        for part in pair:
            _text(part)
        _require(pair[0] and not any(c in pair[0] for c in "\r\n:\x00")
                 and not any(c in pair[1] for c in "\r\n\x00"),
                 "invalid F32 header framing")
        _require(pair[0].lower() != "content-encoding"
                 or pair[1].lower() == "identity", "unsupported F32 encoding")
        _require(pair[0].lower() not in (
            "authorization", "proxy-authorization", "x-api-key", "cookie",
            "set-cookie",
        ), "credential values do not belong in F32 fixture headers")


def _validate(value):
    """Necessary provider payload checks only, not a protocol/result verifier."""
    _fields(value, (
        "schema", "slice", "provider", "provenance", "approval",
        "mimic_base_revision", "cpa_revision", "dependencies", "registrations",
        "comparison", "required_future_hashes", "synthetic_context", "cases",
    ))
    _require((value["schema"], value["slice"], value["provider"],
              value["provenance"], value["approval"])
             == (SCHEMA, "F32", "kimi", "SYNTHETIC", APPROVAL),
             "unsupported or non-preparatory F32 payload")
    _require(value["mimic_base_revision"] == BASE
             and value["cpa_revision"] == CPA_REVISION, "stale F32 source pin")
    _require(value["dependencies"] == DEPENDENCIES,
             "F32 cannot import or admit dependencies")
    _require(value["registrations"] == REGISTRATIONS,
             "native and generic Kimi registrations must stay distinct")
    _require(value["comparison"] == COMPARISON
             and value["required_future_hashes"] == list(HASH_ROLES),
             "unsupported F32 normalization or hash requirements")
    context = value["synthetic_context"]
    _fields(context, (
        "clock_ms", "credential_slots", "selected_account", "client_session",
        "manager_state", "target_endpoints", "registration_orders",
    ))
    _require(type(context["clock_ms"]) is int and context["clock_ms"] >= 0
             and context["credential_slots"] == ["synthetic-a", "synthetic-b"]
             and context["selected_account"] == "synthetic-b"
             and context["client_session"] == "synthetic-client-1"
             and context["manager_state"] == "independent_per_target"
             and context["target_endpoints"] == {"cpa": None, "mimic": None}
             and context["registration_orders"] == [
                 ["kimi", "openai-compatible-kimi"],
                 ["openai-compatible-kimi", "kimi"],
             ], "F32 requires symbolic isolated state and unknown target bindings")
    _require(isinstance(value["cases"], list) and value["cases"], "missing F32 cases")
    ids = set()
    for case in value["cases"]:
        _fields(case, (
            "id", "row_id", "primary_case_id", "provenance", "approval",
            "description", "source_refs", "stimulus", "assertions", "expected",
            "difference",
        ))
        row = case["row_id"]
        # Historical membership/tuple/fixture invariants live in focused tests.
        _require(isinstance(row, str) and row.startswith("kimi-")
                 and case["primary_case_id"] == row + ".final-v1"
                 and isinstance(case["id"], str) and case["id"].startswith(row + ".")
                 and case["id"].endswith(".final-v1")
                 and case["id"] != case["primary_case_id"] and case["id"] not in ids,
                 "invalid F32 provisional probe mapping")
        ids.add(case["id"])
        _require(case["provenance"] == "SYNTHETIC" and case["approval"] == APPROVAL,
                 "F32 cases must be SYNTHETIC UNAPPROVED")
        _text(case["description"])
        for key in ("source_refs", "assertions"):
            _require(isinstance(case[key], list) and case[key]
                     and all(isinstance(item, str) and item for item in case[key]),
                     "missing F32 source references or planned assertions")
        stimulus = case["stimulus"]
        _fields(stimulus, (
            "registration", "auth_mode", "oauth_domain", "selected_model",
            "base_path", "transport", "body_encoding", "content_encoding",
            "turns", "controls",
        ))
        registration = stimulus["registration"]
        _require(isinstance(registration, str) and registration in REGISTRATIONS and row == (
            "kimi-native" if registration == "kimi" else "kimi-generic"),
            "native Kimi cannot be satisfied by a generic registration")
        _require(stimulus["auth_mode"] in ("api_key", "oauth")
                 and stimulus["oauth_domain"] in (
                     ("kimi.com", "kimi.ai") if stimulus["auth_mode"] == "oauth"
                     else (None,)), "unsupported F32 auth domain")
        _require(stimulus["selected_model"] == "kimi-k2.7-code"
                 and stimulus["base_path"] == REGISTRATIONS[registration]["default_base_path"]
                 and (stimulus["transport"], stimulus["body_encoding"],
                      stimulus["content_encoding"]) == ("http/1.1", "utf-8", "identity")
                 and isinstance(stimulus["controls"], dict)
                 and isinstance(stimulus["turns"], list) and stimulus["turns"],
                 "unsupported F32 provider stimulus")
        expected = case["expected"]
        _fields(expected, ("kind", "failure", "send_state", "required_upstream_requests",
                           "scope", "retry", "quota_effect"))
        rejection = expected["kind"] == "pre_io_rejection_required"
        count = expected["required_upstream_requests"]
        _require(expected["kind"] in ("observation_required", "pre_io_rejection_required")
                 and expected["failure"] in (None, "Unsupported", "InvalidConfiguration")
                 and expected["send_state"] == ("NotSent" if rejection else None)
                 and (type(count) is int and count == 0 if rejection else count is None)
                 and expected["scope"] == ("request" if rejection else "none")
                 and expected["retry"] == ("forbidden" if rejection else "not_asserted")
                 and expected["quota_effect"] == "not_asserted",
                 "unsupported F32 planned rejection intent")
        for turn in stimulus["turns"]:
            _fields(turn, ("label", "protocol", "operation", "mode", "request", "responses"))
            _text(turn["label"])
            _require((turn["protocol"], turn["operation"]) in (
                ("chat", "chat/completions"), ("responses", "responses"),
                ("responses", "responses/compact"), ("anthropic", "messages"),
            ) and turn["mode"] in ("buffered", "streaming"), "unsupported F32 protocol")
            unsupported_generic = registration == "openai-compatible-kimi" and (
                stimulus["auth_mode"] != "api_key" or turn["protocol"] != "chat")
            _require(not unsupported_generic or rejection,
                     "generic Kimi cannot claim OAuth/Responses/Messages support")
            request = turn["request"]
            _fields(request, ("method", "target", "headers", "body"))
            _require(request["method"] == "POST"
                     and isinstance(request["target"], str)
                     and request["target"].split("?", 1)[0] in (
                         "/v1/chat/completions", "/v1/responses",
                         "/v1/responses/compact", "/v1/messages")
                     and not any(c in request["target"] for c in "\r\n\x00#"),
                     "unsupported F32 raw target or method")
            _text(request["target"])
            _headers(request["headers"])
            _text(request["body"])  # No provider JSON decoding/re-encoding here.
            _require(isinstance(turn["responses"], list)
                     and (not rejection or not turn["responses"]),
                     "pre-I/O probes cannot contain successful upstream responses")
            for response in turn["responses"]:
                _fields(response, ("status", "headers", "body_chunks"))
                _require(type(response["status"]) is int and 100 <= response["status"] <= 599,
                         "invalid F32 response status")
                _headers(response["headers"])
                _require(isinstance(response["body_chunks"], list), "invalid F32 wire chunks")
                for chunk in response["body_chunks"]:
                    _text(chunk)
        difference = case["difference"]
        _fields(difference, ("status", "note", "normalization"))
        _require(difference["status"] in ("observation_required", "decision_required")
                 and isinstance(difference["note"], str) and difference["normalization"] == [],
                 "F32 differences cannot become normalized matches")
    return value


def load_fixture(root=ROOT):
    """Load only this provider payload; no common contract or harness import."""
    raw = (Path(root) / FIXTURE).read_bytes()
    return _validate(json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object))


def _blockers():
    return [
        "f32_nonexecuting_adapter",
        "f01_contract_not_imported_frozen_or_mapped",
        "synthetic_provider_cases_unapproved",
        "dependency_not_admitted:F03", "f14_coordinator_admitted_not_imported_or_run_bound",
        "f15_peer_admitted_checkpoint_not_independently_imported_or_run_bound",
        "dependency_not_admitted:F16",
        "native_messages_streaming_not_admitted",
        "paired_cpa_mimic_driver_and_fixture_bindings_unqualified",
        "existing_localhost_8317_identity_unknown_do_not_contact",
        "future_result_hash_bindings_missing",
        *HARD_BLOCKERS,
    ]


def case_plan(value, scenario_id):
    """Prepare independent identical paired stimuli; execute/evaluate nothing."""
    _validate(value)
    case = next((item for item in value["cases"] if item["id"] == scenario_id), None)
    _require(case is not None, "unknown F32 Kimi scenario")
    stimulus = {
        "synthetic_context": value["synthetic_context"],
        "registrations": value["registrations"], **case["stimulus"],
    }
    return {
        "schema": "mimic.f32-kimi-preparation/v1", "status": "blocked", "slice": "F32",
        "provider": "kimi", "provenance": "SYNTHETIC", "approval": APPROVAL,
        "scenario_id": case["id"], "row_id": case["row_id"],
        "primary_case_id": case["primary_case_id"], "f01_mapping": "provisional_pending",
        "historical_manifest": HISTORICAL, "mimic_base_revision": BASE,
        "cpa_revision": CPA_REVISION, "dependencies": deepcopy(DEPENDENCIES),
        "peer_f15_checkpoint": deepcopy(PEER_F15), "description": case["description"],
        "source_refs": deepcopy(case["source_refs"]),
        "paired_stimuli": {target: deepcopy(stimulus) for target in ("cpa", "mimic")},
        "comparison": deepcopy(COMPARISON), "normalization": [],
        "planned_assertions": [*REQUIRED_OBSERVATIONS, *case["assertions"]],
        "execution_status": "not_run", "assertion_execution": "not_run",
        "expected": deepcopy(case["expected"]), "difference": deepcopy(case["difference"]),
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified", "blockers": _blockers(),
    }


def blocked_report(root=ROOT, scenario_id=None):
    value = load_fixture(root)
    ids = [scenario_id] if scenario_id is not None else [case["id"] for case in value["cases"]]
    return {
        "schema": "mimic.f32-kimi-readiness/v1", "slice": "F32", "status": "blocked",
        "evidence_class": "preparatory_synthetic", "approval": APPROVAL,
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "dependencies": deepcopy(DEPENDENCIES), "peer_f15_checkpoint": deepcopy(PEER_F15),
        "execution_status": "not_run", "paired_execution": "not_run",
        "cpa_execution": "not_run", "mimic_execution": "not_run",
        "native_acceptance": "not_run", "live_verified": "not_run",
        "historical_strict37": "0/37_unchanged", "normalization": [],
        # Actual local bytes, never substituted for unknown future result bindings.
        "local_file_sha256": {
            name: hashlib.sha256((Path(root) / name).read_bytes()).hexdigest()
            for name in (FIXTURE, DRIVER)
        },
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified", "blockers": _blockers(),
        "cases": [case_plan(value, case_id) for case_id in ids],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", help="prepare one SYNTHETIC UNAPPROVED probe")
    args = parser.parse_args(argv)
    try:
        report = blocked_report(scenario_id=args.case)
    except (OSError, UnicodeError, ValueError):
        print(json.dumps({"status": "rejected", "execution_status": "not_run",
                          "paired_execution": "not_run",
                          "error": "invalid or unavailable F32 payload"}))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 2  # Blocked preparation cannot be a successful parity execution.


if __name__ == "__main__":
    sys.exit(main())
