import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/egress
import mimic/fleet
import mimic/providers/contracts.{
  ApiKey, Buffer, Failure, NotSent, Quota, Rejected, Request, Started, Stream,
  Streaming,
}
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/recorder/tls
import mimic/types.{type Capture, Capture, Header, Transport}

type Fixture

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_start")
fn fixture(
  cert: String,
  key: String,
  response: String,
) -> Result(Fixture, String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_port")
fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_requests")
fn requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_closed")
fn closed(fixture: Fixture) -> Int

@external(erlang, "mimic_provider_runtime_test_ffi", "tls_stop")
fn stop(fixture: Fixture) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

fn origin(fixture: Fixture) -> String {
  "https://127.0.0.1:" <> int.to_string(port(fixture))
}

fn request() -> contracts.Request {
  Request(
    "synthetic",
    "key",
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

fn runtime_for(first: Fixture, second: Fixture) -> runtime.Runtime {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(registry) =
    registry.new([
      registry.Model("synthetic", "model", ["key"], ["test"], ["generate"], [
        Buffer,
        Stream,
      ]),
    ])
  list.each(["a", "b"], fn(id) {
    credentials.save_api_key(
      store,
      credentials.key("synthetic", "key", id),
      "synthetic-" <> id,
    )
    |> should.be_ok
  })
  let assert Ok(runtime) =
    runtime.start(store, registry, [
      runtime.Account(
        "synthetic",
        "key",
        "a",
        origin(first),
        fleet.OperatorHttps,
        2,
        ["model"],
        credentials.StaticKey,
      ),
      runtime.Account(
        "synthetic",
        "key",
        "b",
        origin(second),
        fleet.OperatorHttps,
        2,
        ["model"],
        credentials.StaticKey,
      ),
    ])
  runtime
}

fn plan(
  context: contracts.Context,
  request: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  let assert ApiKey(key) = context.credential
  Ok(Capture(
    "synthetic",
    "1",
    context.origin,
    "test",
    "POST",
    "/generate",
    "HTTP/1.1",
    [
      Header("Host", string.replace(context.origin, "https://", "")),
      Header("Authorization", "Bearer " <> key),
      Header("X-Session", context.session_key),
      Header("Content-Type", "application/json"),
      Header("Content-Length", int.to_string(string.byte_size(request.body))),
    ],
    request.body,
    Transport("http/1.1", None),
  ))
}

fn adapter(cert: String) -> contracts.Adapter(egress.Stream) {
  transport.http(
    plan,
    fn(status, _) {
      case status {
        429 -> Some(Failure(Quota, Rejected, Some(60_000)))
        _ -> None
      }
    },
    Some(cert),
  )
}

const complete = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nX-Order: first\r\nx-order: second\r\n\r\nB\r\ndata: one\n\n\r\nB\r\ndata: two\n\n\r\n0\r\n\r\n"

const partial = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\nB\r\ndata: one\n\n\r\n"

pub fn two_tls_accounts_quota_failover_and_credentials_stay_isolated_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) =
    fixture(
      cert,
      key,
      "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 60\r\nContent-Length: 0\r\n\r\n",
    )
  let assert Ok(second) = fixture(cert, key, complete)
  let runtime = runtime_for(first, second)
  let assert Ok(response) = runtime.open(runtime, adapter(cert), request())
  response.account |> should.equal("b")
  runtime.next(response.stream)
  |> should.equal(Ok(Some(bit_array.from_string("data: one\n\n"))))
  runtime.next(response.stream)
  |> should.equal(Ok(Some(bit_array.from_string("data: two\n\n"))))
  runtime.next(response.stream) |> should.equal(Ok(None))
  let assert [a] = requests(first)
  let assert [b] = requests(second)
  string.contains(a, "Bearer synthetic-a") |> should.be_true
  string.contains(a, "synthetic-b") |> should.be_false
  string.contains(b, "Bearer synthetic-b") |> should.be_true
  string.contains(b, "synthetic-a") |> should.be_false
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  await_closed(first, 50)
  await_closed(second, 50)
  runtime.stop(runtime) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn tls_cancellation_closes_socket_and_does_not_retry_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) = fixture(cert, key, partial)
  let assert Ok(second) = fixture(cert, key, complete)
  let runtime = runtime_for(first, second)
  let assert Ok(response) = runtime.open(runtime, adapter(cert), request())
  runtime.next(response.stream) |> should.be_ok
  runtime.cancel(response.stream)
  runtime.cancel(response.stream)
  await_closed(first, 50)
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  requests(first) |> list.length |> should.equal(1)
  requests(second) |> should.equal([])
  runtime.stop(runtime) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn truncated_tls_stream_is_started_and_never_replayed_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) =
    fixture(
      cert,
      key,
      string.replace(partial, "200 OK\r\n", "200 OK\r\nConnection: close\r\n"),
    )
  let assert Ok(second) = fixture(cert, key, complete)
  let runtime = runtime_for(first, second)
  let assert Ok(response) = runtime.open(runtime, adapter(cert), request())
  runtime.next(response.stream) |> should.be_ok
  let assert Error(error) = runtime.next(response.stream)
  error.delivery |> should.equal(Started)
  requests(first) |> list.length |> should.equal(1)
  requests(second) |> should.equal([])
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn tls_trust_and_hostname_are_verified_before_request_bytes_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) = fixture(cert, key, complete)
  let runtime = runtime_for(first, first)
  let untrusted = transport.http(plan, fn(_, _) { None }, None)
  let assert Error(error) =
    runtime.open(
      runtime,
      untrusted,
      Request(..request(), pinned_account: Some("a")),
    )
  error.delivery |> should.equal(NotSent)
  requests(first) |> should.equal([])
  let bad_host = "https://localhost:" <> int.to_string(port(first))
  let context =
    contracts.Context(
      "synthetic",
      "key",
      "a",
      bad_host,
      "session",
      ApiKey("synthetic"),
    )
  let assert Ok(capture) = plan(context, request())
  let assert Error(error) = egress.stream_open(bad_host, capture, Some(cert))
  error.delivery |> should.equal(NotSent)
  requests(first) |> should.equal([])
  runtime.stop(runtime) |> should.be_ok
  stop(first)
}

pub fn transport_rejects_adapter_origin_override_before_send_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) = fixture(cert, key, complete)
  let runtime = runtime_for(first, first)
  let transport =
    transport.http(
      fn(context, request) {
        let assert Ok(capture) = plan(context, request)
        Ok(Capture(..capture, endpoint: "https://not-approved.example"))
      },
      fn(_, _) { None },
      Some(cert),
    )
  runtime.open(runtime, transport, request()) |> should.be_error
  requests(first) |> should.equal([])
  runtime.stop(runtime) |> should.be_ok
  stop(first)
}

pub fn transport_rejects_host_override_duplicate_and_missing_before_send_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) = fixture(cert, key, complete)
  let runtime = runtime_for(first, first)
  list.each([0, 1, 2], fn(kind) {
    let adapter =
      transport.http(
        fn(context, request) {
          let assert Ok(capture) = plan(context, request)
          let headers =
            list.filter(capture.headers, fn(h) {
              string.lowercase(h.name) != "host"
            })
          let hosts = case kind {
            0 -> []
            1 -> [Header("Host", "unapproved.example")]
            _ -> [
              Header("Host", "127.0.0.1"),
              Header("host", "unapproved.example"),
            ]
          }
          Ok(Capture(..capture, headers: list.append(hosts, headers)))
        },
        fn(_, _) { None },
        Some(cert),
      )
    let assert Error(error) = runtime.open(runtime, adapter, request())
    error.delivery |> should.equal(NotSent)
  })
  requests(first) |> should.equal([])
  runtime.stop(runtime) |> should.be_ok
  stop(first)
}

fn await_closed(fixture: Fixture, attempts: Int) {
  case closed(fixture) > 0, attempts {
    True, _ -> Nil
    False, 0 -> panic as "TLS socket not closed"
    False, _ -> {
      process.sleep(5)
      await_closed(fixture, attempts - 1)
    }
  }
}
