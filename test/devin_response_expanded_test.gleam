import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/response

// All wire values here are synthetic, following CPA's Devin parser and
// executor tests; they are not provider captures.
fn stream(frames: List(BitArray)) -> BitArray {
  <<{ bit_array.concat(frames) }:bits, 2, 2:32-big, "{}":utf8>>
}

pub fn prefix_survives_later_bad_frame_and_trailer_test() {
  let good = connect.envelope(pb.encode([pb.text(3, "first")]))
  let invalid = <<1, 0:32-big>>
  let #(decoder, events, error) =
    response.feed_prefix(response.new(), <<good:bits, invalid:bits>>)
  events |> should.equal([response.Text("first")])
  error |> should.equal(Some("unsupported devin connect flag or compression"))
  response.feed_prefix(decoder, good).2
  |> should.equal(Some("devin response decoder failed"))
  response.finish(decoder) |> should.be_error
  response.feed(response.new(), <<good:bits, invalid:bits>>)
  |> should.be_error

  let trailer_payload =
    bit_array.from_string(
      "{\"error\":{\"code\":\"unauthenticated\",\"message\":\"private session material\"}}",
    )
  let trailer = <<
    2,
    { bit_array.byte_size(trailer_payload) }:32-big,
    trailer_payload:bits,
  >>
  let #(decoder, events, error) =
    response.feed_prefix(response.new(), <<good:bits, trailer:bits>>)
  events |> should.equal([response.Text("first")])
  error |> should.equal(Some("devin upstream trailer status 401"))
  response.finish(decoder) |> should.be_error
}

pub fn prefix_survives_later_protobuf_error_test() {
  let good = connect.envelope(pb.encode([pb.text(3, "first")]))
  let invalid = connect.envelope(pb.encode([pb.Bytes(99, <<0>>)]))
  let #(_, events, error) =
    response.feed_prefix(response.new(), <<good:bits, invalid:bits>>)
  events |> should.equal([response.Text("first")])
  error |> should.equal(Some("unsupported devin response field or stop reason"))
}

pub fn terminal_with_trailing_data_cannot_claim_success_test() {
  let data = connect.envelope(pb.encode([pb.text(3, "prefix")]))
  let wire = <<
    data:bits,
    2,
    2:32-big,
    "{}":utf8,
    { connect.envelope(pb.encode([pb.text(3, "late")])) }:bits,
  >>
  let #(_, events, error) = response.feed_prefix(response.new(), wire)
  events |> should.equal([response.Text("prefix")])
  error |> should.equal(Some("devin data after terminal frame"))
}

pub fn thinking_signature_binary_and_field_order_test() {
  let data =
    pb.encode([
      pb.Varint(5, 2),
      pb.Bytes(9, <<240, 159>>),
      pb.Bytes(10, <<0, 255>>),
      pb.text(21, "anthropic"),
      pb.text(3, "answer"),
    ])
  let second = pb.encode([pb.Bytes(9, <<152, 128>>), pb.Bytes(10, <<1>>)])
  // A stop marker closes the message, so thinking cannot follow it in a
  // subsequent frame. First verify split UTF-8 without stop.
  let first = pb.encode([pb.Bytes(9, <<240, 159>>), pb.Bytes(10, <<0, 255>>)])
  let wire =
    stream([
      connect.envelope(first),
      connect.envelope(second),
      connect.envelope(
        pb.encode([
          pb.Varint(5, 2),
          pb.text(21, "anthropic"),
          pb.text(3, "answer"),
        ]),
      ),
    ])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.content
  |> should.equal([
    ir.Thinking("😀", Some("AP8B"), [
      #("devin_signature_encoding", ir.String("base64")),
      #("devin_signature_type", ir.String("anthropic")),
    ]),
    ir.Text("answer", []),
  ])
  let assert Ok(#(_, events)) =
    response.feed(response.new(), connect.envelope(data))
  events
  |> should.equal([
    response.SignatureDelta(<<0, 255>>),
    response.SignatureType("anthropic"),
    response.Text("answer"),
    response.Reason(2),
  ])
}

pub fn buffered_preserves_interleaved_content_order_test() {
  let wire =
    stream([
      connect.envelope(pb.encode([pb.text(9, "thought 1")])),
      connect.envelope(pb.encode([pb.text(3, "content 1")])),
      connect.envelope(pb.encode([pb.text(9, "thought 2")])),
      connect.envelope(
        pb.encode([
          pb.message(6, [
            pb.text(1, "call_1"),
            pb.text(2, "read"),
            pb.text(3, "{\"path\":\"x\"}"),
          ]),
        ]),
      ),
      connect.envelope(pb.encode([pb.text(3, "content 2")])),
      connect.envelope(
        pb.encode([pb.Bytes(10, <<255>>), pb.text(21, "anthropic")]),
      ),
    ])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.content
  |> should.equal([
    ir.Thinking("thought 1", None, []),
    ir.Text("content 1", []),
    ir.Thinking("thought 2", Some("/w"), [
      #("devin_signature_encoding", ir.String("base64")),
      #("devin_signature_type", ir.String("anthropic")),
    ]),
    ir.ToolCall(
      "call_1",
      "read",
      ir.Object([#("path", ir.String("x"))]),
      Some("{\"path\":\"x\"}"),
      [],
    ),
    ir.Text("content 2", []),
  ])
}

pub fn interleaved_tools_keep_ids_and_raw_json_test() {
  let one =
    pb.message(6, [
      pb.text(1, "call_1"),
      pb.text(2, "bash"),
      pb.text(3, "{\"a\":"),
    ])
  let two =
    pb.message(6, [
      pb.text(1, "call_2"),
      pb.text(2, "read"),
      pb.text(3, "{ \"path\" : \"x\" }"),
    ])
  let continuation = pb.message(6, [pb.text(1, "call_1"), pb.text(3, "1}")])
  let wire =
    stream([
      connect.envelope(pb.encode([one])),
      connect.envelope(pb.encode([two])),
      connect.envelope(pb.encode([continuation, pb.Varint(5, 10)])),
    ])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.stop_reason |> should.equal(Some("tool_use"))
  decoded.content
  |> should.equal([
    ir.ToolCall(
      "call_1",
      "bash",
      ir.Object([#("a", ir.Integer(1))]),
      Some("{\"a\":1}"),
      [],
    ),
    ir.ToolCall(
      "call_2",
      "read",
      ir.Object([#("path", ir.String("x"))]),
      Some("{ \"path\" : \"x\" }"),
      [],
    ),
  ])
}

pub fn custom_tool_retains_non_json_without_projecting_test() {
  let call =
    pb.message(6, [
      pb.text(1, "call_custom"),
      pb.text(2, "bash"),
      pb.text(4, "ls -la"),
      pb.text(5, "not valid json"),
      pb.Varint(6, 1),
    ])
  let wire = stream([connect.envelope(pb.encode([call]))])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.content
  |> should.equal([
    ir.Unknown(
      ir.Object([
        #("devin_tool_call_id", ir.String("call_custom")),
        #("devin_tool_name", ir.String("bash")),
        #("devin_custom_arguments", ir.String("ls -la")),
        #("devin_invalid_json_error", ir.String("not valid json")),
        #("devin_custom", ir.Boolean(True)),
        #("devin_json_arguments", ir.String("")),
      ]),
    ),
  ])
}

pub fn exact_usage_with_cache_and_estimate_fallback_test() {
  let metric = fn(key, value) {
    pb.message(2, [
      pb.message(4, [pb.Fixed32(2, <<value:float-32-little>>)]),
      pb.text(5, key),
    ])
  }
  let estimate =
    pb.message(28, [
      pb.text(1, "Token Usage"),
      metric("input_tokens", 575.0),
      metric("output_tokens", 5.0),
      metric("cached_input_tokens", 128.0),
    ])
  let wire = stream([connect.envelope(pb.encode([estimate]))])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.usage
  |> should.equal(
    Some(
      ir.Usage(575, 5, [
        #("devin_usage_source", ir.String("dimension_estimate")),
        #("cached_input_tokens", ir.Integer(128)),
      ]),
    ),
  )

  let header =
    pb.message(8, [pb.text(1, "Request-Id"), pb.text(2, "req_synthetic")])
  let exact =
    pb.message(7, [
      pb.Varint(2, 3),
      pb.Varint(4, 58),
      pb.Varint(3, 39),
      pb.Varint(5, 19_179),
      pb.Varint(6, 66),
      header,
      pb.text(9, "gpt-synthetic"),
    ])
  let wire = stream([connect.envelope(pb.encode([estimate, exact]))])
  let assert Ok(decoded) = response.buffered(wire, "synthetic", "devin/swe-2")
  decoded.usage
  |> should.equal(
    Some(
      ir.Usage(3, 39, [
        #("cache_write_tokens", ir.Integer(58)),
        #("cached_input_tokens", ir.Integer(19_179)),
        #("devin_status_code", ir.Integer(66)),
        #("devin_request_id", ir.String("req_synthetic")),
        #("devin_model", ir.String("gpt-synthetic")),
      ]),
    ),
  )
}

pub fn partial_exact_usage_does_not_invent_missing_counts_test() {
  let cache_only =
    stream([
      connect.envelope(pb.encode([pb.message(7, [pb.Varint(5, 12)])])),
    ])
  let assert Ok(decoded) =
    response.buffered(cache_only, "synthetic", "devin/swe-2")
  decoded.usage
  |> should.equal(
    Some(
      ir.Usage(0, 0, [
        #("cached_input_tokens", ir.Integer(12)),
        #("devin_input_known", ir.Boolean(False)),
        #("devin_output_known", ir.Boolean(False)),
      ]),
    ),
  )

  let partial =
    stream([
      connect.envelope(pb.encode([pb.message(7, [pb.Varint(2, 7)])])),
      connect.envelope(pb.encode([pb.message(7, [pb.Varint(3, 0)])])),
    ])
  let assert Ok(decoded) =
    response.buffered(partial, "synthetic", "devin/swe-2")
  decoded.usage |> should.equal(Some(ir.Usage(7, 0, [])))
}

pub fn partial_dimension_estimates_preserve_presence_test() {
  let metric = fn(key, value) {
    pb.message(28, [
      pb.text(1, "Token Usage"),
      pb.message(2, [
        pb.message(4, [pb.Fixed32(2, <<value:float-32-little>>)]),
        pb.text(5, key),
      ]),
    ])
  }
  let first = connect.envelope(pb.encode([metric("input_tokens", 7.0)]))
  let second = connect.envelope(pb.encode([metric("output_tokens", 5.0)]))
  let assert Ok(decoded) = response.buffered(stream([second]), "id", "model")
  decoded.usage
  |> should.equal(
    Some(
      ir.Usage(0, 5, [
        #("devin_usage_source", ir.String("dimension_estimate")),
        #("devin_input_known", ir.Boolean(False)),
      ]),
    ),
  )
  let assert Ok(decoded) =
    response.buffered(stream([first, second]), "id", "model")
  decoded.usage
  |> should.equal(
    Some(
      ir.Usage(7, 5, [
        #("devin_usage_source", ir.String("dimension_estimate")),
      ]),
    ),
  )
}

pub fn coalesced_frames_are_bounded_individually_and_preserve_prefix_test() {
  // Two individually valid frames may exceed one frame limit in one read.
  let payload = bit_array.from_string(string.repeat("x", 4_194_305))
  let wire = <<
    { connect.envelope(payload) }:bits,
    { connect.envelope(payload) }:bits,
    1,
  >>
  let #(_, frames, error) = connect.feed_prefix(connect.new(), wire)
  list.length(frames) |> should.equal(2)
  error |> should.equal(Some("unsupported devin connect flag or compression"))
}

pub fn malformed_and_unsupported_never_silently_drop_test() {
  [
    pb.message(6, [pb.text(1, "call"), pb.Varint(99, 1)]),
    pb.message(7, [pb.Varint(99, 1)]),
    pb.message(28, [pb.text(1, "Token Usage"), pb.Varint(2, 5)]),
    pb.Varint(5, 99),
  ]
  |> list.each(fn(field) {
    response.feed(response.new(), connect.envelope(pb.encode([field])))
    |> should.be_error
  })
  let assert Ok(#(decoder, events)) = response.feed(response.new(), <<0, 0>>)
  events |> should.equal([])
  response.finish(decoder) |> should.be_error
  connect.trailer(bit_array.from_string("{not json")) |> should.be_error
}

pub fn native_incomplete_reasons_preserve_text_test() {
  [#(1, "max_tokens"), #(3, "max_tokens"), #(11, "content_filter")]
  |> list.each(fn(pair) {
    let frame =
      connect.envelope(pb.encode([pb.Varint(5, pair.0), pb.text(3, "prefix")]))
    let assert Ok(decoded) = response.buffered(stream([frame]), "id", "model")
    decoded.content |> should.equal([ir.Text("prefix", [])])
    decoded.stop_reason |> should.equal(Some(pair.1))
  })
}
