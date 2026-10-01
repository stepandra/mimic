"""Focused preparation-only tests; import/run under execution_guards."""
import ast
import base64
from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import f34_devin as devin
import safe_unit_tests


class DevinPreparationTest(unittest.TestCase):
    def setUp(self):
        self.enterContext(safe_unit_tests.execution_guards())
        self.value = devin.load_fixture()
        self.first_id = self.value["cases"][0]["id"]

    def plan(self, suffix):
        return devin.case_plan(self.value, "final-v1-devin-" + suffix)

    def stimulus(self, suffix):
        return self.plan(suffix)["paired_stimuli"]["cpa"]

    def reject(self, mutate):
        value = deepcopy(self.value)
        mutate(value)
        with self.assertRaises(ValueError):
            devin.case_plan(value, self.first_id)

    def test_historical_five_field_tuples_unchanged(self):
        historical = json.loads((devin.ROOT / devin.HISTORICAL).read_text(encoding="utf-8"))
        rows = {row["id"]: row for row in historical["capabilities"] if row["provider"] == "devin"}
        keys = ("provider", "auth_mode", "input_protocol", "upstream_mode", "capability")
        self.assertEqual(set(rows), set(devin.HISTORICAL_ROWS))
        self.assertEqual(historical["cpa_revision"], devin.CPA_REVISION)
        for row_id, row in rows.items():
            self.assertEqual([row[key] for key in keys], devin.HISTORICAL_ROWS[row_id])

    def test_primary_ids_and_additive_controls_not_new_denominator(self):
        plans = [devin.case_plan(self.value, case["id"]) for case in self.value["cases"]]
        self.assertEqual(len(plans), 25)
        self.assertEqual({plan["row_id"] for plan in plans}, set(devin.HISTORICAL_ROWS))
        self.assertEqual(sum(plan["mapping_role"] == "historical_primary" for plan in plans), 15)
        for plan in plans:
            self.assertEqual(plan["primary_case_id"], plan["row_id"] + ".final-v1")
            self.assertEqual(plan["f01_mapping"], "provisional_pending")
            self.assertNotEqual(plan["schema"], "mimic.final-parity-plan/v1")

    def test_identical_paired_stimuli_are_deeply_independent(self):
        original = deepcopy(self.value)
        for case in self.value["cases"]:
            plan = devin.case_plan(self.value, case["id"])
            cpa, mimic = (plan["paired_stimuli"][name] for name in ("cpa", "mimic"))
            self.assertEqual(cpa, mimic)
            expected = deepcopy(mimic)
            cpa["synthetic_context"]["credentials"]["synthetic-a"] = "changed"
            if cpa["native_script"]:
                cpa["native_script"][0]["request"]["headers"].append(["X-Synthetic", "changed"])
                cpa["native_script"][0]["request"]["body"]["data"] = "changed"
            if cpa["client_projection"]:
                cpa["client_projection"]["body_chunks"][0]["data"] = "changed"
            self.assertEqual(mimic, expected)
            plan["peer_f23"]["local_import"] = "changed"
            plan["comparison"]["normalization"].append("changed")
        self.assertEqual(self.value, original)
        self.assertEqual(devin.PEER_F23["local_import"], "not_imported")
        self.assertEqual(devin.COMPARISON["normalization"], [])

    def test_raw_target_and_body_preserved_not_json_reserialized(self):
        client = self.stimulus("chat-http")["client_request"]
        self.assertEqual(client["target"], "/v1/chat/completions?synthetic=b%2Fa&synthetic=a")
        body = client["body"]["data"]
        self.assertEqual(body, '{ "model":"devin/swe-1-7", "messages":[{"role":"user","content":"SYNTHETIC café"}], "stream":false }\n')
        self.assertNotEqual(body, json.dumps(json.loads(body)))
        self.assertIn(b"caf\xc3\xa9", body.encode("utf-8"))

    def test_order_case_duplicates_preserved_in_each_direction(self):
        stimulus = self.stimulus("chat-http")
        duplicates = [["X-Synthetic", "first"], ["x-synthetic", "second"], ["X-Synthetic", "third"]]
        records = [stimulus["client_request"], stimulus["native_script"][0]["request"],
                   stimulus["native_script"][0]["response"], stimulus["client_projection"]]
        for record in records:
            self.assertIsInstance(record["headers"], list)
            self.assertEqual([pair for pair in record["headers"] if pair[0].lower() == "x-synthetic"],
                             duplicates)

    def test_literal_basic_auth_and_nested_body_credentials_both_slots(self):
        for request in self.value["payloads"]["native_requests"].values():
            token = devin.CONTEXT["credentials"][request["credential_slot"]]
            self.assertIn(["Authorization", "Basic " + token + "-" + token], request["headers"])
            raw = base64.b64decode(request["body"]["data"], validate=True)
            self.assertIn(b"\x1a\x1f" + token.encode("ascii"), raw)
            self.assertNotIn(b"refresh_token", raw)

    def test_bounded_synthetic_binary_lengths_and_connect_framing(self):
        samples = devin._known_binary()
        self.assertLessEqual(sum(sample["byte_length"] for sample in samples.values()), 4096)
        for sample in samples.values():
            self.assertEqual(sample["provenance"], "SYNTHETIC")
            raw = base64.b64decode(sample["data"], validate=True)
            self.assertEqual(len(raw), sample["byte_length"])
            self.assertLessEqual(len(raw), 512)
            if sample["framing"] == "connect_envelope":
                self.assertIn(raw[0], (0, 2))
                self.assertEqual(int.from_bytes(raw[1:5], "big"), len(raw) - 5)
        self.assertEqual(devin.BINARY_POLICY["raw_capture"], "unsupported")

    def test_native_split_utf8_and_usage_fields_preserved(self):
        script = self.stimulus("native-connect")["native_script"][0]
        chunks = [base64.b64decode(chunk["data"], validate=True) for chunk in script["response"]["body_chunks"]]
        self.assertEqual(chunks[1][5:], b"\x1a\x01\xc3")
        self.assertTrue(chunks[2][5:].startswith(b"\x1a\x01\xa9"))
        self.assertIn(b"\x3a\x04\x10\x03\x18\x02", chunks[2])  # usage field7: input3/output2
        self.assertEqual(script["read_segmentation_bytes"], [1, 3, 11])
        self.assertIsNone(self.stimulus("native-connect")["client_projection"])

    def test_connect_trailer_and_client_sse_are_separate_proposals(self):
        stimulus = self.stimulus("chat-sse")
        native = stimulus["native_script"][0]["response"]["body_chunks"]
        self.assertEqual(base64.b64decode(native[-1]["data"]), b"\x02\x00\x00\x00\x02{}")
        chunks = [chunk["data"] for chunk in stimulus["client_projection"]["body_chunks"]]
        self.assertTrue(chunks[0].endswith("da"))
        self.assertTrue(chunks[1].startswith("ta: "))
        self.assertEqual("".join(chunks).count("data: [DONE]\r\n\r\n"), 1)
        self.assertIn(": SYNTHETIC heartbeat\r\n\r\n", "".join(chunks))
        self.assertEqual(self.plan("chat-sse")["assertion_execution"], "not_run")

    def test_distinct_buffered_chat_messages_responses_and_sse(self):
        targets = {"chat-http": "/v1/chat/completions?synthetic=b%2Fa&synthetic=a",
                   "messages-http": "/v1/messages", "responses-http": "/v1/responses",
                   "responses-sse": "/v1/responses"}
        for suffix, target in targets.items():
            stimulus = self.stimulus(suffix)
            self.assertEqual(stimulus["client_request"]["target"], target)
            projection = stimulus["client_projection"]
            self.assertEqual(projection["headers"][0][1],
                             "text/event-stream" if suffix.endswith("-sse") else "application/json")
            self.assertIsNone(self.plan(suffix)["qualification"]["qualified_target_identity"])
        self.assertIn('"response.completed"', "".join(chunk["data"] for chunk in
                      self.stimulus("responses-sse")["client_projection"]["body_chunks"]))

    def test_tool_result_and_thinking_signature_sketches_not_encoder_proof(self):
        tools = self.stimulus("tools")
        self.assertEqual(tools["client_request"]["body"]["data"].count('"call_id":"synthetic-call"'), 2)
        self.assertIn('"tools"', tools["client_request"]["body"]["data"])
        native = base64.b64decode(tools["native_script"][0]["response"]["body_chunks"][0]["data"])
        self.assertIn(b"synthetic.lookup", native)
        self.assertIn('{"q":"café"}'.encode("utf-8"), native)
        thinking = self.stimulus("thinking")
        client = json.loads(thinking["client_request"]["body"]["data"])
        block = client["messages"][0]["content"][0]
        self.assertEqual(base64.b64decode(block["signature"]), b"synthetic-signature")
        self.assertEqual(block["devin_signature_type"], "synthetic-type")
        for stimulus in (tools, thinking):
            self.assertIsNone(stimulus["client_projection"])

    def test_pkce_import_are_data_not_login_or_discovery(self):
        for suffix in ("auth-pkce", "auth-import"):
            stimulus = self.stimulus(suffix)
            self.assertIsNone(stimulus["client_request"])
            self.assertEqual(stimulus["native_script"], [])
        pkce = json.loads(self.stimulus("auth-pkce")["local_input"]["data"])
        self.assertNotEqual(pkce["state"], pkce["wrong_state"])
        imported = json.loads(self.stimulus("auth-import")["local_input"]["data"])
        self.assertEqual(imported["session_token"], devin.CONTEXT["credentials"]["synthetic-a"])
        self.assertIsNone(imported["refresh_token"])

    def test_model_status_unary_proto_not_framed_chat_or_invented_results(self):
        for suffix, tail in (("models", "GetCliModelConfigs"), ("status-quota", "GetUserStatus")):
            script = self.stimulus(suffix)["native_script"][0]
            self.assertTrue(script["request"]["target"].endswith(tail))
            self.assertEqual(script["request"]["headers"][0], ["Content-Type", "application/proto"])
            self.assertEqual(script["request"]["body"]["framing"], "unframed_protobuf")
            self.assertFalse(any(name == "Sentry-Trace" for name, _ in script["request"]["headers"]))
            self.assertIsNone(script["response"])

    def test_estimate_counts_utf8_payload_bytes_without_upstream_tokenizer(self):
        stimulus = self.stimulus("count-estimate")
        payload = stimulus["local_input"]["data"]
        self.assertGreater(len(payload.encode("utf-8")), len(payload))
        self.assertEqual(len(payload.encode("utf-8")) // 4, 3)
        self.assertEqual(stimulus["native_script"], [])
        self.assertIsNone(stimulus["client_projection"])

    def test_isolation_has_independent_target_state_and_two_synthetic_accounts(self):
        stimulus = self.stimulus("persisted-isolation")
        a, b = (script["request"] for script in stimulus["native_script"])
        self.assertNotEqual(a["credential_slot"], b["credential_slot"])
        self.assertNotEqual(a["body"], b["body"])
        state = json.loads(stimulus["local_input"]["data"])
        self.assertEqual(state["sessions"], ["synthetic-session-a", "synthetic-session-b"])
        self.assertEqual(stimulus["synthetic_context"]["manager_state"], "independent_per_target")
        self.assertEqual(state["restart"], "proposal_only")

    def test_error_scopes_are_proposals_not_status_only_replay(self):
        for suffix, scope, status, reauthorize in (
            ("trailer-auth", "CREDENTIAL", 401, True),
            ("trailer-invalid", "REQUEST", 400, False),
            ("trailer-quota", "REQUEST", 429, False),
            ("429-failover", "REQUEST", 429, False),
        ):
            plan = self.plan(suffix)
            expected = plan["expected"]
            self.assertEqual((expected["scope"], expected["proposed_classified_status"],
                              expected["reauthorize"]), (scope, status, reauthorize))
            self.assertEqual(expected["delivery"], "Uncertain")
            self.assertFalse(expected["retry"])
            self.assertFalse(expected["fallback"])
            self.assertEqual(plan["assertion_execution"], "not_run")
        response = self.stimulus("trailer-auth")["native_script"][0]["response"]
        self.assertEqual(response["status"], 200)  # HTTP status != proposed trailer classification.

    def test_cancel_and_truncation_never_eof_success_or_replay(self):
        cancel = self.stimulus("stream-lifecycle")["native_script"][0]["response"]
        self.assertEqual(cancel["termination"], "cancel")
        truncated = self.stimulus("truncated")["native_script"][0]["response"]["body_chunks"][-1]
        raw = base64.b64decode(truncated["data"])
        self.assertGreater(int.from_bytes(raw[1:5], "big"), len(raw) - 5)
        for suffix in ("stream-lifecycle", "truncated"):
            expected = self.plan(suffix)["expected"]
            self.assertEqual(expected["scope"], "REQUEST")
            self.assertFalse(expected["retry"])
            self.assertEqual(expected["delivery"], "Uncertain")

    def test_unsupported_media_compression_unknown_h2_remote_no_fallback(self):
        for suffix in ("multimodal", "compressed", "unknown-field", "h2", "remote"):
            plan = self.plan(suffix)
            self.assertEqual(plan["expected"]["reference_contract"], "unsupported")
            self.assertFalse(plan["expected"]["fallback"])
            self.assertEqual(plan["difference"]["status"], "decision_required")
            self.assertEqual(plan["difference"]["normalization"], [])
        h2 = self.stimulus("h2")["native_script"][0]
        remote = self.stimulus("remote")["native_script"][0]
        self.assertEqual(h2["transport"], "http/2")
        self.assertEqual(remote["origin"], "https://devin.synthetic.invalid")
        media = self.stimulus("multimodal")
        self.assertEqual(media["native_script"], [])
        self.assertIn("synthetic.invalid/never-fetch", media["client_request"]["body"]["data"])
        self.assertIn("not_a_valid_image_fixture", self.plan("multimodal")["planned_assertions"])

    def test_f23_admitted_coordinator_checkpoint_unimported_not_global_denial(self):
        plan = self.plan("chat-sse")
        peer = plan["peer_f23"]
        self.assertEqual(peer["coordinator_revision"], "428b7671452a4c637ca227411f02bc1760d66349")
        self.assertEqual(peer["provider_revision"], "9facbe42122bb436fbd74db2f7edd2ae8bee76f3")
        self.assertEqual(peer["coordinator_admission"], "ACCEPTED_experimental_LOCAL_ChatSSE")
        self.assertEqual(peer["local_import"], "not_imported")
        self.assertEqual(peer["local_qualification"], "not_qualified")
        self.assertEqual(plan["qualification"]["h2_native_source"], "pending")
        self.assertEqual(plan["qualification"]["remote_binary"], "closed_separate_qualification")
        self.assertEqual(plan["qualification"]["messages_responses"], "unknown_unqualified")

    def test_all_results_blocked_not_run_future_hashes_null_hard_stops(self):
        report = devin.blocked_report()
        self.assertEqual(report["historical_strict37"], "0/37_unchanged")
        for result in (report, *report["cases"]):
            self.assertEqual(result["status"], "blocked")
            self.assertEqual(result["feature_status"], "BLOCKED")
            self.assertEqual(result["provenance"], "SYNTHETIC")
            for name in ("execution_status", "paired_execution", "cpa_execution",
                         "mimic_execution", "assertion_execution"):
                self.assertEqual(result[name], "not_run")
            self.assertEqual(result["future_result_hashes"], {name: None for name in devin.HASH_ROLES})
            self.assertTrue(set(devin.HARD_BLOCKERS).issubset(result["blockers"]))
            self.assertEqual(result["dependencies"],
                             {name: "not_admitted_locally" for name in devin.DEPENDENCIES})
        self.assertEqual(report["native_acceptance"], "not_run")
        self.assertEqual(report["live_verified"], "not_run")

    def test_report_hashes_only_four_owned_local_files(self):
        opened = []
        original_open = Path.open
        def audited(path, *args, **kwargs):
            opened.append(path.relative_to(devin.ROOT).as_posix())
            return original_open(path, *args, **kwargs)
        with patch.object(Path, "open", autospec=True, side_effect=audited):
            report = devin.blocked_report(scenario_id=self.first_id)
        self.assertEqual(set(opened), set(devin.LOCAL_FILES))
        self.assertEqual(len(opened), 5)  # Fixture read once for validation, once for hash.
        self.assertEqual(report["local_file_sha256"], {
            name: hashlib.sha256((devin.ROOT / name).read_bytes()).hexdigest()
            for name in devin.LOCAL_FILES
        })

    def test_no_harness_production_ambient_or_binary_decoder_imports(self):
        source = ast.parse((devin.ROOT / devin.DRIVER).read_text(encoding="utf-8"))
        modules = set()
        for node in ast.walk(source):
            if isinstance(node, ast.Import):
                modules.update(alias.name for alias in node.names)
            if isinstance(node, ast.ImportFrom):
                modules.add(node.module)
            if isinstance(node, ast.Attribute):
                self.assertNotIn(node.attr, ("b64decode", "environ", "getenv", "home",
                                             "expanduser", "glob", "rglob", "connect", "spawn"))
        self.assertEqual(modules, {"argparse", "base64", "copy", "hashlib", "json", "pathlib", "sys"})
        public = {node.name for node in source.body if isinstance(node, ast.FunctionDef)
                  and not node.name.startswith("_")}
        self.assertEqual(public, {"load_fixture", "case_plan", "blocked_report", "main"})

    def test_reject_unknown_provenance_and_approval_even_on_unused_samples(self):
        for update in ({"provenance": "captured"}, {"approval": "APPROVED"},
                       {"f01_mapping": "frozen"}, {"schema": "mimic.final-parity-contract/v1"}):
            with self.subTest(update=update):
                self.reject(lambda value: value.update(update))
        self.reject(lambda value: value["payloads"]["native_requests"]["models-b"]["body"].update(
            provenance="unknown"))

    def test_reject_unknown_binary_credentials_base64_lengths_and_framing(self):
        body = self.value["payloads"]["native_requests"]["chat-a"]["body"]
        token = devin.CONTEXT["credentials"]["synthetic-a"].encode("ascii")
        unknown = base64.b64decode(body["data"]).replace(token, b"untrusted-synthetic-placeholder")
        changes = (
            {"data": base64.b64encode(unknown).decode("ascii")},
            {"data": body["data"] + "\n"}, {"data": "%%%"},
            {"data": base64.b64encode(b"SYNTHETIC" * 513).decode("ascii")},
            {"byte_length": 1}, {"framing": "raw_capture"}, {"encoding": "gzip"},
        )
        with patch.object(base64, "b64decode", side_effect=AssertionError("must not decode input")):
            for change in changes:
                with self.subTest(change=list(change)):
                    self.reject(lambda value: value["payloads"]["native_requests"]["chat-a"]["body"].update(change))

    def test_reject_unknown_header_body_target_or_import_credentials(self):
        mutations = (
            lambda value: value["payloads"]["native_requests"]["chat-a"]["headers"].append(
                ["Authorization", "Basic untrusted-synthetic-placeholder"]),
            lambda value: value["payloads"]["client_requests"]["chat"]["body"].update(
                data='{"token":"untrusted-synthetic-placeholder"}'),
            lambda value: value["payloads"]["local_inputs"]["import"].update(
                data='{"session_token":"untrusted-synthetic-placeholder"}'),
            lambda value: value["synthetic_context"]["origins"].update(
                **{"synthetic-local": "https://localhost:8317"}),
            lambda value: value["payloads"]["native_requests"]["chat-a"].update(
                target="/v1/sessions"),
            lambda value: value["payloads"]["native_requests"]["chat-a"]["headers"].reverse(),
        )
        for mutate in mutations:
            self.reject(mutate)

    def test_reject_unknown_bindings_rows_fields_scopes_and_missing_cases(self):
        mutations = (
            lambda value: value.update(capture_path="/synthetic/not-readable"),
            lambda value: value["cases"].pop(),
            lambda value: value["cases"][0].update(row_id="devin-new-row"),
            lambda value: value["cases"][0].update(primary_case_id="devin-auth-pkce.final-v2"),
            lambda value: value["cases"][0].update(control="match"),
            lambda value: value["cases"][2].update(native_pairs=[["status-a", "ok"]]),
            lambda value: value["qualification"].update(qualified_target_identity="unknown"),
            lambda value: value["dependencies"].update(F23="admitted"),
            lambda value: value["comparison"].update(normalization=["sort_headers"]),
        )
        for mutate in mutations:
            self.reject(mutate)

    def test_reject_numeric_type_coercion_in_closed_literal_vocabulary(self):
        self.reject(lambda value: value["synthetic_context"].update(clock_ms=1000.0))
        self.reject(lambda value: value["payloads"]["native_responses"]["ok"].update(status=200.0))
        self.reject(lambda value: value["payloads"]["native_requests"]["chat-a"]["body"].update(
            byte_length=172.0))

    def test_loader_rejects_duplicate_non_utf8_binary_and_oversized_file(self):
        for raw in (b'{"schema":1,"schema":2}', b"\xff", b"\x00\x00\x00\x00\x01x",
                    b" " * (devin.MAX_FILE_BYTES + 1)):
            with patch.object(Path, "open", return_value=io.BytesIO(raw)):
                with self.assertRaises((ValueError, UnicodeError)):
                    devin.load_fixture()

    def test_reader_is_bounded_and_rejects_other_paths_before_open(self):
        with patch.object(Path, "open") as opened:
            opened.return_value.__enter__.return_value.read.return_value = b"x"
            self.assertEqual(devin._read_local(devin.ROOT, devin.FIXTURE), b"x")
            opened.return_value.__enter__.return_value.read.assert_called_once_with(
                devin.MAX_FILE_BYTES + 1)
        with patch.object(Path, "open") as opened:
            with self.assertRaises(ValueError):
                devin._read_local(devin.ROOT, "synthetic-credentials.json")
            opened.assert_not_called()

    def test_cli_blocked_two_for_all_and_selected_cases_in_process(self):
        for argv, count in (([], 25), (["--case", self.first_id], 1)):
            with redirect_stdout(io.StringIO()) as stdout:
                code = devin.main(argv)
            report = json.loads(stdout.getvalue())
            self.assertEqual(code, 2)
            self.assertEqual(report["status"], "blocked")
            self.assertEqual(len(report["cases"]), count)

    def test_cli_rejected_one_no_payload_echo_or_launch_flags(self):
        for argv in (["--case", "untrusted-synthetic-placeholder"],
                     ["--case"], ["--launch"], ["--root", "/synthetic"],
                     ["--capture", "synthetic.bin"], ["--ca", "synthetic-ca"]):
            with redirect_stdout(io.StringIO()) as stdout:
                code = devin.main(argv)
            report = json.loads(stdout.getvalue())
            self.assertEqual(code, 1)
            self.assertEqual(report["status"], "rejected")
            self.assertEqual(report["execution_status"], "not_run")
            self.assertNotIn("untrusted-synthetic-placeholder", stdout.getvalue())
        with patch.object(devin, "_read_local", side_effect=ValueError("untrusted-synthetic-placeholder")):
            with redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(devin.main([]), 1)
            self.assertNotIn("untrusted-synthetic-placeholder", stdout.getvalue())


if __name__ == "__main__":
    with safe_unit_tests.execution_guards():
        unittest.main(verbosity=2)
