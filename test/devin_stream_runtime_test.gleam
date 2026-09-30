import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/egress
import mimic/fleet
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/connect
import mimic/providers/devin/models as catalog
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response
import mimic/providers/devin/stream
import mimic/providers/registry
import mimic/providers/runtime
import mimic/recorder/tls
import mimic/types.{Header}

// Synthetic numeric-loopback Connect fixtures only. No live Devin traffic,
// captured credentials, or client SSE codec is involved.
type HttpServer

type TlsServer

@external(erlang, "mimic_egress_test_ffi", "start")
fn http_start(response: BitArray) -> Result(HttpServer, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn http_port(server: HttpServer) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn http_requests(server: HttpServer) -> List(BitArray)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn http_stop(server: HttpServer) -> Nil

// Erlang String and BitArray values are both binary at this fixture boundary.
@external(erlang, "mimic_provider_runtime_test_ffi", "tls_start")
fn tls_start(
  cert: String,
  key: String,
  response: BitArray,
) -> Result(TlsServer, String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_port")
fn tls_port(server: TlsServer) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_requests")
fn tls_requests(server: TlsServer) -> List(BitArray)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_closed")
fn tls_closed(server: TlsServer) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_stop")
fn tls_stop(server: TlsServer) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

fn request() -> c.Request {
  c.Request(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "openai-chat",
    "generate",
    c.Streaming,
    [c.Stream],
    "synthetic-client:stream",
    None,
    "{\"model\":\"devin/swe-1-7\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic hello\"}]}",
  )
}

fn account(id: String, origin: String, trust: fleet.Egress) -> runtime.Account {
  runtime.Account(
    "devin",
    "session_token",
    id,
    origin,
    trust,
    2,
    ["devin/swe-1-7"],
    credentials.StaticSession,
  )
}

fn start(accounts: List(runtime.Account)) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory())
  list.each(accounts, fn(a) {
    let assert Ok(_) =
      runtime_store.save(
        store,
        credentials.key("devin", "session_token", a.id),
        c.SessionToken("synthetic-" <> a.id, []),
      )
  })
  // Stream is deliberately absent from bridge.models(), pending client codec
  // qualification. Opt it in only in this native-event runtime test.
  let models =
    bridge.models()
    |> list.map(fn(model) {
      registry.Model(
        ..model,
        capabilities: list.append(model.capabilities, [c.Stream]),
      )
    })
  let assert Ok(registry) = registry.new(models)
  let assert Ok(owner) = runtime.start(store, registry, accounts)
  owner
}

fn http_origin(server: HttpServer) -> String {
  "http://127.0.0.1:" <> int.to_string(http_port(server))
}

fn tls_origin(server: TlsServer) -> String {
  "https://127.0.0.1:" <> int.to_string(tls_port(server))
}

fn data(text: String) -> BitArray {
  connect.envelope(pb.encode([pb.text(3, text)]))
}

fn end() -> BitArray {
  <<2, 2:32-big, "{}":utf8>>
}

fn trailer_error() -> BitArray {
  let payload =
    bit_array.from_string(
      "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"synthetic-private\"}}",
    )
  <<2, { bit_array.byte_size(payload) }:32-big, payload:bits>>
}

fn chunk(bytes: BitArray) -> BitArray {
  let assert Ok(size) = int.to_base_string(bit_array.byte_size(bytes), 16)
  <<size:utf8, "\r\n":utf8, bytes:bits, "\r\n":utf8>>
}

fn chunked(chunks: List(BitArray), suffix: BitArray) -> BitArray {
  let prefix =
    "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  <<
    prefix:utf8,
    { bit_array.concat(list.map(chunks, chunk)) }:bits,
    suffix:bits,
  >>
}

fn fixed(body: BitArray) -> BitArray {
  let prefix =
    "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
    <> int.to_string(bit_array.byte_size(body))
    <> "\r\nConnection: close\r\n\r\n"
  <<prefix:utf8, body:bits>>
}

fn open(owner: runtime.Runtime, ca: Option(String)) -> stream.Stream {
  let assert Ok(#("one", handle)) =
    bridge.open_native_stream(owner, ca, request(), catalog.baseline())
  handle
}

fn assert_request(raw: BitArray) {
  // Inspect only the header prefix: request protobuf includes synthetic
  // in-memory session material and must not be decoded as a String.
  let assert <<
    "POST /exa.api_server_pb.ApiServerService/GetChatMessage HTTP/1.1\r\n":utf8,
    _rest:bits,
  >> = raw
}

pub fn http_prefix_then_trailer_error_never_replays_test() {
  let assert Ok(first) =
    http_start(
      chunked([data("synthetic prefix"), trailer_error()], <<"0\r\n\r\n":utf8>>),
    )
  let assert Ok(second) =
    http_start(fixed(<<{ data("should not replay") }:bits, { end() }:bits>>))
  let owner =
    start([
      account("one", http_origin(first), fleet.LocalLoopback),
      account("two", http_origin(second), fleet.LocalLoopback),
    ])
  let handle = open(owner, None)
  let stream.Batch(handle, events, done, error) = stream.next(handle)
  events |> should.equal([response.Text("synthetic prefix")])
  done |> should.be_false
  error |> should.equal(None)
  let stream.Batch(handle, events, done, error) = stream.next(handle)
  events |> should.equal([])
  done |> should.be_true
  error |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
  let stream.Batch(_, events, done, error) = stream.next(handle)
  events |> should.equal([])
  done |> should.be_true
  error |> should.equal(None)
  let assert [raw] = http_requests(first)
  assert_request(raw)
  http_requests(second) |> should.equal([])
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  http_stop(first)
  http_stop(second)
}

pub fn http_same_chunk_prefix_survives_trailer_failure_test() {
  let assert Ok(server) =
    http_start(fixed(<<{ data("once") }:bits, { trailer_error() }:bits>>))
  let owner = start([account("one", http_origin(server), fleet.LocalLoopback)])
  let stream.Batch(_, events, done, error) = stream.next(open(owner, None))
  events |> should.equal([response.Text("once")])
  done |> should.be_true
  error |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  http_stop(server)
}

pub fn http_truncated_after_prefix_is_started_without_stop_test() {
  // Valid Connect EOS is not a successful client stop until HTTP framing EOF.
  let assert Ok(server) = http_start(chunked([data("prefix"), end()], <<>>))
  let owner = start([account("one", http_origin(server), fleet.LocalLoopback)])
  let stream.Batch(handle, first, done, _) = stream.next(open(owner, None))
  first |> should.equal([response.Text("prefix")])
  done |> should.be_false
  let stream.Batch(handle, terminal, done, _) = stream.next(handle)
  terminal |> should.equal([])
  done |> should.be_false
  let stream.Batch(_, events, done, error) = stream.next(handle)
  events |> should.equal([])
  done |> should.be_true
  let assert Some(failure) = error
  failure.delivery |> should.equal(c.Started)
  runtime.active_leases(owner) |> should.equal(Ok(0))
  http_requests(server) |> list.length |> should.equal(1)
  runtime.stop(owner) |> should.be_ok
  http_stop(server)
}

pub fn http_terminal_waits_for_eof_and_stops_once_test() {
  let assert Ok(server) =
    http_start(chunked([data("complete"), end()], <<"0\r\n\r\n":utf8>>))
  let owner = start([account("one", http_origin(server), fleet.LocalLoopback)])
  let stream.Batch(handle, first, done, _) = stream.next(open(owner, None))
  first |> should.equal([response.Text("complete")])
  done |> should.be_false
  let stream.Batch(handle, eos, done, _) = stream.next(handle)
  eos |> should.equal([])
  done |> should.be_false
  let stream.Batch(handle, events, done, error) = stream.next(handle)
  events |> should.equal([response.Stop])
  done |> should.be_true
  error |> should.equal(None)
  let stream.Batch(_, again, done, error) = stream.next(handle)
  again |> should.equal([])
  done |> should.be_true
  error |> should.equal(None)
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  http_stop(server)
}

pub fn tls_verified_stream_cancel_releases_lease_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(server) =
    tls_start(cert, key, chunked([data("tls prefix")], <<>>))
  let owner = start([account("one", tls_origin(server), fleet.OperatorHttps)])
  let stream.Batch(handle, events, done, error) =
    stream.next(open(owner, Some(cert)))
  events |> should.equal([response.Text("tls prefix")])
  done |> should.be_false
  error |> should.equal(None)
  stream.cancel(handle)
  stream.cancel(handle)
  await_closed(server, 50)
  runtime.active_leases(owner) |> should.equal(Ok(0))
  let assert [raw] = tls_requests(server)
  assert_request(raw)
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

pub fn tls_unknown_ca_and_unsupported_origin_or_h2_send_no_bytes_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(server) =
    tls_start(cert, key, fixed(<<{ data("tls") }:bits, { end() }:bits>>))
  let owner = start([account("one", tls_origin(server), fleet.OperatorHttps)])
  let assert Error(failure) =
    bridge.open_native_stream(owner, None, request(), catalog.baseline())
  failure.delivery |> should.equal(c.NotSent)
  tls_requests(server) |> should.equal([])

  let context =
    c.Context(
      "devin",
      "session_token",
      "one",
      "https://localhost:" <> int.to_string(tls_port(server)),
      "synthetic-client:stream",
      c.SessionToken("synthetic-one", []),
    )
  bridge.prepare(context, request())
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  let context = c.Context(..context, origin: tls_origin(server))
  let assert Ok(plan) = bridge.prepare(context, request())
  egress.stream_open_binary(
    tls_origin(server),
    c.HttpRequest(..plan, protocol: c.Http2),
    Some(cert),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  egress.stream_open_binary(
    tls_origin(server),
    c.HttpRequest(..plan, endpoint: "https://other.example"),
    Some(cert),
  )
  |> should.equal(Error(c.Failure(c.InvalidConfiguration, c.NotSent, None)))
  let wrong_host = [
    Header("Host", "unapproved.example"),
    ..list.filter(plan.headers, fn(header) {
      string.lowercase(header.name) != "host"
    })
  ]
  egress.stream_open_binary(
    tls_origin(server),
    c.HttpRequest(..plan, headers: wrong_host),
    Some(cert),
  )
  |> should.equal(Error(c.Failure(c.InvalidConfiguration, c.NotSent, None)))
  tls_requests(server) |> should.equal([])
  runtime.active_leases(owner) |> should.equal(Ok(0))
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

fn await_closed(server: TlsServer, attempts: Int) {
  case tls_closed(server) > 0, attempts {
    True, _ -> Nil
    False, 0 -> panic as "synthetic TLS socket not closed after cancel"
    False, _ -> {
      process.sleep(5)
      await_closed(server, attempts - 1)
    }
  }
}
