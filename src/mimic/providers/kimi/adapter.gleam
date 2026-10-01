/// Kimi Responses lifecycle over the shared codec. Buffered Responses are
/// native JSON, whereas streaming Responses are native SSE in pinned CPA.
/// Chat completions are not projected through Responses here.
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/chat/http as chat_http
import mimic/protocol/chat/stream as chat_stream
import mimic/protocol/responses/http as responses_http
import mimic/protocol/responses/stream
import mimic/providers/claude/http as claude_http
import mimic/providers/claude/stream as claude_stream
import mimic/providers/contracts
import mimic/providers/kimi/json_guard
import mimic/providers/kimi/models
import mimic/providers/kimi/transform
import mimic/providers/runtime
import mimic/types.{type Header}

/// Native Messages use the actual Claude observer and byte lifecycle. Only the
/// selected upstream message_start model is restored, never tool/vendor data.
pub fn run_messages_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(String) -> Result(responses_http.Control, String),
) -> Result(claude_stream.Status, contracts.Failure) {
  use upstream <- result.try(
    case
      request.provider,
      request.protocol,
      request.operation,
      request.mode,
      models.upstream_id(request.model)
    {
      "kimi", "anthropic", "messages", contracts.Streaming, Some(upstream) ->
        Ok(upstream)
      _, _, _, _, _ -> {
        runtime.cancel(response.stream)
        Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
      }
    },
  )
  claude_http.run_with_model(response, upstream, request.model, emit)
  |> result.map_error(fn(error) {
    case error {
      "Claude downstream closed" ->
        contracts.Failure(contracts.Cancelled, contracts.Started, None)
      _ -> invalid_response()
    }
  })
}

/// Requires shared-core immutable snapshot 2. Chat remains native Chat; no
/// Responses projection or provider-local SSE parser participates.
pub fn run_chat_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(chat_stream.Event) -> Result(responses_http.Control, String),
) -> Result(chat_stream.Outcome, contracts.Failure) {
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
    fn(document) { transform.restore_checked(document, request.model) },
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

/// Use this request-bound entry point in dispatch. The old collector has no
/// requested-model context and is retained only for compatibility.
pub fn collect_for(
  response: runtime.Response,
  request: contracts.Request,
) -> Result(runtime.BufferedResponse, contracts.Failure) {
  use collected <- result.try(collect(response, request.operation))
  use text <- result.try(
    bit_array.to_string(collected.body)
    |> result.map_error(fn(_) { invalid_response() }),
  )
  use document <- result.try(
    json_guard.parse(text) |> result.map_error(fn(_) { invalid_response() }),
  )
  use document <- result.try(
    transform.restore_checked(document, request.model)
    |> result.map_error(fn(_) { invalid_response() }),
  )
  let body =
    document
    |> ir.stringify
    |> bit_array.from_string
  Ok(
    runtime.BufferedResponse(
      ..collected,
      body: body,
      headers: list.filter(collected.headers, fn(header) {
        !list.contains(
          ["content-length", "transfer-encoding"],
          string.lowercase(header.name),
        )
      }),
    ),
  )
}

/// Shared Responses framing/validation remains the sole stream authority.
/// Restore only the native envelope, never arbitrary extension/argument values.
pub fn run_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(stream.Event) -> Result(responses_http.Control, String),
) -> Result(stream.Outcome, contracts.Failure) {
  run(response, fn(event) {
    use document <- result.try(transform.restore_response_event(
      event.document,
      request.model,
    ))
    emit(stream.Event(..event, document: document))
  })
}

pub fn collect(
  response: runtime.Response,
  operation: String,
) -> Result(runtime.BufferedResponse, contracts.Failure) {
  case operation {
    "responses" | "chat/completions" | "messages" -> {
      use _ <- result.try(
        json_headers(response.status, response.headers)
        |> result.map_error(fn(_) {
          runtime.cancel(response.stream)
          invalid_response()
        }),
      )
      use body <- result.try(read_json(response.stream, <<>>))
      use text <- result.try(
        bit_array.to_string(body)
        |> result.map_error(fn(_) { invalid_response() }),
      )
      use _ <- result.try(
        case operation {
          "responses" ->
            responses.decode_response(text) |> result.map(fn(_) { Nil })
          "chat/completions" ->
            openai.decode_response(text) |> result.map(fn(_) { Nil })
          "messages" ->
            anthropic.decode_response(text) |> result.map(fn(_) { Nil })
          _ -> Error("Unsupported Kimi response")
        }
        |> result.map_error(fn(_) { invalid_response() }),
      )
      Ok(runtime.BufferedResponse(
        response.status,
        response.headers,
        response.account,
        body,
      ))
    }
    _ -> {
      runtime.cancel(response.stream)
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
    }
  }
}

fn json_headers(status: Int, headers: List(Header)) -> Result(Nil, Nil) {
  let media =
    list.filter(headers, fn(header) {
      string.lowercase(header.name) == "content-type"
    })
  let encodings =
    list.filter(headers, fn(header) {
      string.lowercase(header.name) == "content-encoding"
    })
  case status >= 200 && status < 300, media, encodings {
    True, [type_header], [] | True, [type_header], [_] ->
      case
        string.starts_with(
          string.lowercase(string.trim(type_header.value)),
          "application/json",
        )
        && list.all(encodings, fn(header) {
          string.lowercase(string.trim(header.value)) == "identity"
        })
      {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    _, _, _ -> Error(Nil)
  }
}

fn read_json(
  handle: runtime.Stream,
  body: BitArray,
) -> Result(BitArray, contracts.Failure) {
  case runtime.next(handle) {
    Error(failure) -> {
      runtime.cancel(handle)
      Error(failure)
    }
    Ok(None) -> Ok(body)
    Ok(Some(chunk)) ->
      case bit_array.byte_size(body) + bit_array.byte_size(chunk) <= 1_048_576 {
        True -> read_json(handle, <<body:bits, chunk:bits>>)
        False -> {
          runtime.cancel(handle)
          Error(invalid_response())
        }
      }
  }
}

pub fn run(
  response: runtime.Response,
  emit: fn(stream.Event) -> Result(responses_http.Control, String),
) -> Result(stream.Outcome, contracts.Failure) {
  use state <- result.try(
    responses_http.open_sse(response.status, response.headers)
    |> result.map_error(fn(_) {
      runtime.cancel(response.stream)
      invalid_response()
    }),
  )
  responses_http.run(
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

fn invalid_response() -> contracts.Failure {
  contracts.Failure(contracts.InvalidResponse, contracts.Started, None)
}
