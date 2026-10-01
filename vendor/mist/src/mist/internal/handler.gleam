import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/response
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import glisten.{type Loop, Packet, User}
import glisten/internal/handler as glisten_handler
import glisten/transport
import logging
import mist/internal/encoder
import mist/internal/http.{
  type DecodeError, type Handler, Bytes, Chunked, Connection, DiscardPacket,
  File, Initial, ServerSentEvents, Websocket,
}
import mist/internal/http/handler as http_handler
import mist/internal/http2
import mist/internal/http2/handler as http2_handler
import mist/internal/http2/stream.{type SendMessage, Send}

pub type HandlerError {
  InvalidRequest(DecodeError)
  NotFound
}

pub type State {
  Http1(state: http_handler.State, self: Subject(SendMessage))
  Http2(state: http2_handler.State)
}

pub fn new_state(subj: Subject(SendMessage)) -> State {
  Http1(http_handler.initial_state(), subj)
}

pub fn init(_conn) -> #(State, Option(Selector(SendMessage))) {
  let subj = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(subj)

  #(new_state(subj), Some(selector))
}

pub fn with_func(
  handler: Handler,
  factory_name: process.Name(
    factory.Message(
      fn() -> Result(actor.Started(process.Pid), actor.StartError),
      process.Pid,
    ),
  ),
) -> Loop(State, SendMessage) {
  fn(state: State, msg, conn: glisten.Connection(SendMessage)) {
    let sender = conn.subject
    let conn =
      Connection(
        body: Initial(<<>>),
        socket: conn.socket,
        transport: conn.transport,
        factory_name:,
      )

    let result = case msg, state {
      User(Send(..)), Http1(..) -> {
        Error(Error("Attempted to send HTTP/2 response without upgrade"))
      }
      User(Send(id, resp)), Http2(state) -> {
        case resp.body {
          Bytes(bytes) -> {
            resp
            |> response.set_body(bytes)
            |> http2.send_bytes_tree(conn, state.send_hpack_context, id)
          }
          File(..) -> Error("File sending unsupported over HTTP/2")
          // TODO:  properly error in some fashion for these
          Websocket -> Error("WebSocket unsupported for HTTP/2")
          Chunked -> Error("Chunked encoding not supported for HTTP/2")
          ServerSentEvents -> Error("Server-Sent Events unsupported for HTTP/2")
        }
        |> result.map(fn(context) {
          Http2(http2_handler.send_hpack_context(state, context))
        })
        |> result.map_error(fn(err) {
          logging.log(logging.Debug, "Error sending HTTP/2 data: " <> err)
          Error(err)
        })
      }
      Packet(msg), Http1(state, self) -> {
        call_http1(msg, conn, handler, sender, state, self)
      }
      Packet(msg), Http2(state) -> {
        state
        |> http2_handler.append_data(msg)
        |> http2_handler.call(conn, handler)
        |> result.map(Http2)
      }
    }

    case result {
      Ok(value) -> glisten.continue(value)
      Error(Ok(_nil)) -> glisten.stop()
      Error(Error(reason)) -> glisten.stop_abnormal(reason)
    }
  }
}

fn call_http1(
  data: BitArray,
  conn: http.Connection,
  handler: Handler,
  sender: Subject(glisten_handler.Message(SendMessage)),
  state: http_handler.State,
  self: Subject(SendMessage),
) -> Result(State, Result(Nil, String)) {
  let _ = case state.idle_timer {
    Some(timer) -> process.cancel_timer(timer)
    _ -> process.TimerNotFound
  }
  use parsed <- result.try(
    http.parse_request(data, conn)
    |> result.map_error(parse_error(_, conn)),
  )
  case parsed {
    http.Http1Request(req, version, buffered_tail) -> {
      use #(state, tail) <- result.try(http_handler.call(
        req,
        handler,
        sender,
        version,
      ))
      let tail = bit_array.append(buffered_tail, tail)
      case tail {
        <<>> -> Ok(Http1(state, self))
        _ -> call_http1(tail, conn, handler, sender, state, self)
      }
    }
    http.Upgrade(data) ->
      http2_handler.upgrade(data, conn, self)
      |> result.map(Http2)
      |> result.map_error(Error)
  }
}

fn parse_error(
  error: DecodeError,
  conn: http.Connection,
) -> Result(Nil, String) {
  case error {
    DiscardPacket -> Ok(Nil)
    http.NoHostHeader -> {
      logging.log(logging.Warning, "Missing HTTP `host` header")
      let _ =
        response.new(400)
        |> response.prepend_header("connection", "close")
        |> response.set_body(bytes_tree.new())
        |> encoder.to_bytes_tree("1.1")
        |> transport.send(conn.transport, conn.socket, _)
      Ok(Nil)
    }
    _ -> {
      let message = case error {
        http.MalformedRequest -> "Received malformed HTTP request"
        http.InvalidMethod -> "Received invalid HTTP method"
        http.InvalidPath -> "Received invalid HTTP path"
        http.UnknownHeader -> "Received unknown HTTP header"
        http.UnknownMethod -> "Received unknown HTTP method"
        http.InvalidBody -> "Received invalid HTTP body"
        http.BodyTooLarge -> "Received excessive HTTP body"
        http.InvalidHttpVersion -> "Received invalid HTTP version"
        _ -> "Received invalid HTTP request"
      }
      logging.log(logging.Warning, message)
      Error(message)
    }
  }
}
