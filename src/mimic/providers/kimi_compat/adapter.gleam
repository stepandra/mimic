/// Generic Kimi Chat SSE over the shared native Chat codec. Documents are
/// validated, not projected through Responses or native Kimi transformations.
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/protocol/chat/http as chat_http
import mimic/protocol/chat/stream as chat_stream
import mimic/protocol/responses/http as responses_http
import mimic/providers/contracts
import mimic/providers/kimi_compat/request as compat_request
import mimic/providers/runtime

/// The root must synchronously adopt response.stream before changing owners.
/// Shared Chat code owns framing, valid-prefix delivery and cancellation.
pub fn run_chat_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(chat_stream.Event) -> Result(responses_http.Control, String),
) -> Result(chat_stream.Outcome, contracts.Failure) {
  use _ <- result.try(
    case
      request.provider == compat_request.provider
      && request.auth_mode == "api_key"
      && request.protocol == "chat"
      && request.operation == "chat/completions"
      && request.mode == contracts.Streaming
    {
      True -> Ok(Nil)
      False -> {
        runtime.cancel(response.stream)
        Error(contracts.Failure(contracts.Unsupported, contracts.Started, None))
      }
    },
  )
  use state <- result.try(
    chat_http.open_sse(response.status, response.headers)
    |> result.map_error(fn(_) {
      runtime.cancel(response.stream)
      invalid_response()
    }),
  )
  chat_http.run(
    state,
    response.stream,
    fn(handle) {
      runtime.next(handle)
      |> result.map(fn(maybe) {
        case maybe {
          Some(bytes) -> Some(#(bytes, handle))
          None -> None
        }
      })
    },
    runtime.cancel,
    fn(document) { validate_model(document, request.model) },
    emit,
  )
  |> result.map_error(fn(error) {
    case error {
      responses_http.Upstream(failure) -> failure
      responses_http.Protocol(_) -> invalid_response()
      responses_http.Downstream(_) ->
        contracts.Failure(contracts.Cancelled, contracts.Started, None)
    }
  })
}

/// Check only the protocol-owned model field. Error envelopes have no required
/// model; models inside opaque vendor fields or tool arguments are untouched.
fn validate_model(
  document: ir.Value,
  model: String,
) -> Result(ir.Value, String) {
  case ir.field(document, "error") {
    Some(_) -> Ok(document)
    None -> {
      use received <- result.try(ir.string_field(document, "model"))
      case received == model {
        True -> Ok(document)
        False -> Error("Generic Kimi Chat model does not match the request")
      }
    }
  }
}

fn invalid_response() -> contracts.Failure {
  contracts.Failure(contracts.InvalidResponse, contracts.Started, None)
}
