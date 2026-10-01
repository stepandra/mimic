/// F25 provider/root seam. Reuses F27's selected-Context adapter, the current
/// native Stream/F23 Client and F28's SAME runtime guard/deadline, not a second
/// decoder, credential manager, transport or watchdog.
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/protocol/responses/http.{Continue}
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/client
import mimic/providers/devin/identity
import mimic/providers/devin/models
import mimic/providers/devin/responses
import mimic/providers/devin/responses_delivery as delivery
import mimic/providers/devin/responses_request as input
import mimic/providers/devin/responses_stream as projection
import mimic/providers/devin/stream as native
import mimic/providers/registry
import mimic/providers/runtime
import mist

pub const total_deadline_ms = 10_000

/// Begin once before provider preflight/opening; pass unchanged through sender.
pub fn new_deadline() -> Int {
  monotonic_time(Millisecond) + total_deadline_ms
}

type Unit {
  Millisecond
  Second
}

type Tick {
  Tick
}

type Sender {
  Sender(client: client.Client(projection.State), adopted: Bool, deadline: Int)
}

type Bounded(handle) {
  Bounded(handle: handle, bytes: Int)
}

/// Only aggregate byte accounting. Time/lifetime belongs to the existing
/// runtime guard via open_until; it persists through ordinary native next.
fn bounded_adapter(inner: c.Adapter(handle)) -> c.Adapter(Bounded(handle)) {
  c.Adapter(
    open: fn(context, request) {
      use opened <- result.try(inner.open(context, request))
      Ok(c.Opened(opened.status, opened.headers, Bounded(opened.handle, 0)))
    },
    next: fn(bounded) {
      use next <- result.try(inner.next(bounded.handle))
      case next {
        None -> Ok(None)
        Some(#(bytes, handle)) -> {
          let count = bounded.bytes + bit_array.byte_size(bytes)
          case count <= responses.max_bytes {
            True -> Ok(Some(#(bytes, Bounded(handle, count))))
            False -> Error(c.Failure(c.InvalidResponse, c.Started, None))
          }
        }
      }
    },
    cancel: fn(bounded) { inner.cancel(bounded.handle) },
    rejection: inner.rejection,
  )
}

pub fn configured_registration(
  model: String,
  configured: List(models.Model),
) -> Result(registry.Model, String) {
  use selected <- result.try(models.resolve(configured, model))
  let assert [row] = bridge.configured_models([selected])
  Ok(
    registry.Model(..row, protocols: ["openai-responses"], capabilities: [
      c.Stream,
      ..row.capabilities
    ]),
  )
}

pub fn validate(
  request: c.Request,
  configured: List(models.Model),
) -> Result(Nil, String) {
  input.validate(request, configured)
}

pub fn execute_with_adapter(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(models.Model),
  adapter: c.Adapter(handle),
) -> Result(String, c.Failure) {
  execute_with_adapter_until(
    engine,
    request,
    configured,
    adapter,
    new_deadline(),
  )
}

/// Trusted deterministic deadline seam for focused lifecycle tests, not a
/// client field. Uses the same absolute clock/guard across acquisition/failover.
pub fn execute_with_adapter_until(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(models.Model),
  adapter: c.Adapter(handle),
  deadline: Int,
) -> Result(String, c.Failure) {
  use _ <- result.try(preflight(request, configured, c.Buffered))
  use settings <- result.try(
    input.settings(request.body) |> result.replace_error(unsupported()),
  )
  use builder <- result.try(
    responses.new(
      "resp_devin_" <> identity.uuid(),
      request.model,
      system_time(Second),
      settings,
    )
    |> result.replace_error(unsupported()),
  )
  use output <- result.try(runtime.open_until(
    engine,
    bounded_adapter(adapter),
    request,
    deadline,
  ))
  case accepted(output.status) {
    Error(error) -> {
      runtime.cancel(output.stream)
      Error(error)
    }
    Ok(_) -> collect(native.new(output.stream), builder, deadline)
  }
}

fn collect(
  stream: native.Stream,
  builder: responses.Builder,
  deadline: Int,
) -> Result(String, c.Failure) {
  case within_budget(deadline) {
    Error(_) -> {
      native.cancel(stream)
      Error(c.Failure(c.Unavailable, c.Started, None))
    }
    Ok(_) -> collect_batch(stream, builder, deadline)
  }
}

fn collect_batch(
  stream: native.Stream,
  builder: responses.Builder,
  deadline: Int,
) -> Result(String, c.Failure) {
  let batch = native.next(stream)
  let built =
    list.try_fold(batch.events, builder, fn(builder, event) {
      use _ <- result.try(within_budget(deadline))
      responses.push(builder, event)
    })
  case built, batch.error {
    _, Some(error) -> {
      native.cancel(batch.stream)
      Error(error)
    }
    Error(_), _ -> {
      native.cancel(batch.stream)
      Error(c.Failure(c.Unsupported, c.Started, None))
    }
    Ok(builder), None ->
      case batch.done {
        False -> collect(batch.stream, builder, deadline)
        True -> {
          let projected = responses.finish(builder)
          use _ <- result.try(
            within_budget(deadline)
            |> result.replace_error(c.Failure(c.Unavailable, c.Started, None)),
          )
          projected
          |> result.map(responses.json)
          |> result.replace_error(c.Failure(c.Unsupported, c.Started, None))
        }
      }
  }
}

pub fn open_with_adapter(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(models.Model),
  adapter: c.Adapter(handle),
) -> Result(#(String, client.Client(projection.State)), c.Failure) {
  open_with_adapter_until(engine, request, configured, adapter, new_deadline())
}

pub fn open_with_adapter_until(
  engine: runtime.Runtime,
  request: c.Request,
  configured: List(models.Model),
  adapter: c.Adapter(handle),
  deadline: Int,
) -> Result(#(String, client.Client(projection.State)), c.Failure) {
  use _ <- result.try(preflight(request, configured, c.Streaming))
  use settings <- result.try(
    input.settings(request.body) |> result.replace_error(unsupported()),
  )
  use state <- result.try(
    projection.new(
      "resp_devin_" <> identity.uuid(),
      request.model,
      system_time(Second),
      settings,
    )
    |> result.replace_error(unsupported()),
  )
  use output <- result.try(runtime.open_until(
    engine,
    bounded_adapter(adapter),
    request,
    deadline,
  ))
  case accepted(output.status) {
    Error(error) -> {
      runtime.cancel(output.stream)
      Error(error)
    }
    Ok(_) ->
      Ok(#(
        output.account,
        client.new(native.new(output.stream), state, fn(state, event) {
          use _ <- result.try(within_budget(deadline))
          let encoded = projection.encode(state, event)
          use _ <- result.try(within_budget(deadline))
          encoded
        }),
      ))
  }
}

/// Cooperative CPU acceptance checks reuse the SAME original deadline. No
/// timer/process/watchdog is added, and no completed construction can publish
/// success after its budget. One bounded pure operation is not hard-preempted.
fn within_budget(deadline: Int) -> Result(Nil, String) {
  input.ensure(
    monotonic_time(Millisecond) < deadline,
    "Devin Responses projection deadline",
  )
}

fn preflight(request: c.Request, configured: List(models.Model), mode: c.Mode) {
  case request.mode == mode {
    True -> validate(request, configured)
    False -> Error("unsupported Devin Responses mode")
  }
  |> result.replace_error(unsupported())
}

fn unsupported() -> c.Failure {
  c.Failure(c.Unsupported, c.NotSent, None)
}

fn accepted(status: Int) -> Result(Nil, c.Failure) {
  case status >= 200 && status < 300 {
    True -> Ok(Nil)
    False -> Error(c.Failure(c.Unavailable, c.Started, None))
  }
}

/// Same synchronous adoption/owner-death rule as the current F23/F24 senders.
/// Explicit cancel and runtime deadline bound buffering. No idle downstream
/// disconnect watcher or incremental/token-latency claim is made.
pub fn send(
  incoming: Request(mist.Connection),
  opened: client.Client(projection.State),
  deadline: Int,
) -> Response(mist.ResponseData) {
  mist.chunked(
    request: incoming,
    response: Response(200, [#("content-type", "text/event-stream")], ""),
    init: fn(subject) {
      let adopted = client.adopt(opened) == Ok(Nil)
      process.send(subject, Tick)
      Sender(opened, adopted, deadline)
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
          case delivery.run(sender.client, sender.deadline, emit) {
            delivery.Finished -> mist.chunk_stop()
            delivery.Cancelled -> mist.chunk_stop_abnormal("downstream closed")
            delivery.Failed(error, sequence, terminal_attempted) -> {
              // Error notification is best effort after the success budget.
              // Never append an error after a possibly delivered terminal.
              case terminal_attempted, projection.failure(error, sequence) {
                False, Ok(frame) -> {
                  let _ = emit(frame)
                  Nil
                }
                _, _ -> Nil
              }
              mist.chunk_stop_abnormal("upstream stream failed")
            }
          }
        }
      }
    },
  )
}

/// Feature CLI deliberately cannot create accounts or authorize remote access.
pub fn cli(_args: List(String)) -> Result(String, String) {
  Error("Devin Responses is exposed only through the authenticated gateway")
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Unit) -> Int

@external(erlang, "erlang", "system_time")
fn system_time(unit: Unit) -> Int
