import gleam/bit_array
import gleam/list
import gleeunit/should
import mimic/providers/devin/auth
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb

pub fn synthetic_session_token_test() {
  auth.format_session_token(" eyJsynthetic ")
  |> should.equal(Ok("devin-session-token$eyJsynthetic"))
  auth.format_session_token("devin-session-token$synthetic")
  |> should.equal(Ok("devin-session-token$synthetic"))
  auth.format_session_token("opaque-synthetic")
  |> should.equal(Ok("opaque-synthetic"))
  auth.format_session_token("synthetic\r\ninjected") |> should.be_error
  auth.format_session_token(" ") |> should.be_error
}

pub fn synthetic_exchange_and_estimate_test() {
  auth.exchange_body(" code ", " verifier ")
  |> should.equal(Ok("{\"code\":\"code\",\"code_verifier\":\"verifier\"}"))
  auth.exchange_token("{\"token\":\"eyJsynthetic\"}")
  |> should.equal(Ok("devin-session-token$eyJsynthetic"))
  auth.exchange_token("{\"private\":\"must-not-echo\"}")
  |> should.equal(Error("invalid devin token response"))
  auth.estimated_tokens("😀") |> should.equal(1)
}

pub fn protobuf_roundtrip_test() {
  let fields = [
    pb.Varint(1, 0),
    pb.Varint(2, 128),
    pb.text(3, "synthetic"),
    pb.message(31, [pb.Varint(1, 732)]),
    pb.Fixed64(8, <<1.0:float-little>>),
    pb.Fixed32(9, <<0:32>>),
  ]
  pb.decode(pb.encode(fields)) |> should.equal(Ok(fields))
}

pub fn protobuf_invalid_wire_test() {
  [
    <<0>>,
    <<8, 128>>,
    <<10, 3, 1>>,
    <<15>>,
    <<9, 1>>,
    <<8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 2>>,
  ]
  |> list.each(fn(bytes) { pb.decode(bytes) |> should.be_error })
}

pub fn connect_every_byte_fragmentation_test() {
  let wire = <<
    { connect.envelope(<<26, 2, 104, 105>>) }:bits,
    2,
    2:32-big,
    "{}":utf8,
  >>
  let #(decoder, frames) = feed_bytes(wire, connect.new(), [])
  frames |> should.equal([connect.Data(<<26, 2, 104, 105>>), connect.End])
  connect.finish(decoder) |> should.equal(Ok(Nil))
  connect.feed(decoder, <<0>>) |> should.be_error
}

fn feed_bytes(bytes, decoder, frames) {
  case bytes {
    <<byte, rest:bits>> -> {
      let assert Ok(#(decoder, next)) = connect.feed(decoder, <<byte>>)
      feed_bytes(rest, decoder, list.append(frames, next))
    }
    <<>> -> #(decoder, frames)
    _ -> panic as "synthetic fixture must contain whole bytes"
  }
}

pub fn connect_fail_closed_test() {
  connect.finish(connect.new()) |> should.be_error
  connect.feed(connect.new(), <<1, 0:32>>) |> should.be_error
  connect.feed(connect.new(), <<3, 0:32>>) |> should.be_error
  connect.feed(connect.new(), <<4, 0:32>>) |> should.be_error
  connect.feed(connect.new(), <<0, 8_388_609:32>>) |> should.be_error
  let assert Ok(#(decoder, _)) = connect.feed(connect.new(), <<0, 3:32, 1>>)
  connect.finish(decoder) |> should.be_error
}

pub fn trailer_errors_are_secret_safe_test() {
  connect.trailer(bit_array.from_string(
    "{\"error\":{\"code\":\"permission_denied\",\"message\":\"high demand synthetic-secret\"}}",
  ))
  |> should.equal(Error("devin upstream trailer status 429"))
  connect.trailer(bit_array.from_string(
    "{\"error\":{\"code\":\"invalid_argument\",\"message\":\"internal error synthetic-secret\"}}",
  ))
  |> should.equal(Error("devin upstream trailer status 502"))
  connect.trailer(<<"not JSON":utf8>>) |> should.be_error
  connect.trailer(<<"[]":utf8>>) |> should.be_error
}
