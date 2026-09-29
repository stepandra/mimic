/// Gateway composition over shared-core snapshot 4. No receipt store, transport
/// or SSE codec is implemented here. All handles/history are private runtime data.
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/dialect/responses
import mimic/protocol/continuation
import mimic/protocol/responses/http as pump
import mimic/protocol/responses/stream
import mimic/providers/codex/adapter
import mimic/providers/codex/json_guard
import mimic/providers/codex/lite
import mimic/providers/codex/request
import mimic/providers/codex/response
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/runtime
import mimic/types.{type Header}

pub opaque type Opened {
  Opened(
    upstream: runtime.Response,
    plan: request.Prepared,
    scope: continuation.Scope,
    cache: continuation.Cache(session.Continuation),
  )
}

/// Integration creates one bounded nonpersistent cache; it never loads client
/// history into it. Tenant and Request.session MUST be authenticated server scope.
/// A follow-up locates its account in the same server cache before selection.
/// The pin alone grants nothing: lookup uses the selected authoritative Revision.
pub fn open(
  provider: runtime.Runtime,
  cache: continuation.Cache(session.Continuation),
  config: adapter.Config,
  ca_file: Option(String),
  req: contracts.Request,
) -> Result(Opened, contracts.Failure) {
  use body <- result.try(before(json_guard.parse(req.body)))
  use decoded <- result.try(before(responses.request_from_value(body)))
  use marked_lite <- result.try(before(lite.enabled(body)))
  let req = case req.operation == "responses" && marked_lite {
    True -> contracts.Request(..req, operation: "responses/lite")
    False -> req
  }
  use _ <- result.try(case req.operation {
    "responses/compact" ->
      Error(failure(contracts.Unsupported, contracts.NotSent))
    _ -> Ok(Nil)
  })
  use req <- result.try(case decoded.previous_response_id {
    None -> Ok(req)
    Some(id) -> {
      use account <- result.try(
        before(continuation.locate(
          cache,
          config.tenant,
          contracts.Request(..req, pinned_account: None),
          id,
        )),
      )
      case req.pinned_account {
        Some(expected) if expected != account ->
          Error(failure(contracts.Unsupported, contracts.NotSent))
        _ -> Ok(contracts.Request(..req, pinned_account: Some(account)))
      }
    }
  })
  let plans = process.new_subject()
  let transport =
    adapter.http(adapter.Config(..config, continuation: None), ca_file)
  use upstream <- result.try(runtime.open_scoped(
    provider,
    transport,
    fn(context, revision, req) {
      use scope <- result.try(
        before(continuation.scope(config.tenant, context, revision, req)),
      )
      use receipt <- result.try(case decoded.previous_response_id {
        None -> Ok(None)
        Some(id) ->
          before(continuation.get(cache, scope, id)) |> result.map(Some)
      })
      let selected =
        adapter.http_planned(
          adapter.Config(..config, continuation: receipt),
          ca_file,
          fn(account, plan) { process.send(plans, #(account, scope, plan)) },
        )
      selected.open(context, req)
    },
    req,
  ))
  case selected_plan(plans, upstream.account) {
    Ok(#(scope, plan)) -> Ok(Opened(upstream, plan, scope, cache))
    Error(error) -> {
      runtime.cancel(upstream.stream)
      Error(error)
    }
  }
}

pub fn account(opened: Opened) -> String {
  opened.upstream.account
}

pub fn status(opened: Opened) -> Int {
  opened.upstream.status
}

pub fn headers(opened: Opened) -> List(Header) {
  opened.upstream.headers
}

pub fn cancel(opened: Opened) -> Nil {
  runtime.cancel(opened.upstream.stream)
}

/// Must be called in the receiving process before consuming/forwarding a handle
/// transferred by a gateway worker.
pub fn adopt(opened: Opened) -> Result(Nil, contracts.Failure) {
  runtime.adopt(opened.upstream.stream)
}

pub fn consume(opened: Opened) -> Result(response.Terminal, contracts.Failure) {
  use terminal <- result.try(
    response.consume(opened.upstream, opened.plan)
    |> result.replace_error(failure(
      contracts.InvalidResponse,
      contracts.Started,
    )),
  )
  publish(opened, terminal)
}

/// Shared run_fold supplies ordered valid-prefix delivery, bounded framing,
/// cleanup and clean EOF. No receipt is published on Cancel/error, even after a
/// response.completed event was emitted. Every failure remains Started.
pub fn forward(
  opened: Opened,
  emit: fn(stream.Event) -> Result(pump.Control, String),
) -> Result(response.Terminal, contracts.Failure) {
  let outcome = {
    use state <- result.try(
      pump.open_sse(opened.upstream.status, opened.upstream.headers)
      |> result.replace_error(failure(
        contracts.InvalidResponse,
        contracts.Started,
      )),
    )
    use finished <- result.try(
      pump.run_fold(
        state,
        opened.upstream.stream,
        fn(handle) {
          runtime.next(handle)
          |> result.map(fn(bytes) {
            case bytes {
              None -> None
              Some(bytes) -> Some(#(bytes, handle))
            }
          })
        },
        runtime.cancel,
        None,
        fn(prior, event) {
          // Deliver the validated prefix even when receipt policy later fails.
          use control <- result.try(
            emit(event) |> result.replace_error("Codex downstream failed"),
          )
          case control {
            pump.Cancel -> Ok(#(None, pump.Cancel))
            pump.Continue ->
              response.observe(opened.plan, prior, event)
              |> result.replace_error("Codex receipt validation failed")
              |> result.map(fn(next) { #(next, pump.Continue) })
          }
        },
      )
      |> result.map_error(fn(error) {
        case error {
          pump.Upstream(error) -> failure(error.reason, contracts.Started)
          pump.Protocol(_) ->
            failure(contracts.InvalidResponse, contracts.Started)
          pump.Downstream("Codex receipt validation failed") ->
            failure(contracts.InvalidResponse, contracts.Started)
          pump.Downstream(_) -> failure(contracts.Cancelled, contracts.Started)
        }
      }),
    )
    use _ <- result.try(case finished {
      #(stream.Cancelled, None) ->
        Error(failure(contracts.Cancelled, contracts.Started))
      _ -> Ok(Nil)
    })
    use terminal <- result.try(
      response.finish_observed(finished.0, finished.1)
      |> result.replace_error(failure(
        contracts.InvalidResponse,
        contracts.Started,
      )),
    )
    publish(opened, terminal)
  }
  runtime.cancel(opened.upstream.stream)
  outcome
}

fn publish(
  opened: Opened,
  terminal: response.Terminal,
) -> Result(response.Terminal, contracts.Failure) {
  case terminal {
    response.Completed(completed) -> {
      use _ <- result.try(
        continuation.put(
          opened.cache,
          opened.scope,
          completed.response.id,
          completed.continuation,
        )
        |> result.replace_error(failure(
          contracts.Persistence,
          contracts.Started,
        )),
      )
      Ok(terminal)
    }
    _ -> Ok(terminal)
  }
}

fn selected_plan(
  plans: process.Subject(#(String, continuation.Scope, request.Prepared)),
  account: String,
) -> Result(#(continuation.Scope, request.Prepared), contracts.Failure) {
  use plan <- result.try(
    process.receive(plans, 1000)
    |> result.replace_error(failure(
      contracts.InvalidResponse,
      contracts.Started,
    )),
  )
  case plan.0 == account {
    True -> Ok(#(plan.1, plan.2))
    False -> selected_plan(plans, account)
  }
}

fn before(value: Result(a, String)) -> Result(a, contracts.Failure) {
  result.replace_error(value, failure(contracts.Unsupported, contracts.NotSent))
}

fn failure(reason, delivery) -> contracts.Failure {
  contracts.Failure(reason, delivery, None)
}
