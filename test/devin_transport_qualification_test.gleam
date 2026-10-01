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

// F22: synthetic loopback only. This module never contacts CPA or Devin.
type TlsServer

type Socket

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_start")
fn tls_start_ffi(
  ca: String,
  key: String,
  certificate_host: String,
  protocols: List(String),
  response: BitArray,
  close_after: Bool,
) -> Result(TlsServer, String)

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_port")
fn tls_port(server: TlsServer) -> Int

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_stats")
fn tls_stats(server: TlsServer) -> #(Int, Int, Int, Int)

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_requests")
fn tls_requests(server: TlsServer) -> List(#(String, BitArray))

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_alpn")
fn tls_alpn(server: TlsServer) -> List(String)

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "tls_stop")
fn tls_stop(server: TlsServer) -> Nil

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "with_resources")
fn with_resources(run: fn() -> a) -> a

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "phase")
fn phase(name: String, run: fn() -> a) -> a

fn tls_start(
  ca: String,
  key: String,
  certificate_host: String,
  protocols: List(String),
  response: BitArray,
  close_after: Bool,
) -> Result(TlsServer, String) {
  use <- phase("leaf-and-listen")
  tls_start_ffi(ca, key, certificate_host, protocols, response, close_after)
}

// Direct calls to the SAME shared TLS primitive expose the negative reason;
// the provider/runtime intentionally returns only a fixed safe Failure.
@external(erlang, "mimic_egress_ffi", "connect_with_ca")
fn shared_connect(
  host: String,
  port: Int,
  secure: Bool,
  timeout: Int,
  ca: Option(String),
) -> Result(Socket, String)

@external(erlang, "mimic_egress_ffi", "close")
fn shared_close(socket: Socket) -> Nil

@external(erlang, "mimic_devin_transport_qualification_test_ffi", "directory")
fn directory(kind: String) -> String

fn generate_ca() -> Result(#(String, String), String) {
  use <- phase("ca-generate")
  tls.generate_ca(directory("ca"))
}

fn request() -> c.Request {
  c.Request(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "openai-chat",
    "generate",
    c.Streaming,
    [c.Stream],
    "synthetic-f22-session",
    None,
    "{\"model\":\"devin/swe-1-7\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"synthetic F22 hello\"}]}",
  )
}

fn context(origin: String) -> c.Context {
  c.Context(
    "devin",
    "session_token",
    "one",
    origin,
    "synthetic-f22-runtime-scope",
    c.SessionToken("synthetic-f22-token", []),
  )
}

pub fn prepare_rejects_invalid_ports_before_serializing_secret_plan_test() {
  list.each([-1, 0, 65_536, 999_999], fn(port) {
    let rejected = case
      bridge.prepare(
        context("http://127.0.0.1:" <> int.to_string(port)),
        request(),
      )
    {
      Error(c.Failure(_, c.NotSent, _)) -> True
      _ -> False
    }
    rejected |> should.be_true
  })
}

pub fn prepare_accepts_valid_port_boundaries_without_socket_io_test() {
  list.each([1, 65_535], fn(port) {
    let origin = "http://127.0.0.1:" <> int.to_string(port)
    // Prepare only. Never connect to these boundary/privileged ports.
    let prepared = case bridge.prepare(context(origin), request()) {
      Ok(plan) -> plan.endpoint == origin && plan.protocol == c.Http1
      _ -> False
    }
    prepared |> should.be_true
  })
}

fn tls_origin(server: TlsServer) -> String {
  "https://127.0.0.1:" <> int.to_string(tls_port(server))
}

fn account(id: String, origin: String) -> runtime.Account {
  runtime.Account(
    "devin",
    "session_token",
    id,
    origin,
    fleet.OperatorHttps,
    1,
    ["devin/swe-1-7"],
    credentials.StaticSession,
  )
}

fn start(accounts: List(runtime.Account)) -> runtime.Runtime {
  use <- phase("runtime-setup")
  let assert Ok(store) = storage.new(directory("state"))
  list.each(accounts, fn(account) {
    use <- phase("credential-save")
    let assert Ok(_) =
      runtime_store.save(
        store,
        credentials.key("devin", "session_token", account.id),
        c.SessionToken("synthetic-f22-token", []),
      )
  })
  // Test-only native-event opt-in. The root registry must NOT advertise SSE.
  let native_models =
    bridge.models()
    |> list.map(fn(model) {
      registry.Model(
        ..model,
        capabilities: list.append(model.capabilities, [c.Stream]),
      )
    })
  let assert Ok(registry) = registry.new(native_models)
  let assert Ok(owner) =
    phase("runtime-start", fn() { runtime.start(store, registry, accounts) })
  owner
}

fn data(text: String) -> BitArray {
  connect.envelope(pb.encode([pb.text(3, text)]))
}

fn end() -> BitArray {
  <<2, 2:32-big, "{}":utf8>>
}

fn fixed(body: BitArray) -> BitArray {
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
    <> int.to_string(bit_array.byte_size(body))
    <> "\r\nConnection: close\r\n\r\n"
  <<header:utf8, body:bits>>
}

fn complete() -> BitArray {
  fixed(<<{ data("synthetic F22 reply") }:bits, { end() }:bits>>)
}

fn open(owner: runtime.Runtime, ca: String) -> stream.Stream {
  let assert Ok(#("one", handle)) =
    bridge.open_native_stream(owner, Some(ca), request(), catalog.baseline())
  handle
}

fn success(owner: runtime.Runtime, ca: String) {
  let stream.Batch(handle, events, done, error) = stream.next(open(owner, ca))
  events |> should.equal([response.Text("synthetic F22 reply")])
  done |> should.be_false
  error |> should.equal(None)
  let stream.Batch(handle, events, done, error) = stream.next(handle)
  events |> should.equal([response.Stop])
  done |> should.be_true
  error |> should.equal(None)
  let stream.Batch(_, events, done, error) = stream.next(handle)
  events |> should.equal([])
  done |> should.be_true
  error |> should.equal(None)
  runtime.active_leases(owner) |> should.equal(Ok(0))
}

fn assert_wire(server: TlsServer) {
  let assert [#(header, body)] = tls_requests(server)
  string.starts_with(
    header,
    "POST /exa.api_server_pb.ApiServerService/GetChatMessage HTTP/1.1\r\n",
  )
  |> should.be_true
  string.contains(
    header,
    "Host: 127.0.0.1:" <> int.to_string(tls_port(server)) <> "\r\n",
  )
  |> should.be_true
  string.contains(
    header,
    "Authorization: Basic synthetic-f22-token-synthetic-f22-token\r\n",
  )
  |> should.be_true
  string.contains(header, "Content-Type: application/connect+proto\r\n")
  |> should.be_true
  string.contains(header, "Connect-Protocol-Version: 1\r\n") |> should.be_true
  string.contains(
    header,
    "Content-Length: " <> int.to_string(bit_array.byte_size(body)) <> "\r\n",
  )
  |> should.be_true
  list.each(["user-agent:", "accept-encoding:", "transfer-encoding:"], fn(name) {
    string.contains(string.lowercase(header), name) |> should.be_false
  })
  // The literal auth token is also inside the Connect protobuf. These are
  // synthetic in-memory bytes, not a capture or a String conversion of binary.
  let assert <<0, size:32-big, payload:bytes-size(size)>> = body
  let assert Ok(fields) = pb.decode(payload)
  let assert [metadata] = field_bytes(fields, 1)
  let assert Ok(metadata) = pb.decode(metadata)
  field_bytes(metadata, 3)
  |> should.equal([bit_array.from_string("synthetic-f22-token")])
}

fn field_bytes(fields: List(pb.Field), tag: Int) -> List(BitArray) {
  list.filter_map(fields, fn(field) {
    case field {
      pb.Bytes(number, value) if number == tag -> Ok(value)
      _ -> Error(Nil)
    }
  })
}

pub fn tls_verified_ca_observes_actual_http1_alpn_and_connect_wire_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(server) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  let owner = start([account("one", tls_origin(server))])
  success(owner, ca)
  assert_wire(server)
  tls_alpn(server) |> should.equal(["http/1.1"])
  let #(accepts, handshakes, failures, _) = tls_stats(server)
  #(accepts, handshakes, failures) |> should.equal(#(1, 1, 0))
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

pub fn tls_no_alpn_is_observed_separately_not_inferred_http2_support_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(server) = tls_start(ca, key, "127.0.0.1", [], complete(), True)
  let owner = start([account("one", tls_origin(server))])
  success(owner, ca)
  assert_wire(server)
  tls_alpn(server) |> should.equal(["none"])
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

fn not_sent(owner: runtime.Runtime, ca: String) {
  let result =
    bridge.open_native_stream(owner, Some(ca), request(), catalog.baseline())
  let rejected = case result {
    Error(c.Failure(c.Unavailable, c.NotSent, None)) -> True
    _ -> False
  }
  rejected |> should.be_true
  runtime.active_leases(owner) |> should.equal(Ok(0))
}

fn await_stats(
  server: TlsServer,
  expected: fn(#(Int, Int, Int, Int)) -> Bool,
  attempts: Int,
) {
  case expected(tls_stats(server)), attempts {
    True, _ -> Nil
    False, 0 -> panic as "synthetic TLS counters did not reach expected state"
    False, _ -> {
      process.sleep(5)
      await_stats(server, expected, attempts - 1)
    }
  }
}

pub fn tls_wrong_ca_is_actual_handshake_failure_before_application_bytes_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(#(wrong_ca, _)) = generate_ca()
  let assert Ok(server) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  // Control: the exact shared primitive trusts the signer when configured.
  let assert Ok(socket) =
    shared_connect("127.0.0.1", tls_port(server), True, 5000, Some(ca))
  shared_close(socket)
  let assert Error(reason) =
    shared_connect("127.0.0.1", tls_port(server), True, 5000, Some(wrong_ca))
  string.contains(reason, "unknown_ca") |> should.be_true
  let owner = start([account("one", tls_origin(server))])
  not_sent(owner, wrong_ca)
  await_stats(server, fn(stats) { stats.0 == 3 && stats.2 == 2 }, 200)
  tls_requests(server) |> should.equal([])
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

pub fn tls_same_ca_actual_certificate_hostname_mismatch_not_host_policy_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(matching) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  let assert Ok(mismatch) =
    tls_start(ca, key, "synthetic-f22.invalid", ["http/1.1"], complete(), True)
  let owner = start([account("one", tls_origin(matching))])
  success(owner, ca)
  runtime.stop(owner) |> should.be_ok
  // Both leaves use the SAME trusted signer. Endpoint and HTTP Host remain
  // 127.0.0.1, so policy validation passes; only certificate SAN differs.
  let assert Error(reason) =
    shared_connect("127.0.0.1", tls_port(mismatch), True, 5000, Some(ca))
  string.contains(reason, "hostname_check_failed") |> should.be_true
  let owner = start([account("one", tls_origin(mismatch))])
  not_sent(owner, ca)
  await_stats(mismatch, fn(stats) { stats.0 == 2 && stats.2 == 2 }, 200)
  tls_requests(mismatch) |> should.equal([])
  runtime.stop(owner) |> should.be_ok
  tls_stop(matching)
  tls_stop(mismatch)
}

pub fn tls_h2_only_peer_has_no_common_alpn_and_receives_no_http_bytes_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(server) =
    tls_start(ca, key, "127.0.0.1", ["h2"], complete(), True)
  let assert Error(reason) =
    shared_connect("127.0.0.1", tls_port(server), True, 5000, Some(ca))
  string.contains(reason, "no_application_protocol") |> should.be_true
  let owner = start([account("one", tls_origin(server))])
  not_sent(owner, ca)
  await_stats(server, fn(stats) { stats.0 == 2 && stats.2 == 2 }, 200)
  tls_alpn(server) |> should.equal([])
  tls_requests(server) |> should.equal([])
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
}

fn drain(
  handle: stream.Stream,
  prefix: List(response.Event),
  remaining: Int,
) -> #(List(response.Event), Option(c.Failure)) {
  case remaining {
    0 -> panic as "synthetic stream exceeded bounded pull count"
    _ -> {
      let stream.Batch(handle, events, done, error) = stream.next(handle)
      let events = list.append(prefix, events)
      case done {
        True -> {
          let stream.Batch(_, again, done, repeated_error) = stream.next(handle)
          again |> should.equal([])
          done |> should.be_true
          repeated_error |> should.equal(None)
          #(events, error)
        }
        False -> drain(handle, events, remaining - 1)
      }
    }
  }
}

fn assert_failed_stream(server: TlsServer, fallback: TlsServer, ca: String) {
  let owner =
    start([
      account("one", tls_origin(server)),
      account("two", tls_origin(fallback)),
    ])
  let #(events, error) = drain(open(owner, ca), [], 10)
  events |> should.equal([response.Text("valid prefix")])
  error |> should.equal(Some(c.Failure(c.InvalidResponse, c.Started, None)))
  runtime.active_leases(owner) |> should.equal(Ok(0))
  tls_requests(server) |> list.length |> should.equal(1)
  tls_stats(fallback) |> should.equal(#(0, 0, 0, 0))
  runtime.stop(owner) |> should.be_ok
}

fn rejected_suffixes(suffixes: List(BitArray)) {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(fallback) =
    phase("fallback-listen-ready", fn() {
      tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
    })
  list.each(suffixes, fn(suffix) {
    let assert Ok(server) =
      phase("primary-listen-ready", fn() {
        tls_start(
          ca,
          key,
          "127.0.0.1",
          ["http/1.1"],
          fixed(<<{ data("valid prefix") }:bits, suffix:bits>>),
          True,
        )
      })
    phase("reject-and-release", fn() {
      assert_failed_stream(server, fallback, ca)
    })
    phase("primary-teardown", fn() { tls_stop(server) })
  })
  phase("fallback-teardown", fn() { tls_stop(fallback) })
}

pub fn tls_compressed_data_flag_fails_after_prefix_without_replay_test() {
  rejected_suffixes([<<1>>])
}

pub fn tls_compressed_trailer_flag_fails_after_prefix_without_replay_test() {
  rejected_suffixes([<<3>>])
}

pub fn tls_reserved_connect_flag_fails_after_prefix_without_replay_test() {
  rejected_suffixes([<<4>>])
}

pub fn tls_malformed_connect_trailer_json_fails_closed_test() {
  rejected_suffixes([<<2, 1:32-big, "{":utf8>>])
}

pub fn tls_nonobject_connect_trailer_fails_closed_test() {
  rejected_suffixes([<<2, 2:32-big, "[]":utf8>>])
}

pub fn tls_invalid_utf8_connect_trailer_fails_closed_test() {
  rejected_suffixes([<<2, 1:32-big, 255>>])
}

pub fn tls_malformed_protobuf_fails_closed_test() {
  // Protobuf tag zero is invalid; HTTP framing is otherwise complete.
  rejected_suffixes([connect.envelope(<<0>>)])
}

pub fn tls_truncated_connect_header_never_stops_test() {
  rejected_suffixes([<<0, 0, 0>>])
}

pub fn tls_truncated_connect_payload_never_stops_test() {
  rejected_suffixes([<<0, 4:32-big, 1, 2>>])
}

pub fn tls_missing_connect_eos_never_stops_test() {
  rejected_suffixes([<<>>])
}

pub fn tls_incomplete_utf8_even_with_connect_eos_never_stops_test() {
  rejected_suffixes([
    <<
      { connect.envelope(pb.encode([pb.Bytes(3, <<240, 159>>)])) }:bits,
      { end() }:bits,
    >>,
  ])
}

// Manual diagnosis only, not an automatically discovered test. This retains
// the former grouped workload so phase evidence can compare like-for-like.
pub fn grouped_truncation_diagnostic() {
  rejected_suffixes([
    <<0, 0, 0>>,
    <<0, 4:32-big, 1, 2>>,
    <<>>,
    <<
      { connect.envelope(pb.encode([pb.Bytes(3, <<240, 159>>)])) }:bits,
      { end() }:bits,
    >>,
  ])
}

pub fn tls_oversized_connect_data_is_rejected_without_payload_test() {
  // Five bytes suffice to reject; do not allocate/send an oversized payload.
  rejected_suffixes([<<0, 8_388_609:32-big>>])
}

pub fn tls_oversized_connect_trailer_is_rejected_without_payload_test() {
  rejected_suffixes([<<2, 8_388_609:32-big>>])
}

pub fn tls_connect_bytes_after_eos_cannot_publish_success_test() {
  rejected_suffixes([<<{ end() }:bits, 0>>])
}

fn chunk(bytes: BitArray) -> BitArray {
  let assert Ok(size) = int.to_base_string(bit_array.byte_size(bytes), 16)
  <<size:utf8, "\r\n":utf8, bytes:bits, "\r\n":utf8>>
}

fn chunked(chunks: List(BitArray), suffix: BitArray) -> BitArray {
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n"
  <<
    header:utf8,
    { bit_array.concat(list.map(chunks, chunk)) }:bits,
    suffix:bits,
  >>
}

pub fn tls_connect_eos_does_not_mask_truncated_chunked_http_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let assert Ok(server) =
    tls_start(
      ca,
      key,
      "127.0.0.1",
      ["http/1.1"],
      chunked([data("valid prefix"), end()], <<>>),
      True,
    )
  let assert Ok(fallback) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  assert_failed_stream(server, fallback, ca)
  tls_stop(server)
  tls_stop(fallback)
}

fn await_no_leases(owner: runtime.Runtime, remaining: Int) {
  case runtime.active_leases(owner), remaining {
    Ok(0), _ -> Nil
    _, 0 -> panic as "synthetic cancellation did not release runtime lease"
    _, _ -> {
      process.sleep(5)
      await_no_leases(owner, remaining - 1)
    }
  }
}

fn incomplete(ca: String, key: String) -> TlsServer {
  let assert Ok(server) =
    tls_start(
      ca,
      key,
      "127.0.0.1",
      ["http/1.1"],
      chunked([data("valid prefix")], <<>>),
      False,
    )
  server
}

pub fn tls_duplicate_cancel_proves_peer_eof_and_lease_cleanup_without_retry_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let server = incomplete(ca, key)
  let assert Ok(fallback) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  let owner =
    start([
      account("one", tls_origin(server)),
      account("two", tls_origin(fallback)),
    ])
  let stream.Batch(handle, events, done, error) = stream.next(open(owner, ca))
  events |> should.equal([response.Text("valid prefix")])
  done |> should.be_false
  error |> should.equal(None)
  runtime.active_leases(owner) |> should.equal(Ok(1))
  stream.cancel(handle)
  stream.cancel(handle)
  await_stats(server, fn(stats) { stats.3 == 1 }, 200)
  await_no_leases(owner, 200)
  let stream.Batch(_, events, done, error) = stream.next(handle)
  events |> should.equal([])
  done |> should.be_true
  error |> should.equal(Some(c.Failure(c.Cancelled, c.Started, None)))
  tls_stats(fallback) |> should.equal(#(0, 0, 0, 0))
  tls_requests(server) |> list.length |> should.equal(1)
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
  tls_stop(fallback)
}

pub fn tls_adopted_owner_death_closes_stalled_socket_and_releases_lease_test() {
  use <- with_resources
  let assert Ok(#(ca, key)) = generate_ca()
  let server = incomplete(ca, key)
  let assert Ok(fallback) =
    tls_start(ca, key, "127.0.0.1", ["http/1.1"], complete(), True)
  let owner =
    start([
      account("one", tls_origin(server)),
      account("two", tls_origin(fallback)),
    ])
  let handle = open(owner, ca)
  let ready = process.new_subject()
  let borrower =
    process.spawn_unlinked(fn() {
      stream.adopt(handle) |> should.be_ok
      let stream.Batch(handle, events, done, error) = stream.next(handle)
      events |> should.equal([response.Text("valid prefix")])
      done |> should.be_false
      error |> should.equal(None)
      process.send(ready, Nil)
      // Stall on the absent next HTTP chunk; no timeout is used as success.
      let _ = stream.next(handle)
      Nil
    })
  process.receive(ready, 2000) |> should.equal(Ok(Nil))
  runtime.active_leases(owner) |> should.equal(Ok(1))
  process.kill(borrower)
  await_stats(server, fn(stats) { stats.3 == 1 }, 200)
  await_no_leases(owner, 200)
  tls_stats(fallback) |> should.equal(#(0, 0, 0, 0))
  tls_requests(server) |> list.length |> should.equal(1)
  runtime.stop(owner) |> should.be_ok
  tls_stop(server)
  tls_stop(fallback)
}
