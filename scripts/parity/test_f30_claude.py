"""Pure F30 payload/plan tests; run under safe_unit_tests.execution_guards."""
from contextlib import redirect_stderr, redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import f30_claude as claude
import safe_unit_tests


class ClaudePreparationTest(unittest.TestCase):
    def setUp(self):
        self.value = claude.load_fixture()
        self.first_id = self.value["cases"][0]["id"]

    def case(self, suffix):
        return next(case for case in self.value["cases"]
                    if case["id"] == "final-v1-claude-" + suffix)

    def reject_mutation(self, mutate):
        value = deepcopy(self.value)
        mutate(value)
        with self.assertRaises(ValueError):
            claude.case_plan(value, self.first_id)

    def test_every_future_pair_gets_identical_independent_stimulus(self):
        original = deepcopy(self.value)
        for case in self.value["cases"]:
            with self.subTest(case=case["id"]):
                plan = claude.case_plan(self.value, case["id"])
                self.assertEqual(plan["paired_stimuli"]["cpa"], case["stimulus"])
                self.assertEqual(plan["paired_stimuli"]["mimic"], case["stimulus"])
                plan["paired_stimuli"]["cpa"]["request"]["headers"][0][0] = "changed"
                self.assertEqual(plan["paired_stimuli"]["mimic"], case["stimulus"])
        self.assertEqual(self.value, original)

    def test_order_duplicate_and_case_preserved_in_both_directions(self):
        plan = claude.case_plan(self.value, self.first_id)
        expected_request = [
            ["Content-Type", "application/json"],
            ["Authorization", "Bearer synthetic-client"],
            ["X-Synthetic", "first"], ["x-synthetic", "mixed-case"],
            ["X-Synthetic", "second"],
            ["Anthropic-Beta", "synthetic-beta-b,synthetic-beta-a"],
            ["anthropic-beta", "synthetic-beta-b"],
        ]
        expected_response = [
            ["Content-Type", "application/json"],
            ["X-Synthetic", "first"], ["x-synthetic", "mixed-case"],
            ["X-Synthetic", "second"],
        ]
        for stimulus in plan["paired_stimuli"].values():
            self.assertEqual(stimulus["request"]["headers"], expected_request)
            self.assertEqual(stimulus["responses"][0]["headers"], expected_response)

    def test_raw_target_whitespace_unicode_and_extension_order_preserved(self):
        expected = (
            '{ "model":"synthetic-model", "max_tokens":8, '
            '"messages":[{"role":"user","content":"SYNTHETIC café"}], '
            '"synthetic_extension":{"b":2,"a":1} }\n'
        )
        request = claude.case_plan(
            self.value, self.first_id)["paired_stimuli"]["cpa"]["request"]
        self.assertEqual(request["target"], "/v1/messages?beta=true")
        self.assertEqual(request["body"].encode("utf-8"), expected.encode("utf-8"))
        count = self.case("count-wire")["stimulus"]
        self.assertEqual(count["request"]["target"], "/v1/messages/count_tokens")
        self.assertEqual(count["responses"][0]["body_chunks"], ['{ "input_tokens":7 }\n'])

    def test_duplicate_provider_json_is_raw_stimulus_not_envelope_normalization(self):
        request = self.case("duplicate-user-id")["stimulus"]["request"]["body"]
        token = self.case("refresh-duplicate-envelope")[
            "stimulus"]["responses"][0]["body_chunks"][0]
        self.assertIn('"user_id":"synthetic-first"', request)
        self.assertIn('"user\\u005fid":"synthetic-second"', request)
        self.assertIn('"refresh_token":"synthetic-first"', token)
        self.assertIn('"refresh\\u005ftoken":"synthetic-second"', token)
        ambiguous = self.case("refresh-429-ambiguous")[
            "stimulus"]["responses"][0]["body_chunks"][0]
        self.assertEqual(ambiguous, '{"error":"rate_limit_error","error":"invalid_grant"}')
        for suffix in ("duplicate-user-id", "refresh-duplicate-envelope",
                       "refresh-429-ambiguous"):
            case = self.case(suffix)
            plan = claude.case_plan(self.value, case["id"])
            self.assertEqual(plan["paired_stimuli"]["mimic"], case["stimulus"])

    def test_sse_chunks_signature_tools_and_terminal_are_not_reframed(self):
        case = self.case("sse-tool-thinking")
        stimulus = claude.case_plan(
            self.value, case["id"])["paired_stimuli"]["cpa"]
        chunks = stimulus["responses"][0]["body_chunks"]
        self.assertEqual(chunks, case["stimulus"]["responses"][0]["body_chunks"])
        self.assertTrue(chunks[6].endswith("\r\nda"))
        self.assertTrue(chunks[7].startswith("ta: "))
        body = "".join(chunks)
        self.assertIn('"signature":"synthetic-signature"', body)
        self.assertIn('"id":"synthetic-tool-1"', body)
        self.assertIn('"partial_json":"{\\\"text\\\":\\\"SYNTHETIC\\\"}"', body)
        self.assertEqual(body.count("event: message_stop\r\n"), 1)
        self.assertIn(": SYNTHETIC heartbeat\r\n\r\n", body)

    def test_mappings_are_historical_claude_rows_but_not_approved(self):
        historical = json.loads((claude.ROOT / "test/parity/v2/manifest.json").read_text())
        rows = {row["id"] for row in historical["capabilities"]
                if row["provider"] == "claude"}
        self.assertEqual(set(claude.ROW_IDS), rows)
        self.assertEqual(self.value["cpa_revision"], historical["cpa_revision"])
        for case in self.value["cases"]:
            self.assertIn(case["row_id"], rows)
            self.assertEqual(case["primary_case_id"], case["row_id"] + ".final-v1")
            plan = claude.case_plan(self.value, case["id"])
            self.assertEqual(plan["f01_mapping"], "pending")
            self.assertEqual(plan["approval"], "pending_f01_mapping_and_qualification")
            self.assertNotEqual(plan["schema"], "mimic.final-parity-plan/v1")

    def test_every_plan_is_blocked_with_no_assertion_execution(self):
        for case in self.value["cases"]:
            plan = claude.case_plan(self.value, case["id"])
            self.assertEqual(plan["status"], "blocked")
            self.assertEqual(plan["assertion_execution"], "not_run")
            for dependency in ("F03", "F08", "F09", "F10"):
                self.assertIn("dependency_not_admitted:" + dependency, plan["blockers"])
            self.assertIn(
                "pinned_cpa_unconditionally_starts_antigravity_version_updater",
                plan["blockers"])
            self.assertIn("candidate_descendant_containment_unavailable", plan["blockers"])
            self.assertTrue(set(claude.REQUIRED_OBSERVATIONS).issubset(
                plan["planned_assertions"]))
            self.assertNotIn("passed", plan)
            self.assertNotIn("observations", plan)

    def test_report_distinguishes_local_byte_hashes_from_unknown_run_bindings(self):
        report = claude.blocked_report()
        self.assertEqual(report["status"], "blocked")
        self.assertEqual(report["historical_strict37"], "0/37_unchanged")
        for key in ("paired_execution", "cpa_execution", "mimic_execution", "live_verified"):
            self.assertEqual(report[key], "not_run")
        self.assertEqual(report["hash_binding_status"], "unknown_not_verified")
        self.assertEqual(set(report["future_result_hashes"]), set(claude.HASH_ROLES))
        self.assertTrue(all(value is None for value in report["future_result_hashes"].values()))
        for name, digest in report["local_file_sha256"].items():
            self.assertEqual(digest, hashlib.sha256(
                (claude.ROOT / name).read_bytes()).hexdigest())
        self.assertEqual(len(report["cases"]), len(self.value["cases"]))
        selected = claude.blocked_report(scenario_id=self.first_id)
        self.assertEqual(len(selected["cases"]), 1)

    def test_exact_request_credential_and_token_error_scopes_remain_distinct(self):
        bad_request = self.case("request-400")["expected"]
        credential = self.case("credential-401")["expected"]
        model = self.case("request-model-mismatch")["expected"]
        refresh = self.case("refresh-429-json")["expected"]
        ambiguous = self.case("refresh-duplicate-envelope")["expected"]
        ambiguous_429 = self.case("refresh-429-ambiguous")["expected"]
        grant = self.case("refresh-invalid-grant")["expected"]
        permission = self.case("request-403")["expected"]
        self.assertEqual((bad_request["scope"], bad_request["retry"]), ("request", False))
        self.assertEqual((credential["scope"], credential["failure"], credential["send_state"],
                          credential["retry"]),
                         ("credential", "CredentialUnavailable", "Rejected", True))
        self.assertEqual((model["scope"], model["failure"], model["send_state"]),
                         ("request", "Unsupported", "NotSent"))
        self.assertEqual((refresh["scope"], refresh["failure"]),
                         ("credential_refresh", "RefreshRateLimited"))
        self.assertEqual((ambiguous["scope"], ambiguous["failure"]),
                         ("credential_refresh", "RefreshUnavailable"))
        self.assertEqual((ambiguous_429["scope"], ambiguous_429["failure"]),
                         ("credential_refresh", "RefreshUnavailable"))
        self.assertEqual((grant["scope"], grant["failure"]),
                         ("credential_refresh", "InvalidGrant"))
        self.assertEqual((permission["scope"], permission["retry"],
                          permission["downstream_status"]), ("request", False, 502))
        for suffix in ("messages-429-fast-refusal", "messages-429-quota"):
            case = self.case(suffix)
            self.assertEqual(case["expected"], {
                "kind": "decision_required", "scope": "ambiguous_response",
                "failure": "Unsupported", "send_state": "Rejected",
                "downstream_status": 503, "quota_effect": "none", "retry": False,
            })
            self.assertEqual(case["difference"]["status"], "decision_required")

    def test_hardening_differences_survive_planning_without_normalization(self):
        for suffix in ("helper-hour-rejected", "invalid-cache-order", "duplicate-user-id",
                       "refresh-duplicate-envelope", "refresh-429-ambiguous",
                       "request-403", "messages-429-quota"):
            case = self.case(suffix)
            plan = claude.case_plan(self.value, case["id"])
            self.assertEqual(plan["difference"], case["difference"])
            self.assertEqual(plan["difference"]["status"], "decision_required")
            self.assertEqual(plan["comparison"]["normalization"], "none")
        self.reject_mutation(lambda value: value["comparison"].update(normalization="sort_headers"))
        self.reject_mutation(lambda value: value["cases"][0]["difference"].update(
            normalization="drop_private_fields"))

    def test_unknown_scenario_provider_row_and_extra_fields_rejected(self):
        with self.assertRaises(ValueError):
            claude.case_plan(self.value, "claude-messages.final-v1")
        self.reject_mutation(lambda value: value.update(provider="unknown"))
        self.reject_mutation(lambda value: value["cases"][0].update(row_id="claude-sse"))
        self.reject_mutation(lambda value: value.update(allow_execution=True))
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"].update(endpoint="https://localhost:8317"))

    def test_unsupported_transport_encoding_auth_policy_and_target_rejected(self):
        for field, invalid in (
            ("transport", "http/2"), ("transport", "websocket"),
            ("body_encoding", "binary"), ("content_encoding", "gzip"),
            ("auth_mode", "ambient"),
        ):
            with self.subTest(field=field, value=invalid):
                self.reject_mutation(lambda value: value["cases"][0]["stimulus"].update(
                    {field: invalid}))
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
            "operator_policy"].update(profile="infer_from_user_agent"))
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
            "request"].update(target="https://localhost:8317/v1/messages"))
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
            "request"].update(body={"model": "synthetic-model"}))

    def test_lossy_headers_compression_and_header_injection_rejected(self):
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
            "request"].update(headers={"X-Synthetic": "second"}))
        for headers in (
            [["Content-Encoding", "gzip"]],
            [["X-Synthetic", "bad\r\ninjection"]],
            [["X-Synthetic: bad", "value"]],
        ):
            with self.subTest(headers=headers):
                self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
                    "request"].update(headers=headers))
        self.reject_mutation(lambda value: value["cases"][0]["stimulus"][
            "responses"][0].update(body_chunks=[b"binary"]))

    def test_stale_pins_approval_dependency_admission_and_quota_claims_rejected(self):
        self.reject_mutation(lambda value: value.update(mimic_base_revision="unknown"))
        self.reject_mutation(lambda value: value.update(cpa_revision="unknown"))
        self.reject_mutation(lambda value: value.update(approval="approved"))
        self.reject_mutation(lambda value: value["dependencies"].update(F10="admitted"))
        self.reject_mutation(lambda value: value.update(required_future_hashes=["fixture"]))
        self.reject_mutation(lambda value: value["cases"][0]["expected"].update(
            failure="Quota", quota_effect="cooldown", retry=True))

    def test_duplicate_envelope_keys_and_non_utf8_are_rejected(self):
        for raw in (b'{"slice":"F30","sl\\u0069ce":"F30"}', b"\xff"):
            with self.subTest(raw=raw), patch.object(Path, "read_bytes", return_value=raw):
                with self.assertRaises((ValueError, UnicodeError)):
                    claude.load_fixture()

    def test_cli_cannot_claim_success_or_select_a_run_mode(self):
        output = io.StringIO()
        with redirect_stdout(output):
            code = claude.main(["--case", self.first_id])
        self.assertEqual(code, 2)
        self.assertEqual(json.loads(output.getvalue())["status"], "blocked")
        output = io.StringIO()
        with redirect_stdout(output):
            code = claude.main(["--case", "unknown"])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["paired_execution"], "not_run")
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            claude.main(["--run"])
        self.assertEqual(error.exception.code, 2)

    def test_missing_fixture_is_sanitized_rejection_not_automatic_pass(self):
        output = io.StringIO()
        with patch.object(Path, "read_bytes", side_effect=OSError("synthetic-private-detail")):
            with redirect_stdout(output):
                code = claude.main([])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(output.getvalue())["status"], "rejected")
        self.assertNotIn("synthetic-private-detail", output.getvalue())

    def test_existing_audit_guard_rejects_process_and_network_events(self):
        # Audit events only: no process/network API is called.
        with safe_unit_tests.execution_guards():
            for event in ("subprocess.Popen", "os.exec", "os.posix_spawn",
                          "socket.connect", "socket.bind", "socket.getaddrinfo",
                          "socket.sendto"):
                with self.subTest(event=event), self.assertRaises(AssertionError):
                    sys.audit(event, "SYNTHETIC guard control")
