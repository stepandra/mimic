/// Synthetic control: the imported Mist chunk lifecycle before the F12 fix.
/// This is not the historical pre-F44 tree and is not an admission receipt.
/// Kept only to compare passive idle/half-close behavior in dedicated tests.
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import glisten/transport
import logging
import mist
import mist/internal/encoder
import mist/internal/http

pub fn chunked(
  req: Request(mist.Connection),
  response: Response(discard),
  init: fn(Subject(message)) -> state,
  loop: fn(state, message, mist.Connection) -> mist.ChunkNext(state),
) -> Response(mist.ResponseData) {
  let start = fn() {
    actor.new_with_initialiser(1000, fn(subj) {
      init(subj)
      |> actor.initialised
      |> actor.returning(process.self())
      |> actor.selecting(process.new_selector() |> process.select(subj))
      |> Ok
    })
    |> actor.on_message(fn(state, message) {
      case loop(state, message, req.body) {
        mist.ChunkContinue(state) -> actor.continue(state)
        mist.ChunkStop -> {
          let _ = case mist.send_chunk(req.body, <<>>) {
            Ok(_nil) -> Nil
            Error(_reason) -> {
              logging.log(logging.Debug, "Failed to send final chunk")
            }
          }
          actor.stop()
        }
        mist.ChunkAbort(reason) -> actor.stop_abnormal(reason)
      }
    })
    |> actor.start
    |> result.map(fn(started) { actor.Started(started.data, started.data) })
  }

  let headers = [#("transfer-encoding", "chunked"), ..response.headers]
  let initial_payload =
    encoder.response_builder(
      response.status,
      headers,
      http.version_to_string(http.Http11),
    )

  let assert Ok(_nil) =
    transport.send(req.body.transport, req.body.socket, initial_payload)

  let factory_supervisor = factory.get_by_name(req.body.factory_name)

  case factory.start_child(factory_supervisor, start) {
    Ok(started) -> {
      let assert Ok(_controlled) =
        transport.controlling_process(
          req.body.transport,
          req.body.socket,
          started.data,
        )
      response.new(200) |> response.set_body(mist.Chunked)
    }
    Error(_start_error) -> {
      logging.log(logging.Error, "Failed to start chunked response process")
      response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}
