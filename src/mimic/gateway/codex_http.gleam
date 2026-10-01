/// Opt-in Codex HTTP continuation ingress. The gateway owns authentication and
/// stable tenant-scoped session selection; this module owns only the private
/// receipt cache lifetime and the Mist response lifecycle. Never take history
/// or a continuation from client headers/body as authority.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/json
import gleam/option.{None}
import gleam/result
import mimic/protocol/continuation
import mimic/protocol/responses/http as responses_http
import mimic/protocol/responses/stream as responses_stream
import mimic/providers/codex/adapter
import mimic/providers/codex/http as codex_http
import mimic/providers/codex/response as codex_response
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/runtime
import mist

pub opaque type State {
  State(cache: continuation.Cache(session.Continuation))
}

type Tick {
  Tick
}

type StreamState {
  StreamState(opened: codex_http.Opened, adopted: Bool)
}

/// Nonpersistent and bounded. A fresh State has no previous-response receipts.
pub fn start() -> Result(State, String) {
  continuation.start(continuation.Limits(32, 8_388_608, 2_097_152, 900_000))
  |> result.map(State)
}

/// Stop fences any later publication by already-open streams.
pub fn stop(state: State) -> Result(Nil, String) {
  continuation.stop(state.cache)
}

/// Only use for authenticated, stable, tenant-scoped HTTP /responses requests.
/// The caller must choose the cache-free gateway path for headerless requests
/// and compact; this function deliberately never falls back after stateful error.
pub fn serve(
  incoming: Request(mist.Connection),
  engine: runtime.Runtime,
  state: State,
  config: adapter.Config,
  request: contracts.Request,
  streaming: Bool,
) -> Response(mist.ResponseData) {
  case
    request.provider == "codex"
    && request.auth_mode == "oauth"
    && request.protocol == "responses"
    && {
      request.operation == "responses" || request.operation == "responses/lite"
    }
    && request.session != ""
    && config.tenant != ""
    && config.continuation == None
    && case request.mode, streaming {
      contracts.Streaming, True | contracts.Buffered, False -> True
      _, _ -> False
    }
  {
    False -> reject(422, "unsupported Codex HTTP request")
    True ->
      case codex_http.open(engine, state.cache, config, None, request) {
        Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, _)) ->
          reject(422, "unsupported Codex HTTP request or continuation")
        Error(_) -> reject(503, "provider unavailable")
        Ok(opened) ->
          case streaming {
            True ->
              case
                responses_http.open_sse_with_policy(
                  codex_http.status(opened),
                  codex_http.headers(opened),
                  codex_http.http_policy(opened),
                )
              {
                Error(_) -> {
                  codex_http.cancel(opened)
                  reject(502, "invalid upstream response")
                }
                Ok(_) -> stream(incoming, opened)
              }
            False ->
              case codex_http.consume_http(opened) {
                Ok(delivery) ->
                  case codex_response.delivery_body(delivery) {
                    Ok(body) -> reply(200, body, "application/json")
                    Error(_) -> reject(502, "invalid upstream response")
                  }
                _ -> reject(502, "invalid upstream response")
              }
          }
      }
  }
}

fn stream(
  incoming: Request(mist.Connection),
  opened: codex_http.Opened,
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: incoming,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      // Mist hands the chunk worker a new process. Adopt synchronously before
      // the request owner exits, or the runtime will revoke the stream lease.
      let adopted = case codex_http.adopt(opened) {
        Ok(_) -> True
        Error(_) -> {
          codex_http.cancel(opened)
          False
        }
      }
      process.send(subject, Tick)
      StreamState(opened, adopted)
    },
    loop: fn(state, _, connection) {
      case state.adopted {
        False -> mist.chunk_stop_abnormal("upstream ownership unavailable")
        True -> {
          let emit = fn(data) {
            mist.send_chunk(connection, bit_array.from_string(data))
            |> result.map(fn(_) { responses_http.Continue })
            |> result.replace_error("downstream closed")
          }
          // Preserve strict valid-prefix delivery before receipt construction.
          // Sparse delivery has a separate wire/report authority contract.
          let forwarded = case codex_http.http_policy(state.opened) {
            responses_stream.Strict ->
              codex_http.forward(state.opened, fn(event) {
                emit(responses_stream.encode_event(event))
              })
              |> result.map(fn(_) { Nil })
            responses_stream.NativeSparse(_, _, _) ->
              codex_http.forward_http(state.opened, fn(event) {
                emit(responses_stream.encode_wire_event(event))
              })
              |> result.map(fn(_) { Nil })
          }
          case forwarded {
            Ok(_) -> mist.chunk_stop()
            Error(_) -> mist.chunk_stop_abnormal("upstream stream failed")
          }
        }
      }
    },
  )
}

fn reject(status: Int, message: String) -> Response(mist.ResponseData) {
  reply(
    status,
    json.object([#("error", json.string(message))]) |> json.to_string,
    "application/json",
  )
}

fn reply(
  status: Int,
  body: String,
  content_type: String,
) -> Response(mist.ResponseData) {
  Response(
    status,
    [#("content-type", content_type)],
    mist.Bytes(bytes_tree.from_string(body)),
  )
}
