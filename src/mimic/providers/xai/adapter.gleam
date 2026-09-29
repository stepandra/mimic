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
import mimic/providers/xai/bridge
import mimic/providers/xai/endpoint
import mimic/providers/xai/request as xai_request
import mimic/providers/xai/tools
import mimic/types.{type Header, Header}

pub opaque type Handle {
  Handle(
    upstream: egress.Stream,
    refs: List(tools.Ref),
    codec: Option(Result(stream.Stream, String)),
  )
}

/// Gateway factory hook. Credential values are selected from Context only.
pub fn http(
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.Adapter(Handle) {
  http_with_config(fn(_) { config }, ca_file)
}

/// Runtime-approved origin is selected per open, including account failover.
/// No key, account or first-account base URL is captured by this factory.
pub fn selected_http(
  config: endpoint.Config,
  ca_file: Option(String),
) -> contracts.Adapter(Handle) {
  http_with_config(
    fn(context) {
      endpoint.Config(
        ..config,
        http_base: Some(context.origin <> "/v1"),
        compact_base: Some(context.origin <> "/v1"),
      )
    },
    ca_file,
  )
}

fn http_with_config(config, ca_file) {
  contracts.Adapter(
    open: fn(context, request) {
      use plan <- result.try(bridge.prepare_plan(
        config(context),
        context,
        request,
      ))
      use opened <- result.try(egress.stream_open(
        context.origin,
        plan.capture,
        ca_file,
      ))
      let codec = case
        request.operation == "responses" && opened.0 >= 200 && opened.0 < 300
      {
        True -> Some(responses_http.open_sse(opened.0, opened.1))
        False -> None
      }
      Ok(contracts.Opened(
        opened.0,
        opened.1,
        Handle(opened.2, plan.tool_refs, codec),
      ))
    },
    next: next,
    cancel: fn(handle) { egress.stream_cancel(handle.upstream) },
    rejection: bridge.rejection,
  )
}

/// Shared codec validates framing/lifecycle; the only provider transform is
/// restoration with the refs produced in this exact selected-account open.
/// A deferred error preserves valid events preceding a bad frame in one chunk.
fn next(handle: Handle) {
  case handle.codec {
    Some(Error(_)) -> {
      egress.stream_cancel(handle.upstream)
      Error(invalid_response())
    }
    codec -> {
      use chunk <- result.try(egress.stream_next(handle.upstream))
      case chunk, codec {
        None, Some(Ok(state)) ->
          stream.finish(state)
          |> result.map(fn(_) { None })
          |> result.replace_error(invalid_response())
        None, None -> Ok(None)
        Some(#(bytes, upstream)), None ->
          Ok(Some(#(bytes, Handle(..handle, upstream: upstream))))
        Some(#(bytes, upstream)), Some(Ok(state)) -> {
          let batch = stream.feed_partial(state, bytes)
          let next_handle =
            Handle(..handle, upstream: upstream, codec: Some(batch.next))
          // The outer streaming consumer may stop immediately on a terminal.
          // Do not hide a known same-chunk failure behind that terminal: keep
          // its nonterminal prefix, then deliver the deferred protocol error.
          let events = case batch.next {
            Ok(_) -> batch.events
            Error(_) ->
              list.filter(batch.events, fn(event) {
                !list.contains(
                  [
                    "response.completed",
                    "response.failed",
                    "response.incomplete",
                    "response.cancelled",
                    "error",
                  ],
                  event.name,
                )
              })
          }
          let restored =
            events
            |> list.map(fn(event) {
              stream.encode_event(stream.Event(
                event.name,
                xai_request.restore_event(event.document, handle.refs),
              ))
            })
            |> string.join("")
          case restored {
            "" -> next(next_handle)
            _ -> Ok(Some(#(bit_array.from_string(restored), next_handle)))
          }
        }
        _, Some(Error(_)) -> Error(invalid_response())
      }
    }
  }
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
