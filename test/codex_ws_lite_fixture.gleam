/// Synthetic loopback peer. Exact metadata/done/completed strings below are
/// source-derived CPA fixtures, not a capture or actual native-client proof.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/responses/frames
import mimic/providers/codex/adapter
import mimic/providers/codex/models
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{Header}

pub const metadata = "{\"type\":\"codex.response.metadata\",\"headers\":{\"x-models-etag\":\"models-v1\",\"x-codex-turn-state\":\"turn-1\",\"x-codex-safety-buffering-enabled\":\"true\",\"x-codex-safety-buffering-faster-model\":\"fixture-model\"},\"future\":{\"ok\":true}}"

pub const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}"

pub const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[],\"future\":{\"ok\":true},\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}"

pub const created = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}"

pub const model = "gpt-5.6-sol"

pub type Socket

pub type Turn {
  Turn(
    prefix: List(String),
    gate: Option(process.Subject(process.Subject(Nil))),
    suffix: List(String),
    wire_tail: BitArray,
    released_tail: BitArray,
  )
}

pub type Mock {
  Mock(
    listener: Socket,
    port: Int,
    pid: process.Pid,
    requests: process.Subject(String),
    closed: process.Subject(Nil),
  )
}

pub type Pressure {
  Pressure(
    listener: Socket,
    port: Int,
    pid: process.Pid,
    ready: process.Subject(process.Subject(Nil)),
    eof: process.Subject(Result(#(Int, String), String)),
    endpoints: process.Subject(#(Int, Int)),
  )
}

type Peer {
  Peer(socket: Socket, decoder: frames.Decoder, pending: BitArray)
}

@external(erlang, "mimic_f13_codex_ws_test_ffi", "listen")
fn listen(
  secure: Bool,
  cert: String,
  key: String,
) -> Result(#(Socket, Int), String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "accept")
fn accept(socket: Socket) -> Result(Socket, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "read")
fn read(socket: Socket) -> Result(BitArray, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "write")
fn write(socket: Socket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "mimic_f13_codex_ws_test_ffi", "drain_eof")
fn drain_eof(socket: Socket, timeout: Int) -> Result(#(Int, String), String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "endpoints")
fn endpoints(socket: Socket) -> Result(#(Int, Int), String)

@external(erlang, "mimic_auth_test_ffi", "state_directory")
pub fn directory() -> String

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
pub fn ca_directory() -> String

pub fn peer(
  secure: Bool,
  cert: String,
  key: String,
  turns: List(Turn),
) -> Mock {
  let assert Ok(#(listener, port)) = listen(secure, cert, key)
  let requests = process.new_subject()
  let closed = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      case accept(listener) {
        Error(_) -> Nil
        Ok(socket) -> {
          let _ = serve(socket, requests, turns)
          close(socket)
        }
      }
      process.send(closed, Nil)
    })
  Mock(listener, port, pid, requests, closed)
}

pub fn turn(events: List(String)) -> Turn {
  Turn(events, None, [], <<>>, <<>>)
}

pub fn gated(
  prefix: List(String),
  ready: process.Subject(process.Subject(Nil)),
  suffix: List(String),
) -> Turn {
  Turn(prefix, Some(ready), suffix, <<>>, <<>>)
}

/// Prefix plus raw tail is one physical write, so complete terminal data and
/// withheld/fragmented/oversized stale framing can share the same read.
pub fn raw_turn(
  prefix: List(String),
  tail: BitArray,
  ready: process.Subject(process.Subject(Nil)),
  after_release: BitArray,
) -> Turn {
  Turn(prefix, Some(ready), [], tail, after_release)
}

pub fn stop(mock: Mock) {
  close(mock.listener)
  process.kill(mock.pid)
}

fn serve(socket: Socket, requests: process.Subject(String), turns: List(Turn)) {
  use pending <- result.try(upgrade(socket, requests))
  use decoder <- result.try(frames.new(frames.Server, 1_048_576, 1_048_576))
  loop(Peer(socket, decoder, pending), requests, turns)
}

fn upgrade(
  socket: Socket,
  requests: process.Subject(String),
) -> Result(BitArray, String) {
  use head <- result.try(header(socket, <<>>))
  process.send(requests, head.0)
  let headers =
    string.split(head.0, "\r\n")
    |> list.filter_map(fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) -> Ok(Header(name, string.trim(value)))
        Error(_) -> Error(Nil)
      }
    })
  use upgrade <- result.try(frames.server_upgrade("GET", headers))
  let response =
    "HTTP/1.1 101 Switching Protocols\r\n"
    <> string.join(
      list.map(upgrade, fn(h) { h.name <> ": " <> h.value <> "\r\n" }),
      "",
    )
    <> "\r\n"
  use _ <- result.try(write(socket, bit_array.from_string(response)))
  Ok(head.1)
}

/// Hold all peer reads after upgrade/control publication. The test must release
/// this peer only after timed admission/abort returns; EOF is measured directly,
/// not inferred from writer timeout or an arbitrary fixture error.
pub fn pressure_peer(
  secure: Bool,
  cert: String,
  key: String,
  tail: BitArray,
) -> Pressure {
  let assert Ok(#(listener, port)) = listen(secure, cert, key)
  let ready = process.new_subject()
  let eof = process.new_subject()
  let identity = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let outcome = {
        use socket <- result.try(accept(listener))
        use ports <- result.try(endpoints(socket))
        process.send(identity, ports)
        let requests = process.new_subject()
        let drained = {
          use _ <- result.try(upgrade(socket, requests))
          use _ <- result.try(send_with_tail(socket, ["pressure-ready"], tail))
          let release = process.new_subject()
          process.send(ready, release)
          use _ <- result.try(
            process.receive(release, 5000)
            |> result.replace_error("synthetic pressure gate timed out"),
          )
          drain_eof(socket, 1000)
        }
        close(socket)
        drained
      }
      process.send(eof, outcome)
    })
  Pressure(listener, port, pid, ready, eof, identity)
}

pub fn stop_pressure(peer: Pressure) {
  close(peer.listener)
  process.kill(peer.pid)
}

fn header(
  socket: Socket,
  bytes: BitArray,
) -> Result(#(String, BitArray), String) {
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error("header encoding"),
  )
  case string.split_once(text, "\r\n\r\n") {
    Ok(#(head, rest)) -> Ok(#(head, bit_array.from_string(rest)))
    Error(_) -> {
      use _ <- result.try(case bit_array.byte_size(bytes) < 65_536 {
        True -> Ok(Nil)
        False -> Error("synthetic header limit")
      })
      use next <- result.try(read(socket))
      header(socket, bit_array.concat([bytes, next]))
    }
  }
}

fn next(peer: Peer) -> Result(#(Peer, frames.Event), String) {
  use bytes <- result.try(case peer.pending {
    <<>> -> read(peer.socket)
    pending -> Ok(pending)
  })
  use decoded <- result.try(frames.feed_one(peer.decoder, bytes))
  let peer = Peer(..peer, decoder: decoded.0, pending: decoded.2)
  case decoded.1 {
    None -> next(peer)
    Some(event) -> Ok(#(peer, event))
  }
}

fn loop(peer: Peer, requests: process.Subject(String), turns: List(Turn)) {
  use incoming <- result.try(next(peer))
  let peer = incoming.0
  case incoming.1 {
    frames.Close(_, _) -> Ok(Nil)
    frames.Pong(_) -> loop(peer, requests, turns)
    frames.Ping(_) -> Error("unexpected synthetic ping")
    frames.Text(message) -> {
      process.send(requests, message)
      case turns {
        [] -> Error("unexpected additional upstream create")
        [turn, ..rest] -> {
          use _ <- result.try(send_with_tail(
            peer.socket,
            turn.prefix,
            turn.wire_tail,
          ))
          use _ <- result.try(case turn.gate {
            None -> Ok(Nil)
            Some(ready) -> {
              let release = process.new_subject()
              process.send(ready, release)
              process.receive(release, 5000)
              |> result.replace_error("synthetic gate timed out")
            }
          })
          use _ <- result.try(send_with_tail(
            peer.socket,
            turn.suffix,
            turn.released_tail,
          ))
          loop(peer, requests, rest)
        }
      }
    }
  }
}

fn send_with_tail(socket: Socket, events: List(String), tail: BitArray) {
  use encoded <- result.try(
    list.try_map(events, fn(event) {
      frames.encode_text(frames.Server, event, None)
    }),
  )
  let packet = bit_array.concat(list.append(encoded, [tail]))
  case packet {
    <<>> -> Ok(Nil)
    _ -> write(socket, packet)
  }
}

pub fn material() -> contracts.AuthMaterial {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-f13-access",
        "synthetic-f13-refresh",
        9_000_000_000_000,
      ),
      [#("chatgpt_account_id", "synthetic-f13-provider-account")],
    ),
  )
}

pub fn key() -> String {
  credentials.key("codex", "oauth", "selected")
}

pub fn store() -> storage.Store {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) = runtime_store.save(store, key(), material())
  store
}

pub fn context(mock: Mock, secure: Bool) -> contracts.Context {
  contracts.Context(
    "codex",
    "oauth",
    "selected",
    origin(mock, secure),
    "server-session",
    material(),
  )
}

pub fn origin(mock: Mock, secure: Bool) -> String {
  case secure {
    True -> "https://127.0.0.1:"
    False -> "http://127.0.0.1:"
  }
  <> int.to_string(mock.port)
}

pub fn request(body: String) -> contracts.Request {
  contracts.Request(
    "codex",
    "oauth",
    model,
    "responses",
    "responses",
    contracts.Streaming,
    [contracts.WebSocket],
    "server-session",
    None,
    body,
  )
}

pub fn create(previous: Option(String), marker: Bool) -> String {
  ir.stringify(
    ir.Object(list.append(
      [
        #("type", ir.String("response.create")),
        #("model", ir.String(model)),
        #("input", ir.Array([])),
      ],
      list.append(
        case previous {
          None -> []
          Some(id) -> [#("previous_response_id", ir.String(id))]
        },
        case marker {
          False -> []
          True -> [
            #(
              "client_metadata",
              ir.Object([
                #(
                  "ws_request_header_x_openai_internal_codex_responses_lite",
                  ir.Boolean(True),
                ),
              ]),
            ),
          ]
        },
      ),
    )),
  )
}

pub fn runtime(
  store: storage.Store,
  mock: Mock,
  secure: Bool,
) -> runtime.Runtime {
  runtime_for_model(store, mock, secure, model)
}

pub fn runtime_for_model(
  store: storage.Store,
  mock: Mock,
  secure: Bool,
  selected_model: String,
) -> runtime.Runtime {
  let assert Ok(entry) = models.lookup(models.pinned(), selected_model)
  let assert Ok(registered) = adapter.registration(entry)
  let assert Ok(registry) =
    registry.new([
      registry.Model(..registered, capabilities: [
        contracts.WebSocket,
        ..registered.capabilities
      ]),
    ])
  let selected =
    runtime.Account(
      "codex",
      "oauth",
      "selected",
      origin(mock, secure),
      case secure {
        True -> fleet.OperatorHttps
        False -> fleet.LocalLoopback
      },
      1,
      [selected_model],
      credentials.Refreshable(
        contracts.Refresh(fn(_, _) {
          // Synthetic unexpired material needs no refresh. An accidental refresh
          // must fail explicitly, never contact a provider or fabricate a grant.
          Error(contracts.RefreshUnsupported)
        }),
      ),
    )
  let assert Ok(runtime) =
    runtime.start(store, registry, [
      runtime.Account(
        ..selected,
        id: "absent",
        origin: "http://127.0.0.1:1",
        egress: fleet.LocalLoopback,
      ),
      selected,
    ])
  runtime
}
