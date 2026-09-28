import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/egress
import mimic/fleet
import mimic/providers/contracts.{
  ApiKey, Buffer, ConnectProto, Context, Failure, Http1, Http2, HttpRequest,
  InvalidConfiguration, NotSent, OAuth, OAuthData, Proto, Quota, Refresh,
  RefreshUnsupported, Rejected, Request, SessionToken, Started, Stream,
  Streaming, Unsupported,
}
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/recorder/tls
import mimic/types.{Capture, Header, Transport}

type HttpFixture

type TlsFixture

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_egress_test_ffi", "start")
fn http_start(response: BitArray) -> Result(HttpFixture, String)

@external(erlang, "mimic_egress_test_ffi", "port")
fn http_port(fixture: HttpFixture) -> Int

@external(erlang, "mimic_egress_test_ffi", "requests")
fn http_requests(fixture: HttpFixture) -> List(BitArray)

@external(erlang, "mimic_egress_test_ffi", "stop")
fn http_stop(fixture: HttpFixture) -> Nil

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_start")
fn tls_start(
  cert: String,
  key: String,
  response: BitArray,
) -> Result(TlsFixture, String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_port")
fn tls_port(fixture: TlsFixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_requests")
fn tls_requests(fixture: TlsFixture) -> List(BitArray)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_closed")
fn tls_closed(fixture: TlsFixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_stop")
fn tls_stop(fixture: TlsFixture) -> Nil

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

@external(erlang, "mimic_provider_runtime_test_ffi", "unsafe_string")
fn unsafe_string(bytes: BitArray) -> String

@external(erlang, "mimic_provider_runtime_test_ffi", "session_phase")
fn run_session_phase(directory: String, restart: Bool) -> Bool

fn key(id: String) -> String {
  credentials.key("synthetic", "session", id)
}

fn material(id: String) -> contracts.AuthMaterial {
  SessionToken("synthetic-session-" <> id, [#("user_id", id)])
}

fn payload(token: String) -> BitArray {
  bit_array.concat([<<0, 255>>, bit_array.from_string(token), <<128, 0>>])
}

fn response(media: String, body: BitArray) -> BitArray {
  bit_array.append(
    bit_array.from_string(
      "HTTP/1.1 200 OK\r\nContent-Type: "
      <> media
      <> "\r\nContent-Length: "
      <> int.to_string(bit_array.byte_size(body))
      <> "\r\n\r\n",
    ),
    body,
  )
}

fn request() -> contracts.Request {
  Request(
    "synthetic",
    "session",
    "model",
    "test",
    "generate",
    Streaming,
    [],
    "session",
    None,
    "{}",
  )
}

fn context(origin: String) -> contracts.Context {
  Context("synthetic", "session", "a", origin, "scoped-session", material("a"))
}

fn plan(
  context: contracts.Context,
  _request: contracts.Request,
) -> Result(contracts.HttpRequest, contracts.Failure) {
  case context.credential {
    SessionToken(token, _) -> {
      let body = payload(token)
      let authority =
        context.origin
        |> string.replace("http://", "")
        |> string.replace("https://", "")
      Ok(HttpRequest(
        context.origin,
        "POST",
        "/synthetic-rpc",
        [
          Header("Host", authority),
          Header("Authorization", "Basic " <> token <> "-" <> token),
          Header("X-Order", "first"),
          Header("x-order", "second"),
          Header("Content-Type", "application/connect+proto"),
          Header("Content-Length", int.to_string(bit_array.byte_size(body))),
        ],
        body,
        Http1,
        ConnectProto,
      ))
    }
    _ -> Error(Failure(InvalidConfiguration, NotSent, None))
  }
}

fn registry() -> registry.Registry {
  let assert Ok(registry) =
    registry.new([
      registry.Model("synthetic", "model", ["session"], ["test"], ["generate"], [
        Buffer,
        Stream,
      ]),
    ])
  registry
}

fn account(id: String, origin: String, mode: fleet.Egress) -> runtime.Account {
  runtime.Account(
    "synthetic",
    "session",
    id,
    origin,
    mode,
    2,
    ["model"],
    credentials.StaticSession,
  )
}

fn new_store() -> storage.Store {
  let assert Ok(store) = storage.new(directory())
  list.each(["a", "b"], fn(id) {
    runtime_store.save(store, key(id), material(id)) |> should.be_ok
  })
  store
}

fn adapter(cert: Option(String)) -> contracts.Adapter(egress.Stream) {
  transport.binary_http(
    plan,
    fn(status, _) {
      case status {
        429 -> Some(Failure(Quota, Rejected, Some(60_000)))
        _ -> None
      }
    },
    cert,
  )
}

pub fn binary_request_response_invalid_utf8_is_byte_identical_test() {
  let bytes = payload("synthetic-response")
  bit_array.to_string(bytes) |> should.be_error
  let assert Ok(fixture) =
    http_start(response("application/connect+proto", bytes))
  let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
  let assert Ok(runtime) =
    runtime.start(new_store(), registry(), [
      account("a", origin, fleet.LocalLoopback),
    ])
  let assert Ok(result) = runtime.execute(runtime, adapter(None), request())
  result.body |> should.equal(bytes)
  let assert [raw] = http_requests(fixture)
  let body = payload("synthetic-session-a")
  bit_array.slice(
    raw,
    bit_array.byte_size(raw) - bit_array.byte_size(body),
    bit_array.byte_size(body),
  )
  |> should.equal(Ok(body))
  let assert Ok(header_bytes) =
    bit_array.slice(
      raw,
      0,
      bit_array.byte_size(raw) - bit_array.byte_size(body),
    )
  let assert Ok(headers) = bit_array.to_string(header_bytes)
  string.contains(headers, "X-Order: first\r\nx-order: second")
  |> should.be_true
  string.contains(headers, "Accept-Encoding:") |> should.be_false
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
  http_stop(fixture)
}

pub fn unary_proto_is_explicit_and_not_json_decoded_test() {
  let bytes = <<255, 0, 128, 7>>
  let assert Ok(fixture) = http_start(response("application/proto", bytes))
  let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
  let assert Ok(original) = plan(context(origin), request())
  let unary =
    HttpRequest(
      ..original,
      media: Proto,
      headers: list.map(original.headers, fn(h) {
        case h.name {
          "Content-Type" -> Header(h.name, "application/proto")
          _ -> h
        }
      }),
    )
  let assert Ok(#(200, _, stream)) =
    egress.stream_open_binary(origin, unary, None)
  let assert Ok(Some(#(chunk, next))) = egress.stream_next(stream)
  chunk |> should.equal(bytes)
  egress.stream_next(next) |> should.equal(Ok(None))
  egress.stream_cancel(next)
  http_stop(fixture)
}

pub fn legacy_capture_path_rejects_binary_media_and_invalid_utf8_test() {
  let assert Ok(fixture) =
    http_start(response("application/json", <<123, 125>>))
  let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
  let headers = [
    Header("Host", "127.0.0.1:" <> int.to_string(http_port(fixture))),
    Header("Content-Length", "3"),
    Header("Content-Type", "application/json"),
  ]
  let capture =
    Capture(
      "synthetic",
      "1",
      origin,
      "test",
      "POST",
      "/",
      "HTTP/1.1",
      headers,
      unsafe_string(<<255, 0, 128>>),
      Transport("http/1.1", None),
    )
  egress.stream_open(origin, capture, None)
  |> should.equal(Error(Failure(InvalidConfiguration, NotSent, None)))
  let assert Ok(client) = egress.start(origin)
  let _ = egress.send(client, capture) |> should.be_error
  egress.close(client) |> should.be_ok
  let binary_media =
    Capture(
      ..capture,
      body: "abc",
      headers: list.map(headers, fn(h) {
        case h.name {
          "Content-Type" -> Header(h.name, "application/connect+proto")
          _ -> h
        }
      }),
    )
  egress.stream_open(origin, binary_media, None) |> should.be_error
  http_requests(fixture) |> should.equal([])
  http_stop(fixture)
}

pub fn binary_protocol_and_unqualified_origin_gates_are_explicit_test() {
  let assert Ok(plan) = plan(context("http://127.0.0.1:1"), request())
  egress.stream_open_binary(
    plan.endpoint,
    HttpRequest(..plan, protocol: Http2),
    None,
  )
  |> should.equal(Error(Failure(Unsupported, NotSent, None)))
  let remote = "https://unqualified.invalid"
  egress.stream_open_binary(remote, HttpRequest(..plan, endpoint: remote), None)
  |> should.equal(Error(Failure(Unsupported, NotSent, None)))
}

pub fn binary_request_byte_caps_and_framing_fail_before_send_test() {
  let assert Ok(fixture) =
    http_start(response("application/connect+proto", <<0>>))
  let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
  let assert Ok(original) = plan(context(origin), request())
  let wrong_length =
    HttpRequest(
      ..original,
      headers: list.map(original.headers, fn(h) {
        case h.name {
          "Content-Length" -> Header(h.name, "1")
          _ -> h
        }
      }),
    )
  let duplicate_length =
    HttpRequest(..original, headers: [
      Header("content-length", "1"),
      ..original.headers
    ])
  let chunked =
    HttpRequest(..original, headers: [
      Header("Transfer-Encoding", "chunked"),
      ..original.headers
    ])
  let encoded =
    HttpRequest(..original, headers: [
      Header("Content-Encoding", "gzip"),
      ..original.headers
    ])
  let wrong_media = HttpRequest(..original, media: Proto)
  let wrong_host =
    HttpRequest(
      ..original,
      headers: list.map(original.headers, fn(h) {
        case h.name {
          "Host" -> Header(h.name, "elsewhere.invalid")
          _ -> h
        }
      }),
    )
  let duplicate_host =
    HttpRequest(..original, headers: [
      Header("Host", "elsewhere.invalid"),
      ..original.headers
    ])
  let oversized =
    HttpRequest(
      ..original,
      body: bit_array.from_string(string.repeat("x", 8_388_609)),
      headers: list.map(original.headers, fn(h) {
        case h.name {
          "Content-Length" -> Header(h.name, "8388609")
          _ -> h
        }
      }),
    )
  let partial_byte = HttpRequest(..wrong_length, body: <<1:size(1)>>)
  let control_header =
    HttpRequest(..original, headers: [
      Header("X-Test", "\u{000B}"),
      ..original.headers
    ])
  let delete_header =
    HttpRequest(..original, headers: [
      Header("X-Test", "\u{007F}"),
      ..original.headers
    ])
  let oversized_header =
    HttpRequest(..original, headers: [
      Header("X-Test", string.repeat("x", 8192)),
      ..original.headers
    ])
  let injection =
    HttpRequest(..original, target: "/\r\nsecret: synthetic-session-a")
  list.each(
    [
      wrong_length,
      duplicate_length,
      chunked,
      encoded,
      wrong_media,
      wrong_host,
      duplicate_host,
      oversized,
      partial_byte,
      control_header,
      delete_header,
      oversized_header,
      injection,
    ],
    fn(invalid) {
      let error = egress.stream_open_binary(origin, invalid, None)
      error |> should.equal(Error(Failure(InvalidConfiguration, NotSent, None)))
      string.inspect(error)
      |> string.contains("synthetic-session-a")
      |> should.be_false
    },
  )
  http_requests(fixture) |> should.equal([])
  http_stop(fixture)
}

pub fn binary_response_media_encoding_and_size_caps_fail_closed_test() {
  list.each(
    [
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1\r\n\r\nx",
      "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: 8388609\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: 1\r\nContent-Encoding: gzip\r\n\r\nx",
      "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
    ],
    fn(raw) {
      let assert Ok(fixture) = http_start(bit_array.from_string(raw))
      let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
      let assert Ok(plan) = plan(context(origin), request())
      egress.stream_open_binary(origin, plan, None) |> should.be_error
      http_requests(fixture) |> list.length |> should.equal(1)
      http_stop(fixture)
    },
  )
}

pub fn binary_redirect_is_returned_without_forwarding_credentials_test() {
  let assert Ok(destination) =
    http_start(response("application/connect+proto", <<255>>))
  let location = "http://127.0.0.1:" <> int.to_string(http_port(destination))
  let assert Ok(source) =
    http_start(bit_array.from_string(
      "HTTP/1.1 302 Found\r\nLocation: "
      <> location
      <> "\r\nContent-Length: 0\r\n\r\n",
    ))
  let origin = "http://127.0.0.1:" <> int.to_string(http_port(source))
  let assert Ok(plan) = plan(context(origin), request())
  let assert Ok(#(302, _, stream)) =
    egress.stream_open_binary(origin, plan, None)
  egress.stream_next(stream) |> should.equal(Ok(None))
  egress.stream_cancel(stream)
  http_requests(source) |> list.length |> should.equal(1)
  http_requests(destination) |> should.equal([])
  http_stop(source)
  http_stop(destination)
}

pub fn static_session_never_refreshes_and_delete_prevents_next_use_test() {
  let store = new_store()
  let assert Ok(worker) =
    credentials.start(store, key("a"), credentials.StaticSession)
  credentials.get(worker, 9_999_999_999_999_999)
  |> should.equal(Ok(material("a")))
  runtime_store.metadata(store, key("a"))
  |> should.equal(Ok(runtime_store.Metadata("session_token", None)))
  let invoked = process.new_subject()
  let assert Ok(wrong) =
    credentials.start(
      store,
      key("a"),
      credentials.Refreshable(
        Refresh(fn(_, _) {
          process.send(invoked, Nil)
          Error(RefreshUnsupported)
        }),
      ),
    )
  credentials.get(wrong, 0) |> should.be_error
  process.receive(invoked, 0) |> should.equal(Error(Nil))
  runtime_store.delete(store, key("a")) |> should.be_ok
  credentials.get(worker, 0) |> should.be_error
  credentials.stop(worker)
  credentials.stop(wrong)
}

pub fn session_token_cas_replacement_delete_and_record_compatibility_test() {
  let store = new_store()
  let before = material("a")
  let updated = SessionToken("synthetic-replaced", [#("user_id", "a")])
  runtime_store.save(store, key("a"), updated) |> should.be_ok
  runtime_store.save_if_unchanged(store, key("a"), before, material("b"))
  |> should.be_error
  runtime_store.load(store, key("a")) |> should.equal(Ok(updated))
  runtime_store.delete(store, key("a")) |> should.be_ok
  runtime_store.save_if_unchanged(store, key("a"), updated, before)
  |> should.be_error
  runtime_store.load(store, key("a")) |> should.be_error
  list.each(
    [
      #(
        "{\"version\":1,\"kind\":\"api_key\",\"secret\":\"synthetic-key\"}",
        ApiKey("synthetic-key"),
      ),
      #(
        "{\"version\":1,\"kind\":\"oauth\",\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_at_ms\":123,\"private_metadata\":[]}",
        OAuth(
          OAuthData(
            auth.Credential("synthetic-access", "synthetic-refresh", 123),
            [],
          ),
        ),
      ),
    ],
    fn(fixture) {
      // Literal v2 record fixtures, not output re-encoded by the v3 writer.
      storage.write_runtime(store, key("old"), fixture.0) |> should.be_ok
      runtime_store.load(store, key("old")) |> should.equal(Ok(fixture.1))
    },
  )
  runtime_store.save(
    store,
    key("bad"),
    SessionToken("synthetic", [#("same", "1"), #("same", "2")]),
  )
  |> should.be_error
  runtime_store.save(store, key("bad"), SessionToken("", [])) |> should.be_error
  list.each(
    [
      "{\"version\":2,\"kind\":\"session_token\",\"token\":\"synthetic-private\",\"private_metadata\":[]}",
      "{\"version\":1,\"kind\":\"unknown\",\"token\":\"synthetic-private\"}",
    ],
    fn(raw) {
      storage.write_runtime(store, key("bad"), raw) |> should.be_ok
      let failure = runtime_store.load(store, key("bad"))
      failure |> should.equal(Error("Invalid runtime credential"))
      string.inspect(failure)
      |> string.contains("synthetic-private")
      |> should.be_false
    },
  )
  auth.list_metadata(store) |> should.equal(Ok([]))
}

pub fn session_token_restores_in_fresh_vm_without_expiry_or_reseed_test() {
  let path = directory()
  run_session_phase(path, False) |> should.be_true
  run_session_phase(path, True) |> should.be_true
}

pub fn session_phase(path: String, restart: Bool) {
  let assert Ok(store) = storage.new(path)
  case restart {
    False -> runtime_store.save(store, key("a"), material("a")) |> should.be_ok
    True -> Nil
  }
  let assert Ok(worker) =
    credentials.start(store, key("a"), credentials.StaticSession)
  credentials.get(worker, 9_999_999_999_999_999)
  |> should.equal(Ok(material("a")))
  runtime_store.metadata(store, key("a"))
  |> should.equal(Ok(runtime_store.Metadata("session_token", None)))
  credentials.stop(worker)
}

pub fn binary_tls_failover_isolates_session_bodies_and_cancel_closes_test() {
  let assert Ok(#(cert, cert_key)) = tls.generate_ca(ca_directory())
  let bytes = <<0, 255, 128, 1>>
  let partial =
    bit_array.concat([
      bit_array.from_string(
        "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n",
      ),
      bytes,
      <<13, 10>>,
    ])
  let assert Ok(first) =
    tls_start(
      cert,
      cert_key,
      bit_array.from_string(
        "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n",
      ),
    )
  let assert Ok(second) = tls_start(cert, cert_key, partial)
  let origin_a = "https://127.0.0.1:" <> int.to_string(tls_port(first))
  let origin_b = "https://127.0.0.1:" <> int.to_string(tls_port(second))
  let assert Ok(runtime) =
    runtime.start(new_store(), registry(), [
      account("a", origin_a, fleet.OperatorHttps),
      account("b", origin_b, fleet.OperatorHttps),
    ])
  let assert Ok(response) =
    runtime.open(runtime, adapter(Some(cert)), request())
  response.account |> should.equal("b")
  runtime.next(response.stream) |> should.equal(Ok(Some(bytes)))
  runtime.cancel(response.stream)
  runtime.cancel(response.stream)
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  let assert [a] = tls_requests(first)
  let assert [b] = tls_requests(second)
  list.each(
    [#(a, "synthetic-session-a"), #(b, "synthetic-session-b")],
    fn(pair) {
      let body = payload(pair.1)
      bit_array.slice(
        pair.0,
        bit_array.byte_size(pair.0) - bit_array.byte_size(body),
        bit_array.byte_size(body),
      )
      |> should.equal(Ok(body))
    },
  )
  await_closed(second, 50)
  runtime.stop(runtime) |> should.be_ok
  tls_stop(first)
  tls_stop(second)
}

pub fn binary_tls_certificate_verification_and_started_no_replay_test() {
  let assert Ok(#(cert, cert_key)) = tls.generate_ca(ca_directory())
  let truncated =
    bit_array.concat([
      bit_array.from_string(
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n",
      ),
      <<255>>,
      <<13, 10>>,
    ])
  let assert Ok(first) = tls_start(cert, cert_key, truncated)
  let assert Ok(second) =
    tls_start(cert, cert_key, response("application/connect+proto", <<255>>))
  let a = "https://127.0.0.1:" <> int.to_string(tls_port(first))
  let b = "https://127.0.0.1:" <> int.to_string(tls_port(second))
  let assert Ok(runtime) =
    runtime.start(new_store(), registry(), [
      account("a", a, fleet.OperatorHttps),
      account("b", b, fleet.OperatorHttps),
    ])
  runtime.open(
    runtime,
    adapter(None),
    Request(..request(), pinned_account: Some("a")),
  )
  |> should.be_error
  tls_requests(first) |> should.equal([])
  let assert Ok(response) =
    runtime.open(runtime, adapter(Some(cert)), request())
  runtime.next(response.stream) |> should.equal(Ok(Some(<<255>>)))
  let assert Error(error) = runtime.next(response.stream)
  error.delivery |> should.equal(Started)
  tls_requests(second) |> should.equal([])
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
  tls_stop(first)
  tls_stop(second)
}

pub fn binary_plan_exception_diagnostics_do_not_expose_body_token_test() {
  let assert Ok(runtime) =
    runtime.start(new_store(), registry(), [
      account("a", "http://127.0.0.1:1", fleet.LocalLoopback),
    ])
  let adapter =
    transport.binary_http(
      fn(context, request) {
        let assert Ok(secret_plan) = plan(context, request)
        panic as string.inspect(secret_plan)
      },
      fn(_, _) { None },
      None,
    )
  let failure = runtime.open(runtime, adapter, request())
  let _ = failure |> should.be_error
  string.inspect(failure)
  |> string.contains("synthetic-session-a")
  |> should.be_false
  runtime.stop(runtime) |> should.be_ok
}

fn await_closed(fixture: TlsFixture, attempts: Int) {
  case tls_closed(fixture) > 0, attempts {
    True, _ -> Nil
    False, 0 -> panic as "TLS binary stream remained open"
    False, _ -> {
      process.sleep(5)
      await_closed(fixture, attempts - 1)
    }
  }
}

pub fn binary_chunked_exact_cap_and_cumulative_overflow_test() {
  let block = bit_array.from_string(string.repeat("x", 4_194_304))
  let chunk =
    bit_array.concat([bit_array.from_string("400000\r\n"), block, <<13, 10>>])
  list.each([False, True], fn(overflow) {
    let ending = case overflow {
      False -> "0\r\n\r\n"
      True -> "1\r\nx\r\n0\r\n\r\n"
    }
    let raw =
      bit_array.concat([
        bit_array.from_string(
          "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n",
        ),
        chunk,
        chunk,
        bit_array.from_string(ending),
      ])
    let assert Ok(first) = http_start(raw)
    let assert Ok(second) =
      http_start(response("application/connect+proto", <<255>>))
    let a = "http://127.0.0.1:" <> int.to_string(http_port(first))
    let b = "http://127.0.0.1:" <> int.to_string(http_port(second))
    let assert Ok(runtime) =
      runtime.start(new_store(), registry(), [
        account("a", a, fleet.LocalLoopback),
        account("b", b, fleet.LocalLoopback),
      ])
    let result = runtime.execute(runtime, adapter(None), request())
    case overflow {
      False -> {
        let assert Ok(response) = result
        bit_array.byte_size(response.body) |> should.equal(8_388_608)
      }
      True -> {
        let assert Error(error) = result
        error.delivery |> should.equal(Started)
      }
    }
    http_requests(first) |> list.length |> should.equal(1)
    http_requests(second) |> should.equal([])
    runtime.active_leases(runtime) |> should.equal(Ok(0))
    runtime.stop(runtime) |> should.be_ok
    http_stop(first)
    http_stop(second)
  })
}

pub fn empty_binary_response_media_policy_is_explicit_test() {
  list.each(
    [
      #(200, "", False),
      #(200, "Content-Type: application/connect+proto\r\n", True),
      #(200, "Content-Type: application/json\r\n", False),
      #(429, "", True),
      #(429, "Content-Type: application/json\r\n", False),
      #(
        429,
        "Content-Type: application/connect+proto\r\nContent-Type: application/connect+proto\r\n",
        False,
      ),
    ],
    fn(example) {
      let raw =
        "HTTP/1.1 "
        <> int.to_string(example.0)
        <> " Synthetic\r\n"
        <> example.1
        <> "Content-Length: 0\r\n\r\n"
      let assert Ok(fixture) = http_start(bit_array.from_string(raw))
      let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
      let assert Ok(plan) = plan(context(origin), request())
      case egress.stream_open_binary(origin, plan, None) {
        Ok(#(_, _, stream)) -> {
          example.2 |> should.be_true
          egress.stream_next(stream) |> should.equal(Ok(None))
          egress.stream_cancel(stream)
        }
        Error(_) -> example.2 |> should.be_false
      }
      http_stop(fixture)
    },
  )
}

pub fn session_bounds_kind_matrix_and_metadata_only_cas_test() {
  let store = new_store()
  let before = material("a")
  let assert SessionToken(token, metadata) = before
  let enriched =
    SessionToken(token, [#("profile", "synthetic-profile"), ..metadata])
  runtime_store.save_if_unchanged(store, key("a"), before, enriched)
  |> should.be_ok
  runtime_store.load(store, key("a")) |> should.equal(Ok(enriched))
  let metadata =
    list.map([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17], fn(n) {
      #(int.to_string(n), "synthetic")
    })
  list.each(
    [
      SessionToken(string.repeat("x", 16_385), []),
      SessionToken("synthetic", metadata),
      SessionToken("synthetic", [#("field", string.repeat("x", 16_385))]),
      SessionToken("synthetic", [#(string.repeat("x", 129), "value")]),
    ],
    fn(invalid) {
      let _ = runtime_store.save(store, key("bad"), invalid) |> should.be_error
      Nil
    },
  )
  let assert Ok(session) =
    credentials.start(store, key("matrix"), credentials.StaticSession)
  let assert Ok(api_key) =
    credentials.start(store, key("matrix"), credentials.StaticKey)
  list.each(
    [
      ApiKey("synthetic"),
      OAuth(OAuthData(auth.Credential("synthetic", "synthetic", 999_999), [])),
      material("a"),
    ],
    fn(value) {
      runtime_store.save(store, key("matrix"), value) |> should.be_ok
      let with_session = credentials.get(session, 0)
      let with_key = credentials.get(api_key, 0)
      case value {
        SessionToken(_, _) -> {
          with_session |> should.equal(Ok(value))
          let _ = with_key |> should.be_error
          Nil
        }
        ApiKey(_) -> {
          let _ = with_session |> should.be_error
          with_key |> should.equal(Ok(value))
        }
        _ -> {
          let _ = with_session |> should.be_error
          let _ = with_key |> should.be_error
          Nil
        }
      }
    },
  )
  credentials.stop(session)
  credentials.stop(api_key)
}

@external(erlang, "mimic_provider_runtime_test_ffi", "capture_logs")
fn capture_logs(run: fn() -> value) -> #(value, List(String))

pub fn binary_secret_head_read_and_callback_errors_are_not_logged_test() {
  let #(_, logs) =
    capture_logs(fn() {
      binary_plan_exception_diagnostics_do_not_expose_body_token_test()
      list.each(
        [
          "HTTP/1.1 synthetic-session-a Broken\r\nContent-Length: 0\r\n\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\nsynthetic-session-a\r\n",
          "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nsynthetic-session-a: trailer\r\n\r\n",
        ],
        fn(raw) {
          let assert Ok(fixture) = http_start(bit_array.from_string(raw))
          let origin = "http://127.0.0.1:" <> int.to_string(http_port(fixture))
          let assert Ok(runtime) =
            runtime.start(new_store(), registry(), [
              account("a", origin, fleet.LocalLoopback),
            ])
          let failure = runtime.execute(runtime, adapter(None), request())
          let _ = failure |> should.be_error
          string.inspect(failure)
          |> string.contains("synthetic-session-a")
          |> should.be_false
          runtime.active_leases(runtime) |> should.equal(Ok(0))
          runtime.stop(runtime) |> should.be_ok
          http_stop(fixture)
        },
      )
    })
  let logs = string.join(logs, "\n")
  string.contains(logs, "runtime-v3-log-sink-ready") |> should.be_true
  string.contains(logs, "synthetic-session-a") |> should.be_false
}
