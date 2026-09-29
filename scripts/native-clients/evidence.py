"""Fail-closed native workflow report contract; shared hashing, no process/network IO."""

import hashlib
import json
from pathlib import Path

SCHEMA = "mimic.native-client-workflow/v1"
SOURCES = ("Dockerfile", "clients.lock.json", "evidence.py", "fixtures.py", "harness.py", "qa.py")
EXECUTABLES = {"claude": "/clients/claude", "codex": "/clients/codex/bin/codex"}
QUALIFIABLE_WORKFLOWS = {"sse"}
REASONS = {
    "container_required", "network_namespace_not_isolated", "privilege_containment_missing",
    "readonly_root_required", "gateway_provision_failed", "gateway_exited",
    "gateway_readiness_timeout", "client_never_started_stream", "native_stream_event_not_observed",
    "cancellation_not_observed", "client_exit_or_output_assertion", "native_tool_result_not_observed",
    "continuation_history_not_observed", "gateway_protocol_assertion", "deadline_exceeded",
    "harness_error", "provenance_unavailable", "workflow_evidence_contract_unimplemented",
}


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def source_hashes(directory):
    return {name: digest(Path(directory) / name) for name in SOURCES}


def shipment_hash(directory):
    hashes = {}
    for path in sorted(Path(directory).rglob("*")):
        if path.is_symlink():
            raise ValueError("shipment_symlink")
        if path.is_file():
            hashes[path.relative_to(directory).as_posix()] = digest(path)
    if "entrypoint.sh" not in hashes or "mimic/ebin/mimic.beam" not in hashes:
        raise ValueError("not_a_mimic_shipment")
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def provenance(pin, sources, shipment, executable):
    return {"client_pin": pin, "source_sha256": sources,
            "shipment_sha256": shipment, "executable_sha256": executable}


def empty_report(client, workflow, request_id, binding):
    return {"schema": SCHEMA, "client": client, "workflow": workflow, "request_id": request_id,
            "provenance": binding, "status": "failed", "client_exits": [],
            "client_output_checks": [], "output_marker": False, "observations": [],
            "native_stream_event_observed": False, "upstream_disconnect": False}


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate_report_key")
        value[key] = item
    return value


def _constant(_):
    raise ValueError("nonfinite_report_number")


def validate(raw, container_exit, client, workflow, request_id, binding):
    """Reject incomplete/misattributed reports; never repair or overwrite child identity.

    This validates a trusted harness's evidence, not remote attestation against
    a malicious Docker daemon. A synthetic unit-test report is not execution proof.
    """
    if not isinstance(raw, bytes) or len(raw) > 65536:
        raise ValueError("report_size_or_type")
    value = json.loads(raw, object_pairs_hook=_object, parse_constant=_constant)
    required = set(empty_report(client, workflow, request_id, binding))
    if not isinstance(value, dict) or set(value) not in (required, required | {"reason"}):
        raise ValueError("report_schema")
    if (value["schema"] != SCHEMA or value["client"] != client or value["workflow"] != workflow
            or value["request_id"] != request_id or value["provenance"] != binding):
        raise ValueError("report_identity_or_provenance")
    status = value["status"]
    if not isinstance(status, str) or status not in ("passed", "failed", "blocked"):
        raise ValueError("report_status")
    if type(container_exit) is not int or container_exit != {
            "passed": 0, "failed": 1, "blocked": 2}[status]:
        raise ValueError("report_exit_mismatch")
    if status == "passed" and "reason" in value:
        raise ValueError("passed_report_has_reason")
    if status != "passed" and value.get("reason") not in REASONS:
        raise ValueError("report_reason")
    exits, outputs, observations = (
        value["client_exits"], value["client_output_checks"], value["observations"])
    if (not isinstance(exits, list) or len(exits) > 2
            or any(type(code) is not int or not -128 <= code <= 255 for code in exits)
            or not isinstance(outputs, list) or len(outputs) > 2
            or any(type(check) is not bool for check in outputs)
            or not isinstance(observations, list) or len(observations) > 12):
        raise ValueError("report_measurements")
    for field in ("output_marker", "native_stream_event_observed", "upstream_disconnect"):
        if type(value[field]) is not bool:
            raise ValueError("report_boolean")
    path = "/v1/messages" if client == "claude" else "/backend-api/codex/responses"
    flags = {"stream", "model_ok", "upstream_auth_ok", "client_credential_not_forwarded",
             "tool_result_canary"}
    for item in observations:
        if (not isinstance(item, dict) or set(item) != flags | {"path", "history_items"}
                or item["path"] != path
                or any(type(item[field]) is not bool for field in flags)
                or type(item["history_items"]) is not int or not 0 <= item["history_items"] <= 10000):
            raise ValueError("report_observation")
    if status == "blocked" and (exits or outputs or observations or value["output_marker"]
                                or value["native_stream_event_observed"] or value["upstream_disconnect"]):
        raise ValueError("blocked_report_claims_execution")
    if status != "passed":
        return value
    if workflow not in QUALIFIABLE_WORKFLOWS:
        raise ValueError("workflow_evidence_contract_unimplemented")
    if not observations or not all(all(item[field] for field in flags - {"tool_result_canary"})
                                   for item in observations):
        raise ValueError("missing_successful_protocol_observations")
    if (exits != [0] or outputs != [True] or not value["output_marker"]
            or value["native_stream_event_observed"] or value["upstream_disconnect"]
            or any(item["tool_result_canary"] or item["history_items"] < 1 for item in observations)):
        raise ValueError("missing_native_sse_success_evidence")
    return value
