import gleam/option.{None}
import gleeunit/should
import mimic/types.{Capture, Header, Transport}
import mimic/wire

pub fn ordered_headers_round_trip_test() {
  let raw =
    "POST /v1/messages HTTP/1.1\r\nHoSt: example.test\r\nX-Test: first\r\nx-test: second\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
  let capture =
    wire.parse_request(raw, "synthetic", "1", "example.test", "messages")
    |> should.be_ok
  capture.headers
  |> should.equal([
    Header("HoSt", "example.test"),
    Header("X-Test", "first"),
    Header("x-test", "second"),
    Header("Content-Type", "application/json"),
    Header("Content-Length", "7"),
  ])
  capture.transport |> should.equal(Transport("http/1.1", None))
  wire.render_request(capture) |> should.equal(Ok(raw))
}

pub fn unsupported_framing_rejected_test() {
  let raw = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
  wire.parse_request(raw, "synthetic", "1", "local", "test")
  |> should.be_error
}

pub fn stale_length_rejected_test() {
  let raw =
    "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{}"
  wire.parse_request(raw, "synthetic", "1", "local", "test")
  |> should.be_error
}

pub fn h2_rejected_test() {
  wire.parse_request("GET / HTTP/2\r\n\r\n", "synthetic", "1", "local", "test")
  |> should.be_error
}

pub fn no_alpn_is_valid_for_http_1_1_test() {
  let raw = "GET /v1/messages HTTP/1.1\r\nHost: fixture.test\r\n\r\n"
  let capture =
    wire.parse_request(raw, "synthetic", "1", "fixture.test", "messages")
    |> should.be_ok
  let no_alpn = Capture(..capture, transport: Transport("none", None))
  wire.render_request(no_alpn) |> should.equal(Ok(raw))
  let h2 = Capture(..capture, transport: Transport("h2", None))
  wire.render_request(h2) |> should.be_error
}
