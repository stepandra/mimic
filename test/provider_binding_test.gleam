import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/protocol/continuation
import mimic/protocol/responses/http as responses_http
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/recorder/tls
import mimic/types

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

fn account() -> runtime.Account {
  runtime.Account(
    "synthetic-bindings",
    "key",
    "a",
    "http://127.0.0.1:1",
    fleet.LocalLoopback,
    1,
    ["model"],
    credentials.StaticKey,
  )
}

fn registry() -> registry.Registry {
  let assert Ok(registry) =
    registry.new([
      registry.Model(
        "synthetic-bindings",
        "model",
        ["key"],
        ["responses"],
        ["generate", "compact", "unbound"],
        [contracts.Buffer, contracts.Stream],
      ),
    ])
  registry
}

fn request(operation: String) -> contracts.Request {
  contracts.Request(
    "synthetic-bindings",
    "key",
    "model",
    "responses",
    operation,
    contracts.Streaming,
    [],
    "tenant-client-session",
    None,
    "{}",
  )
}

fn binding(operation: String, origin: String) -> runtime.EndpointBinding {
  runtime.EndpointBinding(
    "synthetic-bindings",
    "key",
    "a",
    "responses",
    operation,
    origin,
    fleet.OperatorHttps,
  )
}

fn plan(
  context: contracts.Context,
  request: contracts.Request,
) -> Result(types.Capture, contracts.Failure) {
  let assert contracts.ApiKey(key) = context.credential
  Ok(types.Capture(
    "synthetic",
    "1",
    context.origin,
    "responses",
    "POST",
    "/" <> request.operation,
    "HTTP/1.1",
    [
      types.Header("Host", string.replace(context.origin, "https://", "")),
      types.Header("Authorization", "Bearer " <> key),
      types.Header("Content-Type", "application/json"),
      types.Header("Content-Length", "2"),
    ],
    request.body,
    types.Transport("http/1.1", None),
  ))
}

pub fn approved_operations_share_generation_but_use_distinct_tls_origins_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let assert Ok(first) = fixture(cert, key, response)
  let assert Ok(second) = fixture(cert, key, response)
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic-bindings", "key", "a")
  credentials.save_api_key(store, key, "synthetic-private") |> should.be_ok
  let assert Ok(record) = runtime_store.load_record(store, key)
  let expected_generation = runtime_store.revision(record)
  let assert Ok(runtime) =
    runtime.start_with_bindings(store, registry(), [account()], [
      binding("generate", origin(first)),
      binding("compact", origin(second)),
    ])
  let observed = process.new_subject()
  let adapter = transport.http(plan, fn(_, _) { None }, Some(cert))
  list.each(["generate", "compact"], fn(operation) {
    let assert Ok(opened) =
      runtime.open_scoped(
        runtime,
        adapter,
        fn(context, generation, request) {
          process.send(observed, #(context.account, context.origin, generation))
          adapter.open(context, request)
        },
        request(operation),
      )
    // Both bindings reserve the same account slot, not independent pools.
    runtime.open(runtime, adapter, request("compact"))
    |> should.equal(
      Error(contracts.Failure(contracts.NoAccount, contracts.NotSent, None)),
    )
    runtime.next(opened.stream) |> should.be_ok
    runtime.next(opened.stream) |> should.equal(Ok(None))
  })
  process.receive(observed, 1000)
  |> should.equal(Ok(#("a", origin(first), expected_generation)))
  process.receive(observed, 1000)
  |> should.equal(Ok(#("a", origin(second), expected_generation)))
  runtime.open(runtime, adapter, request("unbound")) |> should.be_error
  runtime.open(
    runtime,
    adapter,
    contracts.Request(..request("generate"), auth_mode: "other"),
  )
  |> should.be_error
  runtime.open(
    runtime,
    adapter,
    contracts.Request(..request("generate"), model: "other"),
  )
  |> should.be_error
  runtime.open(
    runtime,
    adapter,
    contracts.Request(..request("generate"), pinned_account: Some("other")),
  )
  |> should.be_error
  let assert [a] = requests(first)
  let assert [b] = requests(second)
  string.contains(a, "POST /generate ") |> should.be_true
  string.contains(b, "POST /compact ") |> should.be_true
  string.contains(a, "Bearer synthetic-private") |> should.be_true
  string.contains(b, "Bearer synthetic-private") |> should.be_true
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn binding_configuration_is_explicit_and_unambiguous_test() {
  let assert Ok(store) = storage.new(directory())
  let approved = binding("generate", "https://127.0.0.1:443")
  [
    [approved, approved],
    [runtime.EndpointBinding(..approved, account: "missing")],
    [runtime.EndpointBinding(..approved, operation: "unknown")],
    [runtime.EndpointBinding(..approved, origin: "https://127.0.0.1/path")],
    [runtime.EndpointBinding(..approved, origin: "https://127.0.0.1?query")],
    [runtime.EndpointBinding(..approved, origin: "https://user@127.0.0.1")],
    [runtime.EndpointBinding(..approved, origin: "http://provider.invalid")],
  ]
  |> list.each(fn(bindings) {
    runtime.start_with_bindings(store, registry(), [account()], bindings)
    |> should.equal(
      Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.NotSent,
        None,
      )),
    )
  })
}

pub fn same_token_admin_save_rotates_authoritative_generation_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic-bindings", "key", "a")
  credentials.save_api_key(store, key, "synthetic-private") |> should.be_ok
  let assert Ok(worker) = credentials.start(store, key, credentials.StaticKey)
  let assert Ok(first) = credentials.acquire_versioned(worker)
  credentials.save_api_key(store, key, "synthetic-private") |> should.be_ok
  let assert Ok(second) = credentials.acquire_versioned(worker)
  first.0 |> should.equal(second.0)
  first.1 |> should.not_equal(second.1)
  runtime_store.delete(store, key) |> should.be_ok
  credentials.acquire_versioned(worker) |> should.be_error
  credentials.stop(worker)
}

pub fn cooldown_is_shared_across_operation_origins_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(first) =
    fixture(
      cert,
      key,
      "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n",
    )
  let assert Ok(second) =
    fixture(
      cert,
      key,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
    )
  let assert Ok(store) = storage.new(directory())
  credentials.save_api_key(
    store,
    credentials.key("synthetic-bindings", "key", "a"),
    "synthetic",
  )
  |> should.be_ok
  let assert Ok(runtime) =
    runtime.start_with_bindings(store, registry(), [account()], [
      binding("generate", origin(first)),
      binding("compact", origin(second)),
    ])
  let adapter =
    transport.http(
      plan,
      fn(status, _) {
        case status {
          429 ->
            Some(contracts.Failure(
              contracts.Quota,
              contracts.Rejected,
              Some(60_000),
            ))
          _ -> None
        }
      },
      Some(cert),
    )
  runtime.open(runtime, adapter, request("generate")) |> should.be_error
  runtime.open(runtime, adapter, request("compact"))
  |> should.equal(
    Error(contracts.Failure(contracts.NoAccount, contracts.NotSent, None)),
  )
  requests(first) |> list.length |> should.equal(1)
  requests(second) |> should.equal([])
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  runtime.stop(runtime) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn real_tls_fold_rejects_terminal_followed_by_invalid_http_framing_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let events =
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"synth\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
    <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"synth\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n"
  let assert Ok(chunk_size) = int.to_base_string(string.byte_size(events), 16)
  let response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
    <> chunk_size
    <> "\r\n"
    <> events
    <> "\r\nINVALID\r\n"
  let assert Ok(upstream) = fixture(cert, key, response)
  let assert Ok(store) = storage.new(directory())
  credentials.save_api_key(
    store,
    credentials.key("synthetic-bindings", "key", "a"),
    "synthetic",
  )
  |> should.be_ok
  let assert Ok(runtime) =
    runtime.start_with_bindings(store, registry(), [account()], [
      binding("generate", origin(upstream)),
    ])
  let adapter = transport.http(plan, fn(_, _) { None }, Some(cert))
  let assert Ok(opened) = runtime.open(runtime, adapter, request("generate"))
  let assert Ok(state) = responses_http.open_sse(opened.status, opened.headers)
  let observed = process.new_subject()
  let result =
    responses_http.run_fold(
      state,
      opened.stream,
      fn(handle) {
        runtime.next(handle)
        |> result.map(fn(bytes) {
          option.map(bytes, fn(bytes) { #(bytes, handle) })
        })
      },
      runtime.cancel,
      [],
      fn(acc, event) {
        process.send(observed, event.name)
        Ok(#(list.append(acc, [event.name]), responses_http.Continue))
      },
    )
  result |> should.be_error
  process.receive(observed, 1000) |> should.equal(Ok("response.created"))
  process.receive(observed, 1000) |> should.equal(Ok("response.completed"))
  runtime.active_leases(runtime) |> should.equal(Ok(0))
  await_closed(upstream, 100)
  runtime.stop(runtime) |> should.be_ok
  stop(upstream)
}

pub fn runtime_selected_generation_cannot_lookup_old_cached_receipt_test() {
  let assert Ok(store) = storage.new(directory())
  let key = credentials.key("synthetic-bindings", "key", "a")
  credentials.save_api_key(store, key, "synthetic") |> should.be_ok
  let assert Ok(runtime) = runtime.start(store, registry(), [account()])
  let assert Ok(cache) =
    continuation.start(continuation.Limits(4, 4096, 4096, 60_000))
  let observed = process.new_subject()
  let adapter =
    contracts.Adapter(
      open: fn(_, _) { Ok(contracts.Opened(200, [], Nil)) },
      next: fn(_) { Ok(None) },
      cancel: fn(_) { Nil },
      rejection: fn(_, _) { None },
    )
  // Synthetic trusted receipt fixture: this tests generation plumbing, not
  // provider completion policy. No provider tokens/history enter diagnostics.
  let open = fn(context, revision, request) {
    let assert Ok(scope) =
      continuation.scope("tenant", context, revision, request)
    process.send(observed, continuation.get(cache, scope, "r"))
    let _ = continuation.put(cache, scope, "r", "synthetic-receipt")
    adapter.open(context, request)
  }
  let assert Ok(first) =
    runtime.open_scoped(runtime, adapter, open, request("generate"))
  runtime.next(first.stream) |> should.equal(Ok(None))
  process.receive(observed, 1000)
  |> should.equal(Ok(Error("continuation receipt unavailable")))
  let assert Ok(second) =
    runtime.open_scoped(runtime, adapter, open, request("generate"))
  runtime.next(second.stream) |> should.equal(Ok(None))
  process.receive(observed, 1000) |> should.equal(Ok(Ok("synthetic-receipt")))
  credentials.save_api_key(store, key, "synthetic") |> should.be_ok
  let assert Ok(third) =
    runtime.open_scoped(runtime, adapter, open, request("generate"))
  runtime.next(third.stream) |> should.equal(Ok(None))
  process.receive(observed, 1000)
  |> should.equal(Ok(Error("continuation receipt unavailable")))
  continuation.stop(cache) |> should.be_ok
  runtime.stop(runtime) |> should.be_ok
}

fn await_closed(fixture: Fixture, attempts: Int) -> Nil {
  case closed(fixture), attempts {
    count, _ if count > 0 -> Nil
    _, 0 -> panic as "synthetic TLS socket was not closed"
    _, _ -> {
      process.sleep(5)
      await_closed(fixture, attempts - 1)
    }
  }
}
