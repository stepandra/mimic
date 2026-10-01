"""Pure synthetic fixture assertions, not MIMIC/CPA/socket execution."""

from pathlib import Path
import runpy
import unittest

FIXTURE = runpy.run_path(str(Path(__file__).with_name("smoke-xai-http-continuation.py")))
DENY = FIXTURE["assert_denied"]
ENCODE = FIXTURE["encoded"]


class DenialEvidenceTest(unittest.TestCase):
    def setUp(self):
        # Four inference peers and the OAuth peer, with TCP and HTTP counters.
        self.before = [(1, 1), (1, 1), (1, 1), (1, 1), (0, 0)]
        self.error = ENCODE({"error": {"message": "unsupported xAI request"}})

    def test_explicit_unsupported_without_any_activity_is_denial(self):
        DENY(422, "application/json", self.error, self.before, list(self.before))

    def test_stateless_acceptance_cannot_be_relabelled_continuation_or_denial(self):
        with self.assertRaises(AssertionError):
            DENY(200, "application/json", ENCODE({"id": "synthetic", "output": []}),
                 self.before, self.before)

    def test_connection_without_http_is_still_upstream_activity(self):
        after = list(self.before)
        after[0] = (2, 1)
        with self.assertRaises(AssertionError):
            DENY(422, "application/json", self.error, self.before, after)

    def test_oauth_refresh_is_not_ignored_by_inference_counters(self):
        after = list(self.before)
        after[-1] = (1, 1)
        with self.assertRaises(AssertionError):
            DENY(422, "application/json", self.error, self.before, after)

    def test_sse_error_is_not_the_prescribed_http_json_denial(self):
        with self.assertRaises(AssertionError):
            DENY(422, "text/event-stream", self.error, self.before, self.before)

    def test_broken_gateway_is_not_a_successful_unsupported_guard(self):
        with self.assertRaises(AssertionError):
            DENY(503, "application/json", self.error, self.before, self.before)

    def test_synthetic_secret_echo_is_detected(self):
        with self.assertRaises(AssertionError):
            FIXTURE["no_secrets"](FIXTURE["CLIENTS"][0].encode())


if __name__ == "__main__":
    unittest.main()
