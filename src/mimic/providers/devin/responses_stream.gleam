/// F25 delayed buffered-to-SSE. No opening/success frame escapes before the
/// common constructor has qualified Stop, usage, tools and terminal semantics.
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/response
import mimic/providers/devin/responses
import mimic/providers/devin/responses_request as input

pub opaque type State {
  State(builder: responses.Builder)
}

pub fn new(
  id: String,
  model: String,
  created_at: Int,
  settings: input.Settings,
) -> Result(State, String) {
  responses.new(id, model, created_at, settings) |> result.map(State)
}

pub fn encode(
  state: State,
  event: response.Event,
) -> Result(#(State, List(String)), String) {
  use builder <- result.try(responses.push(state.builder, event))
  case event {
    response.Stop -> {
      use projection <- result.try(responses.finish(builder))
      Ok(#(State(builder), responses.frames(projection)))
    }
    _ -> Ok(#(State(builder), []))
  }
}

/// Pinned SDK ResponseErrorEvent is flat, not {"error":{...}}. Nullable code
/// and param remain explicit; sequence is the actual next publication sequence.
pub type ErrorEvent {
  ErrorEvent(
    code: Option(String),
    message: String,
    param: Option(String),
    sequence_number: Int,
  )
}

/// Safe protocol error, never native protobuf, diagnostics, token or context.
pub fn failure(
  _error: c.Failure,
  sequence_number: Int,
) -> Result(String, String) {
  encode_error(ErrorEvent(
    Some("provider_unavailable"),
    "Devin Responses stream failed",
    None,
    sequence_number,
  ))
}

pub fn encode_error(event: ErrorEvent) -> Result(String, String) {
  use _ <- result.try(input.ensure(
    event.sequence_number >= 0 && event.message != "",
    "invalid Responses ErrorEvent identity",
  ))
  Ok(
    "event: error\ndata: "
    <> ir.stringify(
      ir.Object([
        #("type", ir.String("error")),
        #("code", nullable(event.code)),
        #("message", ir.String(event.message)),
        #("param", nullable(event.param)),
        #("sequence_number", ir.Integer(event.sequence_number)),
      ]),
    )
    <> "\n\n",
  )
}

fn nullable(value: Option(String)) -> ir.Value {
  case value {
    None -> ir.Null
    Some(text) -> ir.String(text)
  }
}
