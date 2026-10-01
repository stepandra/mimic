/// F24 root/Mist seam. Reuses the actual native codecs, F23 client lifecycle,
/// runtime authentication/selection and shared binary HTTP transport.
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/anthropic
import mimic/ir
import mimic/protocol/responses/http.{Continue}
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/chat_gateway
import mimic/providers/devin/client
import mimic/providers/devin/identity
import mimic/providers/devin/messages
import mimic/providers/devin/messages_stream as projection
import mimic/providers/devin/models
import mimic/providers/devin/request as wire
import mimic/providers/devin/stream as native
import mimic/providers/registry
import mimic/providers/runtime
import mist

pub const total_deadline_ms = 10_000

type Tick {
  Tick
}

type Sender {
  Sender(client: client.Client(projection.State), adopted: Bool)
}

type Done {
  Done
}

type Timer {
  Timer(pid: process.Pid, stop: process.Subject(Done))
}

pub opaque type Bounded(handle) {
  Bounded(handle: handle, timer: Timer, bytes: Int)
}

/// A request-wide deadline, including handshake, slow trickle and idle pulls.
/// It does NOT reset per chunk or account attempt. Only the runtime execution
/// worker is killed; its existing monitors close sockets/release the lease.
/// This resource wrapper is not another provider manager or HTTP transport.
pub fn bounded_adapter(
  inner: c.Adapter(handle),
  budget_ms: Int,
) -> c.Adapter(Bounded(handle)) {
  let deadline = now_ms() + budget_ms
  c.Adapter(
    open: fn(context, request) {
      let timer = start_timer(deadline)
      case inner.open(context, request) {
        Error(error) -> {
          stop_timer(timer)
          Error(error)
        }
        Ok(opened) ->
          Ok(c.Opened(
            opened.status,
            opened.headers,
            Bounded(opened.handle, timer, 0),
          ))
      }
    },
    next: fn(bounded) {
      use next <- result.try(inner.next(bounded.handle))
      case next {
        None -> Ok(None)
        Some(#(bytes, handle)) -> {
          let count = bounded.bytes + bit_array.byte_size(bytes)
          case count <= messages.max_bytes {
            True -> Ok(Some(#(bytes, Bounded(handle, bounded.timer, count))))
            False -> Error(c.Failure(c.InvalidResponse, c.Started, None))
          }
        }
      }
    },
    cancel: fn(bounded) {
      inner.cancel(bounded.handle)
      stop_timer(bounded.timer)
    },
    rejection: inner.rejection,
  )
}

fn start_timer(deadline: Int) -> Timer {
  let owner = process.self()
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let stop = process.new_subject()
      let monitor = process.monitor(owner)
      let selector =
        process.new_selector()
        |> process.select(stop)
        |> process.select_specific_monitor(monitor, fn(_) { Done })
      process.send(ready, stop)
      case process.selector_receive(selector, int_max(0, deadline - now_ms())) {
        Ok(_) -> process.demonitor_process(monitor)
        Error(_) -> process.kill(owner)
      }
    })
  let assert Ok(stop) = process.receive(ready, 1000)
  Timer(pid, stop)
}

fn stop_timer(timer: Timer) -> Nil {
  let monitor = process.monitor(timer.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Done })
  process.send(timer.stop, Done)
  let _ = process.selector_receive(selector, 1000)
  process.demonitor_process(monitor)
}

fn int_max(a: Int, b: Int) {
  case a > b {
    True -> a
    False -> b
  }
}

pub fn registration(model: String) -> Result(registry.Model, String) {
  configured_registration(model, models.baseline())
}

pub fn configured_registration(
  model: String,
  configured: List(models.Model),
) -> Result(registry.Model, String) {
  use selected <- result.try(models.resolve(configured, model))
  let assert [row] = bridge.configured_models([selected])
  Ok(
    registry.Model(..row, protocols: ["anthropic-messages"], capabilities: [
      c.Stream,
      ..row.capabilities
    ]),
  )
}

/// Baseline-current root hook: no dependency on the unadmitted F27 catalog.
/// Both current Chat and Messages rows actually support these capabilities.
pub fn combined_registration(model: String) -> Result(registry.Model, String) {
  configured_combined_registration(model, models.baseline())
}

pub fn configured_combined_registration(
  model: String,
  configured: List(models.Model),
) -> Result(registry.Model, String) {
  use chat <- result.try(chat_gateway.configured_registration(model, configured))
  use row <- result.try(configured_registration(model, configured))
  use _ <- result.try(messages.ensure(
    chat.capabilities == row.capabilities
      && chat.auth_modes == row.auth_modes
      && chat.operations == row.operations,
    "asymmetric Devin protocol capabilities",
  ))
  Ok(
    registry.Model(
      ..chat,
      protocols: list.append(chat.protocols, row.protocols),
    ),
  )
}

/// Pure preflight before runtime credentials/lease/I/O. The fixed synthetic
/// identity exercises the CURRENT native codec, not a second request mapper.
pub fn validate(
  request: c.Request,
  configured: List(models.Model),
) -> Result(Nil, String) {
  use _ <- result.try(messages.ensure(
    request.provider == "devin"
      && request.auth_mode == "session_token"
      && request.protocol == "anthropic-messages"
      && request.operation == "generate"
      && request.pinned_account == None
      && request.session != ""
      && string.byte_size(request.body) <= messages.max_bytes
      && list.all(request.required, fn(cap) {
      cap == c.Buffer || cap == c.Stream || cap == c.Tools || cap == c.Images
    }),
    "unsupported Devin Messages request",
  ))
  use model <- result.try(models.resolve(configured, request.model))
  use _ <- result.try(ir.parse_bounded(
    request.body,
    messages.max_bytes,
    128,
    65_536,
  ))
  use input <- result.try(anthropic.decode_request(request.body))
  use _ <- result.try(messages.ensure(
    input.model == request.model
      && { input.stream == Some(True) } == { request.mode == c.Streaming },
    "Devin Messages model or stream mismatch",
  ))
  use _ <- result.try(case input.max_tokens {
    Some(n) ->
      messages.ensure(
        n > 0 && n <= model.max_tokens,
        "invalid Messages max_tokens",
      )
    None -> Error("Messages max_tokens required")
  })
  use _ <- result.try(
    list.try_each(input.turns, fn(turn) {
      list.try_each(turn.content, fn(part) {
        case part {
          ir.Thinking(_, Some(signature), []) ->
            messages.qualify_signature(
              bit_array.from_string(signature),
              "anthropic",
            )
            |> result.replace(Nil)
          ir.Thinking(..) ->
            Error("unsupported or unsigned Messages thinking history")
          _ -> Ok(Nil)
        }
      })
    }),
  )
  use _ <- result.try(wire.encode_configured(
    input,
    "synthetic-f24-preflight",
    wire.Identity(
      "linux",
      string.repeat("0", 732),
      "00000000-0000-4000-8000-000000000024",
      "00000000-0000-4000-8000-000000000025",
    ),
    configured,
  ))
  Ok(Nil)
}

pub fn execute(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
) -> Result(String, c.Failure) {
  execute_configured(engine, ca, request, models.baseline())
}

pub fn execute_configured(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: List(models.Model),
) -> Result(String, c.Failure) {
  execute_with_adapter(
    engine,
    request,
    configured,
    bridge.configured_adapter(ca, configured),
  )
}

pub fn execute_with_adapter(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(models.Model),
  adapter: c.Adapter(handle),
) -> Result(String, c.Failure) {
  use _ <- result.try(preflight(request, configured, c.Buffered))
  use output <- result.try(runtime.execute(
    engine,
    bounded_adapter(adapter, total_deadline_ms),
    request,
  ))
  use _ <- result.try(accepted(output.status))
  messages.buffered(output.body, "msg-devin-" <> identity.uuid(), request.model)
  |> result.replace_error(c.Failure(c.Unsupported, c.Started, None))
}

pub fn open(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
) -> Result(#(String, client.Client(projection.State)), c.Failure) {
  open_configured(engine, ca, request, models.baseline())
}

pub fn open_configured(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: List(models.Model),
) -> Result(#(String, client.Client(projection.State)), c.Failure) {
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
  configured: List(models.Model),
  adapter: c.Adapter(handle),
) -> Result(#(String, client.Client(projection.State)), c.Failure) {
  use _ <- result.try(preflight(request, configured, c.Streaming))
  use state <- result.try(
    projection.new("msg-devin-" <> identity.uuid(), request.model)
    |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None)),
  )
  // Same native Stream/F23 Client as Chat, with only a resource budget wrapper.
  use output <- result.try(runtime.open(
    engine,
    bounded_adapter(adapter, total_deadline_ms),
    request,
  ))
  case accepted(output.status) {
    Error(error) -> {
      runtime.cancel(output.stream)
      Error(error)
    }
    Ok(_) ->
      Ok(#(
        output.account,
        client.new(native.new(output.stream), state, projection.encode),
      ))
  }
}

fn preflight(request: c.Request, configured: List(models.Model), mode: c.Mode) {
  case request.mode == mode {
    True -> validate(request, configured)
    False -> Error("unsupported Devin Messages mode")
  }
  |> result.replace_error(c.Failure(c.Unsupported, c.NotSent, None))
}

fn accepted(status: Int) {
  case status >= 200 && status < 300 {
    True -> Ok(Nil)
    False -> Error(c.Failure(c.Unavailable, c.Started, None))
  }
}

pub fn serve(
  incoming: Request(mist.Connection),
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
) -> Response(mist.ResponseData) {
  case open(engine, ca, request) {
    Error(error) ->
      Response(
        case error.reason {
          c.Unsupported -> 422
          _ -> 503
        },
        [#("content-type", "application/json")],
        mist.Bytes(bytes_tree.from_string(
          "{\"error\":\"provider unavailable\"}",
        )),
      )
    Ok(#(_, opened)) -> send(incoming, opened)
  }
}

/// Synchronous adoption is the existing F23 convention. Sender death or
/// explicit cancellation releases upstream even BEFORE buffered construction.
/// No claim of an idle downstream-close watcher is made.
pub fn send(
  incoming: Request(mist.Connection),
  opened: client.Client(projection.State),
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
              case error.reason {
                c.Cancelled -> Nil
                _ -> {
                  let _ = emit(projection.failure(error))
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
