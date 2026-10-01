"""Offline FINAL-v1 inventory/plan boundary, not a runner or release admission gate.

Only public source and synthetic fixture contracts are consumed. No process,
network, service discovery, credential directory, or environment inspection.
"""

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import stat
import sys

ROOT = Path(__file__).resolve().parents[2]
CONTRACT_PATH = "docs/parity/final-v1/contract.json"
SCHEMA = "mimic.final-parity-contract/v1"
PLAN_SCHEMA = "mimic.final-parity-plan/v1"
CPA = "acdace936fa7df2905500c7f5e0a97d683138dea"
CPA_ARCHIVE = "56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540"
DRIFT = "97f244b8ddb9cbf564b6e6faab0159102cca8617"
DRIFT_ARCHIVE = "4292170dba8bc8933248c6e292e015b20bef9dfa4f9efb8c5197ae50f566a988"
HISTORICAL_PATH = "test/parity/v2/manifest.json"
HISTORICAL_SHA256 = "3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9"
HISTORICAL_FIXTURES_SHA256 = "1d60dcf36b1659508ae070f418fa32cf22df8ff198b39c992614c5ae1961aef7"
CLIENTS_PATH = "scripts/native-clients/clients.lock.json"
CLIENTS_SHA256 = "c3e2985192d3725e4ddd2a8ff0634630a5a0798af393182c443e00f5ddfbf85a"
PROVIDERS = {"claude", "codex", "kimi", "xai", "devin", "shared_runtime"}
EXCLUDED = {"gemini", "antigravity", "copilot"}
TUPLE = ("provider", "auth_mode", "input_protocol", "upstream_mode", "capability")
UNIVERSAL_CHECKS = (
    "assembled_ingress", "target_identity", "synthetic_only",
    "ordered_wire_observations", "client_credential_not_forwarded",
)
EVIDENCE_DEFAULTS = {
    "candidate": "not_run", "reference": "not_run", "differential": "not_run",
    "native": "not_run", "destination": "not_run", "live": "not_run",
}
CODEX_CHAIN_REFS = {
    "routes", "codex-handler-format", "codex-format-constant", "codex-base-stream",
    "codex-response-protocol", "codex-router", "codex-provider",
    "codex-registry-provider", "codex-model-provider-lookup", "codex-provider-adjust",
    "codex-auth-selection", "codex-after-auth", "codex-after-auth-rewrite",
    "codex-auto-registration", "codex-auto-transport", "codex-stream-interceptors",
}
CODEX_EXECUTOR_ASSERTIONS = {
    "native_lite_terminal_exact_no_hydration", "native_lite_metadata_exact_once",
    "compatibility_hydration_separate",
}
# v1 is a reviewed scope snapshot. Source presence cannot grant applicability;
# changing these dispositions requires an explicit versioned scope decision.
OPERATION_SCOPE = {
    "final-v1-claude-expiry": ("partial", "historical_required"),
    "final-v1-claude-oauth-replay": ("partial", "historical_required"),
    "final-v1-codex-executor-lite": ("present", "wave_requirement"),
    "final-v1-codex-http-sse-lite": ("present", "wave_requirement"),
    "final-v1-codex-buffered-lite": ("present", "product_extension_pending"),
    "final-v1-codex-ws-lite": ("present", "wave_requirement"),
    "final-v1-kimi-messages-sse": ("present", "wave_requirement"),
    "final-v1-kimi-responses-sse": ("present", "wave_requirement"),
    "final-v1-kimi-generic-chat-sse": ("present", "wave_requirement"),
    "final-v1-kimi-compact-http": ("unsupported", "unsupported_upstream"),
    "final-v1-kimi-compact-sse": ("unsupported", "unsupported_upstream"),
    "final-v1-grok-http-continuation": ("unsupported", "unsupported_upstream"),
    "final-v1-grok-physical-ws": ("partial", "wave_requirement"),
    "final-v1-grok-tool-forms": ("partial", "conditional_scope_pending"),
    "final-v1-grok-compact": ("present", "conditional_scope_pending"),
    "final-v1-xai-images-generate": ("present", "conditional_scope_pending"),
    "final-v1-xai-images-edit": ("present", "conditional_scope_pending"),
    "final-v1-xai-images-sse": ("present", "conditional_scope_pending"),
    "final-v1-xai-video-create": ("present", "conditional_scope_pending"),
    "final-v1-xai-video-status": ("present", "conditional_scope_pending"),
    "final-v1-xai-video-content": ("present", "conditional_scope_pending"),
    "final-v1-xai-video-cancel": ("absent_core_route", "unsupported_upstream"),
    "final-v1-devin-media": ("present", "historical_required"),
    "final-v1-devin-model-catalog": ("partial", "historical_required"),
    "final-v1-devin-remote-connect": ("present", "wave_requirement"),
}
OPERATION_IDS = frozenset(OPERATION_SCOPE)
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_JSON_DEPTH = 128


class ContractError(ValueError):
    """A contract/binding is invalid; callers must not repair it to pass."""


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def _require(condition, message):
    if not condition:
        raise ContractError(message)


def _object(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value, "duplicate JSON key: " + key)
        value[key] = item
    return value


def _constant(_):
    raise ContractError("nonfinite JSON number")


def _float(text):
    number = float(text)
    _require(math.isfinite(number), "nonfinite JSON number")
    return number


def _serialize(value, **options):
    """One fail-closed rule for direct dict inputs, binding hashes and output."""
    try:
        _json_value(value)
        return json.dumps(value, allow_nan=False, **options)
    except (ValueError, TypeError, RecursionError) as error:
        raise ContractError("nonfinite or non-JSON value") from error


def _same_json(left, right):
    """Python's True == 1 must not weaken typed protocol expectations."""
    return _serialize(left, sort_keys=True, separators=(",", ":")) == \
        _serialize(right, sort_keys=True, separators=(",", ":"))


def _json_value(value, depth=0):
    _require(depth <= MAX_JSON_DEPTH, "JSON nesting limit")
    kind = type(value)
    if kind is dict:
        for key, item in value.items():
            _require(type(key) is str, "JSON object key must be text")
            _json_value(key, depth + 1)
            _json_value(item, depth + 1)
    elif kind is list:
        for item in value:
            _json_value(item, depth + 1)
    elif kind is str:
        try:
            value.encode("utf-8")
        except UnicodeError as error:
            raise ContractError("invalid UTF-8 JSON string") from error
    elif kind is float:
        _require(math.isfinite(value), "nonfinite JSON number")
    else:
        _require(value is None or kind in (int, bool), "non-JSON value")


def decode(raw):
    """Strict UTF-8 JSON; duplicate keys and nonfinite/overflow numbers fail."""
    _require(isinstance(raw, bytes) and len(raw) <= 1024 * 1024, "JSON input type/size")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_object,
                           parse_constant=_constant, parse_float=_float)
        _json_value(value)
        return value
    except (UnicodeError, json.JSONDecodeError, RecursionError, ValueError) as error:
        raise ContractError("invalid UTF-8 JSON") from error


def _keys(value, names, context):
    _require(isinstance(value, dict) and set(value) == set(names.split()),
             context + ": fields")


def _text(value, context):
    _require(isinstance(value, str) and bool(value.strip()), context + ": text")


def _hash(value, context):
    _require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value),
             context + ": SHA256")


def _strings(value, context, nonempty=True):
    _require(isinstance(value, list) and (bool(value) or not nonempty),
             context + ": list")
    for item in value:
        _text(item, context)
    _require(len(value) == len(set(value)), context + ": duplicates")


def _relative(value):
    _text(value, "path")
    path = PurePosixPath(value)
    _require(not path.is_absolute() and ".." not in path.parts
             and "\\" not in value and path.as_posix() == value, "unsafe path")
    return path


def _read(root, path):
    relative = _relative(path)
    root = Path(root).resolve()
    target = root.joinpath(*relative.parts)
    _require(all(not parent.is_symlink() for parent in
                 [target, *target.parents] if parent != root.parent),
             "symlink input: " + path)
    _require(target.is_relative_to(root), "path escapes root")
    try:
        info = target.stat()
        _require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_FILE_BYTES,
                 "input must be a bounded regular file: " + path)
        with target.open("rb") as source:
            raw = source.read(MAX_FILE_BYTES + 1)
        _require(len(raw) <= MAX_FILE_BYTES, "input size limit: " + path)
        return raw
    except OSError as error:
        raise ContractError("missing/unreadable input: " + path) from error


def _bound_json(root, path, expected):
    raw = _read(root, path)
    _require(digest(raw) == expected, "input hash mismatch: " + path)
    return decode(raw)


@dataclass(frozen=True)
class Contract:
    """Raw bytes are the binding; document access returns an independent copy."""

    root: Path
    raw: bytes

    @property
    def sha256(self):
        return digest(self.raw)

    @property
    def document(self):
        return decode(self.raw)


def _historical_route(row):
    row_id = row["id"]
    transport = "http"
    method = "POST"
    if row["input_protocol"] == "models":
        method, path = "GET", "/v1/models"
    elif row_id in ("claude-count", "devin-count-estimate"):
        path = "/v1/messages/count_tokens"
    elif row_id == "codex-alias":
        path = "/backend-api/codex/responses"
    elif row_id == "codex-compact":
        path = "/v1/responses/compact"
    elif row["input_protocol"] == "messages":
        path = "/v1/messages"
    elif row["input_protocol"] == "chat_completions":
        path = "/v1/chat/completions"
    else:
        path = "/v1/responses"
    if row_id in ("codex-ws", "codex-isolation"):
        method, transport = "GET", "websocket"
    elif row_id in ("codex-sse", "codex-lifecycle", "devin-responses-sse",
                    "devin-stream-lifecycle"):
        transport = "sse"
    return {"method": method, "path": path, "transport": transport}


def validate_contract(value, root=ROOT, source_dir=None):
    """Fail closed on scope loss, stale fixtures/pins, or unsupported claims.

    source_dir optionally verifies every historical public-source file/span
    against the separately downloaded CPA archive. Offline structural validation
    alone is not proof of source authenticity, executable identity, or parity.
    """
    try:
        serialized = _serialize(value)  # Direct callers cannot bypass decode's rule.
        _require(len(serialized.encode("utf-8")) <= 1024 * 1024, "JSON input type/size")
        _validate_contract(value, root, source_dir)
    except (KeyError, TypeError, AttributeError) as error:
        raise ContractError("invalid contract field type") from error


def _validate_contract(value, root, source_dir):
    _keys(value, "schema scope_id scope_version cpa clients_lock historical "
          "exclusions extension_versions sources rows cases error_cases blockers operations", "contract")
    _require(value["schema"] == SCHEMA and value["scope_id"] == "mimic-final-v1"
             and type(value["scope_version"]) is int and value["scope_version"] == 1,
             "contract version")
    cpa = value["cpa"]
    _keys(cpa, "repository revision archive_sha256 drift_revision "
          "drift_archive_sha256 actual_service_identity", "cpa")
    _require(cpa["repository"] == "https://github.com/router-for-me/CLIProxyAPI"
             and cpa["revision"] == CPA and cpa["archive_sha256"] == CPA_ARCHIVE
             and cpa["drift_revision"] == DRIFT
             and cpa["drift_archive_sha256"] == DRIFT_ARCHIVE, "CPA pin")
    _require(cpa["actual_service_identity"] == "unknown", "service identity is not qualified")

    _keys(value["clients_lock"], "path sha256", "clients lock")
    _require(value["clients_lock"] == {"path": CLIENTS_PATH, "sha256": CLIENTS_SHA256},
             "native-client lock pin")
    _bound_json(root, CLIENTS_PATH, CLIENTS_SHA256)
    history = value["historical"]
    _keys(history, "path sha256 required_rows release_passed source_pending_rows", "history")
    _require(all(type(history[field]) is int for field in
                 ("required_rows", "release_passed", "source_pending_rows")) and history == {
        "path": HISTORICAL_PATH, "sha256": HISTORICAL_SHA256,
        "required_rows": 37, "release_passed": 0, "source_pending_rows": 22,
    }, "historical37/0-of-37 must be retained")
    historical = _bound_json(root, HISTORICAL_PATH, HISTORICAL_SHA256)
    old_rows = {row["id"]: row for row in historical["capabilities"]}
    _require(len(old_rows) == 37 and sum(row["source_status"] == "pending"
             for row in old_rows.values()) == 22, "historical source inventory")
    fixture_hashes = {row["fixture"]: digest(_read(root, row["fixture"]))
                      for row in old_rows.values()}
    inventory_hash = digest(_serialize(fixture_hashes, sort_keys=True,
                                      separators=(",", ":")).encode("utf-8"))
    _require(inventory_hash == HISTORICAL_FIXTURES_SHA256,
             "historical fixture inventory changed; version new fixtures separately")
    _require(value["exclusions"] == historical["excluded_providers"], "scope exclusions")
    _strings(value["blockers"], "blockers")
    blockers = set(value["blockers"])
    extensions = value["extension_versions"]
    _require(isinstance(extensions, dict), "extensions")
    for extension, version in extensions.items():
        _text(extension, "extension id")
        _require(extension.startswith("final-v1-") and type(version) is int
                 and version >= 1, "extension version")

    sources = value["sources"]
    _require(isinstance(sources, dict) and bool(sources), "source catalog")
    for source_id, source in sources.items():
        _text(source_id, "source id")
        _keys(source, "path symbol start_line end_line file_sha256 quote quote_sha256", source_id)
        _relative(source["path"])
        _text(source["symbol"], source_id)
        _hash(source["file_sha256"], source_id)
        _hash(source["quote_sha256"], source_id)
        lo, hi, quote = source["start_line"], source["end_line"], source["quote"]
        _require(type(lo) is int and type(hi) is int and 1 <= lo <= hi, source_id + ": span")
        _text(quote, source_id)
        _require(quote.endswith("\n") and len(quote.splitlines()) == hi - lo + 1
                 and digest(quote.encode("utf-8")) == source["quote_sha256"],
                 source_id + ": excerpt hash/lines")
        if source_dir is not None:
            raw = _read(source_dir, source["path"])
            _require(digest(raw) == source["file_sha256"], source_id + ": source file drift")
            actual = b"".join(raw.splitlines(keepends=True)[lo - 1:hi])
            _require(actual == quote.encode("utf-8"), source_id + ": source excerpt drift")

    def refs(ref_ids, context):
        _strings(ref_ids, context)
        _require(set(ref_ids) <= set(sources), context + ": unknown source reference")

    errors = value["error_cases"]
    _require(isinstance(errors, dict) and set(errors) == {"missing-client-key", "invalid-client-key"},
             "client authentication error cases")
    for error_id, error_case in errors.items():
        _keys(error_case, "status body upstream_requests source_refs", error_id)
        expected = "Missing API key" if error_id == "missing-client-key" else "Invalid API key"
        _require(type(error_case["status"]) is int and error_case["status"] == 401
                 and error_case["body"] == {"error": expected}
                 and type(error_case["upstream_requests"]) is int
                 and error_case["upstream_requests"] == 0, error_id + ": reference error")
        refs(error_case["source_refs"], error_id)

    rows = value["rows"]
    _require(isinstance(rows, list) and bool(rows), "rows")
    by_id, tuples, used_extensions = {}, set(), set()
    for row in rows:
        _keys(row, "id provider auth_mode input_protocol upstream_mode capability required "
              "fixture fixture_sha256 historical_source_status source_assessment "
              "source_refs case_ids owner extension evidence blockers", "row")
        row_id = row["id"]
        _text(row_id, "row id")
        _require(row_id not in by_id, "duplicate row: " + row_id)
        by_id[row_id] = row
        for field in TUPLE:
            _text(row[field], row_id + "." + field)
        identity = tuple(row[field] for field in TUPLE)
        _require(identity not in tuples, "duplicate capability tuple")
        tuples.add(identity)
        _require(row["provider"] in PROVIDERS and row["provider"] not in EXCLUDED
                 and row["required"] is True, row_id + ": FINAL scope/required")
        _text(row["owner"], row_id + ".owner")
        _require(row["evidence"] == EVIDENCE_DEFAULTS, row_id + ": contract is not execution")
        _require(row["source_assessment"] in ("mapped", "partial", "contradicted", "pending"),
                 row_id + ": source assessment")
        refs(row["source_refs"], row_id)
        _strings(row["case_ids"], row_id + ".case_ids")
        _require(row_id + ".final-v1" in row["case_ids"], row_id + ": missing primary v1 case")
        _strings(row["blockers"], row_id + ".blockers", nonempty=False)
        _require(set(row["blockers"]) <= blockers, row_id + ": unknown blocker")
        if row["source_assessment"] != "mapped":
            _require(bool(row["blockers"]), row_id + ": source gap requires a blocker")
        if row_id in old_rows:
            old = old_rows[row_id]
            _require(all(row[field] == old[field] for field in (*TUPLE, "fixture"))
                     and row["historical_source_status"] == old["source_status"]
                     and row["extension"] is None, row_id + ": historical tuple changed")
        else:
            _require(row_id.startswith("final-v1-") and row["extension"] in extensions
                     and row["historical_source_status"] is None, row_id + ": unversioned extension")
            used_extensions.add(row["extension"])
        _require(row["fixture"].startswith(("test/parity/fixtures/",
                                           "docs/parity/final-v1/fixtures/")),
                 row_id + ": fixture namespace")
        _hash(row["fixture_sha256"], row_id)
        fixture = _bound_json(root, row["fixture"], row["fixture_sha256"])
        _require(fixture["cpa_revision"] == CPA and fixture["schema_version"] == 1,
                 row_id + ": fixture CPA/schema")
    _require(set(old_rows) <= set(by_id), "missing historical required rows")
    _require(used_extensions == set(extensions), "empty/orphan extension")

    cases = value["cases"]
    _require(isinstance(cases, dict) and bool(cases), "cases")
    claimed_cases = set()
    for row in rows:
        for case_id in row["case_ids"]:
            _require(case_id in cases and case_id not in claimed_cases, "missing/shared case")
            claimed_cases.add(case_id)
            case = cases[case_id]
            _keys(case, "version row_id route stimulus assertions source_refs "
                  "expected_reference errors", case_id)
            _require(case["row_id"] == row["id"] and type(case["version"]) is int
                     and case["version"] == 1, case_id + ": identity/version")
            _keys(case["route"], "method path transport", case_id + ".route")
            _require(case["route"]["method"] in ("GET", "POST", "DELETE")
                     and case["route"]["transport"] in ("http", "sse", "websocket")
                     and isinstance(case["route"]["path"], str)
                     and case["route"]["path"].startswith("/")
                     and "?" not in case["route"]["path"], case_id + ": route")
            if row["id"] in old_rows and case_id == row["id"] + ".final-v1":
                _require(case["route"] == _historical_route(row), case_id + ": wrong primary route")
            stimulus = case["stimulus"]
            _keys(stimulus, "description request variants parameters", case_id + ".stimulus")
            _text(stimulus["description"], case_id)
            _require(isinstance(stimulus["request"], dict) or stimulus["request"] is None,
                     case_id + ": request")
            _require(isinstance(stimulus["variants"], list)
                     and all(isinstance(variant, dict) for variant in stimulus["variants"])
                     and isinstance(stimulus["parameters"], dict), case_id + ": scenario parameters")
            if case["route"]["transport"] == "sse":
                requests = [stimulus["request"], *stimulus["variants"]]
                _require(all(isinstance(request, dict) and request.get("stream") is True
                             for request in requests), case_id + ": SSE request must set stream=true")
            _strings(case["assertions"], case_id + ".assertions")
            refs(case["source_refs"], case_id)
            _require(case["expected_reference"] in ("supported", "rejected", "difference", "pending"),
                     case_id + ": expected reference")
            _strings(case["errors"], case_id + ".errors", nonempty=False)
            _require(set(case["errors"]) == set(errors), case_id + ": missing/unknown error case")
            if case["expected_reference"] in ("difference", "pending"):
                _require(bool(row["blockers"]), case_id + ": missing investigation blocker")
            if row["source_assessment"] != "mapped":
                _require(case["expected_reference"] != "supported",
                         case_id + ": unresolved source cannot claim support")
            if case_id in ("codex-sse.final-v1", "codex-ws.final-v1"):
                _validate_codex_stream_boundary(case, row, refs)
    _require(set(cases) == claimed_cases, "orphan cases")
    _validate_operations(value["operations"], by_id, blockers, refs, cases)


def _validate_operations(inventory, rows, blockers, refs, cases):
    """Source presence, requested applicability and runtime are separate axes."""
    _keys(inventory, "schema version denominator_effect entries", "operations")
    _require(inventory["schema"] == "mimic.final-operation-inventory/v1"
             and type(inventory["version"]) is int and inventory["version"] == 1
             and inventory["denominator_effect"] == "none_until_explicit_matrix_extension",
             "operation inventory version/denominator")
    entries = inventory["entries"]
    _require(isinstance(entries, dict) and set(entries) == OPERATION_IDS,
             "operation inventory: missing/unknown v1 operation")
    for operation_id, operation in entries.items():
        _keys(operation, "version provider auth_modes upstream_modes row_ids slice_ids route "
              "observation_boundary source_presence applicability reference_behavior stimulus "
              "assertions source_refs runtime_proof blockers", operation_id)
        _require(type(operation["version"]) is int and operation["version"] == 1
                 and operation["provider"] in PROVIDERS, operation_id + ": version/provider")
        for field in ("auth_modes", "upstream_modes", "row_ids", "slice_ids", "assertions"):
            _strings(operation[field], operation_id + "." + field)
        _require(set(operation["row_ids"]) <= set(rows), operation_id + ": unknown row")
        linked = [rows[row_id] for row_id in operation["row_ids"]]
        _require(all(row["provider"] == operation["provider"] for row in linked)
                 and set(operation["auth_modes"]) == {row["auth_mode"] for row in linked},
                 operation_id + ": provider/auth binding")
        _require(all(re.fullmatch(r"F[0-9]{2}", name) for name in operation["slice_ids"]),
                 operation_id + ": slice id")
        _text(operation["observation_boundary"], operation_id)
        route = operation["route"]
        if route is None:
            _require(operation_id == "final-v1-codex-executor-lite",
                     operation_id + ": missing client route")
        else:
            _keys(route, "method path transport", operation_id + ".route")
            _require(route["method"] in ("GET", "POST", "DELETE")
                     and route["transport"] in ("http", "sse", "websocket")
                     and isinstance(route["path"], str) and route["path"].startswith("/")
                     and "?" not in route["path"], operation_id + ": route")
            if route["transport"] == "sse":
                stimulus = operation["stimulus"]
                _require(isinstance(stimulus, dict) and stimulus.get("stream") is True,
                         operation_id + ": SSE request must set stream=true")
        _require(isinstance(operation["reference_behavior"], dict)
                 and bool(operation["reference_behavior"])
                 and (operation["stimulus"] is None or isinstance(operation["stimulus"], dict)),
                 operation_id + ": behavior/stimulus")
        refs(operation["source_refs"], operation_id)
        _strings(operation["blockers"], operation_id + ".blockers", nonempty=False)
        _require(set(operation["blockers"]) <= blockers, operation_id + ": unknown blocker")
        _require(operation["runtime_proof"] == "not_run", operation_id + ": inventory is not runtime")
        _require((operation["source_presence"], operation["applicability"]) ==
                 OPERATION_SCOPE[operation_id],
                 operation_id + ": frozen source presence/applicability")
        if operation["source_presence"] == "partial":
            _require(bool(operation["blockers"]), operation_id + ": source gap requires blocker")

    # The inventory is a projection of the same validated Codex boundary, not a
    # second source of native-lite wire or continuation authority.
    sse = cases["codex-sse.final-v1"]["stimulus"]["parameters"]
    ws = cases["codex-ws.final-v1"]["stimulus"]["parameters"]["ingress_requirements"]
    executor = sse["executor_source_evidence"]
    selectors = executor["selector_conditions"]
    http = sse["ingress_requirements"]
    projections = {
        "final-v1-codex-executor-lite": {
            "source_formats": selectors["native_source_formats"],
            "response_format": selectors["response_format"], "stream": selectors["stream"],
            "upstream_transport": executor["upstream_transport"],
            "downstream_transport": executor["downstream_transport"],
            "lite_predicate": selectors["lite_predicate"],
            "terminal": "preserve_exact", "authority": http["authority"],
        },
        "final-v1-codex-http-sse-lite": {
            "terminal": http["cpa_wire_terminal"],
            "private_metadata_selector": http["selector_conditions"]["private_metadata"],
            "upstream_transport": http["upstream_transport"], "authority": http["authority"],
        },
        "final-v1-codex-ws-lite": {
            "terminal": ws["cpa_wire_terminal"],
            "selection_callback": ws["selector_conditions"]["selection_callback"],
            "internal_output": ws["internal_completed_output"],
            "upstream_transport": ws["upstream_transport"], "authority": ws["authority"],
        },
    }
    for operation_id, expected in projections.items():
        _require(_same_json(entries[operation_id]["reference_behavior"], expected),
                 operation_id + ": Codex operation projection differs from validated boundary")
    _require(_same_json(entries["final-v1-codex-buffered-lite"]["reference_behavior"],
             {"terminal": "unconditional_hydration_before_translation",
              "supplied_terminal_only": "not_reference_behavior", "authority": "none"}),
             "Codex buffered-lite is an unapproved product difference")

    compact_errors = {
        "http": {"status": 501, "message": "/responses/compact not supported",
                 "upstream_requests": 0},
        "sse": {"status": 400, "message": "Streaming not supported for compact responses",
                "error_type": "invalid_request_error", "upstream_requests": 0,
                "response_transport": "http_json_error",
                "executor_stream_guard": {
                    "status": 400, "message": "streaming not supported for /responses/compact"}},
    }
    for name, expected in compact_errors.items():
        operation = entries["final-v1-kimi-compact-" + name]
        _require(operation["source_presence"] == "unsupported"
                 and type(operation["reference_behavior"].get("upstream_requests")) is int
                 and operation["route"] == {"method": "POST", "path": "/v1/responses/compact",
                                             "transport": name}
                 and _same_json(operation["reference_behavior"], expected),
                 "pinned Kimi compact rejection")
    _require(entries["final-v1-kimi-compact-sse"]["observation_boundary"] ==
             "compact_handler_before_executor"
             and {"core-compact-guard", "kimi-compact-sse"} <=
             set(entries["final-v1-kimi-compact-sse"]["source_refs"]),
             "compact streaming HTTP handler differs from executor guard")
    _require(_same_json(entries["final-v1-grok-http-continuation"]["reference_behavior"],
             {"previous_response_id": "deleted", "compact_or_ws_does_not_qualify": True})
             and entries["final-v1-grok-http-continuation"]["source_presence"] == "unsupported",
             "pinned ordinary Grok HTTP continuation is unsupported")
    cancel = entries["final-v1-xai-video-cancel"]
    _require(cancel["source_presence"] == "absent_core_route"
             and _same_json(cancel["reference_behavior"],
             {"cancel_action": "not_registered_in_audited_core_routes",
              "cancelled_status": "not_cancel_action", "plugins_or_future_source": "not_qualified"}),
             "pinned core video cancel is absent")


def _validate_codex_stream_boundary(case, row, refs):
    """Do not promote executor/forwarder source tests into gateway-chain proof."""
    context = row["id"] + ": Codex boundary"
    params = case["stimulus"]["parameters"]
    ingress = params.get("ingress_requirements")
    _keys(ingress, "observation_boundary downstream_transport upstream_transport "
          "selector_conditions cpa_wire_terminal desired_wire_terminal internal_completed_output "
          "same_boundary_test_refs same_boundary_test_scope source_refs "
          "full_chain_source_status full_chain_blocker authority", context)
    _require(ingress["observation_boundary"] == "assembled_client_wire"
             and ingress["full_chain_source_status"] == "blocked"
             and ingress["full_chain_blocker"] == "codex-full-chain-source"
             and ingress["authority"] == "none"
             and ingress["same_boundary_test_scope"] == "framer_forwarder_not_gateway_chain"
             and row["source_assessment"] == "partial"
             and "codex-full-chain-source" in row["blockers"], context + ": unresolved chain")
    _require(params.get("receipt_qualification") == "not_run"
             and params.get("continuation_qualification") == "not_run",
             context + ": no receipt/history/cursor qualification")
    _require(not CODEX_EXECUTOR_ASSERTIONS.intersection(case["assertions"]),
             context + ": executor assertion at assembled ingress")
    _require("codex_gateway_chain_source_gap_blocks" in case["assertions"],
             context + ": missing chain assertion")
    selectors = {
        "entry_protocol": "openai-response", "response_format": "openai-response",
        "provider_resolution": "router_or_home_or_model_registry",
        "plugin_executor": "native_not_assumed",
        "request_interceptors": "observe_effective_headers_and_body",
        "stream_interceptors": "observe_effective_chunks",
    }
    required_refs = set(CODEX_CHAIN_REFS)
    if row["id"] == "codex-sse":
        selectors["private_metadata"] = "codex_user_agent_or_originator_not_lite_predicate"
        tests = ["codex-sse-repair-test", "codex-sse-metadata-test"]
        required_refs.update({
            "codex-handler-dispatch", "codex-handler-stream", "codex-http-selector",
            "codex-ua-selector", "codex-sse-event", "codex-sse-repair",
            "codex-sse-completed", "codex-sse-forward",
        })
        _require(case["expected_reference"] == "difference"
                 and "transparent-sse-product-difference" in row["blockers"]
                 and ingress["downstream_transport"] == "http_sse"
                 and ingress["upstream_transport"] == ["http_sse"]
                 and ingress["cpa_wire_terminal"] == "backfill_empty_output_from_done_items"
                 and ingress["desired_wire_terminal"] == "exact_supplied_terminal_no_hydration"
                 and ingress["internal_completed_output"] == "not_a_receipt",
                 context + ": HTTP SSE product difference")
        _require({"downstream_sse_empty_terminal_output_backfilled",
                  "transparent_sse_terminal_is_blocking_product_difference",
                  "downstream_sse_private_metadata_selector_not_lite_predicate"}
                 <= set(case["assertions"]), context + ": HTTP SSE assertions")
        executor = params.get("executor_source_evidence")
        _keys(executor, "observation_boundary downstream_transport upstream_transport "
              "selector_conditions matrix_parameter assertions source_refs execution_status", context)
        _require(executor["observation_boundary"] == "executor_stream_chunks"
                 and executor["downstream_transport"] == "none"
                 and executor["upstream_transport"] == ["http_sse", "websocket"]
                 and executor["execution_status"] == "not_run"
                 and executor["matrix_parameter"] == "native_fidelity_matrix",
                 context + ": executor source-only evidence")
        _require(executor["selector_conditions"] == {
            "native_source_formats": ["codex", "openai-response"],
            "response_format": "codex", "stream": True,
            "lite_predicate": "explicit_lite_header_or_client_metadata_true",
        } and executor["selector_conditions"]["stream"] is True,
            context + ": executor selectors")
        _strings(executor["assertions"], context)
        _require(set(executor["assertions"]) == CODEX_EXECUTOR_ASSERTIONS,
                 context + ": executor assertions")
        refs(executor["source_refs"], context)
        _require({"codex-native-invocation", "codex-native-detection", "codex-native-lite",
                  "codex-native-fixture", "codex-native-assertion",
                  "codex-native-metadata-assertion", "codex-native-hydration"}
                 <= set(executor["source_refs"]), context + ": executor sources")
        matrix = params.get("native_fidelity_matrix")
        _keys(matrix, "source_formats lite_markers bootstrap_buffering disable_codex_cloaking", context)
        _require(matrix["source_formats"] == ["codex", "openai-response", "claude", "openai"]
                 and matrix["lite_markers"] == ["none", "header", "metadata"]
                 and matrix["bootstrap_buffering"] == [False, True]
                 and all(type(flag) is bool for flag in matrix["bootstrap_buffering"])
                 and matrix["disable_codex_cloaking"] is True, context + ": source matrix")
    else:
        selectors.update(
            lite_predicate="explicit_lite_header_or_client_metadata_true",
            selected_auth_provider="codex", selection_callback="reset_false_then_recompute",
            upstream_websocket="downstream_ws_and_selected_auth_websockets_enabled",
        )
        tests = ["codex-ws-forward-test"]
        required_refs.update({
            "codex-selected-auth-notify", "codex-websockets-enabled",
            "codex-native-lite", "codex-ws-selector", "codex-ws-forward",
        })
        _require(case["expected_reference"] == "pending"
                 and params.get("native_fidelity_case") == "codex-sse.final-v1"
                 and ingress["downstream_transport"] == "websocket"
                 and ingress["upstream_transport"] == ["http_sse", "websocket"]
                 and ingress["cpa_wire_terminal"] == "preserve_if_lite_and_selected_codex"
                 and ingress["desired_wire_terminal"] == "preserve_if_lite_and_selected_codex"
                 and ingress["internal_completed_output"] == "restored_independently_of_wire",
                 context + ": separate downstream WS preservation")
        _require({"downstream_ws_preserve_conditioned_on_lite_and_selected_codex",
                  "downstream_ws_internal_output_not_wire_or_authority",
                  "downstream_ws_compatibility_output_restoration"}
                 <= set(case["assertions"]), context + ": WS assertions")
    _require(ingress["selector_conditions"] == selectors, context + ": ingress selectors")
    refs(ingress["source_refs"], context)
    refs(ingress["same_boundary_test_refs"], context)
    _require(required_refs <= set(ingress["source_refs"])
             and ingress["same_boundary_test_refs"] == tests, context + ": same-boundary sources")


def load_contract(root=ROOT, source_dir=None):
    root = Path(root).resolve()
    raw = _read(root, CONTRACT_PATH)
    validate_contract(decode(raw), root, source_dir)
    return Contract(root, raw)


def select_rows(contract, provider=None):
    """All historical37 plus additive extensions. Unknown providers fail closed."""
    _require(provider is None or provider in PROVIDERS, "unknown/excluded provider")
    document = contract.document
    validate_contract(document, contract.root)
    return [row for row in document["rows"]
            if provider is None or row["provider"] == provider]


def select_operations(contract, provider=None):
    """Versioned scope findings, never an additional passing denominator."""
    _require(provider is None or provider in PROVIDERS, "unknown/excluded provider")
    document = contract.document
    validate_contract(document, contract.root)
    return [dict(id=operation_id, **operation)
            for operation_id, operation in document["operations"]["entries"].items()
            if provider is None or operation["provider"] == provider]


def native_pins(contract):
    """Read-only exact lock, including inventory-only blocked clients."""
    return _bound_json(contract.root, CLIENTS_PATH, CLIENTS_SHA256)


def case_plan(contract, row_id):
    """Return a declarative synthetic plan; do not execute it or call it a pass.

    F02 owns reusable process/filesystem/network/resource lifetime containment;
    F03 qualifies CPA; F04 owns bounded LIVE runs with budget/allowlist
    reservation before send. F30-F34/provider peers and the shared harness own
    differential assertions; the coordinator owns actual destination admission.
    """
    document = contract.document
    validate_contract(document, contract.root)
    matches = [row for row in document["rows"] if row["id"] == row_id]
    _require(len(matches) == 1, "unknown row: " + str(row_id))
    row = matches[0]
    fixture = _bound_json(contract.root, row["fixture"], row["fixture_sha256"])
    cases = []
    for case_id in row["case_ids"]:
        case = copy.deepcopy(document["cases"][case_id])
        case["id"] = case_id
        case["required_checks"] = list(dict.fromkeys([
            *UNIVERSAL_CHECKS, *fixture["required_checks"], *case["assertions"],
        ]))
        cases.append(case)
    return {
        "schema": PLAN_SCHEMA, "scope_id": document["scope_id"],
        "contract_sha256": contract.sha256, "cpa_revision": CPA,
        "historical_manifest_sha256": HISTORICAL_SHA256,
        "clients_lock_sha256": CLIENTS_SHA256, "row": row, "cases": cases,
        "historical_fixture": fixture, "error_cases": document["error_cases"],
        "execution_status": "not_run",
        "normalization": [],
    }


def summary(contract):
    rows = select_rows(contract)
    historical = [row for row in rows if row["extension"] is None]
    formerly_pending = [row for row in historical if row["historical_source_status"] == "pending"]
    unresolved = sum(row["source_assessment"] != "mapped" for row in formerly_pending)
    return {
        "schema": SCHEMA, "scope_id": contract.document["scope_id"],
        "contract_sha256": contract.sha256, "cpa_revision": CPA,
        "actual_service_identity": "unknown", "historical_required": len(historical),
        "historical_release_passed": 0, "historical_source_pending": 22,
        "source_resolved_from_historical_pending": len(formerly_pending) - unresolved,
        "source_unresolved_from_historical_pending": unresolved,
        "source_assessments": {status: sum(row["source_assessment"] == status
                                          for row in historical)
                               for status in ("mapped", "partial", "contradicted", "pending")},
        "extension_required": len(rows) - len(historical),
        "final_required": len(rows), "runtime_parity_passed": 0,
        "cases": sum(len(row["case_ids"]) for row in rows),
        "source_excerpts": len(contract.document["sources"]),
        "source_files": len({source["path"] for source in contract.document["sources"].values()}),
        "operation_inventory": len(contract.document["operations"]["entries"]),
        "operation_denominator_effect": "none_until_explicit_matrix_extension",
        "unresolved_source_rows": [row["id"] for row in historical
                                   if row["source_assessment"] != "mapped"],
        "preparation_validated": True,
        "f01_acceptance_complete": False,
        "destination_admitted": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "inventory", "plan"))
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--provider")
    parser.add_argument("--row")
    args = parser.parse_args(argv)
    try:
        contract = load_contract(args.root, args.source_dir)
        if args.command == "plan":
            _require(args.row is not None and args.provider is None, "plan requires --row only")
            output = case_plan(contract, args.row)
        elif args.command == "inventory":
            _require(args.row is None, "inventory does not accept --row")
            output = {"summary": summary(contract), "rows": select_rows(contract, args.provider),
                      "operations": select_operations(contract, args.provider)}
        else:
            _require(args.row is None and args.provider is None, "validate accepts no selection")
            output = summary(contract)
        print(_serialize(output, indent=2))
        return 0
    except (ContractError, KeyError, TypeError) as error:
        print("contract invalid: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
