import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store as grants
import mimic/auth/storage
import mimic/fleet
import mimic/gateway/config
import mimic/ingress/keys
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/status
import mimic/providers/devin/status_cli
import mimic/providers/devin/status_gateway as client
import mimic/providers/devin/status_observation as observation
import mimic/providers/registry
import mimic/providers/runtime
import mimic/quota

const token = "synthetic-f28-permanent-session"

const operator_key = "synthetic-f28-local-operator-key"

const model = "devin/swe-1-7"

fn account(id: String, origin: String) -> runtime.Account {
  runtime.Account(
    "devin",
    "session_token",
    id,
    origin,
    fleet.LocalLoopback,
    2,
    [model],
    credentials.StaticSession,
  )
}

fn origin(server: Server) -> String {
  "http://127.0.0.1:" <> int.to_string(port(server))
}

fn valid_body() -> BitArray {
  pb.encode([
    pb.message(1, [
      pb.text(3, token),
      pb.text(7, operator_key),
      pb.message(13, [
        pb.Varint(14, 0),
        pb.Varint(15, 100),
        pb.Varint(17, 1_789_200_000),
        pb.Varint(18, 1_789_300_000),
        pb.message(2, [pb.Varint(1, 1)]),
        pb.message(3, [pb.Varint(1, 1_789_100_000)]),
      ]),
    ]),
  ])
}

fn response(code: Int, wire: BitArray) -> BitArray {
  bit_array.append(
    bit_array.from_string(
      "HTTP/1.1 "
      <> int.to_string(code)
      <> " Synthetic\r\nContent-Type: application/proto\r\nContent-Length: "
      <> int.to_string(bit_array.byte_size(wire))
      <> "\r\nConnection: close\r\n\r\n",
    ),
    wire,
  )
}

fn stalled_head() -> BitArray {
  bit_array.from_string(
    "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nContent-Length: 100\r\n\r\n",
  )
}

fn inspect(headers: String, bytes: BitArray) -> Bool {
  case pb.decode(bytes) {
    Ok([pb.Bytes(1, metadata)]) ->
      case pb.decode(metadata) {
        Ok([
          pb.Bytes(1, name),
          pb.Bytes(2, version),
          pb.Bytes(3, secret),
          pb.Bytes(4, language),
          pb.Bytes(5, os),
          pb.Bytes(7, version_again),
          pb.Bytes(12, name_again),
          pb.Bytes(31, fingerprint),
        ]) ->
          string.starts_with(
            headers,
            "POST " <> status.get_user_status_path <> " HTTP/1.1\r\n",
          )
          && string.contains(
            headers,
            "\r\nAuthorization: Basic " <> token <> "-" <> token <> "\r\n",
          )
          && string.contains(headers, "\r\nContent-Type: application/proto\r\n")
          && string.contains(headers, "\r\nConnect-Protocol-Version: 1\r\n")
          && string.contains(
            headers,
            "\r\nContent-Length: " <> int.to_string(bit_array.byte_size(bytes)),
          )
          && string.contains(headers, "\r\nHost: 127.0.0.1:")
          && string.contains(headers, "\r\nAccept: */*")
          && !string.contains(string.lowercase(headers), "user-agent:")
          && !string.contains(string.lowercase(headers), "accept-encoding:")
          && !string.contains(string.lowercase(headers), "transfer-encoding:")
          && !string.contains(string.lowercase(headers), "sentry-trace:")
          && name == bit_array.from_string("chisel")
          && name == name_again
          && version == bit_array.from_string("3000.10.21")
          && version == version_again
          && secret == bit_array.from_string(token)
          && language == bit_array.from_string("en")
          && bit_array.byte_size(os) > 0
          && bit_array.byte_size(fingerprint) == 732
        _ -> False
      }
    _ -> False
  }
}

fn setup(
  directory: String,
  first: Server,
  second: Server,
  fun: fn(storage.Store, runtime.Runtime, client.Scope) -> a,
) -> a {
  let assert Ok(store) = storage.new(directory)
  let primary = account("selected", origin(first))
  let backup = account("backup", origin(second))
  let first_key = credentials.key("devin", "session_token", "selected")
  let second_key = credentials.key("devin", "session_token", "backup")
  grants.save(
    store,
    first_key,
    c.SessionToken(token, [#("private", "synthetic")]),
  )
  |> should.be_ok
  grants.save(store, second_key, c.SessionToken("synthetic-f28-backup", []))
  |> should.be_ok
  let assert Ok(before_one) = grants.load_record(store, first_key)
  let assert Ok(before_two) = grants.load_record(store, second_key)
  let assert Ok(scope) = client.scope(primary)
  let assert Ok(registered) = registry.new([client.registration(scope)])
  let assert Ok(engine) = runtime.start(store, registered, [primary, backup])
  let value =
    finally(fn() { fun(store, engine, scope) }, fn() {
      runtime.stop(engine) |> should.be_ok
    })
  let assert Ok(after_one) = grants.load_record(store, first_key)
  let assert Ok(after_two) = grants.load_record(store, second_key)
  // Exact opaque records include raw bytes, revision, material, metadata, gate.
  { before_one == after_one } |> should.be_true
  { before_two == after_two } |> should.be_true
  grants.metadata(store, first_key)
  |> should.equal(Ok(grants.Metadata("session_token", None)))
  counts(second) |> should.equal(#(0, 0, 0, 0))
  value
}

fn failure_case(wire: BitArray, expected: client.Failure) {
  use directory, first, second <- with_servers(wire, False, inspect)
  use _, engine, scope <- setup(directory, first, second)
  let observed = process.new_subject()
  client.fetch(engine, scope, fn(value) { process.send(observed, value) })
  |> should.equal(Error(expected))
  process.receive(observed, 0) |> should.be_error
  await_no_leases(engine, 200)
  let #(accepts, requests, valid, _) = counts(first)
  #(accepts, requests, valid) |> should.equal(#(1, 1, 1))
}

pub fn f28_authenticated_wire_callback_once_and_numeric_projection_test() {
  use directory, first, second <- with_servers(
    response(200, valid_body()),
    False,
    inspect,
  )
  use _, engine, scope <- setup(directory, first, second)
  let observed = process.new_subject()
  let assert Ok(value) =
    client.fetch(engine, scope, fn(value) { process.send(observed, value) })
  value.account |> should.equal("selected")
  { value.observed_at_ms > 0 } |> should.be_true
  value.daily_remaining_percent |> should.equal(Some(0))
  value.weekly_remaining_percent |> should.equal(Some(100))
  value.daily_reset_seconds |> should.equal(Some(1_789_200_000))
  value.weekly_reset_seconds |> should.equal(Some(1_789_300_000))
  value.plan_start_seconds |> should.equal(Some(1))
  value.plan_end_seconds |> should.equal(Some(1_789_100_000))
  process.receive(observed, 0) |> should.equal(Ok(value))
  process.receive(observed, 0) |> should.be_error
  let output = observation.to_json(value)
  !string.contains(output, token) |> should.be_true
  !string.contains(output, operator_key) |> should.be_true
  await_no_leases(engine, 200)
  counts(first) |> should.equal(#(1, 1, 1, 0))
}

pub fn f28_non_200_exact_safe_errors_no_fallback_test() {
  list.each([201, 401, 403, 503], fn(code) {
    failure_case(
      response(code, bit_array.from_string(token)),
      client.HttpFailure(code),
    )
    client.message(client.HttpFailure(code))
    |> should.equal("Devin status HTTP " <> int.to_string(code))
  })
  failure_case(
    bit_array.from_string(
      "HTTP/1.1 302 Synthetic\r\nLocation: https://example.invalid/private\r\nContent-Length: 0\r\n\r\n",
    ),
    client.HttpFailure(302),
  )
}

pub fn f28_429_only_safe_header_reaches_existing_ledger_test() {
  use directory, first, second <- with_servers(
    bit_array.from_string(
      "HTTP/1.1 429 Synthetic\r\nContent-Length: 0\r\nRetry-After: 2\r\nAnthropic-Ratelimit-Unified-5h-Status: "
      <> token
      <> "\r\n\r\n",
    ),
    False,
    inspect,
  )
  use store, engine, scope <- setup(directory, first, second)
  client.fetch(engine, scope, fn(_) { panic as "unexpected observation" })
  |> should.equal(Error(client.HttpFailure(429)))
  let assert Ok(ledger) = quota.load_or_empty(store)
  {
    quota.cooldown_until(
      ledger,
      credentials.key("devin", "session_token", "selected"),
    )
    > 0
  }
  |> should.be_true
  let assert Ok(persisted) = storage.read_quota_ledger(store)
  !string.contains(persisted, token) |> should.be_true
  await_no_leases(engine, 200)
}

pub fn f28_private_or_noncanonical_retry_after_never_persists_test() {
  list.each([token, "+2", "0002", "2\r\nRetry-After: 3"], fn(retry) {
    use directory, first, second <- with_servers(
      bit_array.from_string(
        "HTTP/1.1 429 Synthetic\r\nContent-Length: 0\r\nRetry-After: "
        <> retry
        <> "\r\n\r\n",
      ),
      False,
      inspect,
    )
    use store, engine, scope <- setup(directory, first, second)
    client.fetch(engine, scope, fn(_) { panic as "unexpected observation" })
    |> should.equal(Error(client.HttpFailure(429)))
    let assert Ok(persisted) = storage.read_quota_ledger(store)
    !string.contains(persisted, token) |> should.be_true
    await_no_leases(engine, 200)
  })
}

pub fn f28_media_and_compression_fail_closed_test() {
  list.each(
    [
      "",
      "Content-Type: application/connect+proto\r\n",
      "Content-Type: application/json\r\n",
      "Content-Type: application/proto\r\nContent-Type: application/proto\r\n",
      "Content-Type: application/proto\r\nContent-Encoding: gzip\r\n",
      "Content-Type: application/proto\r\nContent-Encoding: br\r\n",
    ],
    fn(headers) {
      failure_case(
        bit_array.from_string(
          "HTTP/1.1 200 Synthetic\r\n" <> headers <> "Content-Length: 0\r\n\r\n",
        ),
        client.RuntimeFailure(c.Failure(c.Unavailable, c.Uncertain, None)),
      )
    },
  )
}

pub fn f28_truncation_proto_connect_and_declared_body_limit_test() {
  failure_case(
    bit_array.from_string(
      "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nContent-Length: 100\r\n\r\nshort",
    ),
    client.RuntimeFailure(c.Failure(c.InvalidResponse, c.Started, None)),
  )
  let body = valid_body()
  failure_case(
    response(200, <<0, { bit_array.byte_size(body) }:32, body:bits>>),
    client.InvalidObservation,
  )
  failure_case(response(200, <<10, 20, 1>>), client.InvalidObservation)
  failure_case(response(200, <<>>), client.InvalidObservation)
  failure_case(
    bit_array.from_string(
      "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nContent-Length: 4194305\r\n\r\n",
    ),
    client.RuntimeFailure(c.Failure(c.InvalidResponse, c.Uncertain, None)),
  )
}

pub fn f28_cumulative_limit_and_complete_chunked_framing_test() {
  failure_case(
    bit_array.concat([
      bit_array.from_string(
        "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nTransfer-Encoding: chunked\r\n\r\n400001\r\n",
      ),
      bit_array.from_string(string.repeat("x", status.max_response_bytes + 1)),
      bit_array.from_string("\r\n0\r\n\r\n"),
    ]),
    client.InvalidObservation,
  )
  let body = valid_body()
  failure_case(
    bit_array.concat([
      bit_array.from_string(
        "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nTransfer-Encoding: chunked\r\n\r\n"
        <> int.to_base16(bit_array.byte_size(body))
        <> "\r\n",
      ),
      body,
      bit_array.from_string("\r\n"),
    ]),
    client.RuntimeFailure(c.Failure(c.InvalidResponse, c.Started, None)),
  )
}

pub fn f28_scope_and_registry_remain_private_status_only_test() {
  let baseline = account("selected", "http://127.0.0.1:1234")
  list.each(
    [
      runtime.Account(..baseline, provider: "other"),
      runtime.Account(..baseline, auth_mode: "api_key"),
      runtime.Account(..baseline, auth_policy: credentials.StaticKey),
      runtime.Account(..baseline, egress: fleet.OperatorHttps),
      runtime.Account(..baseline, origin: "https://example.invalid"),
      runtime.Account(..baseline, origin: "http://localhost:1234"),
      runtime.Account(..baseline, origin: "http://127.0.0.1:0"),
      runtime.Account(..baseline, origin: "http://127.0.0.1:65536"),
      runtime.Account(..baseline, origin: "http://127.0.0.1:1234/arbitrary"),
      runtime.Account(..baseline, origin: "http://user:secret@127.0.0.1:1234"),
      runtime.Account(
        ..baseline,
        origin: "http://127.0.0.1:1234?token=synthetic",
      ),
      runtime.Account(..baseline, models: []),
    ],
    fn(value) { client.scope(value) |> should.be_error },
  )
  let assert Ok(scope) = client.scope(baseline)
  let row = client.registration(scope)
  row.protocols |> should.equal(["devin-status"])
  row.operations |> should.equal(["status"])
  let assert Ok(registry) = registry.new([row])
  registry.resolve(
    registry,
    c.Request(
      ..client.request(scope),
      protocol: "openai-chat",
      operation: "generate",
    ),
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
}

pub fn f28_missing_credential_pre_io_test() {
  use directory, first, second <- with_servers(
    response(200, valid_body()),
    False,
    inspect,
  )
  let assert Ok(store) = storage.new(directory)
  let selected = account("selected", origin(first))
  let assert Ok(scope) = client.scope(selected)
  let assert Ok(registry) = registry.new([client.registration(scope)])
  let assert Ok(engine) = runtime.start(store, registry, [selected])
  use <- finally(_, fn() { runtime.stop(engine) |> should.be_ok })
  client.fetch(engine, scope, fn(_) { panic as "unexpected observation" })
  |> should.equal(
    Error(
      client.RuntimeFailure(c.Failure(c.CredentialUnavailable, c.NotSent, None)),
    ),
  )
  counts(first) |> should.equal(#(0, 0, 0, 0))
  counts(second) |> should.equal(#(0, 0, 0, 0))
  await_no_leases(engine, 200)
}

pub fn f28_duplicate_cancel_peer_eof_and_no_second_completion_test() {
  use directory, first, second <- with_servers(stalled_head(), True, inspect)
  use _, engine, scope <- setup(directory, first, second)
  let assert Ok(handle) = client.open(engine, scope)
  runtime.active_leases(engine) |> should.equal(Ok(1))
  client.cancel(handle)
  client.cancel(handle)
  await_peer_eof(first, 200)
  await_no_leases(engine, 200)
  client.finish(handle, fn(_) { panic as "unexpected observation" })
  |> should.be_error
  counts(first) |> should.equal(#(1, 1, 1, 1))
}

pub fn f28_adopted_owner_dies_inside_blocked_pull_test() {
  use directory, first, second <- with_servers(stalled_head(), True, inspect)
  use _, engine, scope <- setup(directory, first, second)
  let assert Ok(handle) = client.open(engine, scope)
  let ready = process.new_subject()
  let borrower =
    process.spawn_unlinked(fn() {
      client.adopt(handle) |> should.be_ok
      process.send(ready, Nil)
      let _ = client.finish(handle, fn(_) { panic as "unexpected observation" })
      Nil
    })
  use <- finally(_, fn() { process.kill(borrower) })
  process.receive(ready, 2000) |> should.equal(Ok(Nil))
  await_pull(borrower) |> should.be_true
  runtime.active_leases(engine) |> should.equal(Ok(1))
  process.kill(borrower)
  await_peer_eof(first, 200)
  await_no_leases(engine, 200)
  counts(first) |> should.equal(#(1, 1, 1, 1))
}

pub fn f28_pending_head_absolute_deadline_peer_eof_test() {
  use directory, first, second <- with_servers(<<>>, True, inspect)
  use _, engine, scope <- setup(directory, first, second)
  let began = monotonic_ms()
  client.open_with_budget(engine, scope, 200)
  |> should.equal(Error(client.DeadlineExceeded))
  { monotonic_ms() - began <= 200 + runtime.deadline_cleanup_ms + 200 }
  |> should.be_true
  await_peer_eof(first, 200)
  await_no_leases(engine, 200)
  counts(first) |> should.equal(#(1, 1, 1, 1))
}

pub fn f28_near_deadline_chunk_trickle_then_stall_not_fresh_read_budget_test() {
  use directory, first, second <- with_script(
    [
      #(
        0,
        bit_array.from_string(
          "HTTP/1.1 200 Synthetic\r\nContent-Type: application/proto\r\nTransfer-Encoding: chunked\r\n\r\n",
        ),
      ),
      #(100, bit_array.from_string("1\r\nx\r\n")),
      #(100, bit_array.from_string("1\r\nx\r\n")),
      #(100, bit_array.from_string("1\r\nx\r\n")),
    ],
    True,
    inspect,
  )
  use _, engine, scope <- setup(directory, first, second)
  let observed = process.new_subject()
  let began = monotonic_ms()
  let assert Ok(handle) = client.open_with_budget(engine, scope, 400)
  client.finish(handle, fn(value) { process.send(observed, value) })
  |> should.equal(Error(client.DeadlineExceeded))
  let elapsed = monotonic_ms() - began
  { elapsed >= 400 && elapsed <= 400 + runtime.deadline_cleanup_ms + 200 }
  |> should.be_true
  process.receive(observed, 0) |> should.be_error
  await_peer_eof(first, 200)
  await_no_leases(engine, 200)
  counts(first) |> should.equal(#(1, 1, 1, 1))
}

pub fn f28_529_retains_shared_bookkeeping_not_body_enforcement_test() {
  use directory, first, second <- with_servers(
    response(529, valid_body()),
    False,
    inspect,
  )
  use store, engine, scope <- setup(directory, first, second)
  client.fetch(engine, scope, fn(_) { panic as "unexpected observation" })
  |> should.equal(Error(client.HttpFailure(529)))
  let assert Ok(ledger) = quota.load_or_empty(store)
  {
    quota.cooldown_until(
      ledger,
      credentials.key("devin", "session_token", "selected"),
    )
    > 0
  }
  |> should.be_true
  await_no_leases(engine, 200)
}

pub fn f28_local_cooldown_no_account_is_pre_io_without_fallback_test() {
  use directory, first, second <- with_servers(<<>>, False, inspect)
  let assert Ok(store) = storage.new(directory)
  let key = credentials.key("devin", "session_token", "selected")
  grants.save(store, key, c.SessionToken(token, [])) |> should.be_ok
  let assert Ok(before) = grants.load_record(store, key)
  keys.create(directory, "synthetic-f28", operator_key) |> should.be_ok
  // A normal pre-existing shared ledger entry, not status-body enforcement.
  quota.cool_down(quota.empty(), key, epoch_ms() + 60_000)
  |> quota.save(store, _)
  |> should.be_ok
  status_cli.run(settings(directory, first), "selected", operator_key)
  |> should.equal(Error("Devin status account unavailable"))
  let assert Ok(after) = grants.load_record(store, key)
  { before == after } |> should.be_true
  counts(first) |> should.equal(#(0, 0, 0, 0))
  counts(second) |> should.equal(#(0, 0, 0, 0))
}

fn settings(directory: String, first: Server) -> config.Config {
  let assert Ok(settings) =
    config.decode(
      ir.stringify(
        ir.Object([
          #("version", ir.Integer(1)),
          #("state_dir", ir.String(directory)),
          #("listen_port", ir.Integer(0)),
          #(
            "accounts",
            ir.Array([
              ir.Object([
                #("provider", ir.String("devin")),
                #("auth_mode", ir.String("session_token")),
                #("id", ir.String("selected")),
                #("origin", ir.String(origin(first))),
                #("models", ir.Array([ir.String(model)])),
              ]),
            ]),
          ),
        ]),
      ),
    )
  settings
}

pub fn f28_operator_auth_precedes_account_selection_and_store_acquisition_test() {
  use directory, first, second <- with_servers(
    response(200, valid_body()),
    False,
    inspect,
  )
  let settings = settings(directory, first)
  status_cli.run(settings, "selected", operator_key)
  |> should.equal(Error("Devin status unauthorized"))
  status_cli.run(settings, "unknown", operator_key)
  |> should.equal(Error("Devin status unauthorized"))
  keys.create(directory, "synthetic-f28", operator_key) |> should.be_ok
  status_cli.run(settings, "unknown", operator_key)
  |> should.equal(Error("Devin status account is not uniquely configured"))
  keys.revoke(directory, "synthetic-f28") |> should.be_ok
  status_cli.run(settings, "selected", operator_key)
  |> should.equal(Error("Devin status unauthorized"))
  counts(first) |> should.equal(#(0, 0, 0, 0))
  counts(second) |> should.equal(#(0, 0, 0, 0))
}

pub fn f28_busy_store_preserves_existing_runtime_test() {
  use directory, first, second <- with_servers(
    response(200, valid_body()),
    False,
    inspect,
  )
  use _, engine, _ <- setup(directory, first, second)
  keys.create(directory, "synthetic-f28", operator_key) |> should.be_ok
  status_cli.run(settings(directory, first), "selected", operator_key)
  |> should.equal(Error(
    "Devin status store busy or unavailable; existing gateway is not stopped",
  ))
  runtime.active_leases(engine) |> should.equal(Ok(0))
  counts(first) |> should.equal(#(0, 0, 0, 0))
}

pub fn f28_authenticated_cli_seam_success_grant_exact_equality_test() {
  use directory, first, second <- with_servers(
    response(200, valid_body()),
    False,
    inspect,
  )
  let assert Ok(store) = storage.new(directory)
  let key = credentials.key("devin", "session_token", "selected")
  grants.save(store, key, c.SessionToken(token, [#("private", "synthetic")]))
  |> should.be_ok
  let assert Ok(before) = grants.load_record(store, key)
  keys.create(directory, "synthetic-f28", operator_key) |> should.be_ok
  let assert Ok(output) =
    status_cli.run(settings(directory, first), "selected", operator_key)
  { string.byte_size(output) < 2048 } |> should.be_true
  !string.contains(output, token) |> should.be_true
  !string.contains(output, operator_key) |> should.be_true
  let assert Ok(after) = grants.load_record(store, key)
  { before == after } |> should.be_true
  counts(first) |> should.equal(#(1, 1, 1, 0))
  counts(second) |> should.equal(#(0, 0, 0, 0))
}

fn await_no_leases(engine: runtime.Runtime, remaining: Int) {
  case runtime.active_leases(engine) {
    Ok(0) -> Nil
    _ if remaining > 0 -> {
      process.sleep(5)
      await_no_leases(engine, remaining - 1)
    }
    _ -> panic as "F28 lease remained"
  }
}

fn await_peer_eof(server: Server, remaining: Int) {
  case counts(server) {
    #(_, _, _, 1) -> Nil
    _ if remaining > 0 -> {
      process.sleep(5)
      await_peer_eof(server, remaining - 1)
    }
    _ -> counts(server) |> should.equal(#(1, 1, 1, 1))
  }
}

pub type Server

@external(erlang, "mimic_devin_f28_status_test_ffi", "with_servers")
fn with_servers(
  response: BitArray,
  hold: Bool,
  inspect: fn(String, BitArray) -> Bool,
  fun: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f28_status_test_ffi", "with_script")
fn with_script(
  packets: List(#(Int, BitArray)),
  hold: Bool,
  inspect: fn(String, BitArray) -> Bool,
  fun: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f28_status_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_devin_f28_status_test_ffi", "counts")
fn counts(server: Server) -> #(Int, Int, Int, Int)

@external(erlang, "mimic_devin_f28_status_test_ffi", "finally")
fn finally(fun: fn() -> a, cleanup: fn() -> b) -> a

@external(erlang, "mimic_devin_f28_status_test_ffi", "await_pull")
fn await_pull(pid: process.Pid) -> Bool

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
fn epoch_ms() -> Int
