/// Native Connect event stream over the shared runtime. Not client SSE.
/// Integrators supply a qualified shared client codec before advertising Stream.
import gleam/list
import gleam/option.{type Option, None, Some}
import mimic/providers/contracts as c
import mimic/providers/devin/response
import mimic/providers/runtime

pub opaque type Stream {
  Stream(handle: runtime.Stream, decoder: response.Decoder, terminal: Bool)
}

/// Prefix events must be delivered once before observing an error. `done` is
/// true on both success and failure; a failure never permits account replay.
pub type Batch {
  Batch(
    stream: Stream,
    events: List(response.Event),
    done: Bool,
    error: Option(c.Failure),
  )
}

pub fn new(handle: runtime.Stream) -> Stream {
  Stream(handle, response.new(), False)
}

pub fn adopt(stream: Stream) -> Result(Nil, c.Failure) {
  runtime.adopt(stream.handle)
}

pub fn cancel(stream: Stream) -> Nil {
  runtime.cancel(stream.handle)
}

pub fn next(stream: Stream) -> Batch {
  case stream.terminal {
    True -> Batch(stream, [], True, None)
    False -> pull(stream)
  }
}

fn pull(stream: Stream) -> Batch {
  case runtime.next(stream.handle) {
    Error(error) -> failed(stream, [], error)
    Ok(None) ->
      case response.finish(stream.decoder) {
        Ok(_) ->
          Batch(Stream(..stream, terminal: True), [response.Stop], True, None)
        Error(_) -> failed(stream, [], invalid())
      }
    Ok(Some(bytes)) -> {
      let #(decoder, events, error) =
        response.feed_prefix(stream.decoder, bytes)
      let stream = Stream(..stream, decoder: decoder)
      // Wait for HTTP EOF before publishing success, so later bytes after EOS
      // or a truncated HTTP body cannot follow a client success marker.
      let events = list.filter(events, fn(event) { event != response.Stop })
      case error {
        Some(_) -> failed(stream, events, invalid())
        None -> Batch(stream, events, False, None)
      }
    }
  }
}

fn failed(
  stream: Stream,
  events: List(response.Event),
  error: c.Failure,
) -> Batch {
  runtime.cancel(stream.handle)
  Batch(
    Stream(..stream, terminal: True),
    events,
    True,
    Some(c.Failure(..error, delivery: c.Started)),
  )
}

fn invalid() -> c.Failure {
  c.Failure(c.InvalidResponse, c.Started, None)
}

/// Shared-codec injection seam. Encode one validated event at a time so a
/// projection failure cannot erase already encoded output from this batch.
/// Caller must deliver returned frames before reporting `error`, and stop on
/// either `batch.done` or a projection error. No transport retry is performed.
pub fn project(
  batch: Batch,
  state: state,
  encode: fn(state, response.Event) -> Result(#(state, List(String)), String),
) -> #(state, List(String), Option(c.Failure)) {
  project_events(batch, state, batch.events, [], encode)
}

fn project_events(
  batch: Batch,
  state: state,
  events: List(response.Event),
  frames: List(String),
  encode: fn(state, response.Event) -> Result(#(state, List(String)), String),
) -> #(state, List(String), Option(c.Failure)) {
  case events {
    [] -> #(state, list.reverse(frames), batch.error)
    [event, ..rest] ->
      case encode(state, event) {
        Ok(#(next, output)) ->
          project_events(
            batch,
            next,
            rest,
            list.append(list.reverse(output), frames),
            encode,
          )
        Error(_) -> {
          cancel(batch.stream)
          #(
            state,
            list.reverse(frames),
            Some(c.Failure(c.Unsupported, c.Started, None)),
          )
        }
      }
  }
}
