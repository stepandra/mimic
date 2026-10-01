"""Pure F31 case-data/plan controls, loaded inside execution_guards only.

Decoding synthetic strings here checks authored case data, not a provider codec
or the common contract. No protocol/result validator or execution is substituted.
"""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import f31_codex as codex
import safe_unit_tests


class CodexPreparationTest(unittest.TestCase):
    def setUp(self):
        self.value = codex.load_fixture()
        self.first_id = self.value["cases"][0]["id"]

    def case(self, probe):
        return next(case for case in self.value["cases"]
                    if case["id"] == probe + ".final-v1")

    def reject_mutation(self, mutate):
        value = deepcopy(self.value)
        mutate(value)
        with self.assertRaises(ValueError):
            codex.case_plan(value, self.first_id)

    def test_identical_independent_pairs_include_context_and_all_turns(self):
        original = deepcopy(self.value)
        for case in self.value["cases"]:
            with self.subTest(case=case["id"]):
                plan = codex.case_plan(self.value, case["id"])
                expected = {"synthetic_context": self.value["synthetic_context"],
                            **case["stimulus"]}
                self.assertEqual(plan["paired_stimuli"]["cpa"], expected)
                self.assertEqual(plan["paired_stimuli"]["mimic"], expected)
                plan["paired_stimuli"]["cpa"]["turns"][0]["request"]["body"] = "changed"
                plan["paired_stimuli"]["cpa"]["synthetic_context"]["scope"]["tenant"] = "changed"
                self.assertEqual(plan["paired_stimuli"]["mimic"], expected)
                plan["expected"]["scope"] = "changed"
                plan["comparison"]["normalization"].append("changed")
        self.assertEqual(self.value, original)

    def test_raw_target_body_header_order_duplicates_and_case_preserved(self):
        stimulus = codex.case_plan(self.value, self.first_id)["paired_stimuli"]["cpa"]
        turn = stimulus["turns"][0]
        request = turn["request"]
        self.assertEqual(request["target"], "/v1/responses?synthetic=%2f&synthetic=%2F")
        expected_body = (
            '{ "model":"synthetic-model", "stream":false, '
            '"input":[{"role":"user","content":"SYNTHETIC first"},'
            '{"role":"assistant","content":"SYNTHETIC prior"},'
            '{"role":"user","content":"SYNTHETIC café"}], '
            '"synthetic_extension":{"b":2,"a":1} }\n'
        )
        self.assertEqual(request["body"].encode("utf-8"), expected_body.encode("utf-8"))
        self.assertEqual(request["headers"][2:5], [
            ["X-Synthetic", "first"], ["x-synthetic", "mixed-case"],
            ["X-Synthetic", "second"],
        ])
        self.assertEqual(turn["responses"][0]["headers"][1:], request["headers"][2:5])

    def test_sse_chunks_crlf_comments_and_usage_are_not_reframed(self):
        case = self.case("codex-http.wire")
        chunks = codex.case_plan(self.value, case["id"])[
            "paired_stimuli"]["cpa"]["turns"][0]["responses"][0]["body_chunks"]
        self.assertEqual(chunks, case["stimulus"]["turns"][0]["responses"][0]["body_chunks"])
        self.assertTrue(chunks[1].endswith("\r\nda"))
        self.assertTrue(chunks[2].startswith("ta: "))
        self.assertIn(": SYNTHETIC heartbeat\r\n\r\n", chunks[0])
        self.assertIn('"input_tokens_details":{"cached_tokens":2}', chunks[2])
        self.assertIn('"synthetic_usage":{"b":2,"a":1}', chunks[2])

    def test_provisional_mappings_use_historical_ids_without_common_import(self):
        historical = json.loads((codex.ROOT / codex.HISTORICAL).read_text())
        rows = {row["id"] for row in historical["capabilities"] if row["provider"] == "codex"}
        self.assertEqual({case["row_id"] for case in self.value["cases"]}, rows)
        self.assertEqual(self.value["cpa_revision"], historical["cpa_revision"])
        for case in self.value["cases"]:
            plan = codex.case_plan(self.value, case["id"])
            self.assertEqual(case["primary_case_id"], case["row_id"] + ".final-v1")
            self.assertTrue(case["id"].endswith(".final-v1"))
            self.assertNotEqual(case["id"], case["primary_case_id"])
            self.assertEqual(plan["f01_mapping"], "provisional_pending")
            self.assertEqual(plan["approval"], codex.APPROVAL)
            self.assertNotEqual(plan["schema"], "mimic.final-parity-plan/v1")
        self.assertFalse(hasattr(codex, "ROW_IDS"))
        self.assertEqual(self.value["provenance"], "SYNTHETIC")

    def test_every_plan_blocked_not_run_missing_bindings_and_hard_blockers(self):
        for case in self.value["cases"]:
            plan = codex.case_plan(self.value, case["id"])
            self.assertEqual(plan["status"], "blocked")
            self.assertEqual(plan["execution_status"], "not_run")
            self.assertEqual(plan["assertion_execution"], "not_run")
            self.assertEqual(plan["normalization"], [])
            self.assertTrue(set(codex.REQUIRED_OBSERVATIONS).issubset(plan["planned_assertions"]))
            for dependency in ("F03", "F11", "F12", "F13"):
                self.assertIn("dependency_not_admitted:" + dependency, plan["blockers"])
            self.assertTrue(set(codex.HARD_BLOCKERS).issubset(plan["blockers"]))
            self.assertIn("f11_admission_withheld_partial_packet_not_merged", plan["blockers"])
            self.assertIn("proposed_provider_cases_not_approved_runtime_fixtures", plan["blockers"])
            self.assertTrue(all(item is None for item in plan["future_result_hashes"].values()))
            self.assertNotIn("passed", plan)
            self.assertNotIn("observations", plan)

    def test_report_local_checksums_not_verified_runtime_or_shipment_hashes(self):
        report = codex.blocked_report()
        self.assertEqual(report["historical_strict37"], "0/37_unchanged")
        self.assertEqual(report["status"], "blocked")
        for key in ("execution_status", "paired_execution", "cpa_execution",
                    "mimic_execution", "live_verified"):
            self.assertEqual(report[key], "not_run")
        self.assertEqual(report["hash_binding_status"], "unknown_not_verified")
        self.assertEqual(set(report["future_result_hashes"]), set(codex.HASH_ROLES))
        self.assertTrue(all(item is None for item in report["future_result_hashes"].values()))
        for path, digest in report["local_file_sha256"].items():
            self.assertEqual(digest, hashlib.sha256((codex.ROOT / path).read_bytes()).hexdigest())
        self.assertEqual(len(report["cases"]), len(self.value["cases"]))
        self.assertEqual(len(codex.blocked_report(scenario_id=self.first_id)["cases"]), 1)

    def test_http_history_replay_keeps_chronology_reasoning_tools_and_difference(self):
        case = self.case("codex-http.history-replay")
        stimulus = codex.case_plan(self.value, case["id"])["paired_stimuli"]["cpa"]
        self.assertEqual(len(stimulus["turns"]), 3)
        self.assertEqual(stimulus["parameters"]["third_turn_input_order"], [
            "initial_input", "response_1.output", "tool_result_input",
            "response_2.output", "third_input",
        ])
        first_output = "".join(stimulus["turns"][0]["responses"][0]["body_chunks"])
        self.assertIn('"encrypted_content":"synthetic-opaque-reasoning"', first_output)
        self.assertIn('"reasoning_tokens":2', first_output)
        self.assertIn('"call_id":"synthetic-call-1"', first_output)
        followup = json.loads(stimulus["turns"][1]["request"]["body"])
        self.assertEqual(followup["previous_response_id"], "synthetic-r-1")
        self.assertEqual(followup["input"][0]["type"], "function_call_output")
        self.assertEqual(case["expected"]["mimic_http"], "safe_full_history_replay_then_delete_id")
        self.assertEqual(case["expected"]["cpa_http"], "delete_id_without_replay")
        self.assertEqual(case["difference"]["status"], "decision_required")
        self.assertEqual(case["difference"]["normalization"], [])

    def test_caller_history_claims_and_item_reference_are_not_receipts(self):
        case = self.case("codex-http.missing-receipt")
        turns = case["stimulus"]["turns"]
        self.assertTrue(json.loads(turns[1]["request"]["body"])["full_history"])
        self.assertEqual(json.loads(turns[2]["request"]["body"])["input"][0]["type"],
                         "item_reference")
        self.assertTrue(all(turn["responses"] == [] for turn in turns))
        self.assertEqual(case["expected"]["send_state"], "NotSent")
        self.assertEqual(case["expected"]["retry"], "never")

    def test_scope_and_restart_data_bind_private_revision_not_caller_hints(self):
        scoped = self.case("codex-isolation.scope-bindings")["stimulus"]
        fields = {field for change in scoped["parameters"]["scope_changes"] for field in change}
        self.assertEqual(fields, set(self.value["synthetic_context"]["scope"])
                         - {"connection_generation"})
        self.assertEqual(scoped["parameters"]["expected_upstream_requests_per_denial"], 0)
        restart = self.case("codex-http.restart")
        self.assertEqual(restart["expected"]["receipt"], "nonpersistent")
        turns = restart["stimulus"]["turns"]
        self.assertEqual(turns[1]["responses"], [])
        self.assertIn("previous_response_id", json.loads(turns[1]["request"]["body"]))
        self.assertNotIn("previous_response_id", json.loads(turns[2]["request"]["body"]))
        self.assertEqual(restart["difference"]["status"], "decision_required")

    def test_compact_lite_http_and_ws_are_separate_not_catalog_or_flag_inferred(self):
        self.assertEqual({case["stimulus"]["path_kind"] for case in self.value["cases"]},
                         {"http", "compact", "lite", "websocket"})
        compact = self.case("codex-compact.separate-operation")["stimulus"]
        self.assertTrue(compact["turns"][0]["request"]["target"].endswith("/compact"))
        self.assertTrue(compact["parameters"]["http_continuation_wrapper_does_not_accept_compact"])
        lite = self.case("codex-sse.lite-header")["stimulus"]
        self.assertEqual(lite["codec_policy"], "Strict")
        self.assertEqual(lite["parameters"]["upstream_target"], "/backend-api/codex/responses")
        self.assertIs(lite["parameters"]["expected_parallel_tool_calls"], False)
        body = json.loads(lite["turns"][0]["request"]["body"])
        self.assertEqual(body["tools"][0]["type"], "custom")
        self.assertEqual(body["additional_tools"][0]["type"], "namespace")
        markers = self.case("codex-sse.lite-markers")["stimulus"]
        self.assertTrue(markers["parameters"]["normal_not_inferred_from_catalog_use_responses_lite"])
        self.assertEqual(markers["codec_policy"], "Strict")
        self.assertEqual(self.case("codex-ws.lite-unsupported")["expected"]["send_state"], "NotSent")

    def test_sparse_terminal_identical_in_both_policy_probes_remains_blocked(self):
        strict = self.case("codex-sse.sparse-strict")
        reconstruct = self.case("codex-sse.sparse-reconstruct")
        self.assertEqual(strict["stimulus"]["turns"][0]["responses"],
                         reconstruct["stimulus"]["turns"][0]["responses"])
        for case in (strict, reconstruct):
            chunks = case["stimulus"]["turns"][0]["responses"][0]["body_chunks"]
            self.assertNotIn('"type":"response.created"', "".join(chunks))
            self.assertNotIn('"type":"response.output_item.added"', "".join(chunks))
            done = json.loads(chunks[0].removeprefix("data: ").strip())
            terminal = json.loads(chunks[1].removeprefix("data: ").strip())["response"]
            self.assertTrue(done["item"]["content"])
            self.assertEqual(terminal["output"], [])
            self.assertNotIn("object", terminal)
            plan = codex.case_plan(self.value, case["id"])
            self.assertEqual(plan["status"], "blocked")
            self.assertEqual(plan["expected"]["receipt"], "none")
            self.assertEqual(plan["difference"]["status"], "decision_required")
        self.assertEqual(reconstruct["stimulus"]["parameters"]["f11_status"],
                         "admission_withheld_fetched_not_merged_partial")
        self.assertEqual(reconstruct["stimulus"]["parameters"]["transparent_raw_native_policy"],
                         "hold_fullpath_review_no_gateway_projection_approval")
        for case in (strict, reconstruct):
            self.assertIn("assembled_output_framer_source_path_review_hold",
                          codex.case_plan(self.value, case["id"])["blockers"])

    def test_native_streaming_bootstrap_and_nonstream_hydration_not_conflated(self):
        bootstrap = self.case("codex-sse.streaming-bootstrap")["stimulus"]
        nonstream = self.case("codex-http.nonstream-hydration")["stimulus"]
        self.assertTrue(json.loads(bootstrap["turns"][0]["request"]["body"])["stream"])
        self.assertFalse(json.loads(nonstream["turns"][0]["request"]["body"])["stream"])
        self.assertEqual(bootstrap["parameters"]["stream_bootstrap_buffering_values"], [False, True])
        self.assertTrue(bootstrap["parameters"]["does_not_cover_nonstreaming_buffered_http"])
        self.assertEqual(bootstrap["parameters"]["source_test_transport_axis"], "upstream_http_or_ws")
        self.assertEqual(bootstrap["parameters"]["downstream_route"],
                         "/v1/responses_assembled_projection_unqualified")
        self.assertEqual(nonstream["parameters"]["supplied_terminal_only_extension"],
                         "unapproved_disabled_not_denominator_not_parity")
        self.assertIn("unconditional_patchCodexCompletedOutput",
                      nonstream["parameters"]["pinned_execute"])
        for probe in ("codex-sse.sparse-strict", "codex-sse.sparse-reconstruct"):
            self.assertTrue(json.loads(self.case(probe)["stimulus"]["turns"][0]["request"]["body"])[
                "stream"])
        self.assertEqual(self.case("codex-http.nonstream-hydration")["difference"]["status"],
                         "decision_required")

    def test_ws_exact_frames_preserve_previous_id_and_standalone_does_not_inherit(self):
        case = self.case("codex-ws.same-socket-history")
        plan = codex.case_plan(self.value, case["id"])
        stimulus = plan["paired_stimuli"]["cpa"]
        turn = stimulus["turns"][0]
        frames = turn["request"]["text_frames"]
        self.assertEqual(frames, case["stimulus"]["turns"][0]["request"]["text_frames"])
        self.assertTrue(frames[0].startswith('{ "type"'))
        self.assertFalse(json.loads(frames[0])["generate"])
        self.assertEqual(json.loads(frames[2])["previous_response_id"], "synthetic-ws-1")
        self.assertNotIn("previous_response_id", json.loads(frames[3]))
        self.assertEqual(sum(stimulus["parameters"]["exchange_response_frame_counts"]),
                         len(turn["responses"][0]["text_frames"]))
        self.assertEqual(stimulus["parameters"]["normal_close"], {
            "code": 1000, "reason": "SYNTHETIC done",
        })
        replacement = self.case("codex-ws.socket-replacement")
        self.assertEqual(replacement["stimulus"]["parameters"]["upstream_create_frames_per_denial"], 0)
        self.assertEqual(replacement["difference"]["status"], "decision_required")

    def test_cancel_uncertain_and_trailing_terminal_never_claim_receipt_or_retry(self):
        for probe in ("cancel", "uncertain-terminal", "trailing-corruption"):
            case = self.case("codex-lifecycle." + probe)
            self.assertEqual(case["expected"]["receipt"], "none")
            self.assertEqual(case["expected"]["retry"], "never")
            self.assertEqual(case["expected"]["send_state"], "Started")
        uncertain = self.case("codex-lifecycle.uncertain-terminal")["stimulus"]
        self.assertEqual(uncertain["parameters"]["original_transport_status"], [200, 503, 200])
        self.assertEqual(uncertain["parameters"]["relabel_inband_200_as_429"], "forbidden")
        trailing = self.case("codex-lifecycle.trailing-corruption")["stimulus"]
        self.assertTrue(trailing["turns"][0]["responses"][0]["body_chunks"][-1].endswith(
            "{SYNTHETIC malformed}\n\n"))

    def test_error_helper_intent_is_not_assembled_scope_or_failover_evidence(self):
        request = self.case("codex-http.request-errors")
        self.assertEqual(request["expected"]["baseline_http_adapter"], "no_typed_header_rejection")
        quota = self.case("codex-quota.reset-units")["stimulus"]["parameters"]
        self.assertEqual(quota["proposed_provider_categories"], [
            "AccountQuota", "AccountQuota", "ModelCapacity", "RateLimit",
        ])
        self.assertEqual(quota["baseline_header_only_failure"], "Quota/Rejected_for_all_429")
        self.assertEqual(quota["baseline_header_only_delay_ms"], [None, None, 17000, None])
        self.assertEqual(quota["proposed_delay_ms_at_clock_1000"], [17000, 17000, 17000, None])
        failover = self.case("codex-quota.auth-failover")
        self.assertEqual([response["credential_slot"] for response in
                          failover["stimulus"]["turns"][0]["responses"]],
                         ["synthetic-a", "synthetic-b"])
        self.assertEqual(failover["expected"]["retry"], "eligible_before_output_only_not_admitted")

    def test_caps_and_default_off_are_data_only_no_large_boundary_allocation(self):
        context = self.value["synthetic_context"]
        self.assertEqual(context["baseline_http_continuation"], "default_off_bounded")
        self.assertEqual(context["codec_limits"], codex.CODEC_LIMITS)
        self.assertEqual(context["policy_selection"], "trusted_admitted_route_only")
        bounds = self.case("codex-http.bounded-retention")["stimulus"]["parameters"]
        self.assertEqual(bounds["baseline_cache_limits"], {
            "count": 32, "total_bytes": 8388608, "entry_bytes": 2097152, "ttl_ms": 900000,
        })
        self.assertTrue(bounds["no_large_allocations_or_generated_event_streams"])
        for key, cap in codex.CODEC_LIMITS.items():
            self.assertEqual(bounds["boundary_probes"][key], [cap, cap + 1])
            for invalid in (cap + 1, 0, True):
                with self.subTest(key=key, invalid=invalid):
                    self.reject_mutation(lambda value: value["synthetic_context"][
                        "codec_limits"].update({key: invalid}))

    def test_no_caller_hash_or_admission_can_remove_blockers(self):
        for key, invalid in (("approval", "approved"), ("cpa_revision", "unknown"),
                             ("mimic_base_revision", "unknown")):
            self.reject_mutation(lambda value: value.update({key: invalid}))
        self.reject_mutation(lambda value: value.update(future_result_hashes={
            name: "a" * 64 for name in codex.HASH_ROLES}))
        self.reject_mutation(lambda value: value.update(allow_execution=True))
        self.reject_mutation(lambda value: value["dependencies"].update(F12="admitted"))
        self.reject_mutation(lambda value: value["synthetic_context"].update(route_admission="admitted"))
        self.reject_mutation(lambda value: value["synthetic_context"].update(policy_selection="caller_lite"))
        # Even a hash-looking proposal in arbitrary provider parameters grants nothing.
        value = deepcopy(self.value)
        value["cases"][0]["stimulus"]["parameters"]["caller_hashes"] = {
            name: "a" * 64 for name in codex.HASH_ROLES}
        plan = codex.case_plan(value, self.first_id)
        self.assertEqual(plan["status"], "blocked")
        self.assertTrue(all(item is None for item in plan["future_result_hashes"].values()))
        self.assertTrue(set(codex.HARD_BLOCKERS).issubset(plan["blockers"]))

    def test_unknown_lifecycle_transport_binary_lossy_headers_and_normalization_rejected(self):
        for field, invalid in (("transport", "http/2"), ("transport", "grpc"),
                               ("codec_policy", "CallerLite"), ("path_kind", "native_sparse")):
            self.reject_mutation(lambda value: value["cases"][0]["stimulus"].update({field: invalid}))
        request = lambda value: value["cases"][0]["stimulus"]["turns"][0]["request"]
        self.reject_mutation(lambda value: request(value).update(target="https://localhost:8317/v1/responses"))
        self.reject_mutation(lambda value: request(value).update(target="/v1/responses/lite"))
        self.reject_mutation(lambda value: request(value).update(body=b"binary"))
        self.reject_mutation(lambda value: request(value).update(text_frames=["SYNTHETIC mixed transport"]))
        self.reject_mutation(lambda value: request(value).update(headers={"X-Synthetic": "last"}))
        for headers in ([["Content-Encoding", "gzip"]], [["X-Synthetic", "bad\r\ninjection"]]):
            self.reject_mutation(lambda value: request(value).update(headers=headers))
        self.reject_mutation(lambda value: value["comparison"].update(normalization=["sort_headers"]))
        self.reject_mutation(lambda value: value["cases"][0]["difference"].update(status="matched"))
        self.reject_mutation(lambda value: value["cases"][0]["difference"].update(normalization=["hydrate"]))
        with self.assertRaises(ValueError):
            codex.case_plan(self.value, "codex-http.final-v1")

    def test_duplicate_envelope_keys_reject_but_duplicate_raw_provider_json_preserved(self):
        for raw in (b'{"slice":"F31","sl\\u0069ce":"F31"}', b"\xff"):
            with self.subTest(raw=raw), patch.object(Path, "read_bytes", return_value=raw):
                with self.assertRaises((ValueError, UnicodeError)):
                    codex.load_fixture()
        value = deepcopy(self.value)
        raw = '{"model":"synthetic-first","mo\\u0064el":"synthetic-second"}\n'
        value["cases"][0]["stimulus"]["turns"][0]["request"]["body"] = raw
        plan = codex.case_plan(value, self.first_id)
        for stimulus in plan["paired_stimuli"].values():
            self.assertEqual(stimulus["turns"][0]["request"]["body"], raw)

    def test_cli_prepares_with_nonzero_status_and_no_execution_or_hash_options(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = codex.main(["--case", self.first_id])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["status"], "blocked")
        output = io.StringIO()
        with redirect_stdout(output):
            code = codex.main(["--case", "unknown"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["paired_execution"], "not_run")
        for args in (["--run"], ["--endpoint", "https://localhost:8317"], ["--hashes", "a" * 64]):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                codex.main(args)
            self.assertEqual(error.exception.code, 2)

    def test_missing_payload_is_sanitized_rejection_not_automatic_pass(self):
        output = io.StringIO()
        with patch.object(Path, "read_bytes", side_effect=OSError("synthetic-private-detail")):
            with redirect_stdout(output):
                code = codex.main([])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["status"], "rejected")
        self.assertNotIn("synthetic-private-detail", output.getvalue())

    def test_execution_guard_controls_are_audit_events_not_actual_process_or_network(self):
        with safe_unit_tests.execution_guards():
            for event in ("subprocess.Popen", "os.exec", "os.fork", "os.posix_spawn",
                          "socket.connect", "socket.bind", "socket.getaddrinfo", "socket.sendto"):
                with self.subTest(event=event), self.assertRaises(AssertionError):
                    sys.audit(event, "SYNTHETIC guard control")
