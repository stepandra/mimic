/// Real sockets through the isolated, authenticated Mist route hook.
/// All accounts, credentials, transcripts and origins are synthetic.
import argv
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/gateway/websocket as gateway_ws
import mimic/ingress/keys
import mimic/protocol/responses/frames
import mimic/providers/codex/adapter
import mimic/providers/codex/models
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mist

type Socket

type Peer {
  Peer(socket: Socket, decoder: frames.Decoder, pending: BitArray)
}

type Mock {
  Mock(
    listener: Socket,
    port: Int,
    pid: process.Pid,
    observed: process.Subject(String),
  )
}

type App {
  App(
    port: Int,
    pid: process.Pid,
    engine: runtime.Runtime,
    store: storage.Store,
  )
}

const create = "{\"type\":\"response.create\",\"model\":\"gpt-5.5\",\"input\":[]}"

const follow = "{\"type\":\"response.create\",\"model\":\"gpt-5.5\",\"input\":[],\"previous_response_id\":\"resp_ws\"}"

const created = "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}"

const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}"

const failed = "{\"type\":\"response.failed\",\"response\":{\"id\":\"resp_ws\",\"object\":\"response\",\"status\":\"failed\",\"output\":[],\"error\":{\"code\":\"synthetic\",\"message\":\"synthetic failure\"}}}"

fn mock(mode: String) -> Mock {
  let assert Ok(#(listener, port)) = listen()
  let observed = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() { accept_loop(listener, observed, mode) })
  Mock(listener, port, pid, observed)
}

fn accept_loop(
  listener: Socket,
  observed: process.Subject(String),
  mode: String,
) {
  case accept(listener) {
    Error(_) -> Nil
    Ok(socket) -> {
      let assert Ok(#(head, rest)) = head(socket)
      process.send(observed, head)
      let assert Ok(#(_, key_line)) =
        string.split_once(head, "Sec-WebSocket-Key: ")
      let assert Ok(#(key, _)) = string.split_once(key_line, "\r\n")
      let assert Ok(accept) = frames.accept_key(key)
      let upgrade =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
        <> accept
        <> "\r\n\r\n"
      let assert Ok(_) = write(socket, bit_array.from_string(upgrade))
      let assert Ok(decoder) = frames.new(frames.Server, 1_048_576, 1_048_576)
      mock_loop(Peer(socket, decoder, rest), observed, mode)
      close(socket)
      accept_loop(listener, observed, mode)
    }
  }
}

fn mock_loop(peer: Peer, observed: process.Subject(String), mode: String) {
  case next(peer) {
    Error(_) -> Nil
    Ok(#(_, frames.Close(_, _))) -> Nil
    Ok(#(peer, frames.Text(message))) -> {
      process.send(observed, message)
      case mode {
        "hold" -> Nil
        _ -> {
          let assert Ok(a) = frames.encode_text(frames.Server, created, None)
          let terminal = case mode {
            "failed" -> failed
            _ -> completed
          }
          let assert Ok(b) = frames.encode_text(frames.Server, terminal, None)
          let data = case mode {
            "malformed" -> <<a:bits, 131, 0>>
            "active" -> a
            _ -> <<a:bits, b:bits>>
          }
          let _ = write(peer.socket, data)
          mock_loop(peer, observed, mode)
        }
      }
    }
    Ok(#(peer, _)) -> mock_loop(peer, observed, mode)
  }
}

fn app(upstreams: List(Mock), enabled: Bool) -> App {
  let assert Ok(store) = storage.new(directory())
  keys.create(store.directory, "client-a", "synthetic-client-a")
  |> should.be_ok
  keys.create(store.directory, "client-b", "synthetic-client-b")
  |> should.be_ok
  let accounts =
    list.index_map(upstreams, fn(mock, index) {
      let id = int.to_string(index)
      let material =
        contracts.OAuth(
          contracts.OAuthData(
            auth.Credential(
              "synthetic-access-" <> id,
              "synthetic-refresh-" <> id,
              9_000_000_000_000,
            ),
            [#("chatgpt_account_id", "synthetic-account-" <> id)],
          ),
        )
      runtime_store.save(store, credentials.key("codex", "oauth", id), material)
      |> should.be_ok
      runtime.Account(
        "codex",
        "oauth",
        id,
        "http://127.0.0.1:" <> int.to_string(mock.port),
        fleet.LocalLoopback,
        1,
        ["gpt-5.5"],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      )
    })
  let catalog = models.pinned()
  let assert Ok(model) = models.lookup(catalog, "gpt-5.5")
  let assert Ok(registration) = adapter.registration(model)
  let assert Ok(registry) =
    registry.new([
      registry.Model(..registration, capabilities: [
        contracts.WebSocket,
        ..registration.capabilities
      ]),
    ])
  let assert Ok(engine) = runtime.start(store, registry, accounts)
  let settings =
    gateway_ws.Settings(
      catalog,
      "synthetic-ws-tests",
      case enabled {
        True -> ["gpt-5.5"]
        False -> []
      },
      None,
      fn() { False },
    )
  let ready = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(req) {
      case request.get_header(req, "authorization") {
        Ok("Bearer synthetic-client-a") ->
          gateway_ws.upgrade_authenticated(
            req,
            engine,
            "tenant-a",
            gateway_ws.Settings(..settings, authorized: fn() {
              keys.verify(store.directory, "synthetic-client-a") == Ok(True)
            }),
          )
        Ok("Bearer synthetic-client-b") ->
          gateway_ws.upgrade_authenticated(
            req,
            engine,
            "tenant-b",
            gateway_ws.Settings(..settings, authorized: fn() {
              keys.verify(store.directory, "synthetic-client-b") == Ok(True)
            }),
          )
        _ ->
          response.new(401) |> response.set_body(mist.Bytes(bytes_tree.new()))
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ready, 1000)
  App(port, server.pid, engine, store)
}

fn connect_client(
  app: App,
  token: String,
  extras: String,
  first: BitArray,
) -> #(String, Peer) {
  let assert Ok(socket) = connect(app.port)
  let raw =
    "GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer "
    <> token
    <> "\r\n"
    <> extras
    <> "\r\n"
  let assert Ok(_) = write(socket, <<raw:utf8, first:bits>>)
  let assert Ok(#(head, rest)) = head(socket)
  string.starts_with(head, "HTTP/1.1 101 Switching Protocols")
  |> should.be_true
  let assert Ok(accept_line) =
    list.find(string.split(head, "\r\n"), fn(line) {
      string.starts_with(string.lowercase(line), "sec-websocket-accept:")
    })
  let assert Ok(#(_, accept)) = string.split_once(accept_line, ":")
  string.trim(accept) |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  let assert Ok(decoder) = frames.new(frames.Client, 1_048_576, 1_048_576)
  #(head, Peer(socket, decoder, rest))
}

// Integration delta for pinned Mist: ambiguity can close the socket before
// emitting HTTP headers. Only a confirmed peer close is rejection; timeout,
// connect failure, send failure and other setup errors must fail the test.
fn connect_rejected(app: App, token: String, version: String, extras: String) {
  let assert Ok(socket) = connect(app.port)
  let raw =
    "GET /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: "
    <> version
    <> "\r\nAuthorization: Bearer "
    <> token
    <> "\r\n"
    <> extras
    <> "\r\n"
  write(socket, bit_array.from_string(raw)) |> should.be_ok
  let assert Ok(reply) = rejection(socket)
  {
    reply == "peer closed"
    || string.starts_with(reply, "HTTP/1.1 400 ")
    || string.starts_with(reply, "HTTP/1.1 401 ")
  }
  |> should.be_true
  close(socket)
}

pub fn rejection_fixture_timeout_is_not_a_peer_close_test() {
  let assert Ok(#(listener, port)) = listen()
  let assert Ok(socket) = connect(port)
  rejection(socket) |> should.equal(Error("fixture rejection timed out"))
  close(socket)
  close(listener)
}

fn send_create(peer: Peer, text: String) {
  let assert Ok(bytes) =
    frames.encode_text(frames.Client, text, Some(<<1, 2, 3, 4>>))
  write(peer.socket, bytes) |> should.be_ok
}

fn next(peer: Peer) -> Result(#(Peer, frames.Event), String) {
  let bytes = case peer.pending {
    <<>> -> read(peer.socket)
    bytes -> Ok(bytes)
  }
  case bytes {
    Error(error) -> Error(error)
    Ok(bytes) ->
      case frames.feed_one(peer.decoder, bytes) {
        Error(error) -> Error(error)
        Ok(#(decoder, event, rest)) -> {
          let peer = Peer(..peer, decoder: decoder, pending: rest)
          case event {
            None -> next(peer)
            Some(event) -> Ok(#(peer, event))
          }
        }
      }
  }
}

fn completed_turn(peer: Peer) -> Peer {
  let assert Ok(#(peer, frames.Text(a))) = next(peer)
  string.contains(a, "\"response.created\"") |> should.be_true
  let assert Ok(#(peer, frames.Text(b))) = next(peer)
  string.contains(b, "\"response.completed\"") |> should.be_true
  peer
}

fn stop_app(app: App, mocks: List(Mock)) {
  // Mist supervisor shutdown terminates its temporary WS owners; guardian
  // process-death cleanup releases upstream sockets/leases.
  process.send_exit(app.pid)
  await_leases(app.engine, 0, 100)
  runtime.stop(app.engine) |> should.be_ok
  list.each(mocks, fn(mock) {
    close(mock.listener)
    process.kill(mock.pid)
  })
}

fn await_leases(engine: runtime.Runtime, wanted: Int, attempts: Int) {
  case runtime.active_leases(engine) {
    Ok(value) if value == wanted -> Nil
    _ if attempts > 0 -> {
      process.sleep(10)
      await_leases(engine, wanted, attempts - 1)
    }
    _ -> panic as "WebSocket lease did not settle"
  }
}

pub fn real_upgrade_coalesced_create_continuation_full_history_and_idle_cancel_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let assert Ok(frame) =
    frames.encode_text(frames.Client, create, Some(<<5, 6, 7, 8>>))
  let #(head, peer) = connect_client(app, "synthetic-client-a", "", frame)
  string.starts_with(head, "HTTP/1.1 101") |> should.be_true
  string.contains(head, "sec-websocket-extensions") |> should.be_false
  let peer = completed_turn(peer)
  let assert Ok(handshake) = process.receive(upstream.observed, 1000)
  string.contains(handshake, "GET /backend-api/codex/responses HTTP/1.1")
  |> should.be_true
  string.contains(handshake, "Authorization: Bearer synthetic-access-0")
  |> should.be_true
  string.contains(handshake, "responses_websockets=2026-02-06")
  |> should.be_true
  let assert Ok(first) = process.receive(upstream.observed, 1000)
  string.contains(first, "\"type\":\"response.create\"") |> should.be_true
  send_create(peer, follow)
  let peer = completed_turn(peer)
  let assert Ok(second) = process.receive(upstream.observed, 1000)
  string.contains(second, "\"previous_response_id\":\"resp_ws\"")
  |> should.be_true
  send_create(peer, create)
  let peer = completed_turn(peer)
  let assert Ok(third) = process.receive(upstream.observed, 1000)
  string.contains(third, "previous_response_id") |> should.be_false
  let assert Ok(cancel) =
    frames.encode_close(frames.Client, Some(1000), "", Some(<<1, 2, 3, 4>>))
  write(peer.socket, cancel) |> should.be_ok
  let assert Ok(#(_, frames.Close(Some(1000), _))) = next(peer)
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

pub fn authentication_opt_in_origin_and_extensions_reject_before_upstream_test() {
  let upstream = mock("complete")
  let disabled = app([upstream], False)
  connect_rejected(disabled, "synthetic-client-a", "13", "")
  stop_app(disabled, [])
  let enabled = app([upstream], True)
  list.each(
    [
      #("invalid", "13", ""),
      #(
        "synthetic-client-a",
        "13",
        "Sec-WebSocket-Extensions: permessage-deflate\r\n",
      ),
      #("synthetic-client-a", "13", "Origin: https://unapproved.invalid\r\n"),
      #("synthetic-client-a", "12", ""),
      #("synthetic-client-a", "13", "Sec-WebSocket-Version: 12\r\n"),
      #("synthetic-client-a", "12", "Sec-WebSocket-Version: 13\r\n"),
    ],
    fn(input) { connect_rejected(enabled, input.0, input.1, input.2) },
  )
  process.receive(upstream.observed, 30) |> should.be_error
  runtime.active_leases(enabled.engine) |> should.equal(Ok(0))
  stop_app(enabled, [upstream])
}

pub fn revoked_key_cannot_send_again_on_existing_socket_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let assert Ok(frame) =
    frames.encode_text(frames.Client, create, Some(<<5, 6, 7, 8>>))
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", frame)
  let peer = completed_turn(peer)
  process.receive(upstream.observed, 1000) |> should.be_ok
  process.receive(upstream.observed, 1000) |> should.be_ok
  keys.revoke(app.store.directory, "client-a") |> should.be_ok
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(error))) = next(peer)
  string.contains(error, "\"type\":\"error\"") |> should.be_true
  string.contains(error, "synthetic-client-a") |> should.be_false
  let assert Ok(#(_, frames.Close(Some(1011), _))) = next(peer)
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  process.receive(upstream.observed, 30) |> should.be_error
  let #(_, other) = connect_client(app, "synthetic-client-b", "", frame)
  let other = completed_turn(other)
  close(other.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

pub fn revoked_after_upgrade_cannot_open_first_upstream_session_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  keys.revoke(app.store.directory, "client-a") |> should.be_ok
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(error))) = next(peer)
  string.contains(error, "\"type\":\"error\"") |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  process.receive(upstream.observed, 30) |> should.be_error
  stop_app(app, [upstream])
}

pub fn failed_terminal_cannot_grant_a_previous_response_receipt_test() {
  let upstream = mock("failed")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(_))) = next(peer)
  let assert Ok(#(peer, frames.Text(message))) = next(peer)
  string.contains(message, "\"response.failed\"") |> should.be_true
  send_create(peer, follow)
  let assert Ok(#(peer, frames.Text(message))) = next(peer)
  string.contains(message, "\"websocket_failed\"") |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

pub fn two_clients_accounts_and_reconnect_receipts_are_isolated_test() {
  let first = mock("complete")
  let second = mock("complete")
  let app = app([first, second], True)
  let #(_, a) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(a, create)
  let a = completed_turn(a)
  let #(_, b) = connect_client(app, "synthetic-client-b", "", <<>>)
  send_create(b, follow)
  let assert Ok(#(b, frames.Text(error))) = next(b)
  string.contains(error, "\"websocket_failed\"") |> should.be_true
  close(b.socket)
  process.receive(second.observed, 30) |> should.be_error
  let #(_, b) = connect_client(app, "synthetic-client-b", "", <<>>)
  send_create(b, create)
  let b = completed_turn(b)
  let assert Ok(ha) = process.receive(first.observed, 1000)
  let assert Ok(hb) = process.receive(second.observed, 1000)
  string.contains(ha, "synthetic-access-0") |> should.be_true
  string.contains(ha, "synthetic-access-1") |> should.be_false
  string.contains(hb, "synthetic-access-1") |> should.be_true
  string.contains(hb, "synthetic-access-0") |> should.be_false
  close(a.socket)
  close(b.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [first, second])
}

pub fn valid_started_prefix_survives_malformed_frame_then_no_replay_test() {
  let upstream = mock("malformed")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(event))) = next(peer)
  string.contains(event, "\"response.created\"") |> should.be_true
  let assert Ok(#(peer, frames.Text(error))) = next(peer)
  string.contains(error, "\"websocket_failed\"") |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  let assert Ok(_) = process.receive(upstream.observed, 1000)
  let assert Ok(_) = process.receive(upstream.observed, 1000)
  process.receive(upstream.observed, 30) |> should.be_error
  stop_app(app, [upstream])
}

pub fn active_cancel_and_normal_server_shutdown_release_real_sockets_test() {
  let upstream = mock("active")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(_))) = next(peer)
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let assert Ok(#(_, frames.Text(_))) = next(peer)
  stop_app(app, [upstream])
  read(peer.socket) |> should.be_error
  close(peer.socket)
}

pub fn credential_rotation_invalidates_real_socket_before_continuation_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let peer = completed_turn(peer)
  let assert Ok(_) = process.receive(upstream.observed, 1000)
  let assert Ok(_) = process.receive(upstream.observed, 1000)
  let rotated =
    contracts.OAuth(
      contracts.OAuthData(
        auth.Credential(
          "synthetic-rotated",
          "synthetic-rotated-refresh",
          9_000_000_000_000,
        ),
        [#("chatgpt_account_id", "synthetic-account-0")],
      ),
    )
  runtime_store.save(app.store, credentials.key("codex", "oauth", "0"), rotated)
  |> should.be_ok
  send_create(peer, follow)
  let assert Ok(#(peer, frames.Text(error))) = next(peer)
  string.contains(error, "\"websocket_failed\"") |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  process.receive(upstream.observed, 30) |> should.be_error
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let peer = completed_turn(peer)
  let assert Ok(handshake) = process.receive(upstream.observed, 1000)
  string.contains(handshake, "Authorization: Bearer synthetic-rotated\r\n")
  |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

pub fn main() {
  case argv.load().arguments {
    ["--probe"] -> handshake_probe(False)
    ["--strict"] -> handshake_probe(True)
    _ -> scenario()
  }
}

fn scenario() {
  real_upgrade_coalesced_create_continuation_full_history_and_idle_cancel_test()
  active_cancel_and_normal_server_shutdown_release_real_sockets_test()
  fragmented_create_and_interleaved_control_use_bounded_server_decoder_test()
  downstream_aggregate_limit_and_invalid_utf8_fail_before_provider_effects_test()
  before_output_disconnect_is_terminal_and_never_replayed_test()
  credential_rotation_invalidates_real_socket_before_continuation_test()
  io.println(
    "{\"synthetic\":true,\"gateway_hook\":true,\"real_websocket\":true,\"live_provider\":false}",
  )
}

/// Diagnostic, NOT an acceptance assertion. The inherited Mist parser loses
/// raw duplicate headers/version before the application hook sees a Request.
fn handshake_probe(strict: Bool) {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let normal =
    "Host: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer synthetic-client-a\r\n"
  list.each(
    [
      #("normal", "1.1", normal),
      #(
        "auth_valid_invalid",
        "1.1",
        normal <> "authorization: Bearer invalid\r\n",
      ),
      #(
        "auth_invalid_valid",
        "1.1",
        "aUtHoRiZaTiOn: Bearer invalid\r\n" <> normal,
      ),
      #("upgrade_valid_invalid", "1.1", normal <> "UPGRADE: invalid\r\n"),
      #("upgrade_invalid_valid", "1.1", "upgrade: invalid\r\n" <> normal),
      #("key_valid_invalid", "1.1", normal <> "sec-websocket-key: bad\r\n"),
      #("key_invalid_valid", "1.1", "Sec-WebSocket-Key: bad\r\n" <> normal),
      #(
        "version_valid_invalid",
        "1.1",
        normal <> "sec-websocket-version: 12\r\n",
      ),
      #(
        "version_invalid_valid",
        "1.1",
        "Sec-WebSocket-Version: 12\r\n" <> normal,
      ),
      #("http_1_0", "1.0", normal),
    ],
    fn(probe) {
      let assert Ok(socket) = connect(app.port)
      let raw =
        "GET /v1/responses HTTP/" <> probe.1 <> "\r\n" <> probe.2 <> "\r\n"
      write(socket, bit_array.from_string(raw)) |> should.be_ok
      let assert Ok(reply) = rejection(socket)
      let status = case string.split_once(reply, "\r\n") {
        Ok(#(status, _)) -> status
        Error(_) if reply == "peer closed" -> "closed without upgrade"
        Error(_) -> panic as "malformed handshake reply"
      }
      io.println(probe.0 <> ": " <> status)
      case strict {
        True ->
          string.contains(status, "101 Switching")
          |> should.equal(probe.0 == "normal")
        False -> Nil
      }
      close(socket)
    },
  )
  process.receive(upstream.observed, 30) |> should.be_error
  stop_app(app, [upstream])
}

pub fn fragmented_create_and_interleaved_control_use_bounded_server_decoder_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  let assert <<first:bits-size(160), rest:bits>> = bit_array.from_string(create)
  let wire = <<
    1,
    148,
    0,
    0,
    0,
    0,
    first:bits,
    137,
    129,
    0,
    0,
    0,
    0,
    112,
    128,
    { 128 + bit_array.byte_size(rest) },
    0,
    0,
    0,
    0,
    rest:bits,
  >>
  send_split(peer.socket, wire)
  let assert Ok(#(peer, frames.Pong(<<"p">>))) = next(peer)
  let peer = completed_turn(peer)
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

fn send_split(socket: Socket, bytes: BitArray) {
  case bytes {
    <<>> -> Nil
    <<byte, rest:bits>> -> {
      write(socket, <<byte>>) |> should.be_ok
      send_split(socket, rest)
    }
    _ -> panic as "synthetic byte-aligned frame required"
  }
}

pub fn downstream_aggregate_limit_and_invalid_utf8_fail_before_provider_effects_test() {
  let upstream = mock("complete")
  let app = app([upstream], True)
  let assert Ok(<<129, fragment:bits>>) =
    frames.encode_text(
      frames.Client,
      string.repeat("x", 600_000),
      Some(<<0, 0, 0, 0>>),
    )
  list.each(
    [
      <<1, fragment:bits, 128, fragment:bits>>,
      <<129, 129, 0, 0, 0, 0, 255>>,
      <<129, 2, 123, 125>>,
    ],
    fn(bytes) {
      let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
      write(peer.socket, bytes) |> should.be_ok
      let assert Ok(#(peer, frames.Text(error))) = next(peer)
      string.contains(error, "\"websocket_failed\"") |> should.be_true
      close(peer.socket)
    },
  )
  process.receive(upstream.observed, 30) |> should.be_error
  await_leases(app.engine, 0, 100)
  stop_app(app, [upstream])
}

pub fn before_output_disconnect_is_terminal_and_never_replayed_test() {
  let upstream = mock("hold")
  let other = mock("complete")
  let app = app([upstream, other], True)
  let #(_, peer) = connect_client(app, "synthetic-client-a", "", <<>>)
  send_create(peer, create)
  let assert Ok(#(peer, frames.Text(error))) = next(peer)
  string.contains(error, "\"websocket_failed\"") |> should.be_true
  close(peer.socket)
  await_leases(app.engine, 0, 100)
  process.receive(other.observed, 30) |> should.be_error
  stop_app(app, [upstream, other])
}

@external(erlang, "mimic_gateway_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_gateway_ws_test_ffi", "listen")
fn listen() -> Result(#(Socket, Int), String)

@external(erlang, "mimic_gateway_ws_test_ffi", "accept")
fn accept(socket: Socket) -> Result(Socket, String)

@external(erlang, "mimic_gateway_ws_test_ffi", "connect")
fn connect(port: Int) -> Result(Socket, String)

@external(erlang, "mimic_gateway_ws_test_ffi", "write")
fn write(socket: Socket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_gateway_ws_test_ffi", "read")
fn read(socket: Socket) -> Result(BitArray, String)

@external(erlang, "mimic_gateway_ws_test_ffi", "head")
fn head(socket: Socket) -> Result(#(String, BitArray), String)

@external(erlang, "mimic_gateway_ws_test_ffi", "close")
fn close(socket: Socket) -> Nil

@external(erlang, "mimic_gateway_ws_rejection_test_ffi", "rejection")
fn rejection(socket: Socket) -> Result(String, String)
