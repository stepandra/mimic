/// Synthetic localhost tests at the actual Mist/glisten socket boundary.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth
import mist

@external(erlang, "mimic_f44_http_boundary_test_ffi", "run")
pub fn main() -> Nil

@external(erlang, "mimic_f44_http_boundary_test_ffi", "exchange")
fn exchange(
  port: Int,
  parts: List(BitArray),
  responses: Int,
  expect_close: Bool,
) -> Result(List(#(String, Int, BitArray)), String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "sequential")
fn sequential(
  port: Int,
  requests: List(BitArray),
) -> Result(List(#(String, Int, BitArray)), String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "websocket")
fn websocket_exchange(port: Int, split: Int) -> Result(String, String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "websocket_with_upgrade")
fn websocket_with_upgrade(
  port: Int,
  split: Int,
  upgrade: String,
) -> Result(String, String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "stop")
fn stop_server(pid: process.Pid) -> Nil

@external(erlang, "mimic_f44_http_boundary_test_ffi", "timeout_probe")
fn timeout_probe(port: Int) -> Result(Int, String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "head_timeout_probe")
fn head_timeout_probe(port: Int) -> Result(Int, String)

@external(erlang, "mimic_f44_http_boundary_test_ffi", "connection_abi")
fn connection_abi(conn: mist.Connection) -> Bool

@external(erlang, "mimic_f44_http_boundary_test_ffi", "retained_frame")
fn retained_frame(conn: mist.Connection) -> Bool

@external(erlang, "mimic_f44_http_boundary_test_ffi", "without_unexpected_messages")
fn without_unexpected_messages(pid: process.Pid, run: fn() -> Nil) -> Bool

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

type Server {
  Server(
    port: Int,
    pid: process.Pid,
    dispatched: process.Subject(#(String, String)),
  )
}

fn stream_body(
  consume: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  body: BitArray,
) -> Result(BitArray, mist.ReadError) {
  use chunk <- result.try(consume(2))
  case chunk {
    mist.Done -> {
      // A repeated terminal token must not enqueue a second completion.
      consume(2) |> should.equal(Ok(mist.Done))
      Ok(body)
    }
    mist.Chunk(data, consume) ->
      stream_body(consume, bit_array.append(body, data))
  }
}

fn serve() -> Server {
  let ready = process.new_subject()
  let dispatched = process.new_subject()
  let handler = fn(req: request.Request(mist.Connection)) {
    connection_abi(req.body) |> should.be_true
    let read = case req.path {
      "/ignore" -> Ok(<<>>)
      "/stream" ->
        mist.stream(req)
        |> result.try(stream_body(_, <<>>))
      "/guard" -> mist.read_body(req, 4) |> result.map(fn(req) { req.body })
      _ -> mist.read_body(req, 4096) |> result.map(fn(req) { req.body })
    }
    let #(status, body) = case read {
      Ok(bytes) -> #(200, bit_array.to_string(bytes) |> result.unwrap("BINARY"))
      Error(mist.ExcessBody) -> #(413, "EXCESS")
      Error(mist.MalformedBody) -> #(400, "MALFORMED")
    }
    process.send(dispatched, #(req.path, body))
    let resp =
      response.new(status)
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(req.path <> ":" <> body)),
      )
    case req.path {
      "/last" -> response.set_header(resp, "connection", "close")
      "/response-close" -> response.set_header(resp, "connection", "Close")
      "/response-close-list" ->
        response.set_header(resp, "connection", "keep-alive, \tClOsE\t ")
      "/response-close-first" ->
        resp
        |> response.prepend_header("connection", "keep-alive")
        |> response.prepend_header("connection", "Close")
      "/response-close-last" ->
        resp
        |> response.prepend_header("connection", "Close")
        |> response.prepend_header("connection", "keep-alive")
      _ -> resp
    }
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ready, 5000)
  Server(port, server.pid, dispatched)
}

fn wire(
  method: String,
  path: String,
  headers: String,
  body: String,
) -> BitArray {
  bit_array.from_string(
    method
    <> " "
    <> path
    <> " HTTP/1.1\r\nHost: localhost\r\n"
    <> headers
    <> "\r\n"
    <> body,
  )
}

fn pair(first: BitArray) -> BitArray {
  bit_array.append(first, wire("GET", "/last", "", ""))
}

fn split_at(data: BitArray, offset: Int) -> List(BitArray) {
  let assert Ok(first) = bit_array.slice(data, 0, offset)
  let assert Ok(rest) =
    bit_array.slice(data, offset, bit_array.byte_size(data) - offset)
  [first, rest]
}

fn fragments(data: BitArray, size: Int) -> List(BitArray) {
  case bit_array.byte_size(data) <= size {
    True -> [data]
    False -> {
      let assert [first, rest] = split_at(data, size)
      [first, ..fragments(rest, size)]
    }
  }
}

// Keep individual lines small: this probes the cumulative wire-byte budget,
// not an incidental decoder line-size limit. Host counts as a raw field too.
fn padded_head(bytes: Int) -> BitArray {
  let fields =
    string.repeat("X-Fill: " <> string.repeat("a", 1000) <> "\r\n", 64)
  let base = wire("GET", "/one", fields <> "X-End: \r\n", "")
  wire(
    "GET",
    "/one",
    fields
      <> "X-End: "
      <> string.repeat("b", bytes - bit_array.byte_size(base))
      <> "\r\n",
    "",
  )
}

fn expected(path: String, body: String) {
  [
    #("HTTP/1.1", 200, bit_array.from_string(path <> ":" <> body)),
    #("HTTP/1.1", 200, <<"/last:":utf8>>),
  ]
}

fn observations(server: Server, first: String, body: String) {
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#(first, body)))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/last", "")))
  process.receive(server.dispatched, 0) |> should.be_error
}

pub fn sequential_get_get_and_post_get_control_test() {
  let server = serve()
  list.each(
    [
      #(wire("GET", "/one", "", ""), ""),
      #(wire("POST", "/one", "Content-Length: 4\r\n", "DATA"), "DATA"),
    ],
    fn(control) {
      sequential(server.port, [control.0, wire("GET", "/last", "", "")])
      |> should.equal(Ok(expected("/one", control.1)))
      observations(server, "/one", control.1)
    },
  )
  stop_server(server.pid)
}

pub fn coalesced_get_get_and_fixed_post_get_test() {
  let server = serve()
  list.each(
    [
      #(wire("GET", "/one", "", ""), ""),
      #(wire("POST", "/one", "Content-Length: 4\r\n", "DATA"), "DATA"),
      #(wire("POST", "/one", "Content-Length: 0\r\n", ""), ""),
      #(wire("POST", "/one", "Content-Length: \t0004 \t\r\n", "DATA"), "DATA"),
      #(wire("DELETE", "/one", "", ""), ""),
      #(wire("POST", "/one", "", ""), ""),
    ],
    fn(control) {
      exchange(server.port, [pair(control.0)], 2, True)
      |> should.equal(Ok(expected("/one", control.1)))
      observations(server, "/one", control.1)
    },
  )
  stop_server(server.pid)
}

pub fn every_fixed_request_pair_byte_split_test() {
  let server = serve()
  list.each(
    [
      #("GET", "/one", "", ""),
      #("POST", "/one", "Content-Length: 4\r\n", "DATA"),
      #("POST", "/stream", "Content-Length: 4\r\n", "DATA"),
    ],
    fn(control) {
      let requests = pair(wire(control.0, control.1, control.2, control.3))
      int.range(1, bit_array.byte_size(requests), Nil, fn(_, offset) {
        let assert Ok(first) = bit_array.slice(requests, 0, offset)
        let assert Ok(rest) =
          bit_array.slice(
            requests,
            offset,
            bit_array.byte_size(requests) - offset,
          )
        exchange(server.port, [first, rest], 2, True)
        |> should.equal(Ok(expected(control.1, control.3)))
        observations(server, control.1, control.3)
      })
    },
  )
  stop_server(server.pid)
}

pub fn multiple_coalesced_requests_and_streaming_fixed_body_test() {
  let server = serve()
  let first = wire("POST", "/stream", "Content-Length: 6\r\n", "ABCDEF")
  let second = wire("GET", "/middle", "", "")
  let third = wire("GET", "/last", "", "")
  exchange(server.port, [bit_array.concat([first, second, third])], 3, True)
  |> should.equal(
    Ok([
      #("HTTP/1.1", 200, <<"/stream:ABCDEF":utf8>>),
      #("HTTP/1.1", 200, <<"/middle:":utf8>>),
      #("HTTP/1.1", 200, <<"/last:":utf8>>),
    ]),
  )
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/stream", "ABCDEF")))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/middle", "")))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/last", "")))
  stop_server(server.pid)
}

pub fn chunked_body_trailers_tail_and_byte_splits_test() {
  let server = serve()
  let encoded = "2;synthetic=yes\r\nDA\r\n2\r\nTA\r\n0\r\nX-Test: yes\r\n\r\n"
  list.each(["/one", "/stream"], fn(path) {
    let requests =
      pair(wire("POST", path, "Transfer-Encoding: Chunked\r\n", encoded))
    int.range(1, bit_array.byte_size(requests), Nil, fn(_, offset) {
      let assert Ok(first) = bit_array.slice(requests, 0, offset)
      let assert Ok(rest) =
        bit_array.slice(
          requests,
          offset,
          bit_array.byte_size(requests) - offset,
        )
      exchange(server.port, [first, rest], 2, True)
      |> should.equal(Ok(expected(path, "DATA")))
      observations(server, path, "DATA")
    })
    exchange(server.port, [requests], 2, True)
    |> should.equal(Ok(expected(path, "DATA")))
    observations(server, path, "DATA")
  })
  stop_server(server.pid)
}

pub fn ambiguous_framing_rejected_without_any_dispatch_test() {
  let server = serve()
  let headers = [
    "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n",
    "Transfer-Encoding: chunked\r\nContent-Length: 4\r\n",
    "Content-Length: 4\r\ncontent-length: 4\r\n",
    "Content-Length: 3\r\nCONTENT-LENGTH: 4\r\n",
    "Transfer-Encoding: chunked\r\ntransfer-encoding: chunked\r\n",
    "Content-Length: -1\r\n",
    "Content-Length: +1\r\n",
    "Content-Length: 1, 1\r\n",
    "Content-Length: 1.0\r\n",
    "Content-Length: \r\n",
    "Content-Length: invalid\r\n",
    "Transfer-Encoding: gzip\r\n",
    "Transfer-Encoding: gzip, chunked\r\n",
    "Transfer-Encoding: chunked, chunked\r\n",
    "Transfer-Encoding: identity\r\n",
    "Transfer-Encoding: \r\n",
  ]
  list.each(headers, fn(headers) {
    exchange(
      server.port,
      [pair(wire("POST", "/one", headers, "DATA"))],
      0,
      True,
    )
    |> should.equal(Ok([]))
    process.receive(server.dispatched, 0) |> should.be_error
  })
  stop_server(server.pid)
}

pub fn duplicate_ui_security_headers_rejected_without_any_dispatch_test() {
  let server = serve()
  list.each(
    [
      #("Origin", "http://127.0.0.1", "https://invalid.test"),
      #("X-CSRF-Token", "synthetic-a", "synthetic-b"),
      #("Cookie", "session=synthetic-a", "session=synthetic-b"),
      #("Authorization", "Bearer synthetic-a", "Bearer synthetic-b"),
    ],
    fn(header) {
      list.each([#(header.1, header.2), #(header.2, header.1)], fn(values) {
        let headers =
          header.0
          <> ": "
          <> values.0
          <> "\r\n"
          <> string.lowercase(header.0)
          <> ": "
          <> values.1
          <> "\r\n"
        exchange(server.port, [pair(wire("GET", "/one", headers, ""))], 0, True)
        |> should.equal(Ok([]))
        process.receive(server.dispatched, 0) |> should.be_error
      })
    },
  )
  stop_server(server.pid)
}

pub fn rejected_size_or_unread_body_closes_before_next_dispatch_test() {
  let server = serve()
  // Rejection must not wait for a missing body, nor dispatch a retained tail
  // after a route ignores even a fully coalesced body.
  list.each(
    [
      #("/guard", "1000000000", "", 413, "EXCESS"),
      #("/guard", "8", "TOO-LONG", 413, "EXCESS"),
      #("/ignore", "1000", "", 200, ""),
      #("/ignore", "4", "DATA", 200, ""),
    ],
    fn(control) {
      exchange(
        server.port,
        [
          pair(wire(
            "POST",
            control.0,
            "Content-Length: " <> control.1 <> "\r\n",
            control.2,
          )),
        ],
        1,
        True,
      )
      |> should.equal(
        Ok([
          #(
            "HTTP/1.1",
            control.3,
            bit_array.from_string(control.0 <> ":" <> control.4),
          ),
        ]),
      )
      process.receive(server.dispatched, 100)
      |> should.equal(Ok(#(control.0, control.4)))
      process.receive(server.dispatched, 0) |> should.be_error
    },
  )
  stop_server(server.pid)
}

pub fn chunked_size_guard_and_malformed_terminator_close_test() {
  let server = serve()
  exchange(
    server.port,
    [pair(wire("POST", "/guard", "Transfer-Encoding: chunked\r\n", "5\r\n"))],
    1,
    True,
  )
  |> should.equal(Ok([#("HTTP/1.1", 413, <<"/guard:EXCESS":utf8>>)]))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/guard", "EXCESS")))
  exchange(
    server.port,
    [pair(wire("POST", "/one", "Transfer-Encoding: chunked\r\n", "2\r\nDAxx"))],
    1,
    True,
  )
  |> should.equal(Ok([#("HTTP/1.1", 400, <<"/one:MALFORMED":utf8>>)]))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/one", "MALFORMED")))
  process.receive(server.dispatched, 0) |> should.be_error
  stop_server(server.pid)
}

pub fn http10_single_body_and_request_close_controls_test() {
  let server = serve()
  let legacy =
    wire("POST", "/one", "Content-Length: 4\r\n", "DATA")
    |> bit_array.to_string
    |> should.be_ok
    |> string.replace("HTTP/1.1", "HTTP/1.0")
    |> bit_array.from_string
  exchange(server.port, [legacy], 1, True)
  |> should.equal(Ok([#("HTTP/1.0", 200, <<"/one:DATA":utf8>>)]))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/one", "DATA")))
  exchange(
    server.port,
    [pair(wire("GET", "/one", "Connection: close\r\n", ""))],
    1,
    True,
  )
  |> should.equal(Ok([#("HTTP/1.1", 200, <<"/one:":utf8>>)]))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/one", "")))
  process.receive(server.dispatched, 0) |> should.be_error
  stop_server(server.pid)
}

pub fn duplicate_connection_and_response_close_tokens_stop_pipeline_test() {
  let server = serve()
  list.each(
    [
      #("/one", "Connection: close\r\nConnection: keep-alive\r\n"),
      #("/one", "Connection: keep-alive\r\nConnection: Close\r\n"),
      #("/one", "Connection: Keep-Alive, \tClOsE\t \r\n"),
      #("/response-close", ""),
      #("/response-close-list", ""),
      #("/response-close-first", ""),
      #("/response-close-last", ""),
    ],
    fn(control) {
      let requests = pair(wire("GET", control.0, control.1, ""))
      list.each([[requests], split_at(requests, 1)], fn(parts) {
        exchange(server.port, parts, 1, True)
        |> should.equal(
          Ok([#("HTTP/1.1", 200, bit_array.from_string(control.0 <> ":"))]),
        )
        process.receive(server.dispatched, 100)
        |> should.equal(Ok(#(control.0, "")))
        process.receive(server.dispatched, 0) |> should.be_error
      })
    },
  )
  // Legal repeated Connection fields without close still allow reuse.
  exchange(
    server.port,
    [
      pair(wire(
        "GET",
        "/one",
        "Connection: keep-alive\r\nConnection: Upgrade\r\n",
        "",
      )),
    ],
    2,
    True,
  )
  |> should.equal(Ok(expected("/one", "")))
  observations(server, "/one", "")
  stop_server(server.pid)
}

pub fn rejected_ows_websocket_upgrade_never_dispatches_http_tail_test() {
  let server = serve()
  list.each(["websocket", "websocket\t", " \tWeBsOcKeT \t"], fn(upgrade) {
    let first =
      wire(
        "GET",
        "/ignore",
        "Connection: Upgrade\r\nUpgrade: " <> upgrade <> "\r\n",
        "",
      )
    // Even if the retained bytes happen to be a valid HTTP request, an
    // ordinary response to a WS upgrade must close, not reinterpret them.
    exchange(server.port, [pair(first)], 1, True)
    |> should.equal(Ok([#("HTTP/1.1", 200, <<"/ignore:":utf8>>)]))
    process.receive(server.dispatched, 100)
    |> should.equal(Ok(#("/ignore", "")))
    process.receive(server.dispatched, 0) |> should.be_error
  })
  stop_server(server.pid)
}

pub fn request_head_byte_and_raw_field_limits_are_per_request_test() {
  let server = serve()
  let exact_bytes = padded_head(65_536)
  bit_array.byte_size(exact_bytes) |> should.equal(65_536)
  let exact_fields = wire("GET", "/one", string.repeat("X-Test: a\r\n", 99), "")
  list.each([exact_bytes, exact_fields], fn(first) {
    let requests = pair(first)
    list.each([[requests], fragments(requests, 1024)], fn(parts) {
      exchange(server.port, parts, 2, True)
      |> should.equal(Ok(expected("/one", "")))
      observations(server, "/one", "")
    })
  })
  let fixed =
    padded_head(65_536 - bit_array.byte_size(<<"Content-Length: 4\r\n":utf8>>))
    |> bit_array.to_string
    |> should.be_ok
    |> string.replace("X-End: ", "Content-Length: 4\r\nX-End: ")
    |> bit_array.from_string
  bit_array.byte_size(fixed) |> should.equal(65_536)
  exchange(
    server.port,
    [pair(bit_array.append(fixed, <<"DATA":utf8>>))],
    2,
    True,
  )
  |> should.equal(Ok(expected("/one", "DATA")))
  observations(server, "/one", "DATA")
  // Two near-limit heads on one connection have separate byte budgets.
  let first = padded_head(65_536)
  let last =
    padded_head(65_536)
    |> bit_array.to_string
    |> should.be_ok
    |> string.replace("/one", "/end")
    |> bit_array.from_string
  exchange(
    server.port,
    [bit_array.concat([first, last, wire("GET", "/last", "", "")])],
    3,
    True,
  )
  |> should.equal(
    Ok([
      #("HTTP/1.1", 200, <<"/one:":utf8>>),
      #("HTTP/1.1", 200, <<"/end:":utf8>>),
      #("HTTP/1.1", 200, <<"/last:":utf8>>),
    ]),
  )
  process.receive(server.dispatched, 100) |> should.equal(Ok(#("/one", "")))
  process.receive(server.dispatched, 100) |> should.equal(Ok(#("/end", "")))
  process.receive(server.dispatched, 100) |> should.equal(Ok(#("/last", "")))
  process.receive(server.dispatched, 0) |> should.be_error
  list.each(
    [
      pair(padded_head(65_537)),
      pair(wire("GET", "/one", string.repeat("X-Test: a\r\n", 100), "")),
      bit_array.from_string("GET /" <> string.repeat("a", 65_536)),
      bit_array.from_string(
        "GET /one HTTP/1.1\r\nHost: localhost\r\nX-Long: "
        <> string.repeat("a", 65_536),
      ),
    ],
    fn(requests) {
      list.each([[requests], split_at(requests, 1024)], fn(parts) {
        exchange(server.port, parts, 0, True) |> should.equal(Ok([]))
        process.receive(server.dispatched, 0) |> should.be_error
      })
    },
  )
  stop_server(server.pid)
}

pub fn request_line_and_header_progress_share_one_absolute_deadline_test() {
  let server = serve()
  let elapsed = head_timeout_probe(server.port) |> should.be_ok
  should.be_true(elapsed >= 14_000)
  should.be_true(elapsed < 17_500)
  process.receive(server.dispatched, 0) |> should.be_error
  // An expired head must not poison a fresh connection.
  exchange(server.port, [pair(wire("GET", "/one", "", ""))], 2, True)
  |> should.equal(Ok(expected("/one", "")))
  observations(server, "/one", "")
  stop_server(server.pid)
}

pub fn chunked_cumulative_size_and_metadata_bounds_test() {
  let server = serve()
  let encoded = "3\r\nABC\r\n2\r\n"
  exchange(
    server.port,
    [pair(wire("POST", "/guard", "Transfer-Encoding: chunked\r\n", encoded))],
    1,
    True,
  )
  |> should.equal(Ok([#("HTTP/1.1", 413, <<"/guard:EXCESS":utf8>>)]))
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/guard", "EXCESS")))
  let malformed = [
    "-1\r\n",
    "1x\r\n",
    "1 \r\n",
    "1;x=" <> string.repeat("a", 8192) <> "\r\nA\r\n0\r\n\r\n",
    string.repeat("1;x=" <> string.repeat("a", 1000) <> "\r\nA\r\n", 66)
      <> "0\r\n\r\n",
    "0\r\nX-Test: " <> string.repeat("a", 8192) <> "\r\n\r\n",
    "0\r\n"
      <> string.repeat("X-Test: " <> string.repeat("a", 1000) <> "\r\n", 66)
      <> "\r\n",
    "0\r\nContent-Length: 4\r\n\r\n",
  ]
  list.each(malformed, fn(encoded) {
    exchange(
      server.port,
      [pair(wire("POST", "/one", "Transfer-Encoding: chunked\r\n", encoded))],
      1,
      True,
    )
    |> should.equal(Ok([#("HTTP/1.1", 400, <<"/one:MALFORMED":utf8>>)]))
    process.receive(server.dispatched, 100)
    |> should.equal(Ok(#("/one", "MALFORMED")))
    process.receive(server.dispatched, 0) |> should.be_error
  })
  stop_server(server.pid)
}

pub fn chunked_progress_does_not_reset_socket_read_deadline_test() {
  let server = serve()
  let elapsed = timeout_probe(server.port) |> should.be_ok
  should.be_true(elapsed >= 14_000)
  should.be_true(elapsed < 17_500)
  process.receive(server.dispatched, 100)
  |> should.equal(Ok(#("/one", "MALFORMED")))
  process.receive(server.dispatched, 0) |> should.be_error
  stop_server(server.pid)
}

pub fn coalesced_http1_oauth_callback_preserves_initial_and_cleanup_test() {
  let port = free_port()
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let config =
    auth.claude_config(
      "synthetic-f44",
      "http://127.0.0.1:1/authorize",
      "http://127.0.0.1:1/token",
      origin <> "/callback",
    )
  let assert Ok(login) = auth.begin_login(config, "synthetic-f44")
  let reply = process.new_subject()
  auth.await_callback(config, login, 5000, fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        let first =
          wire(
            "GET",
            "/callback?state=" <> login.state <> "&code=synthetic-f44",
            "",
            "",
          )
        process.send(reply, exchange(port, [pair(first)], 1, True))
      })
    Nil
  })
  |> should.equal(Ok(#(login.state, "synthetic-f44")))
  process.receive(reply, 5000)
  |> should.equal(
    Ok(
      Ok([
        #("HTTP/1.1", 200, <<
          "Callback received. You may close this window.":utf8,
        >>),
      ]),
    ),
  )
}

pub fn websocket_upgrade_retains_coalesced_and_partial_frame_test() {
  let ready = process.new_subject()
  let handler = fn(req) {
    mist.websocket(
      request: req,
      handler: fn(state, message, connection) {
        case message {
          mist.Text(text) -> {
            let _ = mist.send_text_frame(connection, text)
            mist.continue(state)
          }
          _ -> mist.continue(state)
        }
      },
      on_init: fn(_) { #(Nil, None) },
      on_close: fn(_) { Nil },
    )
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ready, 5000)
  list.each([0, 1, 5, 8], fn(split) {
    websocket_exchange(port, split) |> should.equal(Ok("synthetic"))
  })
  list.each(["websocket\t", " \tWeBsOcKeT \t"], fn(upgrade) {
    list.each([0, 1, 5, 8], fn(split) {
      websocket_with_upgrade(port, split, upgrade)
      |> should.equal(Ok("synthetic"))
    })
  })
  stop_server(server.pid)
}

type SelectorEvent {
  ReplaceSelector
  ReplacementSelected
}

pub fn queued_on_init_selector_replacement_preserves_retained_frame_test() {
  let ready = process.new_subject()
  let entered = process.new_subject()
  let handed_off = process.new_subject()
  let selected = process.new_subject()
  let echoed = process.new_subject()
  let handler = fn(req: request.Request(mist.Connection)) {
    // Assert the precondition too: this test must not accidentally pass by
    // receiving the frame later as a socket message instead of retained bytes.
    retained_frame(req.body) |> should.be_true
    let resp =
      mist.websocket(
        request: req,
        handler: fn(state, message, connection) {
          case message {
            mist.Custom(ReplaceSelector) -> {
              let release = process.new_subject()
              process.send(entered, release)
              let assert Ok(Nil) = process.receive(release, 5000)
              let replacement = process.new_subject()
              process.send(replacement, ReplacementSelected)
              mist.continue(replacement)
              |> mist.with_selector(
                process.new_selector() |> process.select(replacement),
              )
            }
            mist.Custom(ReplacementSelected) -> {
              process.send(selected, Nil)
              mist.continue(state)
            }
            mist.Text(text) -> {
              // Exercise a second replacement from the frame-handler path.
              // Retain the same user subject so its already-queued control
              // message is not intentionally abandoned by a new user topic.
              process.send(state, ReplacementSelected)
              let assert Ok(Nil) = mist.send_text_frame(connection, text)
              mist.continue(state)
              |> mist.with_selector(
                process.new_selector() |> process.select(state),
              )
            }
            _ -> mist.continue(state)
          }
        },
        on_init: fn(_) {
          let custom = process.new_subject()
          process.send(custom, ReplaceSelector)
          #(custom, Some(process.new_selector() |> process.select(custom)))
        },
        on_close: fn(_) { Nil },
      )
    // Returning from mist.websocket proves controlling_process succeeded
    // and receive_initial queued the retained bytes. Do not use sleeps.
    process.send(handed_off, Nil)
    resp
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ready, 5000)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(echoed, websocket_exchange(port, 0))
    })
  let release = process.receive(entered, 2000) |> should.be_ok
  process.receive(handed_off, 2000) |> should.equal(Ok(Nil))
  let ws_pid = process.subject_owner(release) |> should.be_ok
  without_unexpected_messages(ws_pid, fn() {
    process.send(release, Nil)
    process.receive(echoed, 3000) |> should.equal(Ok(Ok("synthetic")))
    process.receive(selected, 100) |> should.equal(Ok(Nil))
    process.receive(selected, 100) |> should.equal(Ok(Nil))
  })
  |> should.be_true
  stop_server(server.pid)
}
