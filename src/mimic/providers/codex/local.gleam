/// Runnable loopback integration: actual shared runtime/store/HTTP transport,
/// synthetic OAuth material and provider responses. No live calls.
import argv
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response as http_response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/dialect/responses
import mimic/fleet
import mimic/ir
import mimic/protocol/responses/http as responses_http
import mimic/protocol/responses/stream as responses_stream
import mimic/providers/codex/adapter
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/codex/request
import mimic/providers/codex/response as codex_response
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mist

pub type Observation {
  Observation(
    target: String,
    status: Int,
    authorization_ok: Bool,
    account_ok: Bool,
    body_valid: Bool,
    continuation_replayed: Bool,
  )
}

type Shutdown {
  Shutdown
}

pub fn main() {
  case cli(argv.load().arguments) {
    Ok(report) -> io.println(report)
    Error(error) -> panic as error
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [state_dir] -> run(state_dir)
    _ -> Error("usage: codex local <existing-private-0700-state-directory>")
  }
}

pub fn run(state_dir: String) -> Result(String, String) {
  let observations = process.new_subject()
  let ports = process.new_subject()
  let builder =
    mist.new(fn(req) {
      let decoded = {
        use read <- result.try(
          mist.read_body(req, 1_048_576)
          |> result.map_error(fn(_) { "synthetic body read failed" }),
        )
        use text <- result.try(
          bit_array.to_string(read.body)
          |> result.map_error(fn(_) { "synthetic body UTF-8" }),
        )
        responses.decode_request(text)
      }
      let #(body_valid, continuation_replayed) = case decoded {
        Ok(request) -> {
          let input = ir.field(request.document, "input")
          let replayed = case input {
            Some(ir.Array([_, reasoning, call, output])) ->
              ir.field(reasoning, "encrypted_content")
              == Some(ir.String("synthetic-opaque-not-a-signature"))
              && ir.field(call, "call_id") == Some(ir.String("call_synthetic"))
              && ir.field(output, "output")
              == Some(ir.String("synthetic-result"))
              && request.previous_response_id == None
            _ -> False
          }
          #(result.is_ok(responses.pair_input(request, [])), replayed)
        }
        Error(_) -> #(False, False)
      }
      let authorization_ok =
        list.contains(req.headers, #(
          "authorization",
          "Bearer synthetic-local-access",
        ))
      let status = case authorization_ok {
        True -> 200
        False -> 401
      }
      process.send(
        observations,
        Observation(
          req.path,
          status,
          authorization_ok,
          list.contains(req.headers, #(
            "chatgpt-account-id",
            "synthetic-provider-account",
          )),
          body_valid,
          continuation_replayed,
        ),
      )
      let #(content_type, body) = case status, req.path {
        401, _ -> #(
          "application/json",
          "{\"error\":{\"code\":\"invalid_api_key\"}}",
        )
        _, "/backend-api/codex/responses/compact" -> #(
          "application/json",
          fixtures.compact,
        )
        _, _ -> #("text/event-stream", fixtures.sse())
      }
      http_response.new(status)
      |> http_response.set_header("content-type", content_type)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    })
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
  use server <- result.try(
    mist.start(builder)
    |> result.map_error(fn(_) { "synthetic provider failed to start" }),
  )
  process.unlink(server.pid)
  let outcome = {
    use port <- result.try(
      process.receive(ports, 1000)
      |> result.map_error(fn(_) { "synthetic provider port missing" }),
    )
    execute(state_dir, "http://127.0.0.1:" <> int.to_string(port), observations)
  }
  process.send_abnormal_exit(server.pid, Shutdown)
  outcome
}

fn execute(
  state_dir: String,
  origin: String,
  observations: process.Subject(Observation),
) -> Result(String, String) {
  use store <- result.try(storage.new(state_dir))
  let material =
    contracts.OAuth(
      contracts.OAuthData(
        auth.Credential(
          "synthetic-local-access",
          "synthetic-local-refresh",
          9_000_000_000_000,
        ),
        [#("chatgpt_account_id", "synthetic-provider-account")],
      ),
    )
  use _ <- result.try(
    list.try_each(["account-a", "account-b"], fn(account) {
      let material = case account {
        "account-a" ->
          contracts.OAuth(
            contracts.OAuthData(
              auth.Credential(
                "synthetic-rejected-access",
                "synthetic-local-refresh",
                9_000_000_000_000,
              ),
              [#("chatgpt_account_id", "synthetic-provider-account")],
            ),
          )
        _ -> material
      }
      runtime_store.save(
        store,
        credentials.key("codex", "oauth", account),
        material,
      )
    }),
  )
  use model <- result.try(models.lookup(models.pinned(), "gpt-5.5"))
  use registration <- result.try(adapter.registration(model))
  use registry <- result.try(registry.new([registration]) |> safe_error)
  let accounts =
    list.map(["account-a", "account-b"], fn(id) {
      runtime.Account(
        "codex",
        "oauth",
        id,
        origin,
        fleet.LocalLoopback,
        1,
        ["gpt-5.5"],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      )
    })
  use runtime <- result.try(
    runtime.start(store, registry, accounts) |> safe_error,
  )
  let outcome = exercise(runtime, observations)
  let stopped = runtime.stop(runtime) |> safe_error
  use _ <- result.try(stopped)
  outcome
}

fn exercise(
  runtime: runtime.Runtime,
  observations: process.Subject(Observation),
) -> Result(String, String) {
  let config =
    adapter.Config(
      "synthetic-tenant",
      "mimic-synthetic-local/1",
      True,
      models.pinned(),
      None,
    )
  let plans = process.new_subject()
  let http =
    transport.http(
      fn(context, request) {
        use prepared <- result.try(adapter.prepare_native(
          config,
          context,
          request,
        ))
        process.send(plans, #(context.account, prepared))
        adapter.capture(context, request, prepared)
      },
      adapter.rejection,
      None,
    )
  let req =
    contracts.Request(
      "codex",
      "oauth",
      "gpt-5.5",
      "responses",
      "responses",
      contracts.Buffered,
      [],
      "synthetic-session",
      None,
      fixtures.request,
    )
  use response <- result.try(runtime.open(runtime, http, req) |> safe_error)
  use prepared <- result.try(take_plan(plans, response.account))
  use _ <- result.try(check(
    response.account == "account-b" && prepared.credential_id == "account-b",
    "rejected account plan was paired with successful account response",
  ))
  use rejected <- result.try(
    process.receive(observations, 1000)
    |> result.map_error(fn(_) {
      "missing synthetic rejected account observation"
    }),
  )
  use _ <- result.try(check(
    rejected.status == 401 && !rejected.authorization_ok,
    "synthetic failover did not start with account rejection",
  ))
  use terminal <- result.try(codex_response.consume(response, prepared))
  use completion <- result.try(case terminal {
    codex_response.Completed(completion) -> Ok(completion)
    _ -> Error("synthetic provider did not complete")
  })
  use expected <- result.try(responses.decode_response(fixtures.completed))
  use _ <- result.try(check(
    completion.response == expected,
    "synthetic decoded response mismatch",
  ))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  // The successful HTTP terminal supplies the trusted history receipt. A real
  // follow-up is pinned to the originating runtime account and sent over HTTP.
  let continuing =
    adapter.http(
      adapter.Config(..config, continuation: Some(completion.continuation)),
      None,
    )
  use _ <- result.try(
    runtime.execute(
      runtime,
      continuing,
      contracts.Request(
        ..req,
        body: fixtures.continuation,
        pinned_account: Some(response.account),
      ),
    )
    |> safe_error,
  )
  use replay <- result.try(read_observation(
    observations,
    "/backend-api/codex/responses",
  ))
  use _ <- result.try(check(
    replay.continuation_replayed,
    "HTTP tool continuation was not replayed on wire",
  ))
  use compact <- result.try(
    runtime.execute(
      runtime,
      http,
      contracts.Request(..req, operation: "responses/compact"),
    )
    |> safe_error,
  )
  use _ <- result.try(check(
    compact.body == bit_array.from_string(fixtures.compact),
    "synthetic compact mismatch",
  ))
  use compact_text <- result.try(
    bit_array.to_string(compact.body)
    |> result.map_error(fn(_) { "compact encoding" }),
  )
  use decoded_compact <- result.try(responses.decode_compact_response(
    compact_text,
  ))
  use _ <- result.try(check(
    ir.field(decoded_compact.document, "object")
      == Some(ir.String("response.compaction")),
    "compact codec mismatch",
  ))
  use _ <- result.try(take_plan(plans, compact.account))
  use _ <- result.try(observed(
    observations,
    "/backend-api/codex/responses/compact",
  ))
  // Buffered consumer refuses even a valid stream when associated with the
  // wrong account's plan, and closes it without granting a receipt.
  use guarded <- result.try(runtime.open(runtime, http, req) |> safe_error)
  use plan <- result.try(take_plan(plans, guarded.account))
  let wrong_account =
    codex_response.consume(
      guarded,
      request.Prepared(..plan, credential_id: "account-a"),
    )
  use _ <- result.try(check(
    wrong_account
      == Error("Codex prepared plan belongs to another runtime account"),
    "Codex consumer accepted a foreign account plan",
  ))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  // Synthetic transport metadata fault: a 400 body must not be accepted as
  // successful SSE even if it happens to contain a valid terminal document.
  use guarded <- result.try(runtime.open(runtime, http, req) |> safe_error)
  use plan <- result.try(take_plan(plans, guarded.account))
  let bad_status =
    codex_response.consume(runtime.Response(..guarded, status: 400), plan)
  use _ <- result.try(check(
    bad_status == Error("unsupported Codex upstream HTTP response"),
    "Codex consumer accepted a non-200 response",
  ))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  let emitted = process.new_subject()
  use forwarded <- result.try(
    runtime.open(
      runtime,
      http,
      contracts.Request(..req, mode: contracts.Streaming),
    )
    |> safe_error,
  )
  use plan <- result.try(take_plan(plans, forwarded.account))
  use outcome <- result.try(
    codex_response.forward(forwarded, plan, fn(event) {
      process.send(emitted, event.name)
      Ok(responses_http.Continue)
    })
    |> safe_error,
  )
  use _ <- result.try(check(
    outcome == responses_stream.Completed,
    "stream forwarding did not complete",
  ))
  let expected = [
    "response.created", "response.output_item.added",
    "response.output_item.done", "response.output_item.added",
    "response.function_call_arguments.delta",
    "response.function_call_arguments.done", "response.output_item.done",
    "response.completed",
  ]
  let events = list.map(expected, fn(_) { process.receive(emitted, 1000) })
  use _ <- result.try(check(
    events == list.map(expected, Ok),
    "Codex streaming event order mismatch",
  ))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  use streaming <- result.try(
    runtime.open(
      runtime,
      http,
      contracts.Request(..req, mode: contracts.Streaming),
    )
    |> safe_error,
  )
  runtime.cancel(streaming.stream)
  runtime.cancel(streaming.stream)
  use _ <- result.try(take_plan(plans, streaming.account))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  // Request bytes really were sent; abandon the socket before reporting
  // uncertain delivery. A second configured account must not trigger replay.
  let uncertain =
    contracts.Adapter(..http, open: fn(context, request) {
      use opened <- result.try(http.open(context, request))
      http.cancel(opened.handle)
      Error(contracts.Failure(contracts.Unavailable, contracts.Uncertain, None))
    })
  let uncertain_result = runtime.execute(runtime, uncertain, req)
  let _ = process.receive(plans, 1000)
  use _ <- result.try(check(
    uncertain_result
      == Error(contracts.Failure(
      contracts.Unavailable,
      contracts.Uncertain,
      None,
    )),
    "uncertain failure was not preserved",
  ))
  use _ <- result.try(observed(observations, "/backend-api/codex/responses"))
  use _ <- result.try(check(
    process.receive(observations, 25) == Error(Nil),
    "uncertain send was replayed",
  ))
  use leases <- result.try(runtime.active_leases(runtime) |> safe_error)
  use _ <- result.try(check(leases == 0, "Codex runtime leaked a lease"))
  Ok(
    "SYNTHETIC Codex loopback runtime/shared-codec passed: configured origin/path, private account header, validated SSE terminal, tool/reasoning/usage preservation, account-pinned HTTP continuation, compact codec, idempotent cancellation, no uncertain-send replay, zero leases. No live provider, WS transport or assembled-ingress claim.",
  )
}

fn observed(
  subject: process.Subject(Observation),
  target: String,
) -> Result(Nil, String) {
  use _ <- result.try(read_observation(subject, target))
  Ok(Nil)
}

/// Drop safely rejected attempt plans; bind the successful runtime account.
pub fn take_plan(
  plans: process.Subject(#(String, request.Prepared)),
  account: String,
) -> Result(request.Prepared, String) {
  use plan <- result.try(
    process.receive(plans, 1000)
    |> result.map_error(fn(_) { "missing prepared Codex plan" }),
  )
  case plan.0 == account {
    True -> Ok(plan.1)
    False -> take_plan(plans, account)
  }
}

fn read_observation(
  subject: process.Subject(Observation),
  target: String,
) -> Result(Observation, String) {
  use observation <- result.try(
    process.receive(subject, 1000)
    |> result.map_error(fn(_) { "synthetic request not observed" }),
  )
  use _ <- result.try(check(
    observation.target == target
      && observation.status == 200
      && observation.authorization_ok
      && observation.account_ok
      && observation.body_valid,
    "Codex target, private auth header or shared request validation mismatch",
  ))
  Ok(observation)
}

fn safe_error(value: Result(a, contracts.Failure)) -> Result(a, String) {
  value
  |> result.map_error(fn(failure) {
    // Public enum only: never inspect credentials, callback exceptions or bodies.
    "synthetic Codex runtime operation failed: " <> string.inspect(failure)
  })
}

fn check(condition: Bool, error: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
