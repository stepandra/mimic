/// Explicit Chat SSE admission facade. Default bridge.models() stays buffered.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/option.{type Option, None}
import gleam/result
import mimic/protocol/responses/http.{Continue}
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/chat
import mimic/providers/devin/client
import mimic/providers/devin/identity
import mimic/providers/devin/models as catalog
import mimic/providers/registry
import mimic/providers/runtime
import mist

type Tick {
  Tick
}

type Sender {
  Sender(client: client.Client(chat.State), adopted: Bool)
}

/// Calling this constructor is an explicit local-only integration opt-in.
/// It registers only Chat; Stream must not leak to buffered Messages.
pub fn registration(model: String) -> Result(registry.Model, String) {
  configured_registration(model, catalog.baseline())
}

pub fn configured_registration(
  model: String,
  configured: List(catalog.Model),
) -> Result(registry.Model, String) {
  use selected <- result.try(catalog.resolve(configured, model))
  let assert [registered] = bridge.configured_models([selected])
  Ok(
    registry.Model(..registered, protocols: ["openai-chat"], capabilities: [
      c.Stream,
      ..registered.capabilities
    ]),
  )
}

pub fn open(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
) -> Result(#(String, client.Client(chat.State)), c.Failure) {
  open_configured(engine, ca, request, catalog.baseline())
}

pub fn open_configured(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: List(catalog.Model),
) -> Result(#(String, client.Client(chat.State)), c.Failure) {
  open_with_adapter(
    engine,
    request,
    configured,
    bridge.configured_adapter(ca, configured),
  )
}

pub fn open_with_adapter(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(catalog.Model),
  adapter: c.Adapter(handle),
) -> Result(#(String, client.Client(chat.State)), c.Failure) {
  use _ <- result.try(
    case request.protocol == "openai-chat" && request.mode == c.Streaming {
      True -> Ok(Nil)
      False -> Error(c.Failure(c.Unsupported, c.NotSent, None))
    },
  )
  use _ <- result.try(
    bridge.validate_chat(request, configured)
    |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None)),
  )
  use state <- result.try(
    chat.new(
      "chatcmpl-devin-" <> identity.uuid(),
      request.model,
      now_ms() / 1000,
    )
    |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None)),
  )
  use #(account, stream) <- result.try(bridge.open_native_with_adapter(
    engine,
    request,
    adapter,
  ))
  Ok(#(account, client.new(stream, state, chat.encode)))
}

pub fn serve(
  incoming: Request(mist.Connection),
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
) -> Response(mist.ResponseData) {
  case open(engine, ca, request) {
    Error(_) ->
      Response(
        503,
        [#("content-type", "application/json")],
        mist.Bytes(bytes_tree.from_string(
          "{\"error\":\"provider unavailable\"}",
        )),
      )
    Ok(#(_, opened)) -> send(incoming, opened)
  }
}

/// The native runtime guard monitors this Mist owner. Sender death closes the
/// upstream and releases the lease even when a pull is blocked.
pub fn send(
  incoming: Request(mist.Connection),
  opened: client.Client(chat.State),
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: incoming,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      let adopted = client.adopt(opened) == Ok(Nil)
      process.send(subject, Tick)
      Sender(opened, adopted)
    },
    loop: fn(sender, _, connection) {
      case sender.adopted {
        False -> mist.chunk_stop_abnormal("upstream ownership unavailable")
        True -> {
          let emit = fn(frame) {
            mist.send_chunk(connection, bit_array.from_string(frame))
            |> result.replace(Continue)
            |> result.replace_error("downstream closed")
          }
          case client.run(sender.client, emit) {
            Ok(_) -> mist.chunk_stop()
            Error(error) -> {
              // Never send DONE after failure; a disconnected client receives
              // no later error attempt. Valid preceding frames were sent once.
              case error.reason {
                c.Cancelled -> Nil
                _ -> {
                  let _ = emit(chat.failure(error))
                  Nil
                }
              }
              mist.chunk_stop_abnormal("upstream stream failed")
            }
          }
        }
      }
    },
  )
}

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
