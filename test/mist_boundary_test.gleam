import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import mist

pub fn main() {
  gleeunit.main()
}

@external(erlang, "mimic_mist_boundary_test_ffi", "request")
fn raw_request(port: Int, bytes: String) -> String

@external(erlang, "mimic_mist_boundary_test_ffi", "handshake")
fn raw_handshake(port: Int, bytes: String) -> String

fn serve() -> Int {
  let port_reply = process.new_subject()
  let handler = fn(req) {
    let body = case mist.read_body(req, 4096) {
      Ok(read) -> bit_array.to_string(read.body) |> result.unwrap("")
      Error(_) -> ""
    }
    let body = case body {
      "" -> "OK"
      value -> value
    }
    response.new(200)
    |> response.prepend_header("connection", "close")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  }
  let assert Ok(_server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(port_reply, port) })
    |> mist.start
  let assert Ok(port) = process.receive(port_reply, 5000)
  port
}

fn send(port: Int, version: String, headers: List(String), body: String) {
  let bytes =
    "GET / HTTP/"
    <> version
    <> "\r\n"
    <> "Host: localhost\r\n"
    <> string.join(headers, "")
    <> "\r\n"
    <> body
  raw_request(port, bytes)
}

fn accepted(response: String) {
  response |> string.contains("SOCKET_TIMEOUT") |> should.be_false
  response |> string.contains(" 200 ") |> should.be_true
}

fn rejected(response: String) {
  response |> string.contains("SOCKET_TIMEOUT") |> should.be_false
  response |> string.contains(" 200 ") |> should.be_false
}

pub fn authorization_duplicate_both_orders_and_case_test() {
  let port = serve()
  let pairs = [
    ["Authorization: Bearer invalid\r\n", "authorization: Bearer valid\r\n"],
    ["authorization: Bearer valid\r\n", "AUTHORIZATION: Bearer invalid\r\n"],
  ]
  list.each(pairs, fn(headers) { send(port, "1.1", headers, "") |> rejected })
}

pub fn host_duplicate_both_orders_and_case_test() {
  let port = serve()
  send(port, "1.1", ["hOSt: alternative\r\n"], "") |> rejected
  raw_request(
    port,
    "GET / HTTP/1.1\r\nHost: alternative\r\nhOSt: localhost\r\n\r\n",
  )
  |> rejected
}

pub fn websocket_singletons_duplicate_both_orders_and_case_test() {
  let port = serve()
  let singletons = [
    #("Upgrade", "websocket"),
    #("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="),
    #("Sec-WebSocket-Version", "13"),
    #("Sec-WebSocket-Protocol", "chat"),
    #("Sec-WebSocket-Extensions", "permessage-deflate"),
  ]
  list.each(singletons, fn(header) {
    let name = header.0
    let value = header.1
    list.each(
      [
        [
          name <> ": " <> value <> "\r\n",
          string.lowercase(name) <> ": other\r\n",
        ],
        [
          string.lowercase(name) <> ": other\r\n",
          name <> ": " <> value <> "\r\n",
        ],
      ],
      fn(headers) { send(port, "1.1", headers, "") |> rejected },
    )
  })
}

pub fn http_version_upgrade_boundary_test() {
  let port = serve()
  send(port, "1.0", ["Upgrade: websocket\r\n"], "") |> rejected
  send(port, "1.0", [], "") |> accepted
  send(port, "1.1", ["Upgrade: websocket\r\n"], "") |> accepted
}

pub fn valid_websocket_http11_handshake_test() {
  let port_reply = process.new_subject()
  let handler = fn(req) {
    mist.websocket(
      request: req,
      handler: fn(state, _, _) { mist.continue(state) },
      on_init: fn(_) { #(Nil, None) },
      on_close: fn(_) { Nil },
    )
  }
  let assert Ok(_server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(port_reply, port) })
    |> mist.start
  let assert Ok(port) = process.receive(port_reply, 5000)
  let response =
    raw_handshake(
      port,
      "GET /ws HTTP/1.1\r\n"
        <> "Host: localhost\r\n"
        <> "Connection: Upgrade\r\n"
        <> "Upgrade: websocket\r\n"
        <> "Sec-WebSocket-Version: 13\r\n"
        <> "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    )
  response |> string.contains("SOCKET_TIMEOUT") |> should.be_false
  response |> string.contains(" 101 ") |> should.be_true
}

pub fn list_valued_duplicates_and_coalesced_body_test() {
  let port = serve()
  let response =
    send(
      port,
      "1.1",
      [
        "Connection: keep-alive\r\n",
        "cOnNeCtIoN: close\r\n",
        "Accept: application/json\r\n",
        "accept: text/plain\r\n",
        "Content-Length: 4\r\n",
      ],
      "DATA",
    )
  response |> accepted
  response |> string.ends_with("DATA") |> should.be_true
}
