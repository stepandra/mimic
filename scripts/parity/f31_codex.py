"""F31 SYNTHETIC Codex preparation only; no target launch or comparison.

This provider payload is not the F01 contract. Case data and local byte hashes
cannot admit a dependency, qualify a route, execute an assertion or return pass.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "test/parity/final/f31_codex.json"
DRIVER = "scripts/parity/f31_codex.py"
BASE = "ca86b531cea7e1a509ac8e6038604fe91819ac07"
CPA_REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
HISTORICAL = "test/parity/v2/manifest.json"
SCHEMA = "mimic.f31-codex-fixtures/v1"
APPROVAL = "pending_f01_mapping_and_qualification"
DEPENDENCIES = ("F03", "F11", "F12", "F13")
HASH_ROLES = (
    "source", "driver", "fixture", "dependency", "executable", "shipment",
    "contract", "historical_manifest", "clients_lock",
)
CODEC_LIMITS = {
    "max_observation_bytes": 16_777_216, "max_events": 100_000,
    "frame_bytes": 1_048_576, "items": 4096, "parts": 4096,
}
COMPARISON = {
    "headers": "ordered_case_sensitive_pairs", "target": "exact_raw",
    "body": "utf8_exact_text", "sse": "raw_chunks_and_frame_bytes_separately",
    "websocket": "ordered_exact_text_frames_and_close",
    "normalization": [], "differences": "decision_required_never_match",
}
REQUIRED_OBSERVATIONS = (
    "assembled_ingress", "target_identity", "upstream_observations",
    "raw_request_target", "ordered_cased_duplicate_headers", "utf8_body_exact",
    "identical_paired_stimulus", "credential_isolation",
    "authoritative_scope_and_revision", "trusted_route_codec_policy",
)
# sourceV3 facts, not launch-module imports or waivable fixture options.
HARD_BLOCKERS = (
    "pinned_cpa_unconditionally_starts_antigravity_version_updater",
    "candidate_descendant_containment_unavailable",
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, names):
    _require(isinstance(value, dict) and set(value) == set(names),
             "unknown or missing F31 payload fields")


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value, "duplicate F31 envelope key")
        value[key] = item
    return value


def _text(value):
    _require(isinstance(value, str), "unsupported non-text F31 wire data")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise ValueError("unsupported non-UTF-8 F31 text") from error


def _headers(headers):
    _require(isinstance(headers, list), "headers must be ordered pairs")
    for pair in headers:
        _require(isinstance(pair, list) and len(pair) == 2
                 and all(isinstance(part, str) for part in pair),
                 "headers must be ordered text pairs")
        _require(pair[0] and not any(c in pair[0] for c in "\r\n:")
                 and not any(c in pair[1] for c in "\r\n"),
                 "invalid F31 header framing")
        for part in pair:
            _text(part)
        _require(pair[0].lower() != "content-encoding"
                 or pair[1].lower() == "identity",
                 "unsupported F31 content encoding")


def _wire_strings(values):
    _require(isinstance(values, list), "wire chunks/frames must be text lists")
    for value in values:
        _text(value)


def _validate(value):
    """Only guard provider data; no row inventory or common/result validator."""
    _fields(value, (
        "schema", "slice", "provider", "provenance", "approval",
        "mimic_base_revision", "cpa_revision", "dependencies", "comparison",
        "required_future_hashes", "synthetic_context", "cases",
    ))
    _require((value["schema"], value["slice"], value["provider"],
              value["provenance"], value["approval"])
             == (SCHEMA, "F31", "codex", "SYNTHETIC", APPROVAL),
             "unsupported or non-preparatory F31 payload")
    _require(value["mimic_base_revision"] == BASE
             and value["cpa_revision"] == CPA_REVISION, "stale F31 source pin")
    _require(value["dependencies"] == {
        name: "not_admitted" for name in DEPENDENCIES
    }, "F31 cannot admit dependencies")
    _require(value["comparison"] == COMPARISON
             and value["required_future_hashes"] == list(HASH_ROLES),
             "unsupported F31 normalization or hash requirements")
    context = value["synthetic_context"]
    _fields(context, (
        "auth_mode", "credential_slots", "clock_ms", "scope", "codec_limits",
        "policy_selection", "route_admission", "baseline_http_continuation",
    ))
    _require(context["auth_mode"] == "oauth"
             and context["credential_slots"] == ["synthetic-a", "synthetic-b"]
             and type(context["clock_ms"]) is int and context["clock_ms"] >= 0
             and context["policy_selection"] == "trusted_admitted_route_only"
             and context["route_admission"] == "not_admitted"
             and context["baseline_http_continuation"] == "default_off_bounded",
             "unsupported F31 auth, clock or route authority")
    _fields(context["codec_limits"], CODEC_LIMITS)
    _require(all(type(context["codec_limits"][key]) is int
                 and 0 < context["codec_limits"][key] <= cap
                 for key, cap in CODEC_LIMITS.items()), "unbounded F31 codec policy")
    _fields(context["scope"], (
        "tenant", "provider", "auth", "credential", "account", "generation",
        "model", "origin", "client", "protocol", "operation", "connection_generation",
    ))
    _require(isinstance(context["scope"], dict)
             and all(isinstance(item, str) and item.startswith("synthetic-")
                     for item in context["scope"].values()),
             "F31 scope must use symbolic synthetic identities")
    _require(isinstance(value["cases"], list) and value["cases"], "missing F31 cases")
    ids = set()
    for case in value["cases"]:
        _fields(case, (
            "id", "row_id", "primary_case_id", "description", "source_refs",
            "stimulus", "assertions", "expected", "difference",
        ))
        # Historical membership is cross-checked in the focused tests, not
        # reinvented here as another contract row inventory.
        row = case["row_id"]
        _require(isinstance(row, str) and row.startswith("codex-")
                 and case["primary_case_id"] == row + ".final-v1"
                 and isinstance(case["id"], str)
                 and case["id"].startswith(row + ".")
                 and case["id"].endswith(".final-v1")
                 and case["id"] != case["primary_case_id"]
                 and case["id"] not in ids, "invalid F31 provisional probe mapping")
        ids.add(case["id"])
        _text(case["description"])
        for key in ("source_refs", "assertions"):
            _require(isinstance(case[key], list) and case[key]
                     and all(isinstance(item, str) and item for item in case[key]),
                     "missing F31 source references or planned assertions")
        stimulus = case["stimulus"]
        _fields(stimulus, (
            "path_kind", "transport", "codec_policy", "continuation_mode",
            "turns", "parameters",
        ))
        _require(stimulus["path_kind"] in ("http", "compact", "lite", "websocket")
                 and stimulus["transport"] == (
                     "websocket" if stimulus["path_kind"] == "websocket" else "http/1.1")
                 and stimulus["codec_policy"] in ("Strict", "Reconstruct")
                 and stimulus["continuation_mode"] in (
                     "default_off", "proposed_bounded_opt_in", "same_socket_receipt")
                 and isinstance(stimulus["parameters"], dict)
                 and isinstance(stimulus["turns"], list) and stimulus["turns"],
                 "unsupported F31 transport or policy proposal")
        for turn in stimulus["turns"]:
            _fields(turn, ("label", "request", "responses", "control"))
            _text(turn["label"])
            _text(turn["control"])
            request = turn["request"]
            _fields(request, ("method", "target", "headers", "body", "text_frames"))
            _require(request["method"] == (
                "GET" if stimulus["transport"] == "websocket" else "POST"),
                "unsupported F31 request method")
            _require(isinstance(request["target"], str)
                     and request["target"].split("?", 1)[0] in (
                         "/v1/responses", "/backend-api/codex/responses",
                         "/v1/responses/compact", "/backend-api/codex/responses/compact",
                     )
                     and not any(c in request["target"] for c in "\r\n"),
                     "unsupported F31 raw target")
            _text(request["target"])
            _headers(request["headers"])
            _text(request["body"])  # Never decode/re-encode provider JSON.
            _wire_strings(request["text_frames"])
            _require(request["body"] == "" if stimulus["transport"] == "websocket"
                     else request["text_frames"] == [],
                     "unsupported mixed HTTP/WS request wire data")
            _require(isinstance(turn["responses"], list), "missing F31 response script")
            for response in turn["responses"]:
                _fields(response, ("credential_slot", "status", "headers",
                                   "body_chunks", "text_frames"))
                _require(response["credential_slot"] in context["credential_slots"]
                         and type(response["status"]) is int
                         and 100 <= response["status"] <= 599,
                         "unsupported F31 response identity/status")
                _headers(response["headers"])
                _wire_strings(response["body_chunks"])
                _wire_strings(response["text_frames"])
                _require(response["body_chunks"] == [] if stimulus["transport"] == "websocket"
                         else response["text_frames"] == [],
                         "unsupported mixed HTTP/WS response wire data")
        _require(isinstance(case["expected"], dict), "missing F31 expected intent")
        difference = case["difference"]
        _fields(difference, ("status", "note", "normalization"))
        _require(difference["status"] in ("observation_required", "decision_required")
                 and isinstance(difference["note"], str)
                 and difference["normalization"] == [],
                 "F31 differences cannot become normalized matches")
    return value


def load_fixture(root=ROOT):
    """Read the explicit provider payload only, not a common contract."""
    raw = (Path(root) / FIXTURE).read_bytes()
    return _validate(json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object))


def _blockers():
    return [
        "f31_nonexecuting_adapter",
        "f01_compiled_contract_not_imported_frozen_or_mapped",
        "proposed_provider_cases_not_approved_runtime_fixtures",
        *("dependency_not_admitted:" + name for name in DEPENDENCIES),
        "f11_admission_withheld_partial_packet_not_merged",
        "assembled_output_framer_source_path_review_hold",
        "native_sparse_terminal_not_admitted",
        "paired_cpa_mimic_driver_bindings_unqualified",
        "existing_localhost_8317_identity_unqualified_do_not_contact",
        "future_result_hash_bindings_missing",
        *HARD_BLOCKERS,
    ]


def case_plan(value, scenario_id):
    """Prepare identical independent inputs, never evaluate or execute them."""
    _validate(value)
    case = next((item for item in value["cases"] if item["id"] == scenario_id), None)
    _require(case is not None, "unknown F31 Codex scenario")
    stimulus = {"synthetic_context": value["synthetic_context"], **case["stimulus"]}
    return {
        "schema": "mimic.f31-codex-preparation/v1", "status": "blocked",
        "provider": "codex", "approval": APPROVAL, "scenario_id": case["id"],
        "row_id": case["row_id"], "primary_case_id": case["primary_case_id"],
        "f01_mapping": "provisional_pending", "historical_manifest": HISTORICAL,
        "cpa_revision": CPA_REVISION, "mimic_base_revision": BASE,
        "description": case["description"], "source_refs": deepcopy(case["source_refs"]),
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
        "schema": "mimic.f31-codex-readiness/v1", "slice": "F31", "status": "blocked",
        "evidence_class": "preparatory_synthetic", "execution_status": "not_run",
        "paired_execution": "not_run", "cpa_execution": "not_run",
        "mimic_execution": "not_run", "live_verified": "not_run",
        "historical_strict37": "0/37_unchanged", "normalization": [],
        # These actual file bytes are not run-bound source/shipment evidence.
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
    parser.add_argument("--case", help="prepare one proposed synthetic probe")
    args = parser.parse_args(argv)
    try:
        report = blocked_report(scenario_id=args.case)
    except (OSError, UnicodeError, ValueError):
        print(json.dumps({"status": "rejected", "paired_execution": "not_run",
                          "error": "invalid or unavailable F31 payload"}))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 2  # Blocked preparation is not a successful parity execution.


if __name__ == "__main__":
    sys.exit(main())
