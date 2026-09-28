import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import mimic/dialect/openai
import mimic/ir
import mimic/providers/devin/auth
import mimic/providers/devin/connect
import mimic/providers/devin/identity
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/request
import mimic/providers/devin/response

pub fn pkce_and_callback_test() {
  let codes = auth.pkce()
  string.length(codes.verifier) |> should.equal(86)
  identity.sha256(bit_array.from_string(codes.verifier))
  |> bit_array.base64_url_encode(False)
  |> should.equal(codes.challenge)
  let assert Ok(url) =
    auth.authorization_url(
      "http://127.0.0.1:1234",
      "",
      auth.Pkce("synthetic", "challenge", "state"),
    )
  url
  |> should.equal(
    "http://127.0.0.1:1234/auth/cli/continue?state=state&prompt=select_account&code_challenge=challenge&code_challenge_method=S256&cli_pkce_marker=1",
  )
  auth.callback_code("code=synthetic&state=expected", "expected")
  |> should.equal(Ok("synthetic"))
  auth.callback_code("code=synthetic&state=wrong", "expected")
  |> should.be_error
  auth.callback_code("code=a&code=b&state=expected", "expected")
  |> should.be_error
  auth.callback_code("code=a&state=expected&error=private", "expected")
  |> should.equal(Error("devin authorization failed"))
}

pub fn exact_first_turn_wire_test() {
  let assert Ok(input) =
    openai.decode_request(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}",
    )
  let fingerprint = string.repeat("a", 732)
  let assert Ok(wire) =
    request.encode(
      input,
      "synthetic",
      request.Identity("linux", fingerprint, "session", "message"),
    )
  let assert <<0, size:32-big, payload:bytes-size(size)>> = wire
  let assert Ok(fields) = pb.decode(payload)
  list.last(fields) |> should.equal(Ok(pb.text(21, "swe-1-7")))
  let assert Ok(pb.Bytes(8, config)) =
    list.find(fields, fn(field) {
      case field {
        pb.Bytes(8, _) -> True
        _ -> False
      }
    })
  let assert Ok(config) = pb.decode(config)
  list.contains(config, pb.Varint(2, 64_000)) |> should.be_true
  list.contains(
    fields,
    pb.message(15, [
      pb.text(1, "session"),
      pb.Varint(3, 4),
      pb.Varint(4, 14),
    ]),
  )
  |> should.be_true
  let assert [pb.Bytes(1, metadata), ..] = fields
  let assert Ok(metadata) = pb.decode(metadata)
  metadata
  |> should.equal([
    pb.text(1, "chisel"),
    pb.text(2, "3000.10.21"),
    pb.text(3, "synthetic"),
    pb.text(4, "en"),
    pb.text(5, "linux"),
    pb.text(7, "3000.10.21"),
    pb.text(12, "chisel"),
    pb.text(31, fingerprint),
  ])
}

pub fn unsupported_request_never_drops_features_test() {
  let assert Ok(input) =
    openai.decode_request(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[]}",
    )
  request.encode(input, "synthetic", request.Identity("linux", "", "", ""))
  |> should.be_error
  request.model_uid("guessed-model") |> should.be_error
}

pub fn text_and_usage_buffered_test() {
  let data =
    pb.encode([
      pb.text(3, "hello"),
      pb.message(7, [pb.Varint(2, 12), pb.Varint(3, 3)]),
      pb.Varint(5, 2),
    ])
  let wire = <<{ connect.envelope(data) }:bits, 2, 2:32-big, "{}":utf8>>
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-1-7")
  decoded.content |> should.equal([ir.Text("hello", [])])
  decoded.usage |> should.equal(Some(ir.Usage(12, 3, [])))
  openai.encode_response(decoded) |> should.be_ok
}

pub fn utf8_split_between_protobuf_frames_test() {
  let first = connect.envelope(pb.encode([pb.Bytes(3, <<240, 159>>)]))
  let second = connect.envelope(pb.encode([pb.Bytes(3, <<152, 128>>)]))
  let assert Ok(#(decoder, events)) = response.feed(response.new(), first)
  events |> should.equal([])
  let assert Ok(#(decoder, events)) = response.feed(decoder, second)
  events |> should.equal([response.Text("😀")])
  response.finish(decoder) |> should.be_error
  let assert Ok(#(decoder, events)) =
    response.feed(decoder, <<2, 2:32-big, "{}":utf8>>)
  events |> should.equal([response.Stop])
  response.finish(decoder) |> should.be_ok
}

pub fn invalid_utf8_and_semantic_loss_test() {
  [
    pb.Bytes(3, <<192, 128>>),
    pb.Bytes(3, <<237, 160>>),
    pb.Bytes(3, <<244, 144>>),
    pb.Bytes(6, <<>>),
    pb.text(9, "thinking"),
    pb.Bytes(28, <<>>),
    pb.Varint(5, 10),
    pb.message(7, [pb.Varint(5, 2)]),
  ]
  |> list.each(fn(field) {
    response.feed(response.new(), connect.envelope(pb.encode([field])))
    |> should.be_error
  })
}

pub fn protobuf_field_order_and_monotonic_stop_test() {
  [
    [pb.Varint(5, 2), pb.text(3, "hi")],
    [pb.text(3, "hi"), pb.Varint(5, 2)],
  ]
  |> list.each(fn(fields) {
    let assert Ok(#(decoder, events)) =
      response.feed(response.new(), connect.envelope(pb.encode(fields)))
    events |> should.equal([response.Text("hi")])
    response.feed(
      decoder,
      connect.envelope(pb.encode([pb.Varint(5, 0), pb.text(3, "late")])),
    )
    |> should.be_error
  })
}

pub fn partial_usage_frames_and_duplicate_output_test() {
  let first =
    connect.envelope(
      pb.encode([
        pb.message(7, [pb.Varint(2, 10), pb.Varint(2, 2)]),
      ]),
    )
  let second =
    connect.envelope(
      pb.encode([
        pb.message(7, [pb.Varint(3, 7), pb.Varint(3, 3)]),
      ]),
    )
  let wire = <<first:bits, second:bits, 2, 2:32-big, "{}":utf8>>
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-1-7")
  decoded.usage |> should.equal(Some(ir.Usage(12, 3, [])))
  let assert Ok(#(decoder, _)) = response.feed(response.new(), first)
  let assert Ok(#(_, events)) = response.feed(decoder, second)
  events |> should.equal([response.Usage(ir.Usage(12, 3, []))])
}
