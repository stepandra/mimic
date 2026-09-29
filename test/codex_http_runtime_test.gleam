/// Actual loopback HTTP, shared runtime revisions and nonpersistent cache.
/// All credentials/content below are synthetic; no live account discovery.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response as wire
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/continuation
import mimic/protocol/responses/http as pump
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/http
import mimic/providers/codex/models
import mimic/providers/codex/normalize
import mimic/providers/codex/response
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

type Shutdown {
  Shutdown
}

fn config(tenant) {
  adapter.Config(tenant, "synthetic-test/1", True, models.pinned(), None)
}

fn req(body) {
  contracts.Request(
    "codex",
    "oauth",
    "gpt-5.5",
    "responses",
    "responses",
    contracts.Buffered,
    [],
    "server-authenticated-client",
    Some("a"),
    body,
  )
}

fn material() {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-access",
        "synthetic-refresh",
        9_000_000_000_000,
      ),
      [#("chatgpt_account_id", "synthetic-account")],
    ),
  )
}

fn with_runtime(exercise) {
  let ports = process.new_subject()
  let observations = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(req) {
      let assert Ok(read) = mist.read_body(req, 1_048_576)
      let assert Ok(text) = bit_array.to_string(read.body)
      let assert Ok(body) = ir.parse(text)
      let assert Some(ir.Array(input)) = ir.field(body, "input")
      process.send(observations, #(
        list.length(input),
        ir.field(body, "previous_response_id") == None,
      ))
      let mode = ir.field(body, "instructions")
      let sse = case mode {
        Some(ir.String("trailing-fault")) ->
          fixtures.sse() <> "data: {\"type\":\n\n"
        Some(ir.String("failed")) ->
          "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_failed\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\ndata: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_failed\",\"object\":\"response\",\"status\":\"failed\",\"output\":[]}}\n\n"
        _ ->
          case list.length(input) {
            4 ->
              fixtures.sse()
              |> string.replace("resp_synthetic", "resp_second")
              |> string.replace("call_synthetic", "call_second")
            7 ->
              fixtures.sse()
              |> string.replace("resp_synthetic", "resp_third")
              |> string.replace("call_synthetic", "call_third")
            _ -> fixtures.sse()
          }
      }
      wire.new(200)
      |> wire.set_header("content-type", "text/event-stream")
      |> wire.set_body(mist.Bytes(bytes_tree.from_string(sse)))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  process.unlink(server.pid)
  let assert Ok(port) = process.receive(ports, 1000)
  let assert Ok(store) = storage.new(directory())
  list.each(["a", "b"], fn(account) {
    runtime_store.save(
      store,
      credentials.key("codex", "oauth", account),
      material(),
    )
    |> should.be_ok
  })
  let assert Ok(model) = models.lookup(models.pinned(), "gpt-5.5")
  let assert Ok(registration) = adapter.registration(model)
  let assert Ok(registry) = registry.new([registration])
  let accounts =
    list.map(["a", "b"], fn(id) {
      runtime.Account(
        "codex",
        "oauth",
        id,
        "http://127.0.0.1:" <> int.to_string(port),
        fleet.LocalLoopback,
        4,
        ["gpt-5.5"],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      )
    })
  let assert Ok(provider) = runtime.start(store, registry, accounts)
  exercise(provider, store, observations)
  runtime.active_leases(provider) |> should.equal(Ok(0))
  runtime.stop(provider) |> should.be_ok
  process.send_abnormal_exit(server.pid, Shutdown)
}

fn cache() {
  let assert Ok(cache) =
    continuation.start(continuation.Limits(32, 8_388_608, 2_097_152, 900_000))
  cache
}

fn first(provider, cache, tenant) {
  let assert Ok(opened) =
    http.open(provider, cache, config(tenant), None, req(fixtures.request))
  http.account(opened) |> should.equal("a")
  let assert Ok(response.Completed(completed)) = http.consume(opened)
  completed
}

pub fn codex_http_server_receipts_three_turns_and_concurrent_tenants_test() {
  with_runtime(fn(provider, _, observations) {
    let cache = cache()
    let done = process.new_subject()
    list.each(["tenant-a", "tenant-b"], fn(tenant) {
      process.spawn(fn() {
        let completed = first(provider, cache, tenant)
        process.send(done, completed.response.id)
      })
    })
    process.receive(done, 5000) |> should.equal(Ok("resp_synthetic"))
    process.receive(done, 5000) |> should.equal(Ok("resp_synthetic"))
    let assert Ok(second) =
      http.open(
        provider,
        cache,
        config("tenant-a"),
        None,
        contracts.Request(..req(fixtures.continuation), pinned_account: None),
      )
    let assert Ok(response.Completed(completed)) =
      http.forward(second, fn(_) { Ok(pump.Continue) })
    completed.response.id |> should.equal("resp_second")
    let third_body =
      fixtures.continuation
      |> string.replace("resp_synthetic", "resp_second")
      |> string.replace("call_synthetic", "call_second")
    let assert Ok(third) =
      http.open(provider, cache, config("tenant-a"), None, req(third_body))
    let assert Ok(response.Completed(completed)) = http.consume(third)
    completed.response.id |> should.equal("resp_third")
    list.each([1, 1, 4, 7], fn(length) {
      process.receive(observations, 1000) |> should.equal(Ok(#(length, True)))
    })
    continuation.stop(cache) |> should.be_ok
  })
}

pub fn codex_http_missing_cross_scope_restart_and_same_token_reenrollment_test() {
  with_runtime(fn(provider, store, observations) {
    let cache = cache()
    first(provider, cache, "tenant-a")
    process.receive(observations, 1000) |> should.be_ok
    http.open(
      provider,
      cache,
      config("tenant-b"),
      None,
      req(fixtures.continuation),
    )
    |> should.be_error
    http.open(
      provider,
      cache,
      config("tenant-a"),
      None,
      contracts.Request(..req(fixtures.continuation), pinned_account: Some("b")),
    )
    |> should.be_error
    http.open(
      provider,
      cache,
      config("tenant-a"),
      None,
      contracts.Request(..req(fixtures.continuation), session: "other-client"),
    )
    |> should.be_error
    let assert Ok(restarted) =
      continuation.start(continuation.Limits(32, 8_388_608, 2_097_152, 900_000))
    http.open(
      provider,
      restarted,
      config("tenant-a"),
      None,
      req(fixtures.continuation),
    )
    |> should.be_error
    continuation.stop(restarted) |> should.be_ok
    // Same values, NEW authoritative generation: token hashes cannot catch this.
    runtime_store.save(
      store,
      credentials.key("codex", "oauth", "a"),
      material(),
    )
    |> should.be_ok
    http.open(
      provider,
      cache,
      config("tenant-a"),
      None,
      req(fixtures.continuation),
    )
    |> should.be_error
    runtime_store.delete(store, credentials.key("codex", "oauth", "a"))
    |> should.be_ok
    http.open(
      provider,
      cache,
      config("tenant-a"),
      None,
      req(fixtures.continuation),
    )
    |> should.be_error
    process.receive(observations, 10) |> should.be_error
    continuation.stop(cache) |> should.be_ok
  })
}

pub fn codex_http_partial_failed_cancelled_streams_never_publish_test() {
  with_runtime(fn(provider, _, _) {
    let cache = cache()
    let assert Ok(body) = ir.parse(fixtures.request)
    list.each(["trailing-fault", "failed", "cancel"], fn(fault) {
      let body = normalize.put(body, "instructions", ir.String(fault))
      let assert Ok(opened) =
        http.open(provider, cache, config(fault), None, req(ir.stringify(body)))
      let result =
        http.forward(opened, fn(_) {
          case fault {
            "cancel" -> Ok(pump.Cancel)
            _ -> Ok(pump.Continue)
          }
        })
      case fault {
        "failed" -> {
          let assert Ok(response.Unsuccessful(_)) = result
          Nil
        }
        _ -> {
          result |> should.be_error
          Nil
        }
      }
      let follow = case fault {
        "failed" ->
          string.replace(fixtures.continuation, "resp_synthetic", "resp_failed")
        _ -> fixtures.continuation
      }
      http.open(provider, cache, config(fault), None, req(follow))
      |> should.be_error
    })
    continuation.stop(cache) |> should.be_ok
  })
}

pub fn codex_http_expired_receipt_rejected_before_network_test() {
  with_runtime(fn(provider, _, observations) {
    let assert Ok(cache) =
      continuation.start(continuation.Limits(2, 8_388_608, 2_097_152, 1))
    first(provider, cache, "tenant")
    process.receive(observations, 1000) |> should.be_ok
    process.sleep(5)
    http.open(
      provider,
      cache,
      config("tenant"),
      None,
      req(fixtures.continuation),
    )
    |> should.be_error
    process.receive(observations, 10) |> should.be_error
    continuation.stop(cache) |> should.be_ok
  })
}

pub fn codex_http_lite_header_intent_and_metadata_share_scoped_history_test() {
  with_runtime(fn(provider, _, observations) {
    let cache = cache()
    let initial =
      contracts.Request(..req(fixtures.request), operation: "responses/lite")
    let assert Ok(opened) =
      http.open(provider, cache, config("tenant"), None, initial)
    http.status(opened) |> should.equal(200)
    let assert Ok(response.Completed(_)) = http.consume(opened)
    let assert Ok(body) = ir.parse(fixtures.continuation)
    let body =
      normalize.put(
        body,
        "client_metadata",
        ir.Object([
          #(
            "ws_request_header_x_openai_internal_codex_responses_lite",
            ir.Boolean(True),
          ),
        ]),
      )
    let follow =
      contracts.Request(..req(ir.stringify(body)), pinned_account: None)
    let assert Ok(opened) =
      http.open(provider, cache, config("tenant"), None, follow)
    let assert Ok(response.Completed(_)) =
      http.forward(opened, fn(_) { Ok(pump.Continue) })
    list.each([1, 4], fn(length) {
      process.receive(observations, 1000) |> should.equal(Ok(#(length, True)))
    })
    continuation.stop(cache) |> should.be_ok
  })
}
