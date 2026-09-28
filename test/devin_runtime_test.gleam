import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/fleet
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response
import mimic/providers/registry
import mimic/providers/runtime

type Server

// Reuse baseline's real loopback socket fixture; binary is never decoded as
// String. All credentials in this module are deliberately synthetic.
@external(erlang, "mimic_egress_test_ffi", "start")
fn server_start(response: BitArray) -> Result(Server, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn observed(server: Server) -> List(BitArray)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn stop(server: Server) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn body() -> String {
  "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic hello\"}]}"
}

fn request() -> c.Request {
  c.Request(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "openai-chat",
    "generate",
    c.Buffered,
    [],
    "synthetic-client:request",
    None,
    body(),
  )
}

fn wire_response() -> BitArray {
  let data =
    pb.encode([
      pb.text(3, "synthetic reply"),
      pb.message(7, [pb.Varint(2, 4), pb.Varint(3, 2)]),
      pb.Varint(5, 2),
    ])
  <<{ connect.envelope(data) }:bits, 2, 2:32-big, "{}":utf8>>
}

fn http_response(status: Int, headers: String, body: BitArray) -> BitArray {
  let prefix =
    "HTTP/1.1 "
    <> int.to_string(status)
    <> " Synthetic\r\n"
    <> "Content-Type: application/connect+proto\r\n"
    <> "Content-Length: "
    <> int.to_string(bit_array.byte_size(body))
    <> "\r\n"
    <> headers
    <> "\r\n"
  <<prefix:utf8, body:bits>>
}

fn account(server: Server, id: String) -> runtime.Account {
  runtime.Account(
    "devin",
    "session_token",
    id,
    "http://127.0.0.1:" <> int.to_string(port(server)),
    fleet.LocalLoopback,
    2,
    ["devin/swe-1-7"],
    credentials.StaticSession,
  )
}

fn start(accounts: List(runtime.Account)) -> #(runtime.Runtime, storage.Store) {
  let assert Ok(store) = storage.new(directory())
  list.each(accounts, fn(a) {
    let assert Ok(_) =
      runtime_store.save(
        store,
        credentials.key("devin", "session_token", a.id),
        c.SessionToken("synthetic-" <> a.id, [
          #("user_id", "synthetic-user-" <> a.id),
        ]),
      )
  })
  let assert Ok(registry) = registry.new(bridge.models())
  let assert Ok(owner) = runtime.start(store, registry, accounts)
  #(owner, store)
}

pub fn real_socket_buffered_chat_and_messages_test() {
  let assert Ok(server) = server_start(http_response(200, "", wire_response()))
  let #(owner, _) = start([account(server, "one")])
  let assert Ok(output) = bridge.execute(owner, None, request())
  let assert Ok(decoded) = openai.decode_response(output)
  decoded.content |> should.equal([ir.Text("synthetic reply", [])])
  let messages = c.Request(..request(), protocol: "anthropic-messages")
  let assert Ok(output) = bridge.execute(owner, None, messages)
  let assert Ok(decoded) = anthropic.decode_response(output)
  decoded.stop_reason |> should.equal(Some("end_turn"))
  runtime.active_leases(owner) |> should.equal(Ok(0))
  let requests = observed(server)
  list.length(requests) |> should.equal(2)
  list.each(requests, fn(raw) {
    let #(headers, payload) = split_headers(raw, <<>>)
    string.contains(
      headers,
      "POST /exa.api_server_pb.ApiServerService/GetChatMessage HTTP/1.1",
    )
    |> should.be_true
    string.contains(headers, "Authorization: Basic synthetic-one-synthetic-one")
    |> should.be_true
    string.contains(string.lowercase(headers), "user-agent") |> should.be_false
    string.contains(string.lowercase(headers), "accept-encoding")
    |> should.be_false
    let assert <<0, size:32-big, bytes:bytes-size(size)>> = payload
    let assert Ok([pb.Bytes(1, metadata), ..]) = pb.decode(bytes)
    let assert Ok(metadata) = pb.decode(metadata)
    list.contains(metadata, pb.text(3, "synthetic-one")) |> should.be_true
  })
  runtime.stop(owner) |> should.be_ok
  stop(server)
}

fn split_headers(raw: BitArray, acc: BitArray) -> #(String, BitArray) {
  case raw {
    <<"\r\n\r\n":utf8, rest:bits>> -> {
      let assert Ok(text) = bit_array.to_string(acc)
      #(text, rest)
    }
    <<byte, rest:bits>> -> split_headers(rest, <<acc:bits, byte>>)
    _ -> panic as "synthetic HTTP request was incomplete"
  }
}

pub fn rejects_before_socket_test() {
  let assert Ok(server) = server_start(http_response(200, "", wire_response()))
  let #(owner, store) = start([account(server, "one")])
  [
    c.Request(..request(), protocol: "responses"),
    c.Request(..request(), mode: c.Streaming),
    c.Request(..request(), required: [c.Tools]),
    c.Request(
      ..request(),
      body: "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"temperature\":0}",
    ),
  ]
  |> list.each(fn(req) { bridge.execute(owner, None, req) |> should.be_error })
  let assert Ok(_) =
    runtime_store.save(
      store,
      credentials.key("devin", "session_token", "one"),
      c.ApiKey("synthetic-wrong-kind"),
    )
  bridge.execute(owner, None, request()) |> should.be_error
  observed(server) |> should.equal([])
  runtime.stop(owner) |> should.be_ok
  stop(server)
}

pub fn remote_binary_is_explicitly_unsupported_test() {
  let context =
    c.Context(
      "devin",
      "session_token",
      "one",
      "https://server.codeium.com",
      "synthetic-session",
      c.SessionToken("synthetic", []),
    )
  bridge.prepare(context, request())
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
}

pub fn real_socket_429_failover_test() {
  let assert Ok(first) =
    server_start(http_response(429, "Retry-After: 2\r\n", <<>>))
  let assert Ok(second) = server_start(http_response(200, "", wire_response()))
  let #(owner, _) = start([account(first, "one"), account(second, "two")])
  bridge.execute(owner, None, request()) |> should.be_ok
  list.length(observed(first)) |> should.equal(1)
  list.length(observed(second)) |> should.equal(1)
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn trailer_failure_never_replays_test() {
  let trailer =
    "{\"error\":{\"code\":\"resource_exhausted\",\"message\":\"synthetic-private\"}}"
  let bytes = <<
    2,
    { bit_array.byte_size(bit_array.from_string(trailer)) }:32-big,
    trailer:utf8,
  >>
  let assert Ok(first) = server_start(http_response(200, "", bytes))
  let assert Ok(second) = server_start(http_response(200, "", wire_response()))
  let #(owner, _) = start([account(first, "one"), account(second, "two")])
  bridge.execute(owner, None, request())
  |> should.equal(Error(c.Failure(c.InvalidResponse, c.Started, None)))
  list.length(observed(first)) |> should.equal(1)
  observed(second) |> should.equal([])
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn actual_runtime_pull_adoption_and_cancellation_test() {
  let assert Ok(server) = server_start(http_response(200, "", wire_response()))
  let #(owner, _) = start([account(server, "one")])
  let assert Ok(opened) = runtime.open(owner, bridge.adapter(None), request())
  let ready = process.new_subject()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let assert Ok(Nil) = runtime.adopt(opened.stream)
      process.send(ready, command)
      let assert Ok(Nil) = process.receive(command, 2000)
      let assert Ok(Some(bytes)) = runtime.next(opened.stream)
      response.feed(response.new(), bytes) |> should.be_ok
      runtime.cancel(opened.stream)
      process.send(done, Nil)
    })
  let assert Ok(command) = process.receive(ready, 2000)
  runtime.next(opened.stream) |> should.be_error
  process.send(command, Nil)
  let assert Ok(Nil) = process.receive(done, 2000)
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  stop(server)
}
