import gleam/int
import gleam/string
import gleeunit/should
import mimic/check
import mimic/demo
import mimic/lab
import mimic/types.{Capture, Header}
import mimic/wire

pub fn local_vertical_slice_test() {
  let root =
    ".mimic/test/integration-"
    <> int.to_string(timestamp())
    <> "-"
    <> int.to_string(unique_id())
  let assert Ok(report) = demo.run(root)
  string.contains(report, "\"deduplicated\":true") |> should.be_true
  string.contains(report, "\"replay_status\":200") |> should.be_true
}

pub fn raw_wire_preserves_order_case_and_duplicates_test() {
  let raw =
    "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nX-One: a\r\nx-one: b\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(capture) =
    wire.parse_request(raw, "synthetic", "1", "http://localhost", "main")
  capture.headers
  |> should.equal([
    Header("Host", "localhost"),
    Header("X-One", "a"),
    Header("x-one", "b"),
    Header("Content-Type", "application/json"),
    Header("Content-Length", "2"),
  ])
  wire.render_request(capture) |> should.equal(Ok(raw))
}

pub fn oracle_detects_invalid_header_over_real_socket_test() {
  let config =
    lab.Config(
      required_headers: [Header("x-test-contract", "expected")],
      failure_status: 400,
      status: 200,
      response_body: "{}",
      sse_events: [],
    )
  let assert Ok(port) = lab.start_with(0, config)
  let assert Ok(missing_header) = demo.fixture(port)
  let valid =
    Capture(..missing_header, headers: [
      Header("x-test-contract", "expected"),
      ..missing_header.headers
    ])
  let positive = check.run(valid.endpoint, [valid], 5000)
  let negative = check.run(missing_header.endpoint, [missing_header], 5000)
  let stopped = lab.stop(port)
  let assert Ok(accepted) = positive
  let assert Ok(rejected) = negative
  stopped |> should.be_ok
  accepted.passed |> should.be_true
  rejected.passed |> should.be_false
}

@external(erlang, "erlang", "unique_integer")
fn unique_id() -> Int

@external(erlang, "erlang", "system_time")
fn timestamp() -> Int
