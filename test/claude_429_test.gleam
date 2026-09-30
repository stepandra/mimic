/// Real local HTTP, synthetic credentials only. No provider/account calls.
import argv
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/providers/claude/adapter
import mimic/providers/claude/transport as claude_transport
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/quota

type Fixture

@external(erlang, "mimic_claude_429_test_ffi", "start")
fn fixture(responses: List(BitArray)) -> Fixture

@external(erlang, "mimic_claude_429_test_ffi", "port")
fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_429_test_ffi", "requests")
fn requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_claude_429_test_ffi", "closed")
fn closed(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_429_test_ffi", "stop")
fn stop(fixture: Fixture) -> Nil

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_provider_runtime_test_ffi", "capture_logs")
fn capture_logs(action: fn() -> a) -> #(a, List(String))

const model = "claude-opus-4-6"

const success = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

fn rejected(body: String) {
  bit_array.from_string(
    "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\nRetry-After: 3600\r\nanthropic-ratelimit-unified-status: rejected\r\nX-Synthetic-Private: synthetic-upstream-private\r\n\r\n"
    <> body,
  )
}

fn rejection_cases() {
  [
    rejected(
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Fast request rejected: usage credits are required for fast mode; synthetic-upstream-private\"}}",
    ),
    rejected(
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"synthetic ordinary quota\"}}",
    ),
    rejected("{synthetic-malformed"),
    rejected(string.repeat("synthetic-upstream-private", 30_000)),
    // Body would time out if read: the fixture withholds it until peer close.
    bit_array.from_string(
      "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: 100\r\nRetry-After: 3600\r\n\r\n",
    ),
  ]
}

pub fn main() {
  let baseline = list.contains(argv.load().arguments, "--baseline")
  let outcomes = matrix(baseline)
  // Never print upstream request/response content on regression failure.
  outcomes |> should.equal(list.repeat(#(True, True, True), 30))
  io.println("PASS: Claude 429 two-account no-replay/no-cooldown wire matrix")
}

pub fn two_account_429_matrix_never_replays_or_cools_test() {
  let #(outcomes, logs) = capture_logs(fn() { matrix(False) })
  outcomes |> should.equal(list.repeat(#(True, True, True), 30))
  let logs = string.join(logs, "\n")
  list.each(
    [
      "synthetic-key-a", "synthetic-key-b", "synthetic-access-a",
      "synthetic-refresh-a", "synthetic-upstream-private",
      "synthetic-client-body",
    ],
    fn(secret) { string.contains(logs, secret) |> should.be_false },
  )
}

fn matrix(baseline) {
  list.flat_map(["api_key", "oauth"], fn(mode) {
    list.flat_map(
      [
        #("messages", contracts.Buffered),
        #("messages", contracts.Streaming),
        #("messages/count_tokens", contracts.Buffered),
      ],
      fn(operation) {
        list.map(rejection_cases(), fn(wire) {
          run_case(mode, operation.0, operation.1, wire, baseline)
        })
      },
    )
  })
}

fn origin(fixture) {
  "http://127.0.0.1:" <> int.to_string(port(fixture))
}

fn seed(store, mode, id) {
  let material = case mode {
    "oauth" ->
      contracts.OAuth(
        contracts.OAuthData(
          auth.Credential(
            "synthetic-access-" <> id,
            "synthetic-refresh-" <> id,
            9_000_000_000_000,
          ),
          [
            #("device_id", string.repeat("a", 64)),
            #("account_uuid", "synthetic-" <> id),
          ],
        ),
      )
    _ -> contracts.ApiKey("synthetic-key-" <> id)
  }
  runtime_store.save(store, credentials.key("claude", mode, id), material)
  |> should.be_ok
}

fn start_engine(store, mode, first, second) {
  let assert Ok(registry) =
    registry.new([
      registry.Model(
        "claude",
        model,
        [mode],
        ["claude"],
        ["messages", "messages/count_tokens"],
        [contracts.Buffer, contracts.Stream],
      ),
    ])
  let policy = case mode {
    "oauth" ->
      credentials.Refreshable(
        contracts.Refresh(fn(_, _) {
          panic as "Synthetic fresh grant must not refresh"
        }),
      )
    _ -> credentials.StaticKey
  }
  let assert Ok(engine) =
    runtime.start(store, registry, [
      runtime.Account(
        "claude",
        mode,
        "a",
        origin(first),
        fleet.LocalLoopback,
        1,
        [model],
        policy,
      ),
      runtime.Account(
        "claude",
        mode,
        "b",
        origin(second),
        fleet.LocalLoopback,
        1,
        [model],
        policy,
      ),
    ])
  engine
}

fn request(mode, operation, delivery) {
  contracts.Request(
    "claude",
    mode,
    model,
    "claude",
    operation,
    delivery,
    [],
    "synthetic-session",
    None,
    "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic-client-body\"}],\"speed\":\"fast\"}",
  )
}

fn run_case(mode, operation, delivery, wire, baseline) {
  let first = fixture([wire, bit_array.from_string(success)])
  let second = fixture([bit_array.from_string(success)])
  let assert Ok(store) = storage.new(directory())
  seed(store, mode, "a")
  seed(store, mode, "b")
  quota.save(store, quota.empty()) |> should.be_ok
  let before = storage.read_quota_ledger(store)
  let engine = start_engine(store, mode, first, second)
  let provider = case baseline {
    True -> transport.http(adapter.prepare, adapter.rejection, None)
    False -> claude_transport.http(adapter.prepare, None)
  }
  let outcome =
    runtime.open(engine, provider, request(mode, operation, delivery))
  let terminal = case outcome {
    Error(error) ->
      error
      == contracts.Failure(contracts.Unsupported, contracts.Rejected, None)
      && !runtime.retryable(error)
    Ok(opened) -> {
      runtime.cancel(opened.stream)
      False
    }
  }
  let isolated =
    list.length(requests(first)) == 1
    && requests(second) == []
    && runtime.active_leases(engine) == Ok(0)
  let untouched = storage.read_quota_ledger(store) == before
  let usable = case terminal && isolated && untouched {
    False -> False
    True -> {
      await_closed(first, 1, 100)
      // A normal request pinned to A must work immediately, not after cooldown.
      let normal =
        contracts.Request(
          ..request(mode, "messages", contracts.Buffered),
          pinned_account: Some("a"),
          body: "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic normal request\"}]}",
        )
      let assert Ok(reply) = runtime.execute(engine, provider, normal)
      reply.account |> should.equal("a")
      reply.body |> should.equal(bit_array.from_string("{}"))
      runtime.active_leases(engine) |> should.equal(Ok(0))
      await_closed(first, 2, 100)
      runtime.stop(engine) |> should.be_ok
      // Restart without reseeding exercises the persisted quota decision.
      let restarted = start_engine(store, mode, first, second)
      let assert Ok(reply) = runtime.execute(restarted, provider, normal)
      reply.account |> should.equal("a")
      runtime.active_leases(restarted) |> should.equal(Ok(0))
      runtime.stop(restarted) |> should.be_ok
      await_closed(first, 3, 100)
      list.length(requests(first)) == 3 && requests(second) == []
    }
  }
  case usable {
    True -> Nil
    False -> {
      runtime.stop(engine) |> should.be_ok
      Nil
    }
  }
  stop(first)
  stop(second)
  #(terminal, isolated, untouched && usable)
}

fn await_closed(fixture, expected, remaining) {
  case closed(fixture), remaining {
    count, _ if count == expected -> Nil
    _, 0 -> should.fail()
    _, _ -> {
      process.sleep(10)
      await_closed(fixture, expected, remaining - 1)
    }
  }
}
