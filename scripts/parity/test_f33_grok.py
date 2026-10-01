"""Focused preparation-only tests; all tests use execution_guards."""
import ast
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import f33_grok as grok
import safe_unit_tests


class GrokPreparationTest(unittest.TestCase):
    def setUp(self):
        self.enterContext(safe_unit_tests.execution_guards())
        self.value = grok.load_fixture()
        self.first_id = self.value["cases"][0]["id"]

    def case(self, suffix):
        return next(case for case in self.value["cases"]
                    if case["id"] == "final-v1-grok-" + suffix)

    def reject_mutation(self, mutate):
        value = deepcopy(self.value)
        mutate(value)
        with self.assertRaises(ValueError):
            grok.case_plan(value, self.first_id)

    def test_identical_paired_stimuli_are_independent_all_the_way_down(self):
        original = deepcopy(self.value)
        for case in self.value["cases"]:
            with self.subTest(case=case["id"]):
                plan = grok.case_plan(self.value, case["id"])
                cpa, mimic = (plan["paired_stimuli"][name] for name in ("cpa", "mimic"))
                self.assertEqual(cpa, mimic)
                self.assertEqual(cpa["turns"], case["stimulus"]["turns"])
                cpa["turns"][0]["request"]["headers"].append(["X-Synthetic", "changed"])
                cpa["synthetic_context"]["credential_slots"].append("changed")
                self.assertEqual(mimic["turns"], case["stimulus"]["turns"])
                self.assertEqual(mimic["synthetic_context"], grok.CONTEXT)
                plan["expected"]["feature_status"] = "changed"
                plan["peer_f17"]["feature_status"] = "changed"
                plan["comparison"]["normalization"].append("changed")
        self.assertEqual(self.value, original)
        self.assertEqual(grok.PEER_F17["feature_status"], "BLOCKED")
        self.assertEqual(grok.COMPARISON["normalization"], [])

    def test_order_case_and_duplicates_preserved_in_both_directions(self):
        case = self.case("api-identity")
        expected = [
            ["Content-Type", "application/json"], ["Authorization", "Bearer synthetic-client"],
            ["X-Synthetic", "first"], ["x-synthetic", "mixed-case"], ["X-Synthetic", "second"],
        ]
        for stimulus in grok.case_plan(self.value, case["id"])["paired_stimuli"].values():
            turn = stimulus["turns"][0]
            self.assertEqual(turn["request"]["headers"], expected)
            self.assertEqual(turn["responses"][0]["headers"], [expected[0], *expected[2:]])

    def test_raw_target_body_whitespace_unicode_and_extension_order(self):
        request = grok.case_plan(self.value, self.first_id)["paired_stimuli"]["cpa"][
            "turns"][0]["request"]
        self.assertEqual(request["target"], "/v1/chat/completions?synthetic=b%2Fa&synthetic=a")
        expected = (
            '{ "model":"synthetic-model", "messages":[{"role":"user","content":"SYNTHETIC café"}], '
            '"stream":false, "synthetic_extension":{"b":2,"a":1} }\n'
        )
        self.assertEqual(request["body"].encode("utf-8"), expected.encode("utf-8"))

    def test_provider_json_is_not_decoded_or_normalized(self):
        raw = '{ "x":1, "\\u0078":2, "SYNTHETIC":"café" }\n'
        self.value["cases"][0]["stimulus"]["turns"][0]["request"]["body"] = raw
        plan = grok.case_plan(self.value, self.first_id)
        for stimulus in plan["paired_stimuli"].values():
            self.assertEqual(stimulus["turns"][0]["request"]["body"], raw)

    def test_sse_chunks_tools_reasoning_usage_and_terminal_preserved(self):
        case = self.case("tools-sse-full-history")
        plan = grok.case_plan(self.value, case["id"])
        for stimulus in plan["paired_stimuli"].values():
            chunks = stimulus["turns"][0]["responses"][0]["body_chunks"]
            self.assertEqual(chunks, case["stimulus"]["turns"][0]["responses"][0]["body_chunks"])
            self.assertTrue(chunks[3].endswith("\r\nda"))
            self.assertTrue(chunks[4].startswith("ta: "))
            raw = "".join(chunks)
            self.assertIn(": SYNTHETIC heartbeat\r\n\r\n", raw)
            self.assertEqual(raw.count('"type":"response.completed"'), 1)
            self.assertIn('"call_id":"synthetic-call"', raw)
            self.assertIn('"name":"synthetic.lookup"', raw)
            self.assertIn('"encrypted_content":"synthetic-opaque"', raw)
            self.assertIn('"input_tokens":5,"output_tokens":4', raw)
            follow = stimulus["turns"][1]["request"]["body"]
            self.assertIn('"type":"function_call_output"', follow)
            self.assertIn('"call_id":"synthetic-call"', follow)
            self.assertNotIn("previous_response_id", follow)
        self.assertEqual(plan["protocol_mapping"], "additive_control_pending_f01")

    def test_ws_raw_logical_payloads_close_and_headers_are_only_controls(self):
        case = self.case("ws-source-runtime-blocker")
        plan = grok.case_plan(self.value, case["id"])
        for stimulus in plan["paired_stimuli"].values():
            turn = stimulus["turns"][0]
            self.assertEqual(turn, case["stimulus"]["turns"][0])
            self.assertEqual(turn["request"]["body"], "")
            self.assertTrue(turn["request"]["text_frames"][0].endswith(" }\n"))
            self.assertIn('"call_id":"synthetic-orphan"', turn["request"]["text_frames"][1])
            self.assertEqual(turn["responses"][0]["body_chunks"], [])
            self.assertEqual(turn["responses"][0]["close"],
                             {"code": 1000, "reason": "SYNTHETIC close"})
        self.assertEqual(plan["qualification"], grok.QUALIFICATION)
        self.assertEqual(plan["expected"]["reference_contract"], "source_runtime_unknown")
        self.assertIn("no_physical_wire_claim", plan["comparison"]["websocket"])

    def test_historical_five_field_tuples_and_primary_ids_unchanged(self):
        historical = json.loads((grok.ROOT / grok.HISTORICAL).read_text(encoding="utf-8"))
        rows = {row["id"]: row for row in historical["capabilities"] if row["provider"] == "xai"}
        keys = ("provider", "auth_mode", "input_protocol", "upstream_mode", "capability")
        self.assertEqual(set(rows), set(grok.HISTORICAL_ROWS))
        self.assertEqual(historical["cpa_revision"], grok.CPA_REVISION)
        for row_id, row in rows.items():
            self.assertEqual([row[key] for key in keys], grok.HISTORICAL_ROWS[row_id])
            self.assertEqual(row["source_status"], "pending")
        for case in self.value["cases"]:
            plan = grok.case_plan(self.value, case["id"])
            self.assertEqual(plan["primary_case_id"], case["row_id"] + ".final-v1")
            self.assertEqual(plan["f01_mapping"], "provisional_pending")
            self.assertEqual(plan["historical_tuple"], grok.HISTORICAL_ROWS[case["row_id"]])
            self.assertNotEqual(plan["schema"], "mimic.final-parity-plan/v1")

    def test_api_key_oauth_and_api_proxy_identities_cannot_be_conflated(self):
        api = grok.case_plan(self.value, self.case("api-identity")["id"])
        proxy = grok.case_plan(self.value, self.case("oauth-proxy-identity")["id"])
        self.assertEqual((api["historical_tuple"][1], api["historical_tuple"][3]),
                         ("api_key", "xai_api"))
        self.assertEqual((proxy["historical_tuple"][1], proxy["historical_tuple"][3]),
                         ("oauth", "grok_build"))
        slots = grok.CONTEXT["origin_slots"]
        self.assertNotEqual(slots["xai_api"], slots["grok_build"])
        for mutation in ({"auth_mode": "oauth"}, {"upstream_mode": "grok_build"}):
            self.reject_mutation(lambda value: value["cases"][0]["stimulus"].update(mutation))

    def test_f17_peer_finding_keeps_all_three_http_reference_controls_blocked(self):
        self.assertEqual(grok.PEER_F17["Execute"], grok.PEER_F17["ExecuteStream"])
        self.assertIn("deletes_previous_response_id", grok.PEER_F17["Execute"])
        self.assertEqual(grok.PEER_F17["compact"],
                         "alone_readds_previous_response_id_on_separate_base")
        self.assertEqual(grok.PEER_F17["reasoning_cache"],
                         "model_session_cache_not_qualified_receipt_or_isolation")
        for suffix in ("continuation-http-blocker", "continuation-sse-blocker",
                       "continuation-compact-blocker"):
            plan = grok.case_plan(self.value, self.case(suffix)["id"])
            self.assertEqual(plan["expected"]["reference_contract"], "unsupported-reference-contract")
            self.assertEqual(plan["expected"]["feature_status"], "BLOCKED")
            self.assertEqual(plan["peer_f17"]["production_continuation_api"], "none")
            self.assertEqual(plan["difference"]["status"], "decision_required")
            self.assertEqual(plan["comparison"]["normalization"], [])
            turn = plan["paired_stimuli"]["cpa"]["turns"][0]
            self.assertIn('"previous_response_id":"synthetic-prior"', turn["request"]["body"])
            self.assertEqual(turn["responses"], [])
        compact = self.case("continuation-compact-blocker")["stimulus"]["turns"][0]["request"]
        self.assertEqual(compact["target"], "/v1/responses/compact")

    def test_media_proposals_are_source_runtime_unknown_not_supported_routes(self):
        for suffix, marker in (("image-source-runtime-blocker", "input_image"),
                               ("video-source-runtime-blocker", "input_video")):
            case = self.case(suffix)
            plan = grok.case_plan(self.value, case["id"])
            self.assertEqual(plan["qualification"]["source_route"], "unknown")
            self.assertEqual(plan["qualification"]["assembled_runtime"], "unknown")
            self.assertIsNone(plan["qualification"]["qualified_route"])
            turn = plan["paired_stimuli"]["cpa"]["turns"][0]
            self.assertEqual(turn["request"]["target"], "/v1/responses")
            self.assertIn(marker, turn["request"]["body"])
            self.assertIn("synthetic.invalid", turn["request"]["body"])
            self.assertEqual(turn["responses"], [])
            self.assertEqual(plan["expected"]["reference_contract"], "source_runtime_unknown")
            self.assertEqual(plan["expected"]["feature_status"], "BLOCKED")

    def test_exact_request_vs_credential_scope_controls_and_no_status_only_replay(self):
        controls = {
            "request-400": (400, "REQUEST", 400, False),
            "request-403-permission": (403, "REQUEST", 403, False),
            "credential-401": (401, "CREDENTIAL", 401, True),
            "credential-403-bad-credentials": (403, "CREDENTIAL", 401, True),
        }
        for suffix, expected in controls.items():
            case = self.case(suffix)
            proposed = case["expected"]
            response = case["stimulus"]["turns"][0]["responses"][0]
            self.assertEqual((response["status"], proposed["scope"],
                              proposed["classified_status"], proposed["reauthorize"]), expected)
            self.assertEqual(proposed["delivery"], "Uncertain")
            self.assertIs(proposed["retry"], False)
            plan = grok.case_plan(self.value, case["id"])
            self.assertEqual(plan["expected"], proposed)
            self.assertEqual(plan["assertion_execution"], "not_run")
        body = self.case("credential-403-bad-credentials")[
            "stimulus"]["turns"][0]["responses"][0]["body_chunks"][0]
        self.assertIn('"body":{"error":{"code":"bad-credentials"', body)
        self.assertIn("access token could not be validated", body)
        permission = self.case("request-403-permission")[
            "stimulus"]["turns"][0]["responses"][0]["body_chunks"][0]
        self.assertNotIn("bad-credentials", permission)

    def test_every_plan_and_report_is_blocked_not_run_and_unbound(self):
        report = grok.blocked_report()
        self.assertEqual(report["historical_strict37"], "0/37_unchanged")
        self.assertEqual(len(report["cases"]), len(self.value["cases"]))
        for item in [report, *report["cases"]]:
            self.assertEqual(item["status"], "blocked")
            self.assertEqual(item["feature_status"], "BLOCKED")
            self.assertEqual(item["approval"], "UNAPPROVED")
            for field in ("execution_status", "paired_execution", "cpa_execution",
                          "mimic_execution", "assertion_execution"):
                self.assertEqual(item[field], "not_run")
            self.assertEqual(item["hash_binding_status"], "unknown_not_verified")
            self.assertEqual(item["future_result_hashes"], dict.fromkeys(grok.HASH_ROLES))
            self.assertEqual(item["dependencies"], {name: "not_admitted" for name in grok.DEPENDENCIES})
            for blocker in (*grok.HARD_BLOCKERS, "unsupported-reference-contract:F17",
                            "existing_localhost_8317_identity_unknown_do_not_contact",
                            "f01_contract_not_imported_frozen_or_mapped"):
                self.assertIn(blocker, item["blockers"])
            self.assertNotIn("passed", item)
            self.assertNotIn("observations", item)
        self.assertEqual(report["native_acceptance"], "not_run")
        self.assertEqual(report["live_verified"], "not_run")
        for plan in report["cases"]:
            self.assertTrue(set(grok.REQUIRED_OBSERVATIONS).issubset(plan["planned_assertions"]))

    def test_four_local_file_hashes_are_bytes_not_future_evidence(self):
        report = grok.blocked_report(scenario_id=self.first_id)
        self.assertEqual(len(report["cases"]), 1)
        self.assertEqual(set(report["local_file_sha256"]),
                         {grok.DRIVER, grok.TEST, grok.FIXTURE, grok.DOC})
        for name, digest in report["local_file_sha256"].items():
            self.assertEqual(digest, hashlib.sha256((grok.ROOT / name).read_bytes()).hexdigest())
        self.assertTrue(all(value is None for value in report["future_result_hashes"].values()))

    def test_payload_cannot_approve_admit_qualify_normalize_or_override_peer_finding(self):
        mutations = (
            lambda value: value.update(approval="APPROVED"),
            lambda value: value.update(f01_mapping="frozen"),
            lambda value: value["dependencies"].update(F17="admitted"),
            lambda value: value["qualification"].update(qualified_route="/v1/responses"),
            lambda value: value["peer_f17"].update(production_continuation_api="supported"),
            lambda value: value["comparison"]["normalization"].append("drop_previous_response_id"),
            lambda value: value["cases"][0].update(primary_case_id="new-row.final-v1"),
            lambda value: value["cases"][0].update(row_id=[]),
            lambda value: value["cases"][-1]["expected"].update(scope="REQUEST"),
            lambda value: value["cases"][-1]["expected"].update(retry=True),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index):
                self.reject_mutation(mutation)

    def test_binary_encoding_protocol_and_header_framing_fail_explicitly(self):
        mutations = (
            lambda value: value["cases"][0]["stimulus"].update(transport="http/2"),
            lambda value: value["cases"][0]["stimulus"].update(content_encoding="gzip"),
            lambda value: value["cases"][0]["stimulus"]["turns"][0]["request"].update(body=b"SYNTHETIC"),
            lambda value: value["cases"][0]["stimulus"]["turns"][0]["request"].update(body="\ud800"),
            lambda value: value["cases"][0]["stimulus"]["turns"][0]["request"].update(headers={"x":"one"}),
            lambda value: value["cases"][0]["stimulus"]["turns"][0]["request"]["headers"].append(["X", "bad\r\nSYNTHETIC"]),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index):
                self.reject_mutation(mutation)

    def test_duplicate_envelope_keys_rejected_without_parsing_provider_json(self):
        for raw in (b'{"slice":"F33","sl\\u0069ce":"F33"}', b"\xff"):
            with self.subTest(raw=raw), patch.object(Path, "read_bytes", return_value=raw):
                with self.assertRaises((UnicodeError, ValueError)):
                    grok.load_fixture()
        self.reject_mutation(lambda value: value["cases"].append(deepcopy(value["cases"][0])))

    def test_cli_blocked_two_rejected_one_no_external_execution(self):
        for args in ([], ["--case", self.first_id]):
            output = io.StringIO()
            with redirect_stdout(output):
                code = grok.main(args)
            self.assertEqual(code, 2)
            report = json.loads(output.getvalue())
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(report["paired_execution"], "not_run")
        for args in (["--case", "SYNTHETIC-unknown"], ["--case"], ["--launch"]):
            output = io.StringIO()
            with redirect_stdout(output):
                code = grok.main(args)
            self.assertEqual(code, 1)
            self.assertEqual(json.loads(output.getvalue())["status"], "rejected")
        output = io.StringIO()
        with patch.object(Path, "read_bytes", side_effect=OSError("SYNTHETIC-private-detail")):
            with redirect_stdout(output):
                code = grok.main([])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["execution_status"], "not_run")
        self.assertNotIn("SYNTHETIC-private-detail", output.getvalue())

    def test_driver_imports_no_harness_contract_provider_or_execution_modules(self):
        tree = ast.parse((grok.ROOT / grok.DRIVER).read_text(encoding="utf-8"))
        modules = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                modules.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                modules.add(node.module)
        self.assertEqual(modules, {"argparse", "copy", "hashlib", "json", "pathlib", "sys"})
        self.assertFalse({"launch", "compare", "admit", "execute", "continuation"} &
                         {node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)})

    def test_guard_controls_are_audit_events_not_process_or_network_attempts(self):
        for event in ("subprocess.Popen", "os.system", "os.exec", "os.fork",
                      "os.posix_spawn", "socket.connect", "socket.bind",
                      "socket.getaddrinfo", "socket.sendto"):
            with self.subTest(event=event), self.assertRaises(AssertionError):
                sys.audit(event, "SYNTHETIC F33 guard control")


if __name__ == "__main__":
    with safe_unit_tests.execution_guards():
        unittest.main(verbosity=2)
