/// Synthetic loopback socket proof for the additive egress deadline seam.
/// No provider, credential, gateway or shared ABI changes.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/egress
import mimic/providers/contracts
import mimic/types.{Capture, Header, Transport}

type Fixture

@external(erlang, "mimic_claude_f10_test_ffi", "start_script")
fn fixture(scripts: List(List(#(Int, BitArray)))) -> Fixture

@external(erlang, "mimic_claude_f10_test_ffi", "port")
fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "closed")
fn closed(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "sent")
fn sent(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "requests")
fn requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_claude_f10_test_ffi", "stop")
fn stop(fixture: Fixture) -> Nil

// Exactly the production clock. BEAM monotonic milliseconds may be negative.
@external(erlang, "mimic_egress_ffi", "now_ms")
fn now_ms() -> Int

pub fn main() {
  expired_buffered_fixed_and_terminal_do_not_consume_test()
  expired_buffered_chunk_size_and_trailer_do_not_consume_test()
  expired_pending_chunk_continuation_does_not_consume_test()
  nested_separator_and_trailer_share_absolute_deadline_test()
  repeated_drip_pulls_share_total_deadline_test()
  raw_field_and_media_normalization_is_http_ows_only_test()
  io.println(
    "PASS: F10 egress absolute deadline, raw headers, expired/drip/cleanup (6 tests)",
  )
}

fn bytes(delay, value) {
  #(delay, bit_array.from_string(value))
}

fn head(framing) {
  "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\n"
  <> framing
  <> "\r\n\r\n"
}

fn open(script) {
  let #(fixture, opened) = open_result(script)
  let assert Ok(#(429, _, stream)) = opened
  #(fixture, stream)
}

fn open_result(script) {
  let fixture = fixture([script])
  let host = "127.0.0.1:" <> int.to_string(port(fixture))
  let endpoint = "http://" <> host
  let capture =
    Capture(
      "synthetic",
      "f10",
      endpoint,
      "test",
      "POST",
      "/v1/messages",
      "HTTP/1.1",
      [
        Header("Host", host),
        Header("Content-Type", "application/json"),
        Header("Content-Length", "2"),
      ],
      "{}",
      Transport("http/1.1", None),
    )
  #(fixture, egress.stream_open(endpoint, capture, None))
}

fn expired(stream) {
  let before = now_ms()
  egress.stream_next_before(stream, before - 1)
  |> should.equal(
    Error(contracts.Failure(
      contracts.InvalidResponse,
      contracts.Uncertain,
      None,
    )),
  )
  { now_ms() - before < 100 } |> should.be_true
}

fn cleanup(fixture, stream) {
  // Reader never closes. One caller-owned cancellation closes one connection.
  closed(fixture) |> should.equal(0)
  egress.stream_cancel(stream)
  await(fn() { closed(fixture) == 1 }, 200)
  requests(fixture) |> list.length |> should.equal(1)
  stop(fixture)
}

fn await(predicate, remaining) {
  case predicate(), remaining {
    True, _ -> Nil
    False, 0 -> should.fail()
    False, _ -> {
      process.sleep(5)
      await(predicate, remaining - 1)
    }
  }
}

pub fn expired_buffered_fixed_and_terminal_do_not_consume_test() {
  let #(fixture, stream) = open([bytes(0, head("Content-Length: 2") <> "{}")])
  await(fn() { sent(fixture) == 1 }, 200)
  expired(stream)
  let assert Ok(Some(#(body, terminal))) = egress.stream_next(stream)
  body |> should.equal(bit_array.from_string("{}"))
  expired(terminal)
  egress.stream_next(terminal) |> should.equal(Ok(None))
  cleanup(fixture, stream)

  let #(fixture, stream) = open([bytes(0, head("Content-Length: 0"))])
  expired(stream)
  egress.stream_next(stream) |> should.equal(Ok(None))
  cleanup(fixture, stream)
}

pub fn expired_buffered_chunk_size_and_trailer_do_not_consume_test() {
  let #(fixture, stream) =
    open([
      bytes(0, head("Transfer-Encoding: chunked") <> "2\r\n{}\r\n0\r\n\r\n"),
    ])
  await(fn() { sent(fixture) == 1 }, 200)
  expired(stream)
  let assert Ok(Some(#(body, terminal))) = egress.stream_next(stream)
  body |> should.equal(bit_array.from_string("{}"))
  expired(terminal)
  // If expiry consumed the buffered zero-size line/trailer, this cannot succeed.
  egress.stream_next(terminal) |> should.equal(Ok(None))
  cleanup(fixture, stream)
}

pub fn expired_pending_chunk_continuation_does_not_consume_test() {
  let body = string.repeat("a", 16_385)
  let #(fixture, stream) =
    open([
      bytes(
        0,
        head("Transfer-Encoding: chunked")
          <> "4001\r\n"
          <> body
          <> "\r\n0\r\n\r\n",
      ),
    ])
  await(fn() { sent(fixture) == 1 }, 200)
  let assert Ok(Some(#(first, continuation))) =
    egress.stream_next_before(stream, now_ms() + 500)
  bit_array.byte_size(first) |> should.equal(16_384)
  expired(continuation)
  let assert Ok(Some(#(last, terminal))) = egress.stream_next(continuation)
  last |> should.equal(bit_array.from_string("a"))
  egress.stream_next(terminal) |> should.equal(Ok(None))
  cleanup(fixture, stream)
}

pub fn nested_separator_and_trailer_share_absolute_deadline_test() {
  list.each(
    [
      [bytes(25, "2\r\n"), bytes(25, "{}"), bytes(150, "\r\n0\r\n\r\n")],
      [bytes(25, "0\r\n"), bytes(175, "\r\n")],
    ],
    fn(rest) {
      let #(fixture, stream) =
        open([bytes(0, head("Transfer-Encoding: chunked")), ..rest])
      let before = now_ms()
      let deadline = before + 100
      egress.stream_next_before(stream, deadline) |> should.be_error
      let elapsed = now_ms() - before
      { elapsed >= 70 && elapsed < 180 } |> should.be_true
      cleanup(fixture, stream)
    },
  )
}

pub fn repeated_drip_pulls_share_total_deadline_test() {
  let #(fixture, stream) =
    open([
      bytes(0, head("Transfer-Encoding: chunked")),
      bytes(30, "1\r\na\r\n"),
      bytes(30, "1\r\nb\r\n"),
      bytes(30, "1\r\nc\r\n"),
      bytes(150, "0\r\n\r\n"),
    ])
  let before = now_ms()
  let deadline = before + 110
  let count = pull_until_deadline(stream, deadline, 0)
  // Scheduling/TCP ACKs need not deliver exactly three chunks before expiry.
  // At least one successful continuation followed by timeout proves one total
  // deadline across pulls; a per-pull reset would reach clean EOF instead.
  { count >= 1 && count <= 3 } |> should.be_true
  let elapsed = now_ms() - before
  { elapsed >= 80 && elapsed < 190 } |> should.be_true
  cleanup(fixture, stream)
}

fn pull_until_deadline(stream, deadline, count) {
  case egress.stream_next_before(stream, deadline) {
    Error(_) -> count
    Ok(Some(#(_, next))) -> pull_until_deadline(next, deadline, count + 1)
    Ok(None) -> panic as "Total deadline must expire before clean EOF"
  }
}

pub fn raw_field_and_media_normalization_is_http_ows_only_test() {
  list.each(
    [
      "Content-Type: \u{000b}application/json\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: \u{200e}application/json\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/json;\u{200e}charset=utf-8\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/json,application/problem+json\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/bad/subtype+json\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/+json\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/json; charset=utf-8; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}",
      "Content-Type: application/json\r\nContent-Length: \u{000b}2\r\n\r\n{}",
      "Content-Type: application/json\r\nContent-Length: \u{200e}2\r\n\r\n{}",
      "Content-Type: application/json\r\nTransfer-Encoding: \u{200e}chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n",
    ],
    fn(fields) {
      let #(fixture, opened) =
        open_result([bytes(0, "HTTP/1.1 429 Synthetic\r\n" <> fields)])
      case opened {
        Error(_) -> Nil
        Ok(#(_, _, stream)) -> {
          egress.stream_cancel(stream)
          should.fail()
        }
      }
      await(fn() { closed(fixture) == 1 }, 200)
      requests(fixture) |> list.length |> should.equal(1)
      stop(fixture)
    },
  )
  // Noncritical valid UTF-8 bytes survive; only SP/HTAB edges are stripped.
  let value = "\u{0301}\u{200e}synthetic\u{200e}"
  let #(fixture, opened) =
    open_result([
      bytes(
        0,
        "HTTP/1.1 429 Synthetic\r\nContent-Type:\t application/problem+json \t\r\nContent-Length:\t 2 \t\r\nX-Value:\t "
          <> value
          <> " \t\r\n\r\n{}",
      ),
    ])
  let assert Ok(#(429, headers, stream)) = opened
  { list.contains(headers, Header("X-Value", value)) } |> should.be_true
  let assert Ok(Some(#(body, final))) = egress.stream_next(stream)
  body |> should.equal(bit_array.from_string("{}"))
  egress.stream_next(final) |> should.equal(Ok(None))
  cleanup(fixture, stream)
}
