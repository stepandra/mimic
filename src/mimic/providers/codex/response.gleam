/// Provider orchestration over the shared Responses codec. No SSE parsing or
/// event state machine is implemented here. A receipt is exposed only after
/// successful terminal validation and a clean end of the HTTP stream.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/http
import mimic/protocol/responses/stream
import mimic/providers/codex/normalize
import mimic/providers/codex/request
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/runtime

pub type Completion {
  Completion(response: responses.Response, continuation: session.Continuation)
}

/// Valid terminal documents remain data even when no continuation is allowed.
/// RemoteError is provider data; sanitize it before logging or client diagnostics.
pub type Terminal {
  Completed(Completion)
  Unsuccessful(responses.Response)
  RemoteError(ir.Value)
}

pub opaque type Collector {
  Collector(
    stream: stream.Stream,
    prepared: request.Prepared,
    terminal: Option(Terminal),
    cancelled: Bool,
  )
}

/// Only ordinary HTTP /responses uses this collector. Compact is a separate
/// JSON document; WS messages require the separately owned future WS wrapper.
pub fn new(prepared: request.Prepared) -> Result(Collector, String) {
  case prepared.target {
    "/backend-api/codex/responses" ->
      Ok(Collector(stream.new(), prepared, None, False))
    _ -> Error("Codex SSE collector requires ordinary Responses")
  }
}

/// Atomic, buffered-only feed. A malformed chunk can withhold its valid prefix.
/// Streaming clients must use forward (shared feed_partial), not this function.
/// On failure discard the collector and cancel; never replay or reuse old state.
pub fn feed(
  collector: Collector,
  bytes: BitArray,
) -> Result(#(Collector, List(stream.Event)), String) {
  use _ <- result.try(case collector.cancelled {
    True -> Error("Codex response was cancelled")
    False -> Ok(Nil)
  })
  use decoded <- result.try(
    stream.feed(collector.stream, bytes)
    |> result.map_error(fn(_) { "invalid Codex Responses stream" }),
  )
  use terminal <- result.try(
    list.try_fold(decoded.1, collector.terminal, fn(prior, event) {
      case event.name {
        "response.completed" -> {
          // This event came from successful feed above, not an unchecked accessor.
          use response <- result.try(
            stream.terminal_response(event)
            |> result.map_error(fn(_) { "invalid Codex terminal response" }),
          )
          use _ <- result.try(
            case
              ir.field(response.document, "model"),
              ir.field(collector.prepared.body, "model")
            {
              Some(actual), Some(expected) if actual == expected -> Ok(Nil)
              None, _ -> Ok(Nil)
              _, _ -> Error("Codex response model does not match request")
            },
          )
          use input <- result.try(ir.required(collector.prepared.body, "input"))
          use input <- result.try(ir.as_array(input))
          let history = list.append(input, response.output)
          // Validate the entire replay, not just outstanding calls. Reusing a
          // completed historical call ID must not mint an unusable receipt.
          use replay <- result.try(
            responses.request_from_value(normalize.put(
              collector.prepared.body,
              "input",
              ir.Array(history),
            )),
          )
          use calls <- result.try(responses.pair_input(replay, []))
          use receipt <- result.try(session.completed(
            collector.prepared.identity,
            response.id,
            calls,
          ))
          let receipt = session.retain_history(receipt, history)
          Ok(Some(Completed(Completion(response, receipt))))
        }
        "response.incomplete" | "response.failed" | "response.cancelled" ->
          stream.terminal_response(event)
          |> result.map(fn(value) { Some(Unsuccessful(value)) })
        "error" -> Ok(Some(RemoteError(event.document)))
        _ -> Ok(prior)
      }
    }),
  )
  Ok(#(Collector(..collector, stream: decoded.0, terminal: terminal), decoded.1))
}

pub fn finish(collector: Collector) -> Result(Completion, String) {
  use terminal <- result.try(finish_terminal(collector))
  case terminal {
    Completed(completion) -> Ok(completion)
    _ -> Error("Codex response did not complete successfully")
  }
}

/// Buffered protocol result: preserves failed/incomplete/cancelled output,
/// usage, incomplete_details and error extensions without granting a receipt.
pub fn finish_terminal(collector: Collector) -> Result(Terminal, String) {
  use outcome <- result.try(
    stream.finish(collector.stream)
    |> result.map_error(fn(_) { "Codex response disconnected or truncated" }),
  )
  case outcome, collector.terminal, collector.cancelled {
    stream.Completed, Some(Completed(_) as terminal), False
    | stream.Incomplete, Some(Unsuccessful(_) as terminal), False
    | stream.Failed, Some(Unsuccessful(_) as terminal), False
    | stream.Cancelled, Some(Unsuccessful(_) as terminal), False
    | stream.RemoteError, Some(RemoteError(_) as terminal), False
    -> Ok(terminal)
    _, _, _ -> Error("Codex response did not complete successfully")
  }
}

pub fn cancel(collector: Collector) -> Collector {
  Collector(
    ..collector,
    stream: stream.cancel(collector.stream),
    terminal: None,
    cancelled: True,
  )
}

/// Buffered client path. Runtime owns socket lifetime, bytes, cancellation and
/// failover; this function only composes its pull API with the shared codec.
/// Non-200 HTTP responses are never interpreted as successful SSE completion.
pub fn consume(
  opened: runtime.Response,
  prepared: request.Prepared,
) -> Result(Terminal, String) {
  let outcome = {
    use _ <- result.try(case opened.account == prepared.credential_id {
      True -> Ok(Nil)
      False -> Error("Codex prepared plan belongs to another runtime account")
    })
    use stream <- result.try(
      http.open_sse(opened.status, opened.headers)
      |> result.map_error(fn(_) { "unsupported Codex upstream HTTP response" }),
    )
    use collector <- result.try(new(prepared))
    pull(opened.stream, Collector(..collector, stream: stream))
  }
  runtime.cancel(opened.stream)
  outcome
}

fn pull(
  handle: runtime.Stream,
  collector: Collector,
) -> Result(Terminal, String) {
  use chunk <- result.try(
    runtime.next(handle)
    |> result.map_error(fn(_) { "Codex response transport failed" }),
  )
  case chunk {
    None -> finish_terminal(collector)
    Some(bytes) -> {
      use next <- result.try(feed(collector, bytes))
      pull(handle, next.0)
    }
  }
}

/// Streaming client path. Delegate prefix-before-error ordering and cleanup to
/// the common HTTP pump, which uses feed_partial. Never use atomic feed here.
/// Runtime has already returned headers: every forwarding failure is Started,
/// even if the first client event has not yet been emitted. No failover/replay.
/// This path returns protocol outcome, not a full-history continuation receipt.
pub fn forward(
  opened: runtime.Response,
  prepared: request.Prepared,
  emit: fn(stream.Event) -> Result(http.Control, String),
) -> Result(stream.Outcome, contracts.Failure) {
  let outcome = {
    use _ <- result.try(case opened.account == prepared.credential_id {
      True -> Ok(Nil)
      False ->
        Error(contracts.Failure(
          contracts.InvalidConfiguration,
          contracts.Started,
          None,
        ))
    })
    use state <- result.try(
      http.open_sse(opened.status, opened.headers)
      |> result.map_error(fn(_) {
        contracts.Failure(contracts.InvalidResponse, contracts.Started, None)
      }),
    )
    http.run(
      state,
      opened.stream,
      fn(handle) {
        runtime.next(handle)
        |> result.map(fn(chunk) {
          case chunk {
            None -> None
            Some(bytes) -> Some(#(bytes, handle))
          }
        })
      },
      runtime.cancel,
      emit,
    )
    |> result.map_error(fn(failure) {
      case failure {
        http.Upstream(error) ->
          contracts.Failure(error.reason, contracts.Started, None)
        http.Protocol(_) ->
          contracts.Failure(contracts.InvalidResponse, contracts.Started, None)
        http.Downstream(_) ->
          contracts.Failure(contracts.Cancelled, contracts.Started, None)
      }
    })
  }
  runtime.cancel(opened.stream)
  outcome
}
