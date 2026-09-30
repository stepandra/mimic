/// Authenticated native Responses upgrade. This deliberately does not call
/// Mist's unbounded/compression-negotiating WebSocket parser. The pinned Mist
/// Connection/factory handoff is isolated here; RFC6455 lives in shared frames.
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/result
import gleam/string
import mimic/ir
import mimic/protocol/responses/frames
import mimic/providers/codex/models
import mimic/providers/codex_websocket
import mimic/providers/contracts
import mimic/providers/runtime
import mimic/types.{type Header, Header}
import mist
import mist/internal/http as mist_http

pub type Settings {
  Settings(
    catalog: models.Catalog,
    user_agent: String,
    enabled_models: List(String),
    ca_file: Option(String),
    // Server-owned current client authorization, never a client-supplied flag.
    authorized: fn() -> Bool,
  )
}

type Message {
  Begin(List(Header), process.Subject(Nil))
  Tick
  InitTimeout
}

type State {
  State(
    connection: mist.Connection,
    engine: runtime.Runtime,
    tenant: String,
    settings: Settings,
    subject: process.Subject(Message),
    decoder: frames.Decoder,
    pending: BitArray,
    upstream: Option(runtime.Session),
    generation: String,
    started: Bool,
    deadline: Int,
  )
}

/// The caller MUST authenticate the HTTP request first and supply a server-
/// derived tenant identity, never a header supplied by the client. No origin,
/// credential, provider, model catalog or WS enablement comes from the frame.
/// Browser Origin is intentionally unsupported, rather than accepting CSWSH.
pub fn upgrade_authenticated(
  req: Request(mist.Connection),
  engine: runtime.Runtime,
  tenant: String,
  settings: Settings,
) -> Response(mist.ResponseData) {
  case validate(req, tenant, settings) {
    Error(_) -> reject()
    Ok(headers) -> {
      let ready = process.new_subject()
      let start = fn() {
        actor.new_with_initialiser(1000, fn(subject) {
          let assert Ok(decoder) =
            frames.new(frames.Server, 1_048_576, 1_048_576)
          let pending = case req.body.body {
            mist_http.Initial(bytes) -> bytes
            _ -> <<>>
          }
          let _ = process.send_after(subject, 1000, InitTimeout)
          process.send(ready, subject)
          Ok(
            actor.initialised(State(
              req.body,
              engine,
              tenant,
              settings,
              subject,
              decoder,
              pending,
              None,
              fresh_id(),
              False,
              now_ms() + 60_000,
            ))
            |> actor.returning(process.self()),
          )
        })
        |> actor.on_message(handle)
        |> actor.start
      }
      let supervisor = factory.get_by_name(req.body.factory_name)
      case factory.start_child(supervisor, start) {
        Error(_) -> reject()
        Ok(started) ->
          case process.receive(ready, 1000) {
            Error(_) -> {
              process.kill(started.pid)
              reject()
            }
            Ok(subject) ->
              case takeover(req.body, started.pid) {
                Error(_) -> {
                  process.kill(started.pid)
                  reject()
                }
                Ok(_) -> {
                  // Old owner remains alive through both socket transfer and
                  // the child's 101 acknowledgement. Exactly one writer.
                  let ack = process.new_subject()
                  process.send(subject, Begin(headers, ack))
                  case process.receive(ack, 1500) {
                    Error(_) -> process.kill(started.pid)
                    Ok(_) -> Nil
                  }
                  Response(200, [], mist.Websocket)
                }
              }
          }
      }
    }
  }
}

fn validate(
  req: Request(mist.Connection),
  tenant: String,
  settings: Settings,
) -> Result(List(Header), String) {
  use _ <- result.try(
    case
      req.method == http.Get
      && req.path == "/v1/responses"
      && tenant != ""
      && settings.authorized()
      && settings.enabled_models != []
      && values(req, "origin") == []
      && values(req, "sec-websocket-extensions") == []
      && values(req, "sec-websocket-protocol") == []
      && values(req, "transfer-encoding") == []
      && {
        values(req, "content-length") == []
        || values(req, "content-length") == ["0"]
      }
      && case req.body.body {
        mist_http.Initial(_) -> True
        _ -> False
      }
    {
      True -> Ok(Nil)
      False -> Error("unsupported WebSocket request")
    },
  )
  frames.server_upgrade(
    "GET",
    list.map(req.headers, fn(header) { Header(header.0, header.1) }),
  )
}

fn values(req: Request(mist.Connection), name: String) -> List(String) {
  req.headers
  |> list.filter(fn(pair) { string.lowercase(pair.0) == name })
  |> list.map(fn(pair) { pair.1 })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    InitTimeout if !state.started -> stop(state)
    InitTimeout -> actor.continue(state)
    Begin(headers, ack) if !state.started -> {
      let bytes =
        "HTTP/1.1 101 Switching Protocols\r\n"
        <> {
          list.map(headers, fn(h) { h.name <> ": " <> h.value })
          |> string.join("\r\n")
        }
        <> "\r\n\r\n"
      let sent = write(state.connection, bytes_tree.from_string(bytes))
      process.send(ack, Nil)
      case sent {
        Error(_) -> stop(state)
        Ok(_) -> {
          process.send(state.subject, Tick)
          actor.continue(State(..state, started: True))
        }
      }
    }
    Begin(_, _) -> stop(state)
    Tick -> {
      case now_ms() > state.deadline {
        True -> fail(state)
        False ->
          case step(state) {
            Error(_) -> fail(state)
            Ok(None) -> stop(state)
            Ok(Some(next)) -> {
              process.send(next.subject, Tick)
              actor.continue(next)
            }
          }
      }
    }
  }
}

fn step(state: State) -> Result(Option(State), String) {
  use bytes <- result.try(case state.pending {
    <<>> -> receive_bytes(state.connection, 10)
    bytes -> Ok(Some(bytes))
  })
  let state = State(..state, pending: <<>>)
  use state <- result.try(case bytes {
    None -> Ok(Some(state))
    Some(bytes) -> {
      use decoded <- result.try(frames.feed_one(state.decoder, bytes))
      let state = State(..state, decoder: decoded.0, pending: decoded.2)
      case decoded.1 {
        None -> Ok(Some(state))
        Some(event) -> events(state, [event])
      }
    }
  })
  case state {
    None -> Ok(None)
    Some(state) ->
      case state.upstream {
        None -> Ok(Some(state))
        Some(upstream) -> {
          use message <- result.try(runtime.session_poll(upstream) |> safe)
          case message {
            None -> Ok(Some(state))
            Some(message) -> {
              use bytes <- result.try(frames.encode_text(
                frames.Server,
                message,
                None,
              ))
              use _ <- result.try(write(
                state.connection,
                bytes_tree.from_bit_array(bytes),
              ))
              Ok(Some(State(..state, deadline: now_ms() + 60_000)))
            }
          }
        }
      }
  }
}

fn events(
  state: State,
  incoming: List(frames.Event),
) -> Result(Option(State), String) {
  case incoming {
    [] -> Ok(Some(state))
    [event, ..rest] ->
      case event {
        frames.Text(text) -> {
          use next <- result.try(create(state, text))
          events(next, rest)
        }
        frames.Ping(payload) -> {
          use bytes <- result.try(frames.encode_pong(
            frames.Server,
            payload,
            None,
          ))
          use _ <- result.try(write(
            state.connection,
            bytes_tree.from_bit_array(bytes),
          ))
          events(state, rest)
        }
        frames.Pong(_) -> events(state, rest)
        frames.Close(code, reason) -> {
          let text = option.unwrap(reason, "")
          let bytes = frames.encode_close(frames.Server, code, text, None)
          let _ =
            result.try(bytes, fn(bytes) {
              write(state.connection, bytes_tree.from_bit_array(bytes))
            })
          // Closing is the only supported cancel. No invented response.cancel.
          Ok(None)
        }
      }
  }
}

fn create(state: State, text: String) -> Result(State, String) {
  use _ <- result.try(case state.settings.authorized() {
    True -> Ok(Nil)
    False -> Error("WebSocket authorization unavailable")
  })
  use document <- result.try(ir.parse(text))
  use model <- result.try(ir.string_field(document, "model"))
  use _ <- result.try(case list.contains(state.settings.enabled_models, model) {
    True -> Ok(Nil)
    False -> Error("model has no enabled WebSocket capability")
  })
  let request =
    contracts.Request(
      "codex",
      "oauth",
      model,
      "responses",
      "responses",
      contracts.Streaming,
      [contracts.WebSocket],
      state.tenant <> ":" <> state.generation,
      option.map(state.upstream, runtime.session_account),
      text,
    )
  use upstream <- result.try(case state.upstream {
    Some(upstream) -> Ok(upstream)
    None ->
      runtime.open_session(
        state.engine,
        codex_websocket.adapter(
          state.tenant,
          state.settings.catalog,
          state.settings.user_agent,
          state.settings.ca_file,
        ),
        request,
      )
      |> safe
  })
  // Opening a session may block on acquisition/refresh. Recheck after it
  // returns as well, and close that handle if authorization was withdrawn.
  let sent = case state.settings.authorized() {
    True -> runtime.session_send(upstream, request)
    False ->
      Error(contracts.Failure(contracts.Cancelled, contracts.NotSent, None))
  }
  case sent {
    Error(_) -> {
      runtime.session_cancel(upstream)
      Error("WebSocket request failed")
    }
    Ok(_) ->
      Ok(State(..state, upstream: Some(upstream), deadline: now_ms() + 60_000))
  }
}

fn fail(state: State) -> actor.Next(State, Message) {
  // Never reflect provider errors, credential plans or untrusted error strings.
  let _ =
    frames.encode_text(
      frames.Server,
      "{\"type\":\"error\",\"error\":{\"type\":\"server_error\",\"code\":\"websocket_failed\",\"message\":\"WebSocket session failed; reconnect with full history\"}}",
      None,
    )
    |> result.try(fn(bytes) {
      write(state.connection, bytes_tree.from_bit_array(bytes))
    })
  let _ =
    frames.encode_close(frames.Server, Some(1011), "session failed", None)
    |> result.try(fn(bytes) {
      write(state.connection, bytes_tree.from_bit_array(bytes))
    })
  stop(state)
}

fn stop(state: State) -> actor.Next(State, Message) {
  case state.upstream {
    Some(upstream) -> runtime.session_cancel(upstream)
    None -> Nil
  }
  close(state.connection)
  actor.stop()
}

fn reject() -> Response(mist.ResponseData) {
  Response(
    400,
    [#("content-type", "application/json")],
    mist.Bytes(bytes_tree.from_string(
      "{\"error\":\"WebSocket upgrade unavailable\"}",
    )),
  )
}

fn safe(value: Result(a, e)) -> Result(a, String) {
  result.replace_error(value, "WebSocket session unavailable")
}

@external(erlang, "mimic_gateway_ws_ffi", "takeover")
fn takeover(
  connection: mist.Connection,
  pid: process.Pid,
) -> Result(Nil, String)

@external(erlang, "mimic_gateway_ws_ffi", "receive_bytes")
fn receive_bytes(
  connection: mist.Connection,
  timeout: Int,
) -> Result(Option(BitArray), String)

@external(erlang, "mimic_gateway_ws_ffi", "write")
fn write(
  connection: mist.Connection,
  bytes: bytes_tree.BytesTree,
) -> Result(Nil, String)

@external(erlang, "mimic_gateway_ws_ffi", "close")
fn close(connection: mist.Connection) -> Nil

@external(erlang, "mimic_gateway_ffi", "fresh_id")
fn fresh_id() -> String

@external(erlang, "mimic_egress_ffi", "now_ms")
fn now_ms() -> Int
