"""F33 SYNTHETIC UNAPPROVED Grok preparation; no launcher or comparator.

Provider proposals are not the F01 contract or executable route qualification.
F17's peer finding is unadmitted; this module supplies no continuation API.
Only explicit local files are read. No process, network or credential access.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "test/parity/final/f33_grok.json"
DRIVER = "scripts/parity/f33_grok.py"
TEST = "scripts/parity/test_f33_grok.py"
DOC = "docs/parity/final/F33_GROK.md"
HISTORICAL = "test/parity/v2/manifest.json"
BASE = "ca86b531cea7e1a509ac8e6038604fe91819ac07"
CPA_REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
SCHEMA = "mimic.f33-grok-fixtures/v1"
APPROVAL = "UNAPPROVED"
DEPENDENCIES = ("F03", "F07", "F17", "F18", "F19", "F20", "F21")
# Unchanged historical five-field tuples, not new required rows or route support.
HISTORICAL_ROWS = {
    "xai-api": ["xai", "api_key", "chat_completions", "xai_api",
                "http_backend_identity"],
    "xai-oauth": ["xai", "oauth", "responses", "grok_build",
                  "http_backend_identity"],
}
PEER_F17 = {
    "evidence_class": "peer_finding_not_imported_or_qualified",
    "Execute": "prepareResponsesRequestTo_deletes_previous_response_id",
    "ExecuteStream": "prepareResponsesRequestTo_deletes_previous_response_id",
    "compact": "alone_readds_previous_response_id_on_separate_base",
    "reasoning_cache": "model_session_cache_not_qualified_receipt_or_isolation",
    "reference_contract": "unsupported-reference-contract",
    "feature_status": "BLOCKED",
    "production_continuation_api": "none",
}
QUALIFICATION = {
    "executor_evidence": "not_assembled_route_qualification",
    "source_route": "unknown",
    "assembled_runtime": "unknown",
    "qualified_route": None,
}
CONTEXT = {
    "clock_ms": 1000,
    "selected_model": "synthetic-model",
    "credential_slots": ["synthetic-a", "synthetic-b"],
    "credential_policy": "explicit_synthetic_placeholders_only",
    "manager_state": "independent_per_target",
    "session_key": "synthetic-session",
    "origin_slots": {"xai_api": "synthetic-api", "grok_build": "synthetic-proxy"},
}
HASH_ROLES = (
    "source", "driver", "fixture", "dependency", "executable", "shipment",
    "contract",
)
COMPARISON = {
    "target": "exact_raw",
    "headers": "ordered_case_sensitive_pairs",
    "body": "utf8_exact_text",
    "sse": "raw_chunks_and_frame_bytes_separately",
    "websocket": "ordered_exact_text_payloads_and_close_no_physical_wire_claim",
    "normalization": [],
    "differences": "decision_required_never_match",
}
REQUIRED_OBSERVATIONS = (
    "assembled_ingress", "qualified_target_identity", "selected_auth_and_backend",
    "actual_upstream_observations", "raw_request_target",
    "ordered_cased_duplicate_headers", "utf8_body_and_stream_bytes_exact",
    "identical_paired_stimulus", "independent_credential_and_manager_state",
    "executor_or_old_fixture_is_not_assembled_route_qualification",
)
# Existing sourceV3 hard stops: no import of launcher/containment modules.
HARD_BLOCKERS = (
    "pinned_cpa_unconditionally_starts_antigravity_version_updater",
    "candidate_descendant_containment_unavailable",
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, names):
    _require(isinstance(value, dict) and set(value) == set(names),
             "unknown or missing F33 payload fields")


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value, "duplicate F33 envelope key")
        value[key] = item
    return value


def _text(value):
    _require(isinstance(value, str), "F33 requires UTF-8 text")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValueError("unsupported non-UTF-8 F33 text") from error


def _strings(values):
    _require(isinstance(values, list), "F33 requires ordered text lists")
    for value in values:
        _text(value)


def _headers(values):
    _require(isinstance(values, list), "F33 headers must be ordered pairs")
    for pair in values:
        _require(isinstance(pair, list) and len(pair) == 2,
                 "F33 headers must be ordered pairs")
        for part in pair:
            _text(part)
        _require(pair[0] and not any(c in pair[0] for c in "\r\n:")
                 and not any(c in pair[1] for c in "\r\n"),
                 "invalid F33 header framing")
        _require(pair[0].lower() != "content-encoding"
                 or pair[1].lower() == "identity",
                 "unsupported F33 content encoding")


def _validate(value):
    """Narrow payload safety guard; does not evaluate provider assertions."""
    _fields(value, (
        "schema", "slice", "provider", "provenance", "approval",
        "mimic_base_revision", "cpa_revision", "historical_manifest",
        "f01_mapping", "historical_rows", "dependencies", "peer_f17",
        "qualification", "synthetic_context", "comparison",
        "required_future_hashes", "cases",
    ))
    _require((value["schema"], value["slice"], value["provider"],
              value["provenance"], value["approval"])
             == (SCHEMA, "F33", "xai", "SYNTHETIC", APPROVAL),
             "unsupported or non-preparatory F33 payload")
    _require(value["mimic_base_revision"] == BASE
             and value["cpa_revision"] == CPA_REVISION
             and value["historical_manifest"] == HISTORICAL,
             "stale F33 source pin")
    _require(value["f01_mapping"] == "provisional_pending"
             and value["historical_rows"] == HISTORICAL_ROWS,
             "F33 cannot replace the historical inventory or F01 mapping")
    _require(value["dependencies"] == {name: "not_admitted" for name in DEPENDENCIES}
             and value["peer_f17"] == PEER_F17
             and value["qualification"] == QUALIFICATION,
             "F33 cannot admit dependencies, continuation or routes")
    _require(value["synthetic_context"] == CONTEXT
             and value["comparison"] == COMPARISON
             and value["required_future_hashes"] == list(HASH_ROLES),
             "unsupported F33 context, normalization or hash requirements")
    _require(isinstance(value["cases"], list) and value["cases"], "missing F33 cases")
    ids = set()
    for case in value["cases"]:
        _fields(case, (
            "id", "row_id", "primary_case_id", "mapping_status", "description",
            "source_refs", "source_requirement", "stimulus", "assertions",
            "expected", "difference",
        ))
        _require(isinstance(case["id"], str)
                 and case["id"].startswith("final-v1-grok-")
                 and case["id"] not in ids, "invalid or duplicate F33 case ID")
        ids.add(case["id"])
        _require(isinstance(case["row_id"], str) and case["row_id"] in HISTORICAL_ROWS
                 and case["primary_case_id"] == case["row_id"] + ".final-v1"
                 and case["mapping_status"] == "provisional_pending",
                 "unknown historical row or approved F33 mapping")
        for name in ("description", "source_requirement"):
            _text(case[name])
            _require(case[name], "missing F33 proposal description")
        for name in ("source_refs", "assertions"):
            _strings(case[name])
            _require(case[name] and all(case[name]), "missing F33 proposal references")
        stimulus = case["stimulus"]
        _fields(stimulus, (
            "auth_mode", "upstream_mode", "input_protocol", "transport",
            "body_encoding", "content_encoding", "turns",
        ))
        row = HISTORICAL_ROWS[case["row_id"]]
        _require(stimulus["auth_mode"] == row[1] and stimulus["upstream_mode"] == row[3],
                 "F33 API-key/OAuth or API/proxy identity conflation")
        _require(stimulus["input_protocol"] in ("chat_completions", "responses")
                 and stimulus["transport"] in ("http/1.1", "websocket")
                 and stimulus["body_encoding"] == "utf-8"
                 and stimulus["content_encoding"] == "identity",
                 "unsupported F33 protocol or encoding")
        ws = stimulus["transport"] == "websocket"
        _require(isinstance(stimulus["turns"], list) and stimulus["turns"],
                 "missing F33 synthetic turns")
        for turn in stimulus["turns"]:
            _fields(turn, ("credential_slot", "request", "responses"))
            _require(turn["credential_slot"] in CONTEXT["credential_slots"],
                     "F33 requires explicit synthetic credential slots")
            request = turn["request"]
            _fields(request, ("method", "target", "headers", "body", "text_frames"))
            _text(request["target"])
            _require(request["method"] == ("GET" if ws else "POST")
                     and request["target"].startswith("/")
                     and not any(c in request["target"] for c in "\r\n"),
                     "invalid F33 proposed request framing")
            _headers(request["headers"])
            _text(request["body"])  # Provider JSON stays raw, including duplicate keys.
            _strings(request["text_frames"])
            _require(request["body"] == "" if ws else request["text_frames"] == [],
                     "F33 HTTP/WS wire representations must stay distinct")
            _require(isinstance(turn["responses"], list), "missing F33 response script")
            for response in turn["responses"]:
                _fields(response, ("status", "headers", "body_chunks", "text_frames", "close"))
                _require(type(response["status"]) is int and 100 <= response["status"] <= 599,
                         "invalid F33 synthetic response status")
                _headers(response["headers"])
                _strings(response["body_chunks"])
                _strings(response["text_frames"])
                _require(response["body_chunks"] == [] if ws
                         else response["text_frames"] == [] and response["close"] is None,
                         "F33 HTTP/WS response representations must stay distinct")
                if response["close"] is not None:
                    _fields(response["close"], ("code", "reason"))
                    _require(type(response["close"]["code"]) is int,
                             "invalid F33 proposed close code")
                    _text(response["close"]["reason"])
        expected = case["expected"]
        _fields(expected, (
            "kind", "scope", "classified_status", "reauthorize", "delivery",
            "retry", "feature_status", "reference_contract",
        ))
        _require(expected["kind"] in (
            "wire_observation_proposal", "blocked_control", "decision_required",
            "error_scope_control") and expected["scope"] in ("NONE", "REQUEST", "CREDENTIAL")
            and expected["feature_status"] == "BLOCKED"
            and expected["retry"] is False
            and expected["reauthorize"] is (expected["scope"] == "CREDENTIAL")
            and expected["reference_contract"] in (
                "qualification_pending", "source_runtime_unknown", "unsupported-reference-contract"),
            "unsupported F33 scope, replay or capability claim")
        if expected["kind"] == "error_scope_control":
            _require(expected["scope"] in ("REQUEST", "CREDENTIAL")
                     and type(expected["classified_status"]) is int
                     and expected["delivery"] == "Uncertain",
                     "F33 status alone cannot authorize replay")
        else:
            _require(expected["classified_status"] is None and expected["delivery"] is None,
                     "F33 cannot fabricate execution outcomes")
        difference = case["difference"]
        _fields(difference, ("status", "note", "normalization"))
        _text(difference["note"])
        _require(difference["status"] in ("observation_required", "decision_required")
                 and difference["normalization"] == [],
                 "F33 differences cannot be normalized into matches")
        if expected["reference_contract"] == "unsupported-reference-contract":
            _require(expected["kind"] == "decision_required"
                     and difference["status"] == "decision_required",
                     "F17 continuation remains a decision-required blocker")
    return value


def load_fixture(root=ROOT):
    """Load this provider payload only; no F01/harness/dependency imports."""
    raw = (Path(root) / FIXTURE).read_bytes()
    return _validate(json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object))


def _blockers():
    return [
        "f33_nonexecuting_adapter", "f01_contract_not_imported_frozen_or_mapped",
        "synthetic_provider_cases_unapproved",
        *("dependency_not_admitted:" + name for name in DEPENDENCIES),
        "unsupported-reference-contract:F17",
        "reasoning_model_session_cache_not_qualified_receipt_or_isolation",
        "media_and_websocket_source_and_assembled_runtime_unknown",
        "paired_cpa_mimic_driver_and_fixture_bindings_unqualified",
        "existing_localhost_8317_identity_unknown_do_not_contact",
        "future_result_hash_bindings_missing", *HARD_BLOCKERS,
    ]


def case_plan(value, scenario_id):
    """Copy independent identical stimuli for future targets; run nothing."""
    _validate(value)
    case = next((item for item in value["cases"] if item["id"] == scenario_id), None)
    _require(case is not None, "unknown F33 Grok scenario")
    stimulus = {"synthetic_context": value["synthetic_context"], **case["stimulus"]}
    row = HISTORICAL_ROWS[case["row_id"]]
    return {
        "schema": "mimic.f33-grok-preparation/v1", "slice": "F33", "provider": "xai",
        "status": "blocked", "feature_status": "BLOCKED",
        "provenance": "SYNTHETIC", "approval": APPROVAL,
        "scenario_id": case["id"], "row_id": case["row_id"],
        "primary_case_id": case["primary_case_id"], "f01_mapping": "provisional_pending",
        "historical_manifest": HISTORICAL, "historical_tuple": deepcopy(row),
        "protocol_mapping": ("historical" if case["stimulus"]["input_protocol"] == row[2]
                             else "additive_control_pending_f01"),
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "dependencies": deepcopy(value["dependencies"]), "peer_f17": deepcopy(PEER_F17),
        "qualification": deepcopy(QUALIFICATION),
        "description": case["description"], "source_refs": deepcopy(case["source_refs"]),
        "source_requirement": case["source_requirement"],
        "paired_stimuli": {target: deepcopy(stimulus) for target in ("cpa", "mimic")},
        "comparison": deepcopy(COMPARISON),
        "planned_assertions": [*REQUIRED_OBSERVATIONS, *case["assertions"]],
        "execution_status": "not_run", "paired_execution": "not_run",
        "cpa_execution": "not_run", "mimic_execution": "not_run",
        "assertion_execution": "not_run",
        "expected": deepcopy(case["expected"]), "difference": deepcopy(case["difference"]),
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified", "blockers": _blockers(),
    }


def blocked_report(root=ROOT, scenario_id=None):
    value = load_fixture(root)
    ids = [scenario_id] if scenario_id is not None else [case["id"] for case in value["cases"]]
    return {
        "schema": "mimic.f33-grok-readiness/v1", "slice": "F33", "status": "blocked",
        "feature_status": "BLOCKED", "evidence_class": "preparatory_synthetic",
        "approval": APPROVAL, "f01_mapping": "provisional_pending",
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "dependencies": deepcopy(value["dependencies"]), "peer_f17": deepcopy(PEER_F17),
        "qualification": deepcopy(QUALIFICATION),
        "execution_status": "not_run", "paired_execution": "not_run",
        "cpa_execution": "not_run", "mimic_execution": "not_run",
        "assertion_execution": "not_run", "native_acceptance": "not_run",
        "live_verified": "not_run", "historical_strict37": "0/37_unchanged",
        # These four local byte digests are NOT future run/qualification bindings.
        "local_file_sha256": {
            name: hashlib.sha256((Path(root) / name).read_bytes()).hexdigest()
            for name in (DRIVER, TEST, FIXTURE, DOC)
        },
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified", "blockers": _blockers(),
        "cases": [case_plan(value, case_id) for case_id in ids],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False, exit_on_error=False)
    parser.add_argument("--case", help="prepare one SYNTHETIC UNAPPROVED scenario")
    try:
        args, extra = parser.parse_known_args(argv)
        _require(not extra, "unsupported F33 CLI arguments")
        report = blocked_report(scenario_id=args.case)
    except (argparse.ArgumentError, OSError, UnicodeError, ValueError):
        print(json.dumps({"status": "rejected", "execution_status": "not_run",
                          "paired_execution": "not_run",
                          "error": "invalid or unavailable F33 payload"}))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 2  # Blocked preparation is never successful parity execution.


if __name__ == "__main__":
    sys.exit(main())
