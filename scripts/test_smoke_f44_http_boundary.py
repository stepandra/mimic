"""Synthetic parser/serialization controls for the F44 real-socket smoke."""

from pathlib import Path
import json
import runpy
import unittest


SMOKE = runpy.run_path(str(Path(__file__).with_name("smoke-f44-http-boundary.py")))


class Socket:
    def __init__(self, parts):
        self.parts = iter(parts)

    def recv(self, _amount):
        return next(self.parts, b"")


def response(status, body, headers=None):
    payload = json.dumps(body, separators=(",", ":")).encode()
    fields = headers if headers is not None else [f"Content-Length: {len(payload)}"]
    return (
        f"HTTP/1.1 {status} synthetic\r\n".encode()
        + "\r\n".join(fields).encode() + b"\r\n\r\n" + payload
    )


def client(parts):
    value = SMOKE["RawClient"].__new__(SMOKE["RawClient"])
    value.socket = Socket(parts)
    value.pending = b""
    return value


class F44SmokeTest(unittest.TestCase):
    def test_wire_keeps_raw_duplicates_and_body_exactly(self):
        headers = b"Origin: synthetic-a\r\norigin: synthetic-b\r\nContent-Length: 4\r\n"
        raw = SMOKE["wire"]("POST", "/synthetic", headers, b"DATA", close=True)
        self.assertEqual(raw.count(b"Origin: synthetic-a\r\n"), 1)
        self.assertIn(b"origin: synthetic-b\r\n", raw)
        self.assertTrue(raw.endswith(b"Content-Length: 4\r\n\r\nDATA"))
        self.assertIn(b"Connection: close\r\n", raw)

    def test_padded_head_counts_only_raw_head_bytes(self):
        for size in [65536, 65537]:
            with self.subTest(size=size):
                raw = SMOKE["padded_head"](size)
                self.assertEqual(len(raw), size)
                self.assertTrue(raw.endswith(b"\r\n\r\n"))
                fields = raw.split(b"\r\n")[1:-2]
                self.assertEqual(len(fields), 67)  # Host, Authorization, 64 fills, end.
                self.assertLess(max(map(len, fields)), 2000)
                joined = raw + SMOKE["wire"]("GET", "/synthetic", close=True)
                self.assertGreater(len(joined), size)

    def test_wire_preserves_connection_field_order_and_upgrade_ows(self):
        fields = (
            b"Connection: Close\r\nConnection: keep-alive\r\n"
            b"Upgrade: \tWeBsOcKeT \t\r\n"
        )
        raw = SMOKE["wire"]("GET", "/synthetic", fields)
        self.assertIn(fields + b"\r\n", raw)
        # Auth and Host are actual raw fields, not implicit client behavior.
        self.assertEqual(len(raw.split(b"\r\n")[1:-2]), 5)

    def test_every_response_byte_split_keeps_order_and_tail(self):
        raw = response(200, {"first": "synthetic"}) + response(404, {"last": True})
        for split in range(1, len(raw)):
            with self.subTest(split=split):
                value = client([raw[:split], raw[split:]])
                self.assertEqual(value.response(), ("HTTP/1.1", 200, {"first": "synthetic"}))
                self.assertEqual(value.response(), ("HTTP/1.1", 404, {"last": True}))
                value.closed()

    def test_ambiguous_or_invalid_response_length_is_not_accepted(self):
        for headers in [
            ["Content-Length: 2", "content-length: 2"],
            ["Content-Length: -1"],
            ["Content-Length: 1000000000"],
            ["Content-Length: 2, 2"],
            ["X-Test: synthetic"],
        ]:
            with self.subTest(headers=headers):
                with self.assertRaises((AssertionError, ValueError)):
                    client([response(200, {}, headers)]).response()

    def test_truncated_response_is_not_counted_passing(self):
        with self.assertRaisesRegex(AssertionError, "closed before"):
            client([b"HTTP/1.1 200 synthetic\r\nContent-Length: 10\r\n\r\n{}"]).response()

    def test_unexpected_extra_response_is_not_zero_dispatch(self):
        with self.assertRaisesRegex(AssertionError, "unexpected response"):
            client([response(200, {})]).closed()

    def test_synthetic_credentials_in_response_fail_the_gate(self):
        for field in ["CLIENT_KEY", "UPSTREAM_KEY"]:
            with self.subTest(field=field):
                with self.assertRaises(AssertionError):
                    client([response(200, {"secret": SMOKE[field]})]).response()


if __name__ == "__main__":
    unittest.main()
