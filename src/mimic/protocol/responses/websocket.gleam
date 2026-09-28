import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream

/// Trusted server-side scope, never populated from frame-supplied credentials.
pub type Scope {
  Scope(
    tenant: String,
    provider: String,
    credential: String,
    account: String,
    model: String,
    client_session: String,
  )
}

type Receipt {
  Receipt(id: String, pending: List(responses.PendingCall))
}

type Phase {
  Ready(Option(Receipt))
  Active(stream.Stream, List(responses.PendingCall))
  Closed
}

pub opaque type Session {
  Session(scope: Scope, generation: String, phase: Phase)
}

pub fn new(scope: Scope, generation: String) -> Result(Session, String) {
  case generation == "" {
    True -> Error("Responses WS requires a trusted connection generation")
    False -> Ok(Session(scope, generation, Ready(None)))
  }
}

fn check_scope(
  session: Session,
  scope: Scope,
  generation: String,
) -> Result(Nil, String) {
  case session.scope == scope && session.generation == generation {
    True -> Ok(Nil)
    False -> Error("Responses WS scope or connection generation mismatch")
  }
}

/// Decode the top-level response.create message. This is not an RFC6455
/// handshake/frame decoder. Only one active response per session is supported.
/// No implicit transcript merge, field inheritance, or cross-connection resume.
pub fn create(
  session: Session,
  scope: Scope,
  generation: String,
  message: String,
) -> Result(#(Session, responses.Request), String) {
  use _ <- result.try(check_scope(session, scope, generation))
  use receipt <- result.try(case session.phase {
    Ready(receipt) -> Ok(receipt)
    Active(_, _) -> Error("Responses WS already has an active response")
    Closed -> Error("Responses WS connection is closed")
  })
  use _ <- result.try(
    case bit_array.byte_size(bit_array.from_string(message)) <= 1_048_576 {
      True -> Ok(Nil)
      False -> Error("Responses WS message exceeds byte limit")
    },
  )
  use value <- result.try(ir.parse(message))
  use _ <- result.try(responses.expect_string(value, "type", "response.create"))
  use _ <- result.try(check_transport_fields(value))
  use _ <- result.try(case ir.field(value, "input") {
    None | Some(ir.Array(_)) -> Ok(Nil)
    _ -> Error("Responses WS input must be an array")
  })
  let document = ir.Object(ir.extras(value, ["type"]))
  use request <- result.try(responses.request_from_value(document))
  use _ <- result.try(case request.model == scope.model {
    True -> Ok(Nil)
    False -> Error("Responses WS model does not match trusted scope")
  })
  use prior <- result.try(case request.previous_response_id, receipt {
    None, _ -> Ok([])
    Some(id), Some(receipt) if id == receipt.id -> Ok(receipt.pending)
    _, _ ->
      Error("Responses WS previous_response_id has no same-connection receipt")
  })
  use pending <- result.try(responses.pair_input(request, prior))
  use _ <- result.try(case prior {
    [] -> Ok(Nil)
    _ ->
      case list.any(prior, fn(call) { list.contains(pending, call) }) {
        True ->
          Error("Responses WS continuation did not satisfy pending tool calls")
        False -> Ok(Nil)
      }
  })
  Ok(#(Session(..session, phase: Active(stream.new(), pending)), request))
}

/// Frame payload for an already provider-prepared native request. Removing
/// stream is a transport distinction; background=true is rejected, not dropped.
/// Provider store defaults, tool rewrites, and previous-response policy stay out.
pub fn encode_create(request: responses.Request) -> Result(String, String) {
  use _ <- result.try(check_transport_fields(request.document))
  use _ <- result.try(case ir.field(request.document, "input") {
    None | Some(ir.Array(_)) -> Ok(Nil)
    _ -> Error("Responses WS input must be an array")
  })
  case ir.field(request.document, "type") {
    None ->
      Ok(
        ir.stringify(
          ir.Object([
            #("type", ir.String("response.create")),
            ..ir.extras(request.document, ["stream", "background"])
          ]),
        ),
      )
    _ -> Error("Responses request has a conflicting transport type")
  }
}

fn check_transport_fields(value: ir.Value) -> Result(Nil, String) {
  use background <- result.try(ir.optional_bool(value, "background", False))
  case background {
    True -> Error("background Responses are unsupported over this WS protocol")
    False -> Ok(Nil)
  }
}

/// Only validated Completed grants a continuation receipt. Failed/incomplete/
/// cancelled/error clear the receipt. The next frame starts a fresh operation.
pub fn receive(
  session: Session,
  scope: Scope,
  generation: String,
  message: String,
) -> Result(#(Session, stream.Event), String) {
  use _ <- result.try(check_scope(session, scope, generation))
  use active <- result.try(case session.phase {
    Active(state, pending) -> Ok(#(state, pending))
    _ -> Error("Responses WS upstream event without active response")
  })
  use _ <- result.try(
    case bit_array.byte_size(bit_array.from_string(message)) <= 1_048_576 {
      True -> Ok(Nil)
      False -> Error("Responses WS message exceeds byte limit")
    },
  )
  use value <- result.try(ir.parse(message))
  use pair <- result.try(stream.push(active.0, value))
  use phase <- result.try(case stream.outcome(pair.0) {
    None -> Ok(Active(pair.0, active.1))
    Some(stream.Completed) -> {
      use response <- result.try(stream.terminal_response(pair.1))
      use calls <- result.try(responses.output_calls(response))
      use _ <- result.try(
        case
          list.any(calls, fn(call) {
            list.any(active.1, fn(prior) { prior.id == call.id })
          })
        {
          True ->
            Error("Responses WS completed output reuses a pending call id")
          False -> Ok(Nil)
        },
      )
      Ok(Ready(Some(Receipt(response.id, list.append(active.1, calls)))))
    }
    Some(_) -> Ok(Ready(None))
  })
  Ok(#(Session(..session, phase: phase), pair.1))
}

/// No response.cancel wire command exists in the inspected CPA request switch.
/// Cancel locally by closing upstream; the Bool is a one-shot cleanup command.
/// Closing also invalidates continuation, even if the last response completed.
pub fn cancel(session: Session) -> #(Session, Bool) {
  case session.phase {
    Closed -> #(session, False)
    _ -> #(Session(..session, phase: Closed), True)
  }
}

/// The caller must close/cancel the physical transport after this notification.
pub fn disconnected(session: Session) -> Result(Nil, String) {
  case session.phase {
    Active(state, _) -> stream.finish(state) |> result.map(fn(_) { Nil })
    _ -> Ok(Nil)
  }
}
