"""F32 case-data tests; load and run only under execution_guards.

JSON decoding here checks the authored synthetic payload, never a provider
codec, F01 contract, external endpoint or CPA/MIMIC comparison.
"""
import ast
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import f32_kimi as kimi
import safe_unit_tests


class KimiPreparationTest(unittest.TestCase):
    def setUp(self):
        self.value = kimi.load_fixture()
        self.first_id = self.value["cases"][0]["id"]

    def case(self, probe):
        return next(case for case in self.value["cases"]
                    if case["id"] == probe + ".final-v1")

    def reject_mutation(self, mutate):
        value = deepcopy(self.value)
        mutate(value)
        with self.assertRaises(ValueError):
            kimi.case_plan(value, self.first_id)

    def test_identical_independent_pairs_copy_context_registrations_and_all_turns(self):
        original = deepcopy(self.value)
        for case in self.value["cases"]:
            with self.subTest(case=case["id"]):
                expected = {
                    "synthetic_context": self.value["synthetic_context"],
                    "registrations": self.value["registrations"], **case["stimulus"],
                }
                plan = kimi.case_plan(self.value, case["id"])
                self.assertEqual(plan["paired_stimuli"]["cpa"], expected)
                self.assertEqual(plan["paired_stimuli"]["mimic"], expected)
                cpa = plan["paired_stimuli"]["cpa"]
                cpa["turns"][0]["request"]["body"] = "changed"
                cpa["synthetic_context"]["credential_slots"][0] = "changed"
                cpa["registrations"]["kimi"]["auth_modes"].append("changed")
                cpa["controls"]["changed"] = True
                plan["comparison"]["normalization"].append("changed")
                plan["expected"]["scope"] = "changed"
                plan["peer_f15_checkpoint"]["reported_gates"]["focused_tests"] = 0
                plan["dependencies"]["F15"] = "changed"
                self.assertEqual(plan["paired_stimuli"]["mimic"], expected)
                self.assertEqual(kimi.PEER_F15["reported_gates"]["focused_tests"], 22)
                self.assertEqual(kimi.DEPENDENCIES["F15"], "peer_reported_admitted_not_imported")
        self.assertEqual(self.value, original)

    def test_registration_identity_and_order_not_inferred_from_model_name(self):
        native = self.value["registrations"]["kimi"]
        generic = self.value["registrations"]["openai-compatible-kimi"]
        self.assertEqual(native["auth_modes"], ["api_key", "oauth"])
        self.assertEqual(native["protocols"], ["chat", "responses", "anthropic"])
        self.assertEqual(generic["auth_modes"], ["api_key"])
        self.assertEqual(generic["protocols"], ["chat"])
        self.assertEqual(generic["transform_policy"], "none")
        self.assertEqual((native["default_base_path"], generic["default_base_path"]),
                         ("/coding", "/v1"))
        context = self.value["synthetic_context"]
        self.assertEqual(context["registration_orders"], [
            ["kimi", "openai-compatible-kimi"], ["openai-compatible-kimi", "kimi"],
        ])
        self.assertEqual(context["selected_account"], "synthetic-b")
        self.assertEqual(context["manager_state"], "independent_per_target")
        self.assertEqual(context["target_endpoints"], {"cpa": None, "mimic": None})
        self.assertEqual(self.case("kimi-native.registration-isolation")[
            "stimulus"]["controls"]["generic_fallback"], "forbidden")
        self.assertEqual(self.case("kimi-native.chat-wire-tools")["stimulus"]["selected_model"],
                         self.case("kimi-generic.chat-wire")["stimulus"]["selected_model"])
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"].update(
            registration="openai-compatible-kimi"))
        self.reject_mutation(lambda value: value["registrations"]["openai-compatible-kimi"][
            "auth_modes"].append("oauth"))

    def test_historical_ids_tuples_fixture_hash_and_inherited_checks_unchanged(self):
        raw = (kimi.ROOT / kimi.HISTORICAL).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),
                         "3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9")
        historical = json.loads(raw)
        rows = {row["id"]: row for row in historical["capabilities"]
                if row["provider"] == "kimi"}
        self.assertEqual(set(rows), {"kimi-native", "kimi-generic"})
        fields = ("provider", "auth_mode", "input_protocol", "upstream_mode", "capability")
        self.assertEqual(tuple(rows["kimi-generic"][key] for key in fields),
                         ("kimi", "api_key", "chat_completions", "openai_compatible",
                          "http_backend_identity"))
        self.assertEqual(tuple(rows["kimi-native"][key] for key in fields),
                         ("kimi", "oauth", "responses", "kimi_native", "http_backend_identity"))
        self.assertEqual(self.value["cpa_revision"], historical["cpa_revision"])
        for row in rows.values():
            self.assertEqual(row["fixture"], "test/parity/fixtures/backend-v1.json")
            fixture = (kimi.ROOT / row["fixture"]).read_bytes()
            self.assertEqual(hashlib.sha256(fixture).hexdigest(),
                             "9cc3a223ec54344afdc11af14f4ca9e72c737301d56b79014302f10af213aa56")
            self.assertEqual(json.loads(fixture)["required_checks"], [
                "exact_backend_selected", "auth_mode_preserved", "native_envelope",
                "no_generic_fallback", "ordered_headers_preserved",
            ])
        self.assertEqual({case["row_id"] for case in self.value["cases"]}, set(rows))
        for case in self.value["cases"]:
            plan = kimi.case_plan(self.value, case["id"])
            self.assertEqual(case["primary_case_id"], case["row_id"] + ".final-v1")
            self.assertNotEqual(case["id"], case["primary_case_id"])
            self.assertEqual(plan["f01_mapping"], "provisional_pending")
            self.assertNotEqual(plan["schema"], "mimic.final-parity-plan/v1")
        self.assertFalse(hasattr(kimi, "ROW_IDS"))

    def test_every_case_plan_is_synthetic_unapproved_blocked_not_run(self):
        for case in self.value["cases"]:
            with self.subTest(case=case["id"]):
                self.assertEqual((case["provenance"], case["approval"]),
                                 ("SYNTHETIC", "UNAPPROVED"))
                plan = kimi.case_plan(self.value, case["id"])
                self.assertEqual(plan["status"], "blocked")
                self.assertEqual(plan["approval"], "UNAPPROVED")
                self.assertEqual(plan["execution_status"], "not_run")
                self.assertEqual(plan["assertion_execution"], "not_run")
                self.assertEqual(plan["normalization"], [])
                self.assertTrue(set(kimi.REQUIRED_OBSERVATIONS).issubset(
                    plan["planned_assertions"]))
                self.assertTrue(set(kimi.HARD_BLOCKERS).issubset(plan["blockers"]))
                self.assertIn("f01_contract_not_imported_frozen_or_mapped", plan["blockers"])
                self.assertIn("synthetic_provider_cases_unapproved", plan["blockers"])
                self.assertNotIn("passed", plan)
                self.assertNotIn("observations", plan)
                self.assertTrue(all(item is None for item in plan["future_result_hashes"].values()))

    def test_report_local_checksums_are_not_future_run_bound_hashes_or_passes(self):
        report = kimi.blocked_report()
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(report["historical_strict37"], "0/37_unchanged")
        self.assertEqual(report["evidence_class"], "preparatory_synthetic")
        for key in ("execution_status", "paired_execution", "cpa_execution",
                    "mimic_execution", "native_acceptance", "live_verified"):
            self.assertEqual(report[key], "not_run")
        self.assertEqual(report["hash_binding_status"], "unknown_not_verified")
        self.assertEqual(report["future_result_hashes"], {name: None for name in kimi.HASH_ROLES})
        for path, digest in report["local_file_sha256"].items():
            self.assertEqual(digest, hashlib.sha256((kimi.ROOT / path).read_bytes()).hexdigest())
        self.assertEqual(len(report["cases"]), 20)
        self.assertEqual(len(kimi.blocked_report(scenario_id=self.first_id)["cases"]), 1)

    def test_peer_f15_checkpoint_separate_from_inspected_base_and_f32_admission(self):
        plan = kimi.case_plan(self.value, "kimi-generic.chat-sse.final-v1")
        peer = plan["peer_f15_checkpoint"]
        self.assertEqual(peer["coordinator_status"], "ACCEPTED")
        self.assertEqual(peer["coordinator_revision"], "8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936")
        self.assertEqual(peer["coordinator_bookmark"], "coordinator-f15-admitted")
        self.assertEqual(peer["provider_library_revision"],
                         "85f44ef07144a8a4433933b2f51f1972e4744039")
        self.assertEqual(peer["reported_gates"], {
            "focused_tests": 22, "source_requests": 18, "shipment_requests": 18,
            "full_gleam_tests": 711, "review": "reported",
        })
        self.assertNotEqual(plan["mimic_base_revision"], peer["coordinator_revision"])
        self.assertEqual(peer["independent_import"], "not_run")
        self.assertEqual(peer["f32_qualification"], "not_admitted")
        self.assertEqual(plan["dependencies"]["F15"], "peer_reported_admitted_not_imported")
        self.assertIn("f15_peer_admitted_checkpoint_not_independently_imported_or_run_bound",
                      plan["blockers"])
        self.assertNotIn("dependency_not_admitted:F15", plan["blockers"])
        self.assertEqual(plan["dependencies"]["F14"], "coordinator_reported_admitted_not_imported")
        self.assertIn("f14_coordinator_admitted_not_imported_or_run_bound", plan["blockers"])
        self.assertIn("dependency_not_admitted:F03", plan["blockers"])
        self.assertIn("dependency_not_admitted:F16", plan["blockers"])
        self.assertIn("complete_ir.Value_preservation", peer["reported_semantics"])
        self.assertTrue(all(item is None for item in plan["future_result_hashes"].values()))

    def test_raw_target_utf8_body_header_order_case_and_duplicates_preserved(self):
        for probe in ("kimi-native.chat-wire-tools", "kimi-generic.chat-wire"):
            case = self.case(probe)
            plan = kimi.case_plan(self.value, case["id"])
            request = plan["paired_stimuli"]["cpa"]["turns"][0]["request"]
            self.assertEqual(request["target"],
                             "/v1/chat/completions?synthetic=%2f&synthetic=%2F")
            self.assertEqual(request["body"].encode("utf-8"),
                             case["stimulus"]["turns"][0]["request"]["body"].encode("utf-8"))
            self.assertTrue(request["body"].startswith('{ "model":'))
            self.assertTrue(request["body"].endswith(" }\n"))
            self.assertIn("café", request["body"])
            self.assertEqual(request["headers"][1:], [
                ["X-Synthetic", "first"], ["x-synthetic", "mixed-case"],
                ["X-Synthetic", "second"],
            ])
            response = plan["paired_stimuli"]["cpa"]["turns"][0]["responses"][0]
            self.assertEqual(response["headers"][1:], request["headers"][1:])

    def test_generic_full_json_value_data_not_coerced_or_native_model_rewritten(self):
        case = self.case("kimi-generic.chat-wire")
        plan = kimi.case_plan(self.value, case["id"])
        for stimulus in plan["paired_stimuli"].values():
            body = stimulus["turns"][0]["request"]["body"]
            value = json.loads(body)
            extension = value["synthetic_extension"]
            self.assertIsNone(extension["null"])
            self.assertIs(extension["bool"], True)
            self.assertEqual(extension["integer"], 12345678901234567890)
            self.assertIn('"exponent":1e-7', body)
            self.assertEqual(extension["array"], [None, False, {"model": "SYNTHETIC nested model"}])
            self.assertEqual(value["model"], "kimi-k2.7-code")
            self.assertNotIn("kimi-for-coding", body)
            self.assertEqual(body, case["stimulus"]["turns"][0]["request"]["body"])
            self.assertEqual(stimulus["turns"][0]["responses"],
                             case["stimulus"]["turns"][0]["responses"])

    def test_raw_sse_scripts_preserve_comments_crlf_splits_usage_and_terminals(self):
        for probe, split_index in (("kimi-native.responses-sse-history", 1),
                                   ("kimi-native.chat-sse", 1),
                                   ("kimi-generic.chat-sse", 1)):
            case = self.case(probe)
            plan = kimi.case_plan(self.value, case["id"])
            chunks = plan["paired_stimuli"]["cpa"]["turns"][0]["responses"][0]["body_chunks"]
            self.assertEqual(chunks, case["stimulus"]["turns"][0]["responses"][0]["body_chunks"])
            self.assertIn(": SYNTHETIC heartbeat\r\n\r\n", chunks[0])
            self.assertTrue(chunks[split_index].endswith("da"))
            self.assertTrue(chunks[split_index + 1].startswith("ta: "))
            self.assertIn('"synthetic_usage"', "".join(chunks))
        native = self.case("kimi-native.responses-sse-history")["stimulus"]["turns"][0]
        generic = self.case("kimi-generic.chat-sse")["stimulus"]["turns"][0]
        self.assertIn("response.completed", "".join(native["responses"][0]["body_chunks"]))
        self.assertEqual(generic["responses"][0]["body_chunks"][-1], "data: [DONE]\r\n\r\n")
        self.assertIn('"tool_calls"', "".join(generic["responses"][0]["body_chunks"]))
        native_chat = self.case("kimi-native.chat-sse")["stimulus"]["turns"][0]
        self.assertEqual(native_chat["responses"][0]["body_chunks"][-1], "data: [DONE]\r\n\r\n")
        self.assertIn('"model":"kimi-for-coding"', native_chat["responses"][0]["body_chunks"][0])
        self.assertIn('"model":"kimi-k2.7-code"', generic["responses"][0]["body_chunks"][0])
        self.assertEqual(self.case("kimi-generic.chat-sse")["stimulus"]["controls"][
            "inspected_base_generic_streaming"], "denied")

    def test_native_chat_reasoning_explicit_tool_ids_and_argument_text(self):
        case = self.case("kimi-native.chat-wire-tools")
        body = json.loads(case["stimulus"]["turns"][0]["request"]["body"])
        self.assertEqual([message["role"] for message in body["messages"]],
                         ["user", "assistant", "tool"])
        assistant, tool = body["messages"][1:]
        call = assistant["tool_calls"][0]
        self.assertEqual(call["id"], tool["tool_call_id"])
        self.assertEqual(assistant["reasoning_content"], "SYNTHETIC prior reasoning")
        self.assertEqual(call["function"]["arguments"],
                         '{ "model" : "SYNTHETIC user model", "text":"café" }')
        self.assertNotIn("type", body["tools"][0]["function"]["parameters"])
        self.assertEqual(case["stimulus"]["controls"]["restore_only_protocol_owned_model"], True)
        self.assertEqual(case["stimulus"]["controls"]["observe_upstream_target"],
                         "/coding/v1/chat/completions")

    def test_native_responses_history_not_chat_or_server_continuation(self):
        body = json.loads(self.case("kimi-native.responses-sse-history")[
            "stimulus"]["turns"][0]["request"]["body"])
        self.assertNotIn("previous_response_id", body)
        self.assertNotIn("thinking", body)
        self.assertEqual(body["reasoning"], {"effort": "high"})
        reason, call, output = body["input"][1:]
        self.assertEqual(reason["encrypted_content"], "SYNTHETIC opaque reasoning")
        self.assertEqual(call["call_id"], output["call_id"])
        self.assertEqual(call["arguments"], '{ "text" : "SYNTHETIC café" }')
        self.assertEqual(body["tools"][0]["type"], "function")

    def test_native_messages_thinking_signatures_tools_and_image_sources(self):
        case = self.case("kimi-native.messages-signed-tools-images")
        turn = case["stimulus"]["turns"][0]
        body = json.loads(turn["request"]["body"])
        self.assertEqual(turn["request"]["target"],
                         "/v1/messages?beta=true&synthetic=%2f&synthetic=%2F")
        self.assertLess(body["thinking"]["budget_tokens"], body["max_tokens"])
        thinking, redacted, call = body["messages"][1]["content"]
        self.assertEqual(thinking["signature"], "SYNTHETIC signature")
        self.assertEqual(redacted["data"], "SYNTHETIC opaque data")
        result = body["messages"][2]["content"][0]
        self.assertEqual(call["id"], result["tool_use_id"])
        self.assertIsInstance(result["content"], str)
        images = body["messages"][0]["content"][1:]
        self.assertEqual([image["source"]["type"] for image in images], ["url", "base64"])
        self.assertEqual(case["stimulus"]["controls"]["media_fetch"], "forbidden")
        self.assertEqual(case["stimulus"]["controls"]["credential_identity"], "kimi_not_claude")

    def test_both_oauth_domains_explicit_bounded_symbolic_isolated_not_login(self):
        for probe, domain in (("kimi-native.oauth-com", "kimi.com"),
                              ("kimi-native.oauth-ai", "kimi.ai")):
            case = self.case(probe)
            stimulus = case["stimulus"]
            self.assertEqual(stimulus["auth_mode"], "oauth")
            self.assertEqual(stimulus["oauth_domain"], domain)
            controls = stimulus["controls"]
            self.assertEqual(controls["auth_endpoint_binding"],
                             "unknown_operator_qualification_required")
            self.assertEqual(controls["device_authorization_target"],
                             "/api/oauth/device_authorization")
            self.assertEqual(controls["token_target"], "/api/oauth/token")
            self.assertEqual((controls["min_poll_ms"], controls["max_poll_ms"],
                              controls["refresh_lead_ms"]), (5000, 900000, 300000))
            self.assertEqual(controls["private_device_slot"], "synthetic-b-device")
            self.assertEqual(controls["parallel_refresh_requests"], 2)
            self.assertEqual(controls["refresh_barriers"],
                             ["refresh_started", "rotation_persisted", "inference_released"])
            self.assertEqual(controls["unknown_rotation_outcome"], "no_blind_retry")
            self.assertEqual(controls["opposite_domain_grant"], "reject_before_inference")
            self.assertEqual(case["difference"]["status"], "decision_required")
            plan = kimi.case_plan(self.value, case["id"])
            self.assertEqual(plan["execution_status"], "not_run")
            self.assertNotIn("access_token", json.dumps(plan))
            self.assertNotIn("refresh_token", json.dumps(plan))

    def test_pre_io_expectations_are_required_controls_not_observed_zero_counts(self):
        for case in self.value["cases"]:
            if case["expected"]["kind"] != "pre_io_rejection_required":
                continue
            plan = kimi.case_plan(self.value, case["id"])
            self.assertEqual(plan["expected"]["required_upstream_requests"], 0)
            self.assertEqual(plan["expected"]["send_state"], "NotSent")
            self.assertEqual(plan["expected"]["scope"], "request")
            self.assertEqual(plan["expected"]["retry"], "forbidden")
            self.assertEqual(plan["execution_status"], "not_run")
            self.assertNotIn("observed_upstream_requests", plan)
            self.assertTrue(all(turn["responses"] == [] for turn in case["stimulus"]["turns"]))
        value = deepcopy(self.value)
        negative = next(case for case in value["cases"]
                        if case["id"] == "kimi-generic.media-pre-io.final-v1")
        negative["expected"]["required_upstream_requests"] = False
        with self.assertRaises(ValueError):
            kimi.case_plan(value, negative["id"])

    def test_native_hardening_differences_never_normalized_into_matches(self):
        for probe in ("kimi-native.tools-pre-io", "kimi-native.controls-pre-io",
                      "kimi-native.media-pre-io", "kimi-native.state-pre-io"):
            case = self.case(probe)
            self.assertEqual(case["difference"]["status"], "decision_required")
            self.assertEqual(case["difference"]["normalization"], [])
            self.assertEqual(case["expected"]["send_state"], "NotSent")
        turns = self.case("kimi-native.tools-pre-io")["stimulus"]["turns"]
        schema = json.loads(turns[0]["request"]["body"])["tools"][0]["function"]["parameters"]
        self.assertEqual(schema["properties"]["text"]["$ref"], "#/$defs/text")
        controls = self.case("kimi-native.controls-pre-io")["stimulus"]["turns"]
        self.assertEqual(json.loads(controls[0]["request"]["body"])["temperature"], 0.2)
        state = self.case("kimi-native.state-pre-io")["stimulus"]
        self.assertIn("previous_response_id", state["turns"][0]["request"]["body"])
        self.assertEqual(state["controls"]["future_f14_messages_hook"], "unknown_not_inferred")

    def test_native_media_probes_cover_all_protocols_and_nested_tool_outputs(self):
        case = self.case("kimi-native.media-pre-io")
        self.assertEqual(case["stimulus"]["controls"]["required_capabilities"], [])
        turns = case["stimulus"]["turns"]
        self.assertEqual({turn["protocol"] for turn in turns}, {"chat", "responses", "anthropic"})
        self.assertEqual([turn["label"] for turn in turns], [
            "chat-user-audio", "chat-tool-video", "responses-input-file",
            "responses-tool-output-audio", "messages-tool-result-image",
        ])
        self.assertTrue(all(turn["responses"] == [] for turn in turns))
        self.assertEqual(case["expected"]["required_upstream_requests"], 0)

    def test_generic_media_semantic_positions_include_empty_caller_capabilities(self):
        case = self.case("kimi-generic.media-pre-io")
        self.assertEqual(case["stimulus"]["controls"]["required_capabilities"], [])
        turns = case["stimulus"]["turns"]
        self.assertEqual([turn["label"] for turn in turns], [
            "user-input-audio", "user-video", "user-file", "tool-input-audio",
            "tool-video", "tool-file", "system-unknown-part", "assistant-message-audio",
        ])
        for turn in turns:
            body = json.loads(turn["request"]["body"])
            self.assertNotIn("audio", body)
            self.assertNotIn("modalities", body)
        self.assertIn("audio", json.loads(turns[-1]["request"]["body"])["messages"][0])
        self.assertEqual(case["expected"]["failure"], "Unsupported")
        self.assertEqual(case["expected"]["send_state"], "NotSent")

    def test_generic_opaque_media_named_data_not_native_schema_or_thinking_policy(self):
        case = self.case("kimi-generic.opaque-tools")
        raw = case["stimulus"]["turns"][0]["request"]["body"]
        body = json.loads(raw)
        self.assertEqual(body["temperature"], 0.2)
        self.assertEqual(body["reasoning_effort"], "none")
        self.assertEqual(body["thinking"]["type"], "disabled")
        self.assertIn("$defs", body["tools"][0]["function"]["parameters"])
        self.assertEqual(body["messages"][1]["tool_calls"][0]["function"]["arguments"],
                         '{ "audio" : true, "model" : "SYNTHETIC user model" }')
        self.assertIsInstance(body["messages"][2]["content"], str)
        self.assertEqual(body["synthetic_extension"]["content"]["type"], "input_audio")
        self.assertEqual(case["stimulus"]["controls"]["recursive_media_key_scan"], "forbidden")
        for stimulus in kimi.case_plan(self.value, case["id"])["paired_stimuli"].values():
            self.assertEqual(stimulus["turns"][0]["request"]["body"], raw)

    def test_generic_image_forms_are_synthetic_bounded_raw_strings_no_fetch(self):
        case = self.case("kimi-generic.images-no-fetch")
        body = json.loads(case["stimulus"]["turns"][0]["request"]["body"])
        inline, remote = body["messages"][0]["content"][1:]
        self.assertTrue(inline["image_url"]["url"].startswith("data:image/gif;base64,"))
        self.assertLess(len(inline["image_url"]["url"]), 128)
        self.assertEqual(remote["image_url"]["url"], "https://synthetic-media.invalid/generic.png")
        self.assertEqual(remote["image_url"]["detail"], "low")
        self.assertEqual(case["stimulus"]["controls"]["media_fetch_or_decode"], "forbidden")
        self.assertEqual(case["stimulus"]["controls"]["inline_media_provenance"],
                         "SYNTHETIC one-pixel GIF")

    def test_exact_model_negative_bodies_are_kept_not_prevalidated_or_coerced(self):
        turns = self.case("kimi-generic.model-pre-io")["stimulus"]["turns"]
        bodies = [turn["request"]["body"] for turn in turns]
        self.assertNotIn("model", json.loads(bodies[0]))
        self.assertIsNone(json.loads(bodies[1])["model"])
        self.assertEqual(json.loads(bodies[2])["model"], 123)
        self.assertEqual(json.loads(bodies[3])["model"], "kimi-for-coding")
        self.assertIn('"mo\\u0064el":"kimi-for-coding"', bodies[4])
        plan = kimi.case_plan(self.value, "kimi-generic.model-pre-io.final-v1")
        self.assertEqual([turn["request"]["body"] for turn in plan["paired_stimuli"]["cpa"][
            "turns"]], bodies)
        native_turns = self.case("kimi-native.model-pre-io")["stimulus"]["turns"]
        self.assertEqual({turn["protocol"] for turn in native_turns},
                         {"chat", "responses", "anthropic"})
        self.assertEqual(self.case("kimi-native.model-pre-io")["expected"]["failure"], None)

    def test_authored_wire_json_syntax_only_not_provider_or_sse_codec_validation(self):
        for case in self.value["cases"]:
            for turn in case["stimulus"]["turns"]:
                with self.subTest(case=case["id"], turn=turn["label"]):
                    self.assertIsInstance(json.loads(turn["request"]["body"]), dict)
                    for response in turn["responses"]:
                        raw = "".join(response["body_chunks"])
                        if ["Content-Type", "text/event-stream"] not in response["headers"]:
                            self.assertIsInstance(json.loads(raw), dict)
                            continue
                        # Only syntax-check authored single-data-line CRLF frames.
                        # This is not a framing/terminal/result implementation.
                        for frame in raw.split("\r\n\r\n"):
                            for line in frame.split("\r\n"):
                                if line.startswith("data: ") and line != "data: [DONE]":
                                    self.assertIsInstance(json.loads(line[len("data: "):]), dict)

    def test_generic_unsupported_protocols_and_oauth_are_negative_not_registered(self):
        protocols = self.case("kimi-generic.protocols-pre-io")
        self.assertEqual([turn["protocol"] for turn in protocols["stimulus"]["turns"]],
                         ["responses", "anthropic"])
        oauth = self.case("kimi-generic.oauth-pre-io")
        self.assertEqual(oauth["stimulus"]["oauth_domain"], "kimi.com")
        self.assertEqual(oauth["stimulus"]["controls"]["opposite_domain_variant"], "kimi.ai")
        for case in (protocols, oauth):
            self.assertEqual(case["expected"]["send_state"], "NotSent")
            value = deepcopy(self.value)
            selected = next(item for item in value["cases"] if item["id"] == case["id"])
            selected["expected"].update(kind="observation_required", failure=None,
                                        send_state=None, required_upstream_requests=None,
                                        scope="none", retry="not_asserted")
            with self.assertRaises(ValueError):
                kimi.case_plan(value, case["id"])

    def test_no_hash_admission_execution_or_peer_override_removes_blockers(self):
        for key, invalid in (("approval", "APPROVED"), ("provenance", "captured"),
                             ("cpa_revision", "unknown"), ("mimic_base_revision", "unknown")):
            self.reject_mutation(lambda value: value.update({key: invalid}))
        for key, invalid in (("future_result_hashes", {"source": "a" * 64}),
                             ("allow_execution", True), ("peer_f15_checkpoint", {"status": "verified"})):
            self.reject_mutation(lambda value: value.update({key: invalid}))
        self.reject_mutation(lambda value: value["dependencies"].update(F15="imported_admitted"))
        self.reject_mutation(lambda value: value["dependencies"].update(F14="admitted"))
        value = deepcopy(self.value)
        value["cases"][0]["stimulus"]["controls"]["caller_hashes"] = {
            name: "a" * 64 for name in kimi.HASH_ROLES}
        plan = kimi.case_plan(value, self.first_id)
        self.assertEqual(plan["status"], "blocked")
        self.assertEqual(plan["future_result_hashes"], {name: None for name in kimi.HASH_ROLES})
        self.assertTrue(set(kimi.HARD_BLOCKERS).issubset(plan["blockers"]))

    def test_unsupported_transport_binary_lossy_headers_and_bad_payloads_reject(self):
        stimulus = lambda value: value["cases"][0]["stimulus"]
        request = lambda value: stimulus(value)["turns"][0]["request"]
        for key, invalid in (("transport", "http/2"), ("body_encoding", "base64"),
                             ("content_encoding", "gzip"), ("registration", []),
                             ("oauth_domain", "kimi.invalid")):
            self.reject_mutation(lambda value: stimulus(value).update({key: invalid}))
        for key, invalid in (("method", "GET"), ("body", b"binary"), ("body", "\ud800"),
                             ("target", "https://localhost:8317/v1/responses"),
                             ("target", "/v1/responses#fragment"),
                             ("headers", {"X-Synthetic": "last"})):
            self.reject_mutation(lambda value: request(value).update({key: invalid}))
        for headers in ([["Content-Encoding", "gzip"]], [["X-Synthetic", "bad\r\ninjection"]],
                        [["Authorization", "synthetic-slot-not-a-value"]],
                        [["Cookie", "synthetic-slot-not-a-value"]]):
            self.reject_mutation(lambda value: request(value).update(headers=headers))
        self.reject_mutation(lambda value: value["synthetic_context"]["target_endpoints"].update(
            cpa="https://localhost:8317"))
        self.reject_mutation(lambda value: value["cases"][0].update(passed=True))
        self.reject_mutation(lambda value: value["cases"].append(deepcopy(value["cases"][0])))
        self.reject_mutation(lambda value: value["comparison"].update(normalization=["sort_headers"]))
        self.reject_mutation(lambda value: value["cases"][0]["difference"].update(status="matched"))
        self.reject_mutation(lambda value: value["cases"][0]["expected"].update(
            kind="pre_io_rejection_required", required_upstream_requests=False))
        with self.assertRaises(ValueError):
            kimi.case_plan(self.value, "kimi-native.final-v1")

    def test_duplicate_envelope_keys_reject_duplicate_raw_provider_json_kept(self):
        for raw in (b'{"slice":"F32","sl\\u0069ce":"F32"}', b"\xff"):
            with self.subTest(raw=raw), patch.object(Path, "read_bytes", return_value=raw):
                with self.assertRaises((ValueError, UnicodeError)):
                    kimi.load_fixture()
        value = deepcopy(self.value)
        raw = '{"model":"synthetic-first","mo\\u0064el":"synthetic-second"}\n'
        value["cases"][0]["stimulus"]["turns"][0]["request"]["body"] = raw
        plan = kimi.case_plan(value, self.first_id)
        for stimulus in plan["paired_stimuli"].values():
            self.assertEqual(stimulus["turns"][0]["request"]["body"], raw)

    def test_cli_only_prepares_with_nonzero_status_and_no_launch_hash_or_waiver_flags(self):
        for args in ([], ["--case", self.first_id]):
            output = io.StringIO()
            with redirect_stdout(output):
                code = kimi.main(args)
            self.assertEqual(code, 2)
            report = json.loads(output.getvalue())
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["cpa_execution"], "not_run")
            self.assertEqual(len(report["cases"]), 20 if not args else 1)
        for args in (["--run"], ["--endpoint", "https://localhost:8317"],
                     ["--hashes", "a" * 64], ["--admit-f15"], ["--waive-updater"]):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                kimi.main(args)
            self.assertEqual(error.exception.code, 2)

    def test_unknown_case_missing_fixture_are_sanitized_rejections_not_passes(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = kimi.main(["--case", "unknown"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["paired_execution"], "not_run")
        output = io.StringIO()
        with patch.object(Path, "read_bytes", side_effect=OSError("synthetic-private-detail")):
            with redirect_stdout(output):
                code = kimi.main([])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["status"], "rejected")
        self.assertNotIn("synthetic-private-detail", output.getvalue())

    def test_adapter_imports_no_contract_harness_provider_process_or_network_modules(self):
        tree = ast.parse((kimi.ROOT / kimi.DRIVER).read_text(encoding="utf-8"))
        imported = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                imported.add(node.module)
        self.assertEqual(imported, {"argparse", "copy", "hashlib", "json", "pathlib", "sys"})
        for name in ("launch", "exercise", "run", "admit", "load_contract", "validate_contract"):
            self.assertFalse(hasattr(kimi, name))

    def test_execution_guard_controls_are_audit_events_not_real_io(self):
        with safe_unit_tests.execution_guards():
            for event in ("subprocess.Popen", "os.exec", "os.fork", "os.posix_spawn",
                          "socket.connect", "socket.bind", "socket.getaddrinfo", "socket.sendto"):
                with self.subTest(event=event), self.assertRaises(AssertionError):
                    sys.audit(event, "SYNTHETIC guard control")
