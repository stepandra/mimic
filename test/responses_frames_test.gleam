import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/protocol/responses/frames
import mimic/protocol/responses/websocket
import mimic/types.{Header}

pub type Socket

@external(erlang, "mimic_responses_ws_test_ffi", "listen")
fn listen() -> Result(#(Socket, Int), String)

@external(erlang, "mimic_responses_ws_test_ffi", "connect")
fn connect(port: Int) -> Result(Socket, String)

@external(erlang, "mimic_responses_ws_test_ffi", "accept")
fn accept(listener: Socket) -> Result(Socket, String)

@external(erlang, "mimic_responses_ws_test_ffi", "send")
fn send(socket: Socket, bytes: BitArray) -> Result(Nil, String)

@external(erlang, "mimic_responses_ws_test_ffi", "recv_exact")
fn recv_exact(socket: Socket, count: Int) -> Result(BitArray, String)

@external(erlang, "mimic_responses_ws_test_ffi", "close")
fn close(socket: Socket) -> Nil

// All wire fixtures are synthetic; zero masks here are for deterministic tests,
// never production client keys.
fn server(max_frame: Int, max_message: Int) -> frames.Decoder {
  let assert Ok(decoder) = frames.new(frames.Server, max_frame, max_message)
  decoder
}

fn client(max_frame: Int, max_message: Int) -> frames.Decoder {
  let assert Ok(decoder) = frames.new(frames.Client, max_frame, max_message)
  decoder
}

fn zero_masked(first: Int, payload: BitArray) -> BitArray {
  let length = bit_array.byte_size(payload)
  let second = 128 + length
  <<first, second, 0, 0, 0, 0, payload:bits>>
}

fn split_feed(
  decoder: frames.Decoder,
  bytes: BitArray,
  events: List(frames.Event),
) -> #(frames.Decoder, List(frames.Event)) {
  case bytes {
    <<>> -> #(decoder, events)
    <<byte:8, rest:bits>> -> {
      let assert Ok(#(next, received)) = frames.feed(decoder, <<byte>>)
      split_feed(next, rest, list.append(events, received))
    }
    _ -> panic as "synthetic fixture must be byte aligned"
  }
}

pub fn fragmented_utf8_and_interleaved_control_test() {
  let frames_bytes =
    bit_array.concat([
      zero_masked(1, <<226>>),
      zero_masked(137, <<"p">>),
      zero_masked(0, <<130>>),
      zero_masked(138, <<"q">>),
      zero_masked(128, <<172>>),
    ])
  let #(_, events) = split_feed(server(125, 3), frames_bytes, [])
  events
  |> should.equal([
    frames.Ping(<<"p">>),
    frames.Pong(<<"q">>),
    frames.Text("€"),
  ])
}

pub fn client_mask_encoder_and_role_decoder_test() {
  let assert Ok(wire) =
    frames.encode_text(frames.Client, "Hi", Some(<<1, 2, 3, 4>>))
  wire |> should.equal(<<129, 130, 1, 2, 3, 4, 73, 107>>)
  let assert Ok(#(_, [frames.Text(text)])) = frames.feed(server(10, 10), wire)
  text |> should.equal("Hi")
  let assert Ok(server_wire) = frames.encode_text(frames.Server, "Hi", None)
  server_wire |> should.equal(<<129, 2, 72, 105>>)
  let assert Ok(#(_, [frames.Text("Hi")])) =
    frames.feed(client(10, 10), server_wire)
}

pub fn extended_lengths_and_arbitrary_chunk_test() {
  let long = "abcdefghijklmnopqrst"
  let assert Ok(wire) = frames.encode_text(frames.Server, long, None)
  let assert Ok(#(_, [frames.Text(value)])) = frames.feed(client(20, 20), wire)
  value |> should.equal(long)
  let assert Ok(long_wire) =
    frames.encode_text(
      frames.Server,
      "x" <> long <> long <> long <> long <> long <> long <> long,
      None,
    )
  let assert #(_, [frames.Text(same)]) =
    split_feed(client(141, 141), long_wire, [])
  same
  |> should.equal("x" <> long <> long <> long <> long <> long <> long <> long)
  let wide = string.repeat("x", 65_536)
  let assert Ok(wide_wire) = frames.encode_text(frames.Server, wide, None)
  let assert <<129, 127, 65_536:64, _:bits>> = wide_wire
  let assert Ok(#(_, [frames.Text(decoded)])) =
    frames.feed(client(65_536, 65_536), wide_wire)
  decoded |> should.equal(wide)
}

pub fn completed_utf8_only_test() {
  let assert Error("WS text message is not UTF-8") =
    frames.feed(server(10, 10), zero_masked(129, <<255>>))
  let assert Ok(#(partial, [])) =
    frames.feed(server(10, 10), zero_masked(1, <<226>>))
  let assert Error("WS text message is not UTF-8") =
    frames.feed(partial, zero_masked(128, <<130>>))
  let empty_frames =
    bit_array.concat([
      zero_masked(1, <<>>),
      zero_masked(0, <<>>),
      zero_masked(128, <<>>),
    ])
  let assert Ok(#(_, [frames.Text("")])) =
    frames.feed(server(1, 1), empty_frames)
}

pub fn close_validation_and_terminal_state_test() {
  let assert Ok(wire) =
    frames.encode_close(frames.Server, Some(1000), "done", None)
  let assert Ok(#(closed, [frames.Close(Some(1000), Some("done"))])) =
    frames.feed(client(125, 125), wire)
  let assert Ok(#(_, [])) = frames.feed(closed, <<>>)
  let assert Error("WS bytes after close") = frames.feed(closed, <<129, 0>>)
  let assert Error("WS bytes after close") =
    frames.feed(client(125, 125), <<136, 0, 137, 0>>)
  let assert Ok(#(_, [frames.Close(None, None)])) =
    frames.feed(client(125, 125), <<136, 0>>)
  let assert Error("WS close payload is missing status byte") =
    frames.feed(client(125, 125), <<136, 1, 3>>)
  let assert Error("WS invalid close code") =
    frames.feed(client(125, 125), <<136, 2, 3, 237>>)
  let assert Error("WS close reason is not UTF-8") =
    frames.feed(client(125, 125), <<136, 3, 3, 232, 255>>)
}

pub fn opcodes_control_and_fragmentation_order_test() {
  let assert Error("WS reserved bits are unsupported") =
    frames.feed(client(10, 10), <<193, 0>>)
  let assert Error("WS reserved opcode") =
    frames.feed(client(10, 10), <<131, 0>>)
  let assert Error(
    "WS continuation order invalid or binary message unsupported",
  ) = frames.feed(client(10, 10), <<130, 0>>)
  let assert Error(
    "WS continuation order invalid or binary message unsupported",
  ) = frames.feed(client(10, 10), <<128, 0>>)
  let assert Error("WS control frame must be final and at most 125 bytes") =
    frames.feed(client(10, 10), <<9, 0>>)
  let assert Error("WS control frame must be final and at most 125 bytes") =
    frames.feed(client(200, 200), <<137, 126>>)
  let assert Ok(#(state, [])) = frames.feed(client(10, 10), <<1, 1, 65>>)
  let assert Error(
    "WS continuation order invalid or binary message unsupported",
  ) = frames.feed(state, <<129, 0>>)
}

pub fn limits_and_nonminimal_lengths_test() {
  let assert Error("WS limits must be between 1 and 1048576 bytes") =
    frames.new(frames.Client, 0, 1)
  let assert Error("WS limits must be between 1 and 1048576 bytes") =
    frames.new(frames.Client, 1_048_577, 1)
  let assert Error("WS frame exceeds byte limit") =
    frames.feed(client(2, 10), <<129, 3>>)
  let assert Error("WS message exceeds byte limit") =
    frames.feed(client(10, 2), <<129, 3>>)
  let assert Ok(#(partial, [])) = frames.feed(client(10, 2), <<1, 2, 65, 66>>)
  let assert Error("WS message exceeds byte limit") =
    frames.feed(partial, <<128, 1>>)
  let assert Error("WS nonminimal or invalid extended length") =
    frames.feed(client(200, 200), <<129, 126, 0, 125>>)
  let assert Error("WS nonminimal or invalid extended length") =
    frames.feed(client(100_000, 100_000), <<
      129,
      127,
      0,
      0,
      0,
      0,
      0,
      0,
      255,
      255,
    >>)
  let assert Error("WS nonminimal or invalid extended length") =
    frames.feed(client(100_000, 100_000), <<129, 127, 128, 0, 0, 0, 0, 0, 0, 0>>)
  let assert Error("WS frame exceeds byte limit") =
    frames.feed(client(10, 10), <<129, 127, 0, 0, 0, 0, 0, 1, 0, 0>>)
}

pub fn mask_rules_and_encoder_guards_test() {
  let assert Error("WS input must be byte aligned") =
    frames.feed(client(10, 10), <<1:1>>)
  let assert Error("WS mask does not match endpoint role") =
    frames.feed(server(10, 10), <<129, 0>>)
  let assert Error("WS mask does not match endpoint role") =
    frames.feed(client(10, 10), zero_masked(129, <<>>))
  let assert Error("WS mask does not match endpoint role") =
    frames.encode_text(frames.Client, "hi", None)
  let assert Error("WS client mask must contain four bytes") =
    frames.encode_text(frames.Client, "hi", Some(<<1, 2, 3>>))
  let assert Error("WS mask does not match endpoint role") =
    frames.encode_text(frames.Server, "hi", Some(<<1, 2, 3, 4>>))
  let assert Error("WS control frame exceeds 125 bytes") =
    frames.encode_ping(frames.Server, <<0:1024>>, None)
  let assert Error("WS close reason requires a status code") =
    frames.encode_close(frames.Server, None, "oops", None)
  let assert Error("WS invalid close code") =
    frames.encode_close(frames.Server, Some(1006), "", None)
  let assert Error("WS encoded frame exceeds byte limit") =
    frames.encode_text(frames.Server, string.repeat("x", 1_048_577), None)
}

pub fn handshake_rfc6455_vector_test() {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let assert Ok(accept) = frames.accept_key(key)
  accept |> should.equal("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  let assert Ok(Nil) = frames.verify_accept(key, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  let assert Error("WS accept key mismatch") =
    frames.verify_accept(key, "not the server's proof")
  let assert Error("WS key must be canonical base64 of 16 bytes") =
    frames.accept_key("YQ==")
}

/// Real local TCP read/write; synthetic HTTP Upgrade bytes and codec frames.
/// This does not expose a listener route or claim production WS availability.
pub fn synthetic_loopback_websocket_mock_test() {
  let assert Ok(#(listener, port)) = listen()
  let assert Ok(client_socket) = connect(port)
  let assert Ok(server_socket) = accept(listener)
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let request =
    bit_array.from_string(
      "GET /mock HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: "
      <> key
      <> "\r\n\r\n",
    )
  let assert Ok(Nil) = send(client_socket, request)
  let assert Ok(received_request) =
    recv_exact(server_socket, bit_array.byte_size(request))
  received_request |> should.equal(request)
  let assert Ok(accept_value) = frames.accept_key(key)
  let response =
    bit_array.from_string(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
      <> accept_value
      <> "\r\n\r\n",
    )
  let assert Ok(Nil) = send(server_socket, response)
  let assert Ok(received_response) =
    recv_exact(client_socket, bit_array.byte_size(response))
  received_response |> should.equal(response)
  let assert Ok(Nil) = frames.verify_accept(key, accept_value)
  let scope =
    websocket.Scope(
      "tenant",
      "mock",
      "credential",
      "account",
      "synthetic",
      "session",
    )
  let assert Ok(session) = websocket.new(scope, "trusted-generation")
  let create =
    "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[]}"
  let assert Ok(request_frame) =
    frames.encode_text(frames.Client, create, Some(<<1, 2, 3, 4>>))
  let assert Ok(Nil) = send(client_socket, request_frame)
  let assert Ok(received_frame) =
    recv_exact(server_socket, bit_array.byte_size(request_frame))
  let #(server_decoder, requests) =
    split_feed(server(4096, 4096), received_frame, [])
  let assert [frames.Text(received_create)] = requests
  let assert Ok(#(session, _)) =
    websocket.create(session, scope, "trusted-generation", received_create)
  let messages = [
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_local_ws\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}",
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_local_ws\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}",
  ]
  let #(session, client_decoder) =
    list.fold(messages, #(session, client(4096, 4096)), fn(acc, text) {
      let assert Ok(frame) = frames.encode_text(frames.Server, text, None)
      let assert Ok(Nil) = send(server_socket, frame)
      let assert Ok(received) =
        recv_exact(client_socket, bit_array.byte_size(frame))
      let #(decoder, events) = split_feed(acc.1, received, [])
      let assert [frames.Text(message)] = events
      let assert Ok(#(session, _)) =
        websocket.receive(acc.0, scope, "trusted-generation", message)
      #(session, decoder)
    })
  let continuation =
    "{\"type\":\"response.create\",\"model\":\"synthetic\",\"previous_response_id\":\"resp_local_ws\",\"input\":[]}"
  let assert Ok(frame) =
    frames.encode_text(frames.Client, continuation, Some(<<5, 6, 7, 8>>))
  let assert Ok(Nil) = send(client_socket, frame)
  let assert Ok(received) =
    recv_exact(server_socket, bit_array.byte_size(frame))
  let #(server_decoder, events) = split_feed(server_decoder, received, [])
  let assert [frames.Text(message)] = events
  let assert Ok(#(active, request)) =
    websocket.create(session, scope, "trusted-generation", message)
  request.previous_response_id |> should.equal(Some("resp_local_ws"))
  let #(closed, should_close) = websocket.cancel(active)
  should_close |> should.be_true
  websocket.cancel(closed).1 |> should.be_false
  let assert Ok(frame) =
    frames.encode_close(
      frames.Client,
      Some(1000),
      "synthetic cancellation",
      Some(<<9, 10, 11, 12>>),
    )
  let assert Ok(Nil) = send(client_socket, frame)
  let assert Ok(received) =
    recv_exact(server_socket, bit_array.byte_size(frame))
  let #(server_decoder, events) = split_feed(server_decoder, received, [])
  events
  |> should.equal([frames.Close(Some(1000), Some("synthetic cancellation"))])
  frames.finish(server_decoder) |> should.be_ok
  let assert Ok(frame) =
    frames.encode_close(frames.Server, Some(1000), "", None)
  let assert Ok(Nil) = send(server_socket, frame)
  let assert Ok(received) =
    recv_exact(client_socket, bit_array.byte_size(frame))
  let #(client_decoder, _) = split_feed(client_decoder, received, [])
  frames.finish(client_decoder) |> should.be_ok
  close(client_socket)
  close(server_socket)
  close(listener)
}

pub fn eof_must_not_accept_partial_frames_or_missing_close_test() {
  frames.finish(client(1024, 1024)) |> should.be_error
  let assert Ok(#(decoder, _)) = frames.feed(client(1024, 1024), <<129>>)
  frames.finish(decoder) |> should.be_error
  let assert Ok(#(decoder, _)) = frames.feed(client(1024, 1024), <<1, 1, 120>>)
  frames.finish(decoder) |> should.be_error
  let assert Ok(frame) =
    frames.encode_close(frames.Server, Some(1000), "", None)
  let assert Ok(#(decoder, _)) = frames.feed(decoder, frame)
  frames.finish(decoder) |> should.be_ok
}

pub fn non_byte_aligned_control_payload_rejected_test() {
  frames.encode_ping(frames.Server, <<1:1>>, None) |> should.be_error
  frames.encode_pong(frames.Client, <<1:1>>, Some(<<1, 2, 3, 4>>))
  |> should.be_error
}

pub fn handshake_headers_enforce_version_tokens_duplicates_and_extensions_test() {
  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  let headers = [
    Header("Upgrade", "websocket"),
    Header("Connection", "keep-alive, Upgrade"),
    Header("Sec-WebSocket-Version", "13"),
    Header("Sec-WebSocket-Key", key),
  ]
  let assert Ok(reply) = frames.server_upgrade("GET", headers)
  frames.client_upgrade(101, reply, key) |> should.be_ok
  frames.server_upgrade("POST", headers) |> should.be_error
  frames.server_upgrade("GET", [Header("Sec-WebSocket-Key", key), ..headers])
  |> should.be_error
  frames.server_upgrade("GET", [
    Header("Sec-WebSocket-Protocol", "unknown"),
    ..headers
  ])
  |> should.be_error
  frames.client_upgrade(200, reply, key) |> should.be_error
  frames.client_upgrade(
    101,
    [Header("Sec-WebSocket-Extensions", "permessage-deflate"), ..reply],
    key,
  )
  |> should.be_error
}

/// Standalone real-loopback scenario; not an assembled route conformance driver.
pub fn main() {
  synthetic_loopback_websocket_mock_test()
  io.println(
    ir.stringify(
      ir.Object([
        #("synthetic", ir.Boolean(True)),
        #("assembled_ingress", ir.Boolean(False)),
        #("real_loopback_websocket", ir.Boolean(True)),
        #(
          "checks",
          ir.Array(list.map(
            [
              "upgrade",
              "masked_create",
              "created_completed",
              "same_connection_continuation",
              "cancel_close",
            ],
            ir.String,
          )),
        ),
      ]),
    ),
  )
}
