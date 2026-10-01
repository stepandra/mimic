"""Recovered F01 regressions. Synthetic mutations are not provider evidence."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from safe_unit_tests import execution_guards

# Guard import as well as execution; no target/service discovery belongs here.
with execution_guards():
    import contract


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guard = execution_guards()
        cls.guard.__enter__()
        cls.addClassCleanup(cls.guard.__exit__, None, None, None)
        cls.loaded = contract.load_contract()
        cls.valid = cls.loaded.document
        (contract.ROOT / "build").mkdir(exist_ok=True)

    def setUp(self):
        self.value = copy.deepcopy(self.valid)

    def row(self, row_id):
        return next(row for row in self.value["rows"] if row["id"] == row_id)

    def case(self, row_id):
        return self.value["cases"][row_id + ".final-v1"]

    def invalid(self, message=None):
        with self.assertRaisesRegex(contract.ContractError, message or "."):
            contract.validate_contract(self.value)

    @contextlib.contextmanager
    def copied_inputs(self):
        """Private copies under ignored build; never mutate historical inputs."""
        with tempfile.TemporaryDirectory(prefix="f01-unit-", dir=contract.ROOT / "build") as temp:
            root = Path(temp)
            paths = {contract.HISTORICAL_PATH, contract.CLIENTS_PATH, contract.CONTRACT_PATH}
            paths.update(row["fixture"] for row in self.valid["rows"])
            for name in paths:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((contract.ROOT / name).read_bytes())
            yield root

    @contextlib.contextmanager
    def synthetic_sources(self):
        """Synthetic hash/span controls, never claimed CPA source evidence."""
        with tempfile.TemporaryDirectory(prefix="f01-source-unit-", dir=contract.ROOT / "build") as temp:
            root = Path(temp)
            for source_id, source in self.value["sources"].items():
                quote = "// SYNTHETIC " + source_id + "\n"
                raw = ("// SYNTHETIC validator control\n" + quote).encode()
                source.update(path="synthetic/" + source_id + ".go",
                              start_line=2, end_line=2, quote=quote,
                              file_sha256=contract.digest(raw),
                              quote_sha256=contract.digest(quote.encode()))
                target = root / source["path"]
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
            yield root

    def test_valid_contract_never_admits_runtime_or_destination(self):
        result = contract.summary(self.loaded)
        self.assertEqual(result["historical_required"], 37)
        self.assertEqual(result["historical_release_passed"], 0)
        self.assertEqual(result["source_resolved_from_historical_pending"], 14)
        self.assertEqual(result["source_unresolved_from_historical_pending"], 8)
        self.assertEqual(result["source_assessments"]["partial"], 9)
        self.assertFalse(result["f01_acceptance_complete"])
        self.assertFalse(result["destination_admitted"])
        self.assertEqual(result["runtime_parity_passed"], 0)
        self.assertEqual(result["operation_inventory"], 25)
        self.assertEqual(result["extension_required"], 0)

    def test_all_37_plans_include_every_historical_and_universal_check(self):
        for row in contract.select_rows(self.loaded):
            with self.subTest(row=row["id"]):
                plan = contract.case_plan(self.loaded, row["id"])
                checks = plan["cases"][0]["required_checks"]
                self.assertTrue(set(plan["historical_fixture"]["required_checks"]) <= set(checks))
                self.assertTrue(set(contract.UNIVERSAL_CHECKS) <= set(checks))
                self.assertEqual(plan["row"], row)
                self.assertEqual(plan["execution_status"], "not_run")
                self.assertEqual(plan["normalization"], [])
                self.assertEqual(plan["contract_sha256"], self.loaded.sha256)
                self.assertEqual(plan["error_cases"], self.valid["error_cases"])

    def test_selection_keeps_auth_backend_and_native_pins_distinct(self):
        kimi = contract.select_rows(self.loaded, "kimi")
        self.assertEqual([(row["auth_mode"], row["upstream_mode"]) for row in kimi],
                         [("api_key", "openai_compatible"), ("oauth", "kimi_native")])
        xai = contract.select_rows(self.loaded, "xai")
        self.assertEqual([row["upstream_mode"] for row in xai], ["xai_api", "grok_build"])
        pins = contract.native_pins(self.loaded)
        self.assertEqual(pins["clients"]["claude"]["version"], "2.1.284")
        self.assertEqual(pins["clients"]["codex"]["version"], "0.158.0-linux-x64")
        for provider in ("kimi", "grok", "devin"):
            self.assertEqual(pins["inventory_only"][provider]["status"], "blocked")

    def test_unknown_and_excluded_selection_fails(self):
        for provider in ("unknown", "gemini", "antigravity", "copilot"):
            with self.subTest(provider=provider), self.assertRaises(contract.ContractError):
                contract.select_rows(self.loaded, provider)
            with self.assertRaises(contract.ContractError):
                contract.select_operations(self.loaded, provider)
        with self.assertRaises(contract.ContractError):
            contract.case_plan(self.loaded, "invented-row")

    def test_document_and_plan_access_do_not_mutate_binding(self):
        document = self.loaded.document
        document["rows"].clear()
        plan = contract.case_plan(self.loaded, "claude-models")
        plan["row"]["provider"] = "invented"
        operations = contract.select_operations(self.loaded)
        operations[0]["runtime_proof"] = "passed"
        self.assertEqual(len(self.loaded.document["rows"]), 37)
        self.assertEqual(contract.select_rows(self.loaded)[0]["provider"], "claude")
        self.assertEqual(contract.select_operations(self.loaded)[0]["runtime_proof"], "not_run")

    def test_native_sparse_codex_fidelity_is_not_hydration_or_receipt_qualification(self):
        case = contract.case_plan(self.loaded, "codex-sse")["cases"][0]
        params = case["stimulus"]["parameters"]
        events = [json.loads(raw) for raw in params["sparse_event_json"]]
        self.assertEqual([event["type"] for event in events], [
            "codex.response.metadata", "response.output_item.done", "response.completed",
        ])
        self.assertEqual(events[-1]["response"]["output"], [])
        self.assertEqual(events[-1]["response"]["future"], {"ok": True})
        self.assertEqual(params["native_fidelity_matrix"]["lite_markers"],
                         ["none", "header", "metadata"])
        executor = params["executor_source_evidence"]
        self.assertEqual(executor["observation_boundary"], "executor_stream_chunks")
        self.assertEqual(executor["downstream_transport"], "none")
        self.assertEqual(executor["upstream_transport"], ["http_sse", "websocket"])
        self.assertEqual(executor["selector_conditions"]["response_format"], "codex")
        self.assertIs(executor["selector_conditions"]["stream"], True)
        self.assertIn("native_lite_terminal_exact_no_hydration", executor["assertions"])
        self.assertIn("compatibility_hydration_separate", executor["assertions"])
        self.assertNotIn("native_lite_terminal_exact_no_hydration", case["required_checks"])
        self.assertIn("no_created_added_or_identity_fabrication", case["required_checks"])
        for row_id in ("codex-http", "codex-ws"):
            params = contract.case_plan(self.loaded, row_id)["cases"][0]["stimulus"]["parameters"]
            self.assertEqual(params["receipt_qualification"], "not_run")
            self.assertEqual(params["continuation_qualification"], "not_run")

    def test_http_sse_transparency_is_a_blocking_product_difference(self):
        case = self.case("codex-sse")
        ingress = case["stimulus"]["parameters"]["ingress_requirements"]
        self.assertEqual(case["expected_reference"], "difference")
        self.assertEqual(ingress["downstream_transport"], "http_sse")
        self.assertEqual(ingress["upstream_transport"], ["http_sse"])
        self.assertEqual(ingress["cpa_wire_terminal"], "backfill_empty_output_from_done_items")
        self.assertEqual(ingress["desired_wire_terminal"], "exact_supplied_terminal_no_hydration")
        self.assertEqual(ingress["selector_conditions"]["private_metadata"],
                         "codex_user_agent_or_originator_not_lite_predicate")
        self.assertIn("transparent-sse-product-difference", self.row("codex-sse")["blockers"])

    def test_downstream_ws_has_its_own_selectors_and_internal_output_boundary(self):
        case = self.case("codex-ws")
        ingress = case["stimulus"]["parameters"]["ingress_requirements"]
        self.assertEqual(case["expected_reference"], "pending")
        self.assertEqual(ingress["downstream_transport"], "websocket")
        self.assertEqual(ingress["upstream_transport"], ["http_sse", "websocket"])
        selectors = ingress["selector_conditions"]
        self.assertEqual(selectors["selected_auth_provider"], "codex")
        self.assertEqual(selectors["selection_callback"], "reset_false_then_recompute")
        self.assertEqual(ingress["cpa_wire_terminal"], "preserve_if_lite_and_selected_codex")
        self.assertEqual(ingress["internal_completed_output"], "restored_independently_of_wire")
        self.assertEqual(ingress["authority"], "none")
        self.assertEqual(ingress["same_boundary_test_refs"], ["codex-ws-forward-test"])

    def test_original_seven_partial_proofs_are_retained_with_two_codex_chain_gaps(self):
        partial = {row["id"] for row in self.value["rows"] if row["source_assessment"] == "partial"}
        self.assertEqual(partial, {
            "claude-oauth", "claude-thinking", "claude-reject-media", "codex-isolation",
            "devin-multimodal", "devin-models", "devin-persisted-isolation",
            "codex-sse", "codex-ws",
        })
        for row_id in partial:
            self.assertTrue(self.row(row_id)["blockers"])

    def test_codex_boundary_claims_cannot_be_promoted_to_whole_gateway_support(self):
        mutations = [
            ("expected_reference", "supported"),
            ("observation_boundary", "executor_stream_chunks"),
            ("full_chain_source_status", "qualified"),
            ("authority", "history_cursor_receipt"),
            ("same_boundary_test_refs", ["codex-native-assertion"]),
        ]
        for row_id in ("codex-sse", "codex-ws"):
            for field, value in mutations:
                with self.subTest(row=row_id, field=field):
                    self.value = copy.deepcopy(self.valid)
                    case = self.case(row_id)
                    target = case if field == "expected_reference" else \
                        case["stimulus"]["parameters"]["ingress_requirements"]
                    target[field] = value
                    self.invalid("Codex|unresolved source")

    def test_executor_native_evidence_cannot_claim_a_downstream_route(self):
        for field, value in (("downstream_transport", "http_sse"),
                             ("upstream_transport", ["downstream_websocket"]),
                             ("execution_status", "passed")):
            with self.subTest(field=field):
                self.value = copy.deepcopy(self.valid)
                executor = self.case("codex-sse")["stimulus"]["parameters"]["executor_source_evidence"]
                executor[field] = value
                self.invalid("Codex")

    def test_codex_selectors_and_same_boundary_source_refs_cannot_be_dropped(self):
        for row_id in ("codex-sse", "codex-ws"):
            for field in ("selector_conditions", "source_refs", "same_boundary_test_refs"):
                with self.subTest(row=row_id, field=field):
                    self.value = copy.deepcopy(self.valid)
                    ingress = self.case(row_id)["stimulus"]["parameters"]["ingress_requirements"]
                    ingress[field] = {}
                    self.invalid("Codex")
        self.value = copy.deepcopy(self.valid)
        selectors = self.case("codex-ws")["stimulus"]["parameters"]["ingress_requirements"]["selector_conditions"]
        selectors["selected_auth_provider"] = "any"
        self.invalid("Codex")

    def test_executor_assertions_cannot_be_reused_as_ingress_requirements(self):
        for row_id in ("codex-sse", "codex-ws"):
            for assertion in contract.CODEX_EXECUTOR_ASSERTIONS:
                with self.subTest(row=row_id, assertion=assertion):
                    self.value = copy.deepcopy(self.valid)
                    self.case(row_id)["assertions"].append(assertion)
                    self.invalid("executor assertion at assembled ingress")

    def test_codex_chain_hops_cannot_be_removed_or_used_as_receipt_qualification(self):
        for row_id in ("codex-sse", "codex-ws"):
            for source_id in contract.CODEX_CHAIN_REFS:
                with self.subTest(row=row_id, source=source_id):
                    self.value = copy.deepcopy(self.valid)
                    ingress = self.case(row_id)["stimulus"]["parameters"]["ingress_requirements"]
                    ingress["source_refs"].remove(source_id)
                    self.invalid("same-boundary sources")
            for qualification in ("receipt_qualification", "continuation_qualification"):
                self.value = copy.deepcopy(self.valid)
                self.case(row_id)["stimulus"]["parameters"][qualification] = "qualified"
                self.invalid("no receipt/history/cursor qualification")

    def test_reviewed_codex_source_anchors_remain_exact(self):
        anchors = {
            "codex-sse-repair-test": (127, 157,
                "c9d38f40aae045f59bc0c94630d27b0be5774e21db09cac8a39c49d828b9b707",
                "1ca070f11a27d897308e2a0023b5f5fd1240c0528507712a86fbf8eee17ed434"),
            "codex-sse-metadata-test": (600, 624,
                "c9d38f40aae045f59bc0c94630d27b0be5774e21db09cac8a39c49d828b9b707",
                "96cc7767da4577ae140124e897f96e03db2758ca67d7eb56bde147fd9a386105"),
            "codex-ws-selector": (683, 758,
                "a48aec8c44dc88e83fad7a56408664f9bdb5a2fcab57421dec2658f4369efd0a",
                "57a374adf27880890dec1ac8e8d03a89d492b8c4ce45c5d6361fb2a9566c65c3"),
            "codex-ws-forward": (153, 190,
                "425dfed513699e2932eeec72423f5a807106489990ff9cdd700ac28cc1b8b2b1",
                "072745a145ef9289b259c49384749eb753920aec75779b2915095747be84e18c"),
            "codex-ws-forward-test": (2487, 2603,
                "fcf4dd39eb57cc496b9096b0c7e4223c83d0c904e07d2cd7abb4f579b4924cfc",
                "f5dfdf4779c70da30acdbe62d3edb19a663bd774e19c286550ea44cb2f5b20ba"),
        }
        for source_id, expected in anchors.items():
            with self.subTest(source=source_id):
                source = self.valid["sources"][source_id]
                self.assertEqual((source["start_line"], source["end_line"],
                                  source["file_sha256"], source["quote_sha256"]), expected)

    def test_every_sse_request_and_whole_request_variant_sets_stream_true(self):
        for case in self.value["cases"].values():
            if case["route"]["transport"] == "sse":
                for request in [case["stimulus"]["request"], *case["stimulus"]["variants"]]:
                    self.assertIs(request.get("stream"), True)
        for case_id, original in self.valid["cases"].items():
            if original["route"]["transport"] != "sse":
                continue
            for index in range(1 + len(original["stimulus"]["variants"])):
                for stream in (None, False, 1, "true"):
                    with self.subTest(case=case_id, request=index, stream=stream):
                        self.value = copy.deepcopy(self.valid)
                        stimulus = self.value["cases"][case_id]["stimulus"]
                        request = ([stimulus["request"], *stimulus["variants"]])[index]
                        if stream is None:
                            request.pop("stream", None)
                        else:
                            request["stream"] = stream
                        self.invalid("SSE request must set stream=true")

    def test_duplicate_nonfinite_utf8_size_depth_and_surrogates_fail_closed(self):
        for raw in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}',
                    b'{"x":-Infinity}', b'{"x":1e309}', b'{"x":-1e309}',
                    b'{"x":[{"nested":1e309}]}', b'[-1e309]', b'{"x":"\\ud800"}',
                    b"\xff", b"[" + b" " * 1024 * 1024,
                    b"[" * 1000 + b"0" + b"]" * 1000):
            with self.subTest(raw_size=len(raw)), self.assertRaises(contract.ContractError):
                contract.decode(raw)
        with self.assertRaises(contract.ContractError):
            contract.decode("{}")

    def test_direct_validation_rejects_non_json_and_nested_nonfinite(self):
        for invalid in (float("inf"), float("-inf"), float("nan"),
                        (1, 2), {1: "not_a_json_key"}, "\ud800"):
            for field in ("request", "variants", "parameters"):
                with self.subTest(value=repr(invalid), field=field):
                    self.value = copy.deepcopy(self.valid)
                    stimulus = self.case("codex-sse")["stimulus"]
                    nested = {"nested": [{"value": invalid}]}
                    if field == "variants":
                        stimulus[field].append(nested)
                    else:
                        stimulus[field]["synthetic_negative"] = nested
                    self.invalid()

    def test_cli_serialization_cannot_emit_nonfinite_json(self):
        for nonfinite in (float("inf"), float("-inf"), float("nan")):
            with mock.patch("contract.summary", return_value={"nested": [nonfinite]}), \
                    contextlib.redirect_stdout(io.StringIO()) as out, \
                    contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(contract.main(["validate"]), 1)
                self.assertEqual(out.getvalue(), "")
                self.assertIn("nonfinite", err.getvalue())

    def test_finite_numbers_are_not_normalized(self):
        self.assertEqual(contract.decode(b'{"x":[1e308,-1e308,0.5]}'),
                         {"x": [1e308, -1e308, 0.5]})
        self.case("codex-sse")["stimulus"]["parameters"]["synthetic_finite"] = [1e308, 0.5]
        contract.validate_contract(self.value)

    def test_unknown_schema_extra_fields_and_malformed_types_fail(self):
        for key, value in (("schema", "mimic.final-parity-contract/v2"), ("status", "passed"),
                           ("rows", None), ("sources", []), ("cases", False), ("cpa", None)):
            with self.subTest(key=key):
                self.value = copy.deepcopy(self.valid)
                self.value[key] = value
                self.invalid()

    def test_pins_service_identity_and_history_cannot_float(self):
        for field in ("revision", "archive_sha256", "drift_revision", "drift_archive_sha256"):
            self.value = copy.deepcopy(self.valid)
            self.value["cpa"][field] = "0" * 64
            self.invalid("CPA pin")
        self.value = copy.deepcopy(self.valid)
        self.value["cpa"]["actual_service_identity"] = contract.CPA
        self.invalid("not qualified")
        for field, value in (("required_rows", 36), ("release_passed", 1),
                             ("source_pending_rows", 0), ("release_passed", False)):
            self.value = copy.deepcopy(self.valid)
            self.value["historical"][field] = value
            self.invalid("retained")

    def test_missing_or_duplicate_rows_and_tuples_are_denied(self):
        removed = self.value["rows"].pop()
        self.value["cases"].pop(removed["case_ids"][0])
        self.invalid("missing historical")
        self.value = copy.deepcopy(self.valid)
        self.value["rows"].append(copy.deepcopy(self.value["rows"][0]))
        self.invalid("duplicate row")
        self.value = copy.deepcopy(self.valid)
        for field in contract.TUPLE:
            self.row("claude-messages")[field] = self.row("claude-models")[field]
        self.invalid("duplicate capability")

    def test_historical_tuples_fixture_pointers_exclusions_and_required_are_immutable(self):
        for field, value in (("auth_mode", "oauth"), ("fixture", "test/parity/fixtures/chat-v1.json"),
                             ("historical_source_status", "pending"), ("required", 1)):
            self.value = copy.deepcopy(self.valid)
            self.row("claude-models")[field] = value
            self.invalid()
        for axis in contract.EVIDENCE_DEFAULTS:
            self.value = copy.deepcopy(self.valid)
            self.row("claude-models")["evidence"][axis] = "passed"
            self.invalid("not execution")
        self.value = copy.deepcopy(self.valid)
        self.value["exclusions"].pop()
        self.invalid("exclusions")

    def test_partial_applicability_cannot_lose_blockers_or_claim_support(self):
        for blockers in ([], ["invented-blocker"]):
            self.value = copy.deepcopy(self.valid)
            self.row("claude-oauth")["blockers"] = blockers
            self.invalid()
        for row_id in ("claude-oauth", "claude-reject-media", "devin-models"):
            self.value = copy.deepcopy(self.valid)
            self.case(row_id)["expected_reference"] = "supported"
            self.invalid("unresolved source")

    def test_source_refs_hashes_spans_quotes_and_paths_are_bound(self):
        for refs in ([], ["invented-source"]):
            self.value = copy.deepcopy(self.valid)
            self.row("claude-models")["source_refs"] = refs
            self.invalid()
        for field, value in (("quote", "invented\n"), ("start_line", True),
                             ("file_sha256", "bad"), ("path", "../../operator-secrets")):
            self.value = copy.deepcopy(self.valid)
            self.value["sources"]["routes"][field] = value
            self.invalid()

    def test_optional_source_verification_rejects_file_and_excerpt_tamper(self):
        with self.synthetic_sources() as source_root:
            contract.validate_contract(self.value, source_dir=source_root)
            source = self.value["sources"]["routes"]
            source["quote"] = "// SYNTHETIC wrong excerpt\n"
            source["quote_sha256"] = contract.digest(source["quote"].encode())
            with self.assertRaisesRegex(contract.ContractError, "source excerpt drift"):
                contract.validate_contract(self.value, source_dir=source_root)
        self.value = copy.deepcopy(self.valid)
        with self.synthetic_sources() as source_root:
            source = self.value["sources"]["routes"]
            (source_root / source["path"]).write_bytes(b"// SYNTHETIC changed\n")
            with self.assertRaisesRegex(contract.ContractError, "source file drift"):
                contract.validate_contract(self.value, source_dir=source_root)

    def test_lock_manifest_and_fixture_bytes_cannot_be_rebound(self):
        for name in (contract.CLIENTS_PATH, contract.HISTORICAL_PATH, self.row("claude-models")["fixture"]):
            self.value = copy.deepcopy(self.valid)
            with self.copied_inputs() as root:
                path = root / name
                path.write_bytes(path.read_bytes() + b"\n")
                if name == self.row("claude-models")["fixture"]:
                    self.row("claude-models")["fixture_sha256"] = contract.digest(path.read_bytes())
                with self.assertRaises(contract.ContractError):
                    contract.validate_contract(self.value, root)

    def test_path_traversal_symlinks_large_files_and_fifo_are_denied_before_read(self):
        self.row("claude-models")["fixture"] = "../../operator-secrets"
        self.invalid()
        with self.copied_inputs() as root:
            path = root / contract.CLIENTS_PATH
            actual = path.with_name("synthetic-lock-copy.json")
            path.rename(actual)
            path.symlink_to(actual.name)
            with self.assertRaisesRegex(contract.ContractError, "symlink input"):
                contract.load_contract(root)
            path.unlink()
            with path.open("wb") as output:
                output.truncate(contract.MAX_FILE_BYTES + 1)
            with self.assertRaisesRegex(contract.ContractError, "bounded regular"):
                contract.load_contract(root)
            if hasattr(os, "mkfifo"):
                path.unlink()
                os.mkfifo(path)
                with self.assertRaisesRegex(contract.ContractError, "bounded regular"):
                    contract.load_contract(root)

    def test_primary_case_route_version_identity_assertions_and_errors_are_checked(self):
        self.row("claude-models")["case_ids"] = ["claude-messages.final-v1"]
        self.invalid("missing primary")
        self.value = copy.deepcopy(self.valid)
        self.value["cases"]["orphan.final-v1"] = copy.deepcopy(self.case("claude-models"))
        self.invalid("orphan")
        for field, value in (("version", True), ("row_id", "codex-http"),
                             ("assertions", []), ("errors", []), ("stimulus", "assume parity")):
            self.value = copy.deepcopy(self.valid)
            self.case("claude-models")[field] = value
            self.invalid()
        self.value = copy.deepcopy(self.valid)
        self.case("claude-models")["route"]["path"] = "/v1/responses"
        self.invalid("wrong primary route")
        self.value = copy.deepcopy(self.valid)
        self.case("claude-models")["route"]["transport"] = "h2-proof"
        self.invalid("route")

    def test_auth_error_envelope_and_zero_upstream_requests_cannot_be_weakened(self):
        for field, value in (("status", 200), ("body", {}), ("upstream_requests", False)):
            self.value = copy.deepcopy(self.valid)
            self.value["error_cases"]["missing-client-key"][field] = value
            self.invalid("reference error")

    def test_extension_rows_require_explicit_version_and_keep_37(self):
        row = copy.deepcopy(self.value["rows"][0])
        row.update(id="final-v1-synthetic-extension", capability="synthetic_extension",
                   extension="final-v1-unit-controls", historical_source_status=None,
                   case_ids=["final-v1-synthetic-extension.final-v1"])
        self.value["rows"].append(row)
        case = copy.deepcopy(self.case("claude-models"))
        case["row_id"] = row["id"]
        self.value["cases"][row["case_ids"][0]] = case
        self.invalid("unversioned extension")
        self.value["extension_versions"]["final-v1-unit-controls"] = 1
        contract.validate_contract(self.value)
        self.assertEqual(len(self.value["rows"]), 38)
        self.value["extension_versions"]["final-v1-unit-controls"] = True
        self.invalid("extension version")

    def test_operation_inventory_keeps_presence_applicability_and_proof_separate(self):
        operations = contract.select_operations(self.loaded)
        self.assertEqual({operation["id"] for operation in operations}, contract.OPERATION_IDS)
        for operation in operations:
            self.assertEqual(operation["runtime_proof"], "not_run")
            self.assertTrue(operation["source_refs"])
        entries = self.value["operations"]["entries"]
        self.assertEqual(entries["final-v1-kimi-compact-http"]["reference_behavior"]["status"], 501)
        self.assertEqual(entries["final-v1-kimi-compact-sse"]["reference_behavior"]["status"], 400)
        compact = entries["final-v1-kimi-compact-sse"]
        self.assertEqual(compact["observation_boundary"], "compact_handler_before_executor")
        self.assertEqual(compact["reference_behavior"]["response_transport"], "http_json_error")
        self.assertNotEqual(compact["reference_behavior"]["message"],
                            compact["reference_behavior"]["executor_stream_guard"]["message"])
        self.assertEqual(entries["final-v1-grok-http-continuation"]["reference_behavior"]["previous_response_id"], "deleted")
        self.assertEqual(entries["final-v1-xai-video-cancel"]["source_presence"], "absent_core_route")
        self.assertEqual(entries["final-v1-xai-images-sse"]["reference_behavior"]["upstream_operation"], "buffered_image_execution")

    def test_operations_cannot_drop_unsupported_or_pending_scope_to_inflate_coverage(self):
        entries = self.value["operations"]["entries"]
        entries.pop("final-v1-xai-video-cancel")
        self.invalid("missing/unknown")
        for key, value in (("source_presence", "present"), ("applicability", "wave_requirement"),
                           ("runtime_proof", "passed"), ("auth_modes", ["api_key"])):
            self.value = copy.deepcopy(self.valid)
            self.value["operations"]["entries"]["final-v1-kimi-compact-http"][key] = value
            self.invalid()
        self.value = copy.deepcopy(self.valid)
        self.value["operations"]["denominator_effect"] = "replace_historical37"
        self.invalid("denominator")

    def test_operation_pinned_rejections_wire_policy_and_whole_sse_request(self):
        for operation_id, field, value in (
                ("final-v1-kimi-compact-http", "status", 200),
                ("final-v1-kimi-compact-http", "upstream_requests", False),
                ("final-v1-grok-http-continuation", "previous_response_id", "forwarded"),
                ("final-v1-grok-http-continuation", "compact_or_ws_does_not_qualify", 1),
                ("final-v1-codex-executor-lite", "stream", 1),
                ("final-v1-xai-video-cancel", "cancel_action", "supported")):
            self.value = copy.deepcopy(self.valid)
            operation = self.value["operations"]["entries"][operation_id]
            operation["reference_behavior"][field] = value
            self.invalid()
        self.value = copy.deepcopy(self.valid)
        self.value["operations"]["entries"]["final-v1-kimi-messages-sse"]["stimulus"]["stream"] = False
        self.invalid("SSE request")

    def test_source_presence_cannot_approve_conditional_or_product_scope(self):
        for operation_id in ("final-v1-xai-images-generate", "final-v1-xai-video-create",
                             "final-v1-grok-compact", "final-v1-codex-buffered-lite"):
            with self.subTest(operation=operation_id):
                self.value = copy.deepcopy(self.valid)
                self.value["operations"]["entries"][operation_id]["applicability"] = "wave_requirement"
                self.invalid("applicability")

    def test_kimi_native_responses_and_grok_physical_ws_tools_are_not_omitted_or_lent(self):
        entries = self.valid["operations"]["entries"]
        kimi = entries["final-v1-kimi-responses-sse"]
        self.assertIs(kimi["stimulus"]["stream"], True)
        self.assertEqual(kimi["reference_behavior"]["source_format"], "openai-response")
        grok = entries["final-v1-grok-physical-ws"]
        self.assertEqual(grok["route"]["transport"], "websocket")
        self.assertEqual(grok["source_presence"], "partial")
        self.assertEqual(grok["reference_behavior"]["required_ws_missing"],
                         "explicit_replay_required_error")
        self.assertEqual(grok["reference_behavior"]["codex_lite_selectors"], "not_applicable")
        self.assertIn("grok-ws-chain-source", grok["blockers"])
        tools = entries["final-v1-grok-tool-forms"]
        self.assertEqual(tools["applicability"], "conditional_scope_pending")
        self.assertIn("grok-tool-form-applicability", tools["blockers"])
        self.assertEqual(tools["runtime_proof"], "not_run")

    def test_operation_projections_cannot_lend_codex_wire_or_authority(self):
        for operation_id, field, value in (
                ("final-v1-codex-executor-lite", "downstream_transport", "http_sse"),
                ("final-v1-codex-http-sse-lite", "terminal", "preserve_exact"),
                ("final-v1-codex-ws-lite", "authority", "history_cursor_receipt")):
            with self.subTest(operation=operation_id):
                self.value = copy.deepcopy(self.valid)
                self.value["operations"]["entries"][operation_id]["reference_behavior"][field] = value
                self.invalid("Codex")

    def test_process_and_network_audit_guards_are_active(self):
        import socket
        import subprocess
        import sys
        for event in ("subprocess.Popen", "socket.connect", "socket.sendto", "os.exec", "os.fork"):
            with self.subTest(event=event), self.assertRaises(AssertionError):
                sys.audit(event)
        with self.assertRaises(AssertionError):
            subprocess.Popen(["f01-forbidden-nonexistent-target"])
        with self.assertRaises(AssertionError):
            socket.getaddrinfo("f01-forbidden.invalid", 80)

    def test_cli_validate_inventory_plan_and_invalid_selections(self):
        for args in (["validate"], ["inventory", "--provider", "kimi"],
                     ["plan", "--row", "devin-chat-http"]):
            with self.subTest(args=args), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(contract.main(args), 0)
                self.assertIsInstance(json.loads(out.getvalue()), dict)
        for args in (["plan"], ["inventory", "--provider", "gemini"], ["validate", "--row", "x"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(contract.main(args), 1)


if __name__ == "__main__":
    unittest.main()
