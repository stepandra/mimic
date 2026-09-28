import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/protocol/responses/frames
import mimic/providers/ws_transport
import mimic/recorder/tls
import mimic/types.{Header}

type Fixture

@external(erlang, "mimic_provider_ws_transport_test_ffi", "start")
fn start(
  secure: Bool,
  cert: String,
  key: String,
  mode: String,
) -> Result(Fixture, String)

@external(erlang, "mimic_provider_ws_transport_test_ffi", "port")
fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_provider_ws_transport_test_ffi", "request")
fn request(fixture: Fixture) -> Option(String)

@external(erlang, "mimic_provider_ws_transport_test_ffi", "received")
fn received(fixture: Fixture) -> Option(BitArray)

@external(erlang, "mimic_provider_ws_transport_test_ffi", "was_closed")
fn was_closed(fixture: Fixture) -> Bool

@external(erlang, "mimic_provider_ws_transport_test_ffi", "stop")
fn stop(fixture: Fixture) -> Nil

@external(erlang, "mimic_recorder_tls_test_ffi", "new_ca_dir")
fn ca_directory() -> String

fn config(ca: Option(String)) -> ws_transport.Config {
  ws_transport.Config(ca, 2000, 100, 1024, 1024)
}

fn origin(fixture: Fixture, secure: Bool, host: String) -> String {
  let scheme = case secure {
    True -> "https://"
    False -> "http://"
  }
  scheme <> host <> ":" <> int.to_string(port(fixture))
}

fn open(
  fixture: Fixture,
  secure: Bool,
  ca: Option(String),
) -> Result(ws_transport.Connection, String) {
  let endpoint = origin(fixture, secure, "127.0.0.1")
  ws_transport.open(
    endpoint,
    endpoint,
    "/v1/responses?test=1",
    [
      Header("Authorization", "Bearer synthetic-only"),
      Header("Content-Type", "application/json"),
      Header("Accept", "application/json"),
      Header("OpenAI-Beta", "responses=v1"),
    ],
    config(ca),
  )
}

fn next_text(
  connection: ws_transport.Connection,
  attempts: Int,
) -> #(ws_transport.Connection, String) {
  let assert Ok(#(next, value)) = ws_transport.poll(connection)
  case value, attempts {
    Some(text), _ -> #(next, text)
    None, n if n > 0 -> next_text(next, n - 1)
    _, _ -> panic as "synthetic WS peer did not deliver text"
  }
}

fn wait_received(fixture: Fixture, attempts: Int) -> BitArray {
  case received(fixture), attempts {
    Some(value), _ -> value
    None, n if n > 0 -> {
      process.sleep(5)
      wait_received(fixture, n - 1)
    }
    _, _ -> panic as "synthetic WS peer did not receive client frame"
  }
}

fn wait_closed(fixture: Fixture, attempts: Int) {
  case was_closed(fixture), attempts {
    True, _ -> Nil
    False, n if n > 0 -> {
      process.sleep(5)
      wait_closed(fixture, n - 1)
    }
    _, _ -> panic as "socket was not closed after its owner exited"
  }
}

fn wait_error(connection: ws_transport.Connection, attempts: Int) -> String {
  case ws_transport.poll(connection) {
    Error(reason) -> reason
    Ok(#(next, _)) if attempts > 0 -> wait_error(next, attempts - 1)
    _ -> panic as "synthetic WS peer did not fail"
  }
}

pub fn loopback_upgrade_segmentation_control_and_mask_test() {
  let assert Ok(peer) = start(False, "", "", "segmented")
  let assert Ok(connection) = open(peer, False, None)
  let assert Some(raw) = request(peer)
  string.contains(raw, "GET /v1/responses?test=1 HTTP/1.1\r\n")
  |> should.be_true
  string.contains(raw, "Authorization: Bearer synthetic-only\r\n")
  |> should.be_true
  string.contains(
    raw,
    "Content-Type: application/json\r\nAccept: application/json\r\nOpenAI-Beta: responses=v1\r\n",
  )
  |> should.be_true
  let #(after_first, first) = next_text(connection, 20)
  first |> should.equal("€")
  let #(connection, second) = next_text(after_first, 20)
  second |> should.equal("OK")
  let pong = wait_received(peer, 50)
  let assert Ok(decoder) = frames.new(frames.Server, 1024, 1024)
  let assert Ok(#(_, [frames.Pong(<<"p">>)])) = frames.feed(decoder, pong)
  ws_transport.close(connection)
  stop(peer)
}

pub fn outbound_text_is_masked_and_idle_is_bounded_test() {
  let assert Ok(peer) = start(False, "", "", "idle")
  let assert Ok(connection) = open(peer, False, None)
  let assert Ok(#(idle, None)) = ws_transport.poll(connection)
  ws_transport.send(idle, "synthetic request") |> should.be_ok
  let frame = wait_received(peer, 50)
  let assert Ok(decoder) = frames.new(frames.Server, 1024, 1024)
  let assert Ok(#(_, [frames.Text("synthetic request")])) =
    frames.feed(decoder, frame)
  ws_transport.close(idle)
  stop(peer)
}

pub fn trusted_wss_upgrade_and_tls_fail_closed_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(ca_directory())
  let assert Ok(peer) = start(True, cert, key, "segmented")
  let assert Ok(connection) = open(peer, True, Some(cert))
  let #(connection, text) = next_text(connection, 20)
  text |> should.equal("€")
  ws_transport.close(connection)
  stop(peer)

  let assert Ok(untrusted) = start(True, cert, key, "idle")
  let assert Error(_) = open(untrusted, True, None)
  request(untrusted) |> should.equal(None)
  stop(untrusted)

  let assert Ok(hostname) = start(True, cert, key, "idle")
  let wrong = origin(hostname, True, "localhost")
  let assert Error(_) =
    ws_transport.open(wrong, wrong, "/", [], config(Some(cert)))
  request(hostname) |> should.equal(None)
  stop(hostname)
}

pub fn origin_target_and_reserved_header_guards_test() {
  let assert Ok(peer) = start(False, "", "", "idle")
  let endpoint = origin(peer, False, "127.0.0.1")
  let assert Error(_) =
    ws_transport.open(endpoint, endpoint <> "/", "/", [], config(None))
  let assert Error(_) =
    ws_transport.open(
      endpoint,
      endpoint,
      "https://elsewhere/",
      [],
      config(None),
    )
  let assert Error(_) =
    ws_transport.open(endpoint, endpoint, "/\r\nX: injection", [], config(None))
  let assert Error(_) =
    ws_transport.open(
      endpoint,
      endpoint,
      "/",
      [Header("SEC-WEBSOCKET-KEY", "override")],
      config(None),
    )
  let assert Error(_) =
    ws_transport.open(
      endpoint,
      endpoint,
      "/",
      [Header("Content-Length", "0")],
      config(None),
    )
  let non_loopback = "http://example.com:443"
  let assert Error(_) =
    ws_transport.open(non_loopback, non_loopback, "/", [], config(None))
  let websocket_scheme = "ws://127.0.0.1:443"
  let assert Error("WS origin must use http or https") =
    ws_transport.open(websocket_scheme, websocket_scheme, "/", [], config(None))
  let ipv6 = "http://[::1]:443"
  let assert Error("IPv6 WS origins are unsupported by the socket primitive") =
    ws_transport.open(ipv6, ipv6, "/", [], config(None))
  request(peer) |> should.equal(None)
  stop(peer)
}

pub fn invalid_upgrade_rejected_test() {
  [
    "bad_status", "bad_accept", "extension", "no_upgrade", "oversize",
    "aggregate",
  ]
  |> list.each(fn(mode) {
    let assert Ok(peer) = start(False, "", "", mode)
    let assert Error(_) = open(peer, False, None)
    stop(peer)
  })
}

pub fn handshake_deadline_and_frame_bounds_test() {
  let assert Ok(stalled) = start(False, "", "", "stall")
  let endpoint = origin(stalled, False, "127.0.0.1")
  let assert Error(_) =
    ws_transport.open(
      endpoint,
      endpoint,
      "/",
      [],
      ws_transport.Config(None, 20, 10, 1024, 1024),
    )
  stop(stalled)
  let assert Error("WS limits must be between 1 and 1048576 bytes") =
    ws_transport.open(
      endpoint,
      endpoint,
      "/",
      [],
      ws_transport.Config(None, 100, 10, 0, 1024),
    )
}

pub fn close_eof_and_mask_violation_are_terminal_test() {
  let assert Ok(closing) = start(False, "", "", "close")
  let assert Ok(connection) = open(closing, False, None)
  wait_error(connection, 10) |> should.equal("WS peer closed connection")
  let reply = wait_received(closing, 50)
  let assert Ok(decoder) = frames.new(frames.Server, 1024, 1024)
  let assert Ok(#(_, [frames.Close(Some(1000), Some(""))])) =
    frames.feed(decoder, reply)
  stop(closing)

  let assert Ok(eof) = start(False, "", "", "eof")
  let assert Ok(connection) = open(eof, False, None)
  let assert Error(_) = ws_transport.poll(connection)
  stop(eof)

  let assert Ok(masked) = start(False, "", "", "bad_frame")
  let assert Ok(connection) = open(masked, False, None)
  wait_error(connection, 10)
  |> should.equal("WS mask does not match endpoint role")
  stop(masked)
}

pub fn valid_prefix_is_delivered_before_later_bad_frame_test() {
  let assert Ok(peer) = start(False, "", "", "prefix_bad_frame")
  let assert Ok(connection) = open(peer, False, None)
  let #(connection, text) = next_text(connection, 10)
  text |> should.equal("OK")
  wait_error(connection, 10)
  |> should.equal("WS mask does not match endpoint role")
  stop(peer)
}

pub fn large_segmented_frame_and_oversized_frame_test() {
  let assert Ok(peer) = start(False, "", "", "large")
  let endpoint = origin(peer, False, "127.0.0.1")
  let assert Ok(connection) =
    ws_transport.open(
      endpoint,
      endpoint,
      "/",
      [],
      ws_transport.Config(None, 2000, 100, 65_536, 65_536),
    )
  let #(connection, text) = next_text(connection, 100)
  text |> should.equal(string.repeat("x", 65_536))
  ws_transport.close(connection)
  stop(peer)

  let assert Ok(too_large) = start(False, "", "", "limit")
  let assert Ok(connection) = open(too_large, False, None)
  wait_error(connection, 10) |> should.equal("WS frame exceeds byte limit")
  stop(too_large)
}

pub fn owning_process_death_closes_socket_test() {
  let assert Ok(peer) = start(False, "", "", "idle")
  let ready = process.new_subject()
  let _pid =
    process.spawn(fn() {
      let assert Ok(_connection) = open(peer, False, None)
      process.send(ready, Nil)
    })
  let assert Ok(Nil) = process.receive(ready, 2000)
  wait_closed(peer, 100)
  stop(peer)
}
