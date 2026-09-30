import gleam/bit_array
import gleam/list
import gleam/option.{None}
import gleeunit/should
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/ir
import mimic/providers/devin/conversation
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/request

fn fields(body: String) -> List(pb.Field) {
  let assert Ok(input) = openai.decode_request(body)
  let assert Ok(bytes) =
    request.encode(
      input,
      "synthetic-fixture-token",
      request.Identity("linux", "", "synthetic-session", "synthetic-message"),
    )
  let assert <<0, n:32-big, payload:bytes-size(n)>> = bytes
  let assert Ok(fields) = pb.decode(payload)
  fields
}

pub fn full_history_and_system_test() {
  let fields =
    fields(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"system\",\"content\":\"instructions\"},{\"role\":\"user\",\"content\":\"one\"},{\"role\":\"assistant\",\"content\":\"two\"},{\"role\":\"user\",\"content\":\"three\"}]}",
    )
  list.contains(fields, pb.text(2, "instructions")) |> should.be_true
  let turns =
    list.filter_map(fields, fn(field) {
      case field {
        pb.Bytes(3, body) -> pb.decode(body)
        _ -> Error("")
      }
    })
  list.length(turns) |> should.equal(3)
  list.map(turns, fn(turn) {
    list.find(turn, fn(f) {
      case f {
        pb.Bytes(3, _) -> True
        _ -> False
      }
    })
  })
  |> should.equal([
    Ok(pb.text(3, "one")),
    Ok(pb.text(3, "two")),
    Ok(pb.text(3, "three")),
  ])
}

pub fn tool_call_and_result_wire_test() {
  let fields =
    fields(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{ \\\"x\\\": 1 }\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call-1\",\"content\":\"answer\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"description\":\"find\",\"parameters\":{\"type\":\"object\"}}}]}",
    )
  let turns =
    list.filter_map(fields, fn(field) {
      case field {
        pb.Bytes(3, body) -> pb.decode(body)
        _ -> Error("")
      }
    })
  let assert [assistant, tool] = turns
  list.contains(
    assistant,
    pb.message(6, [
      pb.text(1, "call-1"),
      pb.text(2, "lookup"),
      pb.text(3, "{ \"x\": 1 }"),
    ]),
  )
  |> should.be_true
  list.contains(tool, pb.Varint(2, 4)) |> should.be_true
  list.contains(tool, pb.text(7, "call-1")) |> should.be_true
  list.contains(
    fields,
    pb.message(15, [pb.text(1, "synthetic-session"), pb.Varint(3, 4)]),
  )
  |> should.be_true
}

pub fn orphan_results_and_duplicate_calls_rejected_test() {
  let tool = ir.ToolCall("a", "f", ir.Object([]), None, [])
  conversation.history(
    [ir.Turn("tool", [ir.ToolResult("a", ir.String("x"), [])], False, [])],
    fn(_) { "id" },
  )
  |> should.be_error
  conversation.history([ir.Turn("assistant", [tool, tool], False, [])], fn(_) {
    "id"
  })
  |> should.be_error
}

pub fn thinking_signature_is_native_bytes_test() {
  let assert Ok(input) =
    anthropic.decode_request(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"reason\",\"signature\":\"claude#opaque\"},{\"type\":\"text\",\"text\":\"answer\"}]},{\"role\":\"user\",\"content\":\"next\"}]}",
    )
  let assert Ok(prompts) = conversation.history(input.turns, fn(_) { "id" })
  let assert [pb.Bytes(3, bytes), ..] = prompts
  let assert Ok(fields) = pb.decode(bytes)
  list.contains(fields, pb.text(11, "reason")) |> should.be_true
  list.contains(fields, pb.Bytes(12, bit_array.from_string("opaque")))
  |> should.be_true
  list.contains(fields, pb.text(18, "anthropic")) |> should.be_true
  conversation.signature_bytes("ambiguous") |> should.be_error
}

pub fn image_forms_and_remote_audio_rejection_test() {
  let assert Ok(image) =
    ir.parse(
      "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AAE=\"}}",
    )
  conversation.image_field(image)
  |> should.equal(
    Ok(pb.message(10, [pb.text(1, "AAE="), pb.text(2, "image/png")])),
  )
  let assert Ok(image) =
    ir.parse(
      "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"AAE=\"}}",
    )
  conversation.image_field(image) |> should.be_ok
  [
    "{\"type\":\"image_url\",\"image_url\":{\"url\":\"https://example.invalid/image.png\"}}",
    "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"AAE=\",\"format\":\"wav\"}}",
    "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"!bad\"}}",
    "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AAE=\",\"detail\":\"high\"}}",
  ]
  |> list.each(fn(body) {
    let assert Ok(image) = ir.parse(body)
    conversation.image_field(image) |> should.be_error
  })
}

pub fn configured_model_mapping_and_token_cap_test() {
  let assert Ok(input) =
    openai.decode_request(
      "{\"model\":\"devin/operator-model\",\"max_tokens\":9000,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}",
    )
  let config = [
    models.Model("devin/operator-model", "exact-source-uid", 2048, False),
  ]
  let assert Ok(bytes) =
    request.encode_configured(
      input,
      "synthetic",
      request.Identity("linux", "", "session", "message"),
      config,
    )
  let assert <<0, n:32-big, payload:bytes-size(n)>> = bytes
  let assert Ok(fields) = pb.decode(payload)
  list.contains(fields, pb.text(21, "exact-source-uid")) |> should.be_true
  let assert Ok(pb.Bytes(8, config)) =
    list.find(fields, fn(field) {
      case field {
        pb.Bytes(8, _) -> True
        _ -> False
      }
    })
  let assert Ok(config) = pb.decode(config)
  list.contains(config, pb.Varint(2, 2048)) |> should.be_true
  models.resolve(models.baseline(), "devin/operator-model") |> should.be_error
  models.validate([
    models.Model("devin/x", "u", 1, False),
    models.Model("devin/x", "u", 1, False),
  ])
  |> should.be_error
}

pub fn no_silent_unknown_request_options_test() {
  let assert Ok(input) =
    openai.decode_request(
      "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"reasoning_effort\":\"high\"}",
    )
  request.encode(input, "synthetic", request.Identity("linux", "", "", ""))
  |> should.be_error
  let input =
    ir.Request(..input, extensions: [#("temperature", ir.Decimal(0.5))])
  request.encode(input, "synthetic", request.Identity("linux", "", "", ""))
  |> should.be_ok
}

pub fn interleaved_text_cannot_be_reordered_across_tools_test() {
  let turn =
    ir.Turn(
      "assistant",
      [
        ir.Text("before", []),
        ir.ToolCall("call", "tool", ir.Object([]), None, []),
        ir.Text("after", []),
      ],
      False,
      [],
    )
  conversation.history([turn], fn(_) { "id" }) |> should.be_error
}
