/// Native HTTP only. Runtime owns account selection, credential acquisition,
/// transport lifetime and retries. This module owns xAI validation and the
/// shared Responses codec boundary; it never captures a credential in Config.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses
import mimic/egress
import mimic/protocol/responses/http as responses_http
import mimic/protocol/responses/stream
import mimic/providers/contracts
import mimic/providers/runtime
import mimic/providers/transport
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/types.{type Header, Header}

/// Gateway factory hook. Credential values are selected from Context only.
pub fn http(
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream) {
  transport.http(
    fn(context, request) { bridge.prepare(config, context, request) },
    bridge.rejection,
    ca_file,
  )
}

/// `/responses` is SSE upstream even when the caller requested a buffered
/// response. Never return concatenated SSE as JSON. The final document carries
/// terminal output and usage; no deltas or terminal documents are accumulated.
pub fn collect(
  response: runtime.Response,
  operation: String,
) -> Result(runtime.BufferedResponse, contracts.Failure) {
  case operation {
    "responses" -> {
      use state <- result.try(
        responses_http.open_sse(response.status, response.headers)
        |> result.map_error(fn(_) {
          runtime.cancel(response.stream)
          invalid_response()
        }),
      )
      use body <- result.try(collect_sse(state, response.stream, None))
      Ok(runtime.BufferedResponse(
        response.status,
        [Header("Content-Type", "application/json")],
        response.account,
        bit_array.from_string(body),
      ))
    }
    "responses/compact" -> {
      use _ <- result.try(
        compact_headers(response.status, response.headers)
        |> result.map_error(fn(_) {
          runtime.cancel(response.stream)
          invalid_response()
        }),
      )
      use body <- result.try(collect_json(response.stream, <<>>))
      use text <- result.try(
        bit_array.to_string(body)
        |> result.map_error(fn(_) { invalid_response() }),
      )
      use _ <- result.try(
        responses.decode_compact_response(text)
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
      Error(unsupported())
    }
  }
}

fn compact_headers(status: Int, headers: List(Header)) -> Result(Nil, Nil) {
  let types =
    headers
    |> list.filter(fn(h) { string.lowercase(h.name) == "content-type" })
    |> list.map(fn(h) { string.lowercase(string.trim(h.value)) })
  let encodings =
    headers
    |> list.filter(fn(h) { string.lowercase(h.name) == "content-encoding" })
    |> list.map(fn(h) { string.lowercase(string.trim(h.value)) })
  case status >= 200 && status < 300, types, encodings {
    True, [media], [] | True, [media], ["identity"] ->
      case string.starts_with(media, "application/json") {
        True -> Ok(Nil)
        False -> Error(Nil)
      }
    _, _, _ -> Error(Nil)
  }
}

fn collect_sse(
  state: stream.Stream,
  handle: runtime.Stream,
  terminal: Option(String),
) -> Result(String, contracts.Failure) {
  case runtime.next(handle) {
    Error(error) -> {
      runtime.cancel(handle)
      Error(error)
    }
    Ok(None) -> {
      use _ <- result.try(
        stream.finish(state) |> result.map_error(fn(_) { invalid_response() }),
      )
      case terminal {
        Some(body) -> Ok(body)
        None -> Error(invalid_response())
      }
    }
    Ok(Some(bytes)) -> {
      let batch = stream.feed_partial(state, bytes)
      let terminal =
        list.fold(batch.events, terminal, fn(found, event) {
          case stream.terminal_response(event) {
            Ok(response) -> Some(responses.encode_response(response))
            Error(_) -> found
          }
        })
      case batch.next {
        Ok(next) -> collect_sse(next, handle, terminal)
        Error(_) -> {
          runtime.cancel(handle)
          Error(invalid_response())
        }
      }
    }
  }
}

fn collect_json(
  handle: runtime.Stream,
  body: BitArray,
) -> Result(BitArray, contracts.Failure) {
  case runtime.next(handle) {
    Error(error) -> {
      runtime.cancel(handle)
      Error(error)
    }
    Ok(None) -> Ok(body)
    Ok(Some(chunk)) -> {
      case bit_array.byte_size(body) + bit_array.byte_size(chunk) <= 1_048_576 {
        True -> collect_json(handle, <<body:bits, chunk:bits>>)
        False -> {
          runtime.cancel(handle)
          Error(invalid_response())
        }
      }
    }
  }
}

/// Deliver validated native events one by one. `http.run` emits a valid prefix
/// before an error later in the *same* TCP chunk, then cancels without retry.
/// The gateway calls `stream.encode_event` for each event after this callback.
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

fn invalid_response() {
  contracts.Failure(contracts.InvalidResponse, contracts.Started, None)
}

fn unsupported() {
  contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
}
