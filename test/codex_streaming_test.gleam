import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/protocol/responses/http
import mimic/protocol/responses/stream
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/codex/response
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn setup() {
  let assert Ok(store) = storage.new(directory())
  let data =
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
  list.each(["a", "b"], fn(id) {
    runtime_store.save(store, credentials.key("codex", "oauth", id), data)
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
        "http://127.0.0.1:1",
        fleet.LocalLoopback,
        1,
        ["gpt-5.5"],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      )
    })
  let assert Ok(runtime) = runtime.start(store, registry, accounts)
  runtime
}

fn req() {
  contracts.Request(
    "codex",
    "oauth",
    "gpt-5.5",
    "responses",
    "responses",
    contracts.Streaming,
    [],
    "synthetic-stream",
    None,
    fixtures.request,
  )
}

fn mock(chunks, plans, calls) {
  contracts.Adapter(
    open: fn(context, request) {
      let assert Ok(prepared) =
        adapter.prepare_native(
          adapter.Config(
            "synthetic-tenant",
            "synthetic-stream/1",
            True,
            models.pinned(),
            None,
          ),
          context,
          request,
        )
      process.send(plans, prepared)
      process.send(calls, "open")
      Ok(contracts.Opened(
        200,
        [Header("Content-Type", "text/event-stream")],
        chunks,
      ))
    },
    next: fn(chunks) {
      process.send(calls, "pull")
      case chunks {
        [] -> Ok(None)
        [first, ..rest] -> Ok(Some(#(first, rest)))
      }
    },
    cancel: fn(_) { process.send(calls, "cancel") },
    rejection: adapter.rejection,
  )
}

pub fn codex_streaming_emits_valid_prefix_before_error_without_retry_test() {
  let runtime = setup()
  let prefix =
    "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}\n\n"
  let malformed = "event: response.output_text.delta\ndata: {malformed}\n\n"
  list.each(
    [
      [bit_array.from_string(prefix <> malformed)],
      [bit_array.from_string(prefix), bit_array.from_string(malformed)],
    ],
    fn(chunks) {
      let plans = process.new_subject()
      let calls = process.new_subject()
      let events = process.new_subject()
      let assert Ok(opened) =
        runtime.open(runtime, mock(chunks, plans, calls), req())
      let assert Ok(prepared) = process.receive(plans, 1000)
      response.forward(opened, prepared, fn(event) {
        process.send(events, event.name)
        Ok(http.Continue)
      })
      |> should.equal(
        Error(contracts.Failure(
          contracts.InvalidResponse,
          contracts.Started,
          None,
        )),
      )
      process.receive(events, 1000) |> should.equal(Ok("response.created"))
      process.receive(events, 0) |> should.be_error
      process.receive(calls, 1000) |> should.equal(Ok("open"))
      list.each(chunks, fn(_) {
        process.receive(calls, 1000) |> should.equal(Ok("pull"))
      })
      process.receive(calls, 1000) |> should.equal(Ok("cancel"))
      // No extra read, second account open, cancel callback, or retry.
      process.receive(calls, 0) |> should.be_error
      runtime.active_leases(runtime) |> should.equal(Ok(0))
    },
  )
  runtime.stop(runtime) |> should.be_ok
}

pub fn codex_streaming_preflight_and_preemit_failures_are_started_and_cleaned_test() {
  let runtime = setup()
  list.each(
    [
      "account",
      "headers",
      "encoding",
      "status",
      "pull",
      "empty",
      "malformed",
      "truncated",
    ],
    fn(mode) {
      let plans = process.new_subject()
      let calls = process.new_subject()
      let events = process.new_subject()
      let chunks = case mode {
        "truncated" -> [bit_array.from_string("data: {")]
        "malformed" -> [bit_array.from_string("data: {malformed}\n\n")]
        _ -> []
      }
      let base = mock(chunks, plans, calls)
      let transport = case mode {
        "pull" ->
          contracts.Adapter(..base, next: fn(_) {
            process.send(calls, "pull")
            Error(contracts.Failure(
              contracts.Unavailable,
              contracts.NotSent,
              None,
            ))
          })
        _ -> base
      }
      let assert Ok(opened) = runtime.open(runtime, transport, req())
      let assert Ok(prepared) = process.receive(plans, 1000)
      let opened = case mode {
        "account" -> runtime.Response(..opened, account: "other")
        "headers" ->
          runtime.Response(..opened, headers: [
            Header("Content-Type", "application/json"),
          ])
        "encoding" ->
          runtime.Response(..opened, headers: [
            Header("Content-Type", "text/event-stream"),
            Header("Content-Encoding", "gzip"),
          ])
        "status" -> runtime.Response(..opened, status: 400)
        _ -> opened
      }
      let reason = case mode {
        "account" -> contracts.InvalidConfiguration
        "pull" -> contracts.Unavailable
        _ -> contracts.InvalidResponse
      }
      response.forward(opened, prepared, fn(event) {
        process.send(events, event.name)
        Ok(http.Continue)
      })
      |> should.equal(Error(contracts.Failure(reason, contracts.Started, None)))
      process.receive(events, 0) |> should.be_error
      process.receive(calls, 1000) |> should.equal(Ok("open"))
      case mode {
        "account" | "headers" | "encoding" | "status" -> Nil
        _ -> process.receive(calls, 1000) |> should.equal(Ok("pull"))
      }
      case mode {
        "truncated" -> process.receive(calls, 1000) |> should.equal(Ok("pull"))
        _ -> Nil
      }
      process.receive(calls, 1000) |> should.equal(Ok("cancel"))
      process.receive(calls, 0) |> should.be_error
      runtime.active_leases(runtime) |> should.equal(Ok(0))
    },
  )
  runtime.stop(runtime) |> should.be_ok
}

pub fn codex_streaming_completion_cancel_and_downstream_failure_test() {
  let runtime = setup()
  list.each(["complete", "cancel", "downstream-error"], fn(mode) {
    let plans = process.new_subject()
    let calls = process.new_subject()
    let assert Ok(opened) =
      runtime.open(
        runtime,
        mock([bit_array.from_string(fixtures.sse())], plans, calls),
        req(),
      )
    let assert Ok(prepared) = process.receive(plans, 1000)
    let outcome =
      response.forward(opened, prepared, fn(_) {
        case mode {
          "cancel" -> Ok(http.Cancel)
          "downstream-error" -> Error("synthetic-secret-not-for-public-errors")
          _ -> Ok(http.Continue)
        }
      })
    case mode {
      "complete" -> outcome |> should.equal(Ok(stream.Completed))
      "cancel" -> outcome |> should.equal(Ok(stream.Cancelled))
      _ ->
        outcome
        |> should.equal(
          Error(contracts.Failure(contracts.Cancelled, contracts.Started, None)),
        )
    }
    process.receive(calls, 1000) |> should.equal(Ok("open"))
    process.receive(calls, 1000) |> should.equal(Ok("pull"))
    process.receive(calls, 1000) |> should.equal(Ok("cancel"))
    process.receive(calls, 0) |> should.be_error
    runtime.active_leases(runtime) |> should.equal(Ok(0))
  })
  runtime.stop(runtime) |> should.be_ok
}
