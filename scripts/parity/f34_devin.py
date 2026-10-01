"""F34 SYNTHETIC UNAPPROVED Devin preparation, not a differential driver.

Only four explicit local preparation files are read. No launcher, comparison,
admission, native client, network, login, process or ambient credential access.
Binary bodies are a closed, bounded synthetic vocabulary; base64 is not redaction.
"""
import argparse
import base64
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
DRIVER = "scripts/parity/f34_devin.py"
TEST = "scripts/parity/test_f34_devin.py"
FIXTURE = "test/parity/final/f34_devin.json"
DOC = "docs/parity/final/F34_DEVIN.md"
LOCAL_FILES = (DRIVER, TEST, FIXTURE, DOC)
HISTORICAL = "test/parity/v2/manifest.json"
BASE = "ca86b531cea7e1a509ac8e6038604fe91819ac07"
CPA_REVISION = "acdace936fa7df2905500c7f5e0a97d683138dea"
SCHEMA = "mimic.f34-devin-fixtures/v1"
MAX_FILE_BYTES = 131072
MAX_BINARY_SAMPLE_BYTES = 512
MAX_BINARY_TOTAL_BYTES = 4096
BINARY_POLICY = {
    "generator": "f34_closed_synthetic_sketches/v1",
    "max_sample_bytes": MAX_BINARY_SAMPLE_BYTES,
    "max_vocabulary_bytes": MAX_BINARY_TOTAL_BYTES,
    "raw_capture": "unsupported", "base64": "encoding_not_redaction",
    "source_layout": "partial_sketches_pending_qualification",
}
DEPENDENCIES = ("F03", "F23", "F24", "F25", "F26", "F27", "F28", "F29")
HASH_ROLES = ("source", "driver", "fixture", "dependency", "executable", "shipment", "contract")
HISTORICAL_ROWS = {
    "devin-auth-pkce": ["devin", "session_token", "chat_completions", "devin_connect_rpc",
                        "pkce_permanent_session_enrollment"],
    "devin-auth-import": ["devin", "session_token", "messages", "devin_connect_rpc",
                          "manual_permanent_session_import"],
    "devin-chat-http": ["devin", "session_token", "chat_completions", "devin_connect_rpc",
                        "buffered_generation"],
    "devin-messages-http": ["devin", "session_token", "messages", "devin_connect_rpc",
                            "buffered_generation"],
    "devin-responses-http": ["devin", "session_token", "responses", "devin_connect_rpc",
                             "buffered_generation"],
    "devin-responses-sse": ["devin", "session_token", "responses", "devin_connect_rpc",
                            "connect_to_sse"],
    "devin-tools": ["devin", "session_token", "responses", "devin_connect_rpc",
                    "tool_call_result_turns"],
    "devin-thinking": ["devin", "session_token", "messages", "devin_connect_rpc",
                       "thinking_signature_replay"],
    "devin-multimodal": ["devin", "session_token", "messages", "devin_connect_rpc",
                         "inline_images_and_unsupported_forms"],
    "devin-models": ["devin", "session_token", "models", "devin_connect_rpc",
                     "catalog_and_model_uid"],
    "devin-count-estimate": ["devin", "session_token", "messages", "devin_connect_rpc",
                             "executor_payload_byte_length_estimate"],
    "devin-stream-lifecycle": ["devin", "session_token", "responses", "devin_connect_rpc",
                               "trailer_truncation_disconnect_cancel"],
    "devin-persisted-isolation": ["devin", "session_token", "chat_completions", "devin_connect_rpc",
                                  "permanent_token_account_session_isolation"],
    "devin-status-quota": ["devin", "session_token", "chat_completions", "devin_connect_rpc",
                          "status_quota_refresh_without_token_rotation"],
    "devin-429-failover": ["devin", "session_token", "chat_completions", "devin_connect_rpc",
                          "429_reset_failover"],
}
CONTEXT = {
    "clock_ms": 1000, "selected_model": "devin/swe-1-7",
    "credentials": {slot: "devin-session-token$" + slot for slot in ("synthetic-a", "synthetic-b")},
    "client_credential": "synthetic-client",
    "origins": {"synthetic-local": "http://127.0.0.1:0",
                "synthetic-remote": "https://devin.synthetic.invalid"},
    "manager_state": "independent_per_target",
    "credential_policy": "known_synthetic_literals_in_headers_and_protobuf_only",
}
PEER_F23 = {
    "evidence_class": "coordinator_checkpoint_reported_only",
    "coordinator_revision": "428b7671452a4c637ca227411f02bc1760d66349",
    "provider_revision": "9facbe42122bb436fbd74db2f7edd2ae8bee76f3",
    "coordinator_admission": "ACCEPTED_experimental_LOCAL_ChatSSE",
    "local_import": "not_imported", "local_admission": "not_admitted",
    "local_qualification": "not_qualified",
    "contract": "not_imported", "other_client_routes": "not_inferred",
}
QUALIFICATION = {
    "base_peer_scope": "buffered_Chat_numeric_127.0.0.1_HTTP_only",
    "base_decoder_seams": "response.feed_prefix_stream.next_project_not_clientSSE_qualification",
    "local_assembled": "unimported_unqualified",
    "h2_native_source": "pending",
    "remote_binary": "closed_separate_qualification",
    "messages_responses": "unknown_unqualified",
    "qualified_target_identity": None,
}
COMPARISON = {
    "target": "exact_raw", "headers": "ordered_cased_duplicate_pairs",
    "body": "exact_known_synthetic_bytes_or_utf8_text",
    "connect": "flag_length_payload_and_chunk_boundaries_separately",
    "client_projection": "raw_JSON_or_SSE_separate_from_native_decoder_events",
    "normalization": [], "differences": "decision_required_never_match",
}
HARD_BLOCKERS = (
    "pinned_cpa_unconditionally_starts_antigravity_version_updater",
    "candidate_descendant_containment_unavailable",
)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _known_binary():
    """Construct only these literals. No raw capture/file/decoder input API."""
    def varint(n):
        result = bytearray()
        while n > 127:
            result.append((n & 127) | 128)
            n >>= 7
        return bytes(result) + bytes([n])

    def field(tag, data):
        data = data.encode("utf-8") if isinstance(data, str) else data
        return varint(tag * 8 + 2) + varint(len(data)) + data

    def number(tag, n):
        return varint(tag * 8) + varint(n)

    def frame(flag, data):
        return bytes([flag]) + len(data).to_bytes(4, "big") + data

    # Small field-layout sketches, NOT complete source/native encodings.
    samples = {}
    for slot, token in CONTEXT["credentials"].items():
        metadata = field(1, "chisel") + field(2, "3000.10.21") + field(3, token)
        prompt = field(1, "synthetic-user") + number(2, 1) + field(3, "SYNTHETIC café")
        session = field(1, "00000000-0000-5000-8000-000000000001") + number(2, 1)
        request = (field(1, metadata) + field(2, "SYNTHETIC system") + field(3, prompt)
                   + number(7, 5) + field(15, session) + number(20, 1) + field(21, "swe-1-7"))
        samples["chat-" + slot[-1]] = ("connect_envelope", frame(0, request))
        samples["unary-" + slot[-1]] = ("unframed_protobuf", field(1, metadata))
    samples.update({
        "text": ("connect_envelope", frame(0, field(1, "synthetic-output")
                                          + field(3, "SYNTHETIC caf"))),
        "utf8-lead": ("connect_envelope", frame(0, field(3, b"\xc3"))),
        "utf8-tail-stop": ("connect_envelope", frame(0, field(3, b"\xa9") + number(5, 2)
                                                    + field(7, number(2, 3) + number(3, 2)))),
        "tools": ("connect_envelope", frame(0, field(6, field(1, "synthetic-call")
                                                   + field(2, "synthetic.lookup")
                                                   + field(3, '{"q":"café"}'))
                                           + number(5, 10))),
        "thinking": ("connect_envelope", frame(0, field(9, "SYNTHETIC thought")
                                              + field(10, b"synthetic-signature")
                                              + field(21, "synthetic-type"))),
        "end": ("connect_envelope", frame(2, b"{}")),
        "unauthenticated": ("connect_envelope", frame(
            2, b'{"error":{"code":"unauthenticated","message":"SYNTHETIC"}}')),
        "invalid-argument": ("connect_envelope", frame(
            2, b'{"error":{"code":"invalid_argument","message":"SYNTHETIC"}}')),
        "quota": ("connect_envelope", frame(
            2, b'{"error":{"code":"resource_exhausted","message":"SYNTHETIC"}}')),
        "truncated": ("connect_fragment", b"\x00\x00\x00\x00\x03\x1a"),
        "compressed-flag": ("unsupported_connect_flag", frame(1, b"")),
        "unknown-field": ("connect_envelope", frame(0, field(99, "SYNTHETIC"))),
    })
    _require(all(len(data) <= MAX_BINARY_SAMPLE_BYTES for _, data in samples.values())
             and sum(len(data) for _, data in samples.values()) <= MAX_BINARY_TOTAL_BYTES,
             "F34 synthetic binary vocabulary exceeds bounds")
    return {name: {"provenance": "SYNTHETIC", "encoding": "base64", "framing": framing,
                   "byte_length": len(data), "data": base64.b64encode(data).decode("ascii")}
            for name, (framing, data) in samples.items()}


def _known_payloads():
    """Closed payload vocabulary, including header AND body credential literals."""
    binary = _known_binary()
    duplicates = [["X-Synthetic", "first"], ["x-synthetic", "second"], ["X-Synthetic", "third"]]

    def headers(content_type, slot=None):
        result = [["Content-Type", content_type]]
        if slot is not None:
            token = CONTEXT["credentials"][slot]
            result += [["Authorization", "Basic " + token + "-" + token]]
        if slot is not None and content_type == "application/connect+proto":
            result += [["Connect-Protocol-Version", "1"], ["Accept", "*/*"],
                       ["Sentry-Trace", "00000000000000000000000000000001-0000000000000001-1"]]
        return result + deepcopy(duplicates)

    def text(body):
        return {"provenance": "SYNTHETIC", "encoding": "utf-8", "data": body}

    def client(target, body, method="POST"):
        return {"method": method, "target": target, "transport": "http/1.1",
                "content_encoding": "identity",
                "headers": headers("application/json") + [["Authorization", "Bearer synthetic-client"]],
                "body": text(body)}

    chat = '{ "model":"devin/swe-1-7", "messages":[{"role":"user","content":"SYNTHETIC café"}], "stream":false }\n'
    messages = '{"model":"devin/swe-1-7","messages":[{"role":"user","content":"SYNTHETIC café"}],"max_tokens":8}'
    responses = '{"model":"devin/swe-1-7","input":"SYNTHETIC café","stream":false}'
    clients = {
        "chat": client("/v1/chat/completions?synthetic=b%2Fa&synthetic=a", chat),
        "chat-sse": client("/v1/chat/completions", chat.replace('"stream":false', '"stream":true')),
        "messages": client("/v1/messages", messages),
        "responses": client("/v1/responses", responses),
        "responses-sse": client("/v1/responses", responses.replace('"stream":false', '"stream":true')),
        "models": client("/v1/models", "", "GET"),
        "count": client("/v1/messages/count_tokens", messages),
        "tools": client("/v1/responses", '{"model":"devin/swe-1-7","input":[{"type":"function_call","call_id":"synthetic-call","name":"synthetic.lookup","arguments":"{\\"q\\":\\"café\\"}"},{"type":"function_call_output","call_id":"synthetic-call","output":"SYNTHETIC result"}],"tools":[{"type":"function","name":"synthetic.lookup","parameters":{"type":"object"}}],"stream":true}'),
        "thinking": client("/v1/messages", '{"model":"devin/swe-1-7","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"SYNTHETIC thought","signature":"c3ludGhldGljLXNpZ25hdHVyZQ==","devin_signature_encoding":"base64","devin_signature_type":"synthetic-type"}]}],"max_tokens":8}'),
        "media": client("/v1/messages", '{"model":"devin/swe-1-7","messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"c3ludGhldGljLW5vdC1hbi1pbWFnZQ=="}},{"type":"image_url","image_url":{"url":"https://image.synthetic.invalid/never-fetch"}},{"type":"input_audio","data":"synthetic-unsupported"}]}],"max_tokens":8}'),
    }
    native_requests = {}
    for slot in CONTEXT["credentials"]:
        suffix = slot[-1]
        for name, target, content_type, sample in (
            ("chat", "/exa.api_server_pb.ApiServerService/GetChatMessage",
             "application/connect+proto", "chat-" + suffix),
            ("models", "/exa.api_server_pb.ApiServerService/GetCliModelConfigs",
             "application/proto", "unary-" + suffix),
            ("status", "/exa.seat_management_pb.SeatManagementService/GetUserStatus",
             "application/proto", "unary-" + suffix),
        ):
            native_requests[name + "-" + suffix] = {
                "method": "POST", "target": target, "content_encoding": "identity",
                "credential_slot": slot, "headers": headers(content_type, slot),
                "body": binary[sample],
            }
    chunks = {
        "ok": ["text", "utf8-lead", "utf8-tail-stop", "end"],
        "tools": ["tools", "end"],
        "thinking": ["thinking", "text", "utf8-lead", "utf8-tail-stop", "end"],
        "auth": ["unauthenticated"], "invalid": ["invalid-argument"], "quota": ["quota"],
        "truncated": ["text", "truncated"], "compressed": ["compressed-flag"],
        "unknown": ["unknown-field"], "cancel": ["text"],
    }
    native_responses = {
        name: {"status": 200, "headers": headers("application/connect+proto"),
               "body_chunks": [binary[sample] for sample in samples],
               "termination": "cancel" if name == "cancel" else "eof"}
        for name, samples in chunks.items()
    }
    native_responses["http429"] = {
        "status": 429, "headers": headers("text/plain") + [["Retry-After", "2"]],
        "body_chunks": [text("SYNTHETIC rate control")], "termination": "eof",
    }
    projections = {
        "chat": ["{ \"id\":\"synthetic-chat\", \"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"SYNTHETIC café\"}}], \"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2} }\n"],
        "messages": ['{"id":"synthetic-message","type":"message","content":[{"type":"text","text":"SYNTHETIC café"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2}}'],
        "responses": ['{"id":"synthetic-response","object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"SYNTHETIC café"}]}],"usage":{"input_tokens":3,"output_tokens":2}}'],
        "chat-sse": [': SYNTHETIC heartbeat\r\n\r\nda',
                     'ta: {"id":"synthetic-chat","choices":[{"delta":{"content":"SYNTHETIC café"},"finish_reason":null}]}\r\n\r\n',
                     'data: {"id":"synthetic-chat","choices":[{"delta":{},"finish_reason":"stop"}]}\r\n\r\n',
                     'data: [DONE]\r\n\r\n'],
        "responses-sse": ['event: response.output_text.delta\ndata: {"type":"response.output_text.delta","delta":"SYNTHETIC café"}\n\n',
                          'event: response.completed\ndata: {"type":"response.completed","response":{"id":"synthetic-response","status":"completed"}}\n\n'],
    }
    return {
        "client_requests": clients, "native_requests": native_requests,
        "native_responses": native_responses,
        "client_projections": {
            name: {"status": 200, "headers": headers("text/event-stream" if name.endswith("-sse")
                                                    else "application/json"),
                   "body_chunks": [text(chunk) for chunk in body]}
            for name, body in projections.items()
        },
        "local_inputs": {
            "pkce": text('{"code":"synthetic-code","code_verifier":"synthetic-verifier","state":"synthetic-state","wrong_state":"synthetic-wrong-state","callback":"http://127.0.0.1:0/synthetic/callback"}'),
            "import": text('{"session_token":"devin-session-token$synthetic-a","source":"explicit_synthetic_manual_input","refresh_token":null}'),
            "estimate": text("SYNTHETIC café"),
            "isolation": text('{"accounts":["synthetic-a","synthetic-b"],"sessions":["synthetic-session-a","synthetic-session-b"],"restart":"proposal_only","token_rotation":false}'),
        },
    }


# Provider-specific bindings, not a generic F01 validator or route inventory.
# suffix, historical row suffix, client input, native request/response pairs,
# client projection, local input, control, planned checks.
CASE_SPECS = (
    ("auth-pkce", "auth-pkce", None, [], None, "pkce", "pending", ["pkce_state_mismatch_reject", "no_login_or_code_exchange"]),
    ("auth-import", "auth-import", None, [], None, "import", "pending", ["permanent_token_not_rotating_oauth", "no_ambient_import"]),
    ("chat-http", "chat-http", "chat", [["chat-a", "ok"]], "chat", None, "pending", ["raw_target_body_headers", "native_not_client_projection"]),
    ("messages-http", "messages-http", "messages", [["chat-a", "ok"]], "messages", None, "pending", ["messages_route_not_inferred"]),
    ("responses-http", "responses-http", "responses", [["chat-a", "ok"]], "responses", None, "pending", ["responses_route_not_inferred"]),
    ("responses-sse", "responses-sse", "responses-sse", [["chat-a", "ok"]], "responses-sse", None, "pending", ["connect_trailer_not_SSE_terminal", "split_utf8_and_SSE_chunks"]),
    ("tools", "tools", "tools", [["chat-a", "tools"]], None, None, "pending", ["tool_call_result_ids_and_arguments", "request_encoder_and_projection_pending"]),
    ("thinking", "thinking", "thinking", [["chat-a", "thinking"]], None, None, "pending", ["signature_bytes_and_type_not_redacted_by_base64", "replay_encoder_pending"]),
    ("multimodal", "multimodal", "media", [], None, None, "unsupported", ["unsupported_media_failclosed_no_fetch", "not_a_valid_image_fixture"]),
    ("models", "models", "models", [["models-a", None]], None, None, "pending", ["unary_proto_not_chat_envelope", "model_uid_catalog_pending"]),
    ("count-estimate", "count-estimate", "count", [], None, "estimate", "pending", ["payload_utf8_byte_length_div4_estimate", "no_upstream_tokenizer"]),
    ("stream-lifecycle", "stream-lifecycle", "responses-sse", [["chat-a", "cancel"]], None, None, "request", ["cancel_disconnect_cleanup_pending", "no_replay_after_Started"]),
    ("persisted-isolation", "persisted-isolation", "chat", [["chat-a", "ok"], ["chat-b", "ok"]], None, "isolation", "pending", ["account_session_isolation_and_restart_pending", "no_real_persistence"]),
    ("status-quota", "status-quota", None, [["status-a", None]], None, None, "pending", ["status_refresh_not_token_rotation", "unary_proto_not_chat_envelope"]),
    ("429-failover", "429-failover", "chat", [["chat-a", "http429"]], None, None, "quota", ["Retry_After_is_not_replay_authority", "F27_recovery_unadmitted"]),
    ("native-connect", "chat-http", None, [["chat-a", "ok"]], None, None, "pending", ["native_layout_source_qualification_pending", "decoder_not_assembled_ingress"]),
    ("chat-sse", "chat-http", "chat-sse", [["chat-a", "ok"]], "chat-sse", None, "pending", ["F23_coordinator_admitted_unimported_unqualified", "client_terminal_separate_from_native"]),
    ("trailer-auth", "status-quota", "chat", [["chat-a", "auth"]], None, None, "credential", ["trailer_auth_credential_scope", "no_replay_after_Started"]),
    ("trailer-invalid", "status-quota", "chat", [["chat-a", "invalid"]], None, None, "invalid", ["trailer_invalid_request_scope_no_reauthorize", "no_replay_after_Started"]),
    ("trailer-quota", "429-failover", "chat", [["chat-a", "quota"]], None, None, "quota", ["trailer_quota_not_invalid_credential", "no_replay_after_Started"]),
    ("truncated", "stream-lifecycle", "responses-sse", [["chat-a", "truncated"]], None, None, "request", ["EOF_not_terminal", "no_partial_success_or_replay"]),
    ("compressed", "stream-lifecycle", None, [["chat-a", "compressed"]], None, None, "unsupported", ["unsupported_compression_no_fallback"]),
    ("unknown-field", "stream-lifecycle", None, [["chat-a", "unknown"]], None, None, "unsupported", ["unknown_semantic_field_no_lossy_fallback"]),
    ("h2", "stream-lifecycle", None, [["chat-a", "ok"]], None, None, "h2", ["h2_native_source_qualification_pending", "no_H1_fallback"]),
    ("remote", "stream-lifecycle", None, [["chat-a", "ok"]], None, None, "remote", ["remote_qualification_distinct_closed", "no_network_or_loopback_fallback"]),
)


def _known_cases():
    return [{
        "id": "final-v1-devin-" + suffix, "row_id": "devin-" + row,
        "primary_case_id": "devin-" + row + ".final-v1", "mapping_status": "provisional_pending",
        "client_request": client, "native_pairs": pairs, "client_projection": projection,
        "local_input": local, "control": control, "checks": checks,
        "native_transport": "http/2" if control == "h2" else "http/1.1",
        "origin_slot": "synthetic-remote" if control == "remote" else "synthetic-local",
    } for suffix, row, client, pairs, projection, local, control, checks in CASE_SPECS]


def _fixture_metadata():
    return {
        "schema": SCHEMA, "slice": "F34", "provider": "devin",
        "provenance": "SYNTHETIC", "approval": "UNAPPROVED",
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "historical_manifest": HISTORICAL, "historical_rows": HISTORICAL_ROWS,
        "f01_mapping": "provisional_pending",
        "dependencies": {name: "not_admitted_locally" for name in DEPENDENCIES},
        "peer_f23": PEER_F23, "qualification": QUALIFICATION,
        "synthetic_context": CONTEXT, "comparison": COMPARISON,
        "binary_policy": BINARY_POLICY,
        "required_future_hashes": list(HASH_ROLES),
    }


def _validate(value):
    """Closed synthetic evidence check, not provider assertions or admission."""
    metadata = _fixture_metadata()
    _require(isinstance(value, dict) and set(value) == {*metadata, "payloads", "cases"},
             "unknown or missing F34 fixture fields")
    _require(all(value[key] == expected for key, expected in metadata.items()),
             "unsupported F34 provenance, identity, mapping or qualification")
    # Never decode arbitrary supplied base64, even when marked SYNTHETIC.
    _require(value["payloads"] == _known_payloads(),
             "unknown F34 binary/text/header provenance; base64 is not redaction")
    _require(value["cases"] == _known_cases(),
             "unknown F34 scenario, binding, scope or historical mapping")
    # Typed literal safety check (e.g. 200.0 is not status integer 200).
    # Provider body strings remain opaque; this never compares provider outputs.
    known = {**metadata, "payloads": _known_payloads(), "cases": _known_cases()}
    _require(json.dumps(value, sort_keys=True, allow_nan=False)
             == json.dumps(known, sort_keys=True, allow_nan=False),
             "unsupported F34 literal type")
    return value


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate F34 fixture key")
        result[key] = value
    return result


def _read_local(root, name):
    _require(name in LOCAL_FILES, "F34 reads only its four preparation files")
    with (Path(root) / name).open("rb") as file:
        raw = file.read(MAX_FILE_BYTES + 1)
    _require(len(raw) <= MAX_FILE_BYTES, "F34 local preparation file exceeds bounds")
    return raw


def load_fixture(root=ROOT):
    """Load the fixed bounded provider file; no ambient discovery or credentials."""
    return _validate(json.loads(_read_local(root, FIXTURE).decode("utf-8"),
                                object_pairs_hook=_unique_object))


def _blockers():
    return [
        "f34_nonexecuting_preparation", "f01_not_frozen_imported_or_mapped",
        "synthetic_fixtures_unapproved", "native_layout_and_h2_source_qualification_pending",
        "remote_binary_qualification_closed", "f23_coordinator_admitted_unimported_unqualified",
        *("dependency_not_admitted_locally:" + name for name in DEPENDENCIES),
        "f24_f29_local_contracts_unknown_f27_recovery_unfrozen",
        "paired_driver_fixture_and_target_bindings_unqualified",
        "existing_localhost_8317_identity_unknown_do_not_contact",
        "future_result_hash_bindings_missing", *HARD_BLOCKERS,
    ]


def _expected(control):
    scope, status = {
        "credential": ("CREDENTIAL", 401), "invalid": ("REQUEST", 400),
        "quota": ("REQUEST", 429), "request": ("REQUEST", None),
    }.get(control, ("NONE", None))
    return {
        "kind": "wire_observation_proposal" if control == "pending" else "blocked_control",
        "scope": scope, "proposed_classified_status": status,
        "reauthorize": scope == "CREDENTIAL",
        "delivery": "Uncertain" if scope != "NONE" else None,
        "retry": False, "fallback": False, "feature_status": "BLOCKED",
        "reference_contract": "unsupported" if control in ("h2", "remote", "unsupported")
                              else "qualification_pending",
    }


def case_plan(value, scenario_id):
    """Independent identical paired inputs; no translation, execution or comparison."""
    _validate(value)
    case = next((case for case in value["cases"] if case["id"] == scenario_id), None)
    _require(case is not None, "unknown F34 Devin scenario")
    payloads = value["payloads"]
    stimulus = {
        "synthetic_context": value["synthetic_context"],
        "client_request": payloads["client_requests"].get(case["client_request"]),
        "local_input": payloads["local_inputs"].get(case["local_input"]),
        "native_script": [{
            "origin": CONTEXT["origins"][case["origin_slot"]],
            "transport": case["native_transport"],
            "request": payloads["native_requests"][request],
            "response": payloads["native_responses"].get(response),
            "read_segmentation_bytes": [1, 3, 11],
        } for request, response in case["native_pairs"]],
        "client_projection": payloads["client_projections"].get(case["client_projection"]),
    }
    return {
        "schema": "mimic.f34-devin-preparation/v1", "slice": "F34", "provider": "devin",
        "status": "blocked", "feature_status": "BLOCKED",
        "provenance": "SYNTHETIC", "approval": "UNAPPROVED",
        "scenario_id": case["id"], "row_id": case["row_id"],
        "primary_case_id": case["primary_case_id"], "f01_mapping": "provisional_pending",
        "historical_manifest": HISTORICAL, "historical_tuple": deepcopy(HISTORICAL_ROWS[case["row_id"]]),
        "mapping_role": "historical_primary" if case["id"] == "final-v1-" + case["row_id"]
                        else "additive_control_not_new_row",
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "dependencies": deepcopy(value["dependencies"]), "peer_f23": deepcopy(PEER_F23),
        "qualification": deepcopy(QUALIFICATION),
        "binary_policy": deepcopy(BINARY_POLICY),
        "source_refs": [HISTORICAL + "#" + case["row_id"], "docs/devin/SOURCE_CONTRACT.md"],
        "source_requirement": "Qualify native wire layout AND assembled client projection separately; partial synthetic sketches are neither.",
        "paired_stimuli": {target: deepcopy(stimulus) for target in ("cpa", "mimic")},
        "comparison": deepcopy(COMPARISON), "planned_assertions": deepcopy(case["checks"]),
        "execution_status": "not_run", "paired_execution": "not_run",
        "cpa_execution": "not_run", "mimic_execution": "not_run", "assertion_execution": "not_run",
        "expected": _expected(case["control"]),
        "difference": {"status": "decision_required", "normalization": [],
                       "note": "Unsupported/hardening differences require a decision, never a normalized match."},
        "future_result_hashes": {name: None for name in HASH_ROLES},
        "hash_binding_status": "unknown_not_verified", "blockers": _blockers(),
    }


def blocked_report(root=ROOT, scenario_id=None):
    value = load_fixture(root)
    ids = [scenario_id] if scenario_id is not None else [case["id"] for case in value["cases"]]
    return {
        "schema": "mimic.f34-devin-readiness/v1", "slice": "F34", "status": "blocked",
        "feature_status": "BLOCKED", "evidence_class": "preparatory_synthetic",
        "provenance": "SYNTHETIC", "approval": "UNAPPROVED", "f01_mapping": "provisional_pending",
        "mimic_base_revision": BASE, "cpa_revision": CPA_REVISION,
        "dependencies": deepcopy(value["dependencies"]), "peer_f23": deepcopy(PEER_F23),
        "qualification": deepcopy(QUALIFICATION),
        "binary_policy": deepcopy(BINARY_POLICY),
        "execution_status": "not_run", "paired_execution": "not_run",
        "cpa_execution": "not_run", "mimic_execution": "not_run", "assertion_execution": "not_run",
        "native_acceptance": "not_run", "live_verified": "not_run",
        "historical_strict37": "0/37_unchanged",
        "local_file_sha256": {
            name: hashlib.sha256(_read_local(root, name)).hexdigest() for name in LOCAL_FILES
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
        _require(not extra, "unsupported F34 CLI arguments")
        report = blocked_report(scenario_id=args.case)
    except (argparse.ArgumentError, OSError, UnicodeError, ValueError, RecursionError):
        print(json.dumps({"status": "rejected", "execution_status": "not_run",
                          "paired_execution": "not_run", "error": "invalid or unavailable F34 payload"}))
        return 1
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 2


if __name__ == "__main__":
    sys.exit(main())
