/// Synthetic protocol examples only; never measured Kimi upstream behavior.
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/kimi/transform

fn chat(extra: String) -> String {
  "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}]"
  <> extra
  <> "}"
}

pub fn native_extensions_and_thinking_keep_survive_test() {
  let assert Ok(body) =
    transform.request(
      chat(
        ",\"thinking\":{\"type\":\"enabled\",\"effort\":\"max\",\"keep\":true},\"temperature\":1,\"native_extension\":{\"nested\":\"preserved\"}",
      ),
      "kimi-k2.8",
      "chat",
      False,
    )
  let assert Ok(value) = ir.parse(body)
  ir.string_field(value, "model") |> should.equal(Ok("kimi-for-coding"))
  let assert Some(thinking) = ir.field(value, "thinking")
  ir.field(thinking, "keep") |> should.equal(Some(ir.Boolean(True)))
  ir.field(value, "native_extension") |> should.not_equal(None)
}

pub fn thinking_effort_maps_without_alias_leak_test() {
  let assert Ok(body) =
    transform.request(
      chat(",\"reasoning_effort\":\"high\""),
      "kimi-k2.8",
      "chat",
      False,
    )
  let assert Ok(value) = ir.parse(body)
  ir.field(value, "reasoning_effort") |> should.equal(None)
  let assert Some(thinking) = ir.field(value, "thinking")
  ir.field(thinking, "effort") |> should.equal(Some(ir.String("high")))
  transform.request(
    chat(",\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"high\""),
    "kimi-k2.8",
    "chat",
    False,
  )
  |> should.be_error
}

pub fn temperature_loss_and_unsupported_effort_are_errors_test() {
  list.each(
    [
      ",\"temperature\":0.2",
      ",\"reasoning_effort\":\"medium\"",
      ",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024}",
    ],
    fn(extra) {
      transform.request(chat(extra), "kimi-k2.8", "chat", False)
      |> should.be_error
    },
  )
  transform.request(
    chat(",\"thinking\":{\"type\":\"disabled\"},\"temperature\":0.6"),
    "kimi-k2.8",
    "chat",
    False,
  )
  |> should.be_ok
  transform.request(
    "{\"model\":\"kimi-k2.7-code\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}],\"reasoning_effort\":\"none\"}",
    "kimi-k2.7-code",
    "chat",
    False,
  )
  |> should.be_error
}

pub fn tools_schema_names_ids_and_arguments_survive_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"parameters\":{\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"]}}}],\"messages\":[{\"role\":\"assistant\",\"reasoning_content\":\"synthetic reasoning\",\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":  \\\"synthetic\\\"}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call_1\",\"content\":\"synthetic result\"}]}"
  let assert Ok(transformed) =
    transform.request(body, "kimi-k2.8", "chat", False)
  let assert Ok(value) = ir.parse(transformed)
  let assert Some(ir.Array([tool])) = ir.field(value, "tools")
  let assert Some(function) = ir.field(tool, "function")
  let assert Some(parameters) = ir.field(function, "parameters")
  ir.field(parameters, "type") |> should.equal(Some(ir.String("object")))
  let assert Some(ir.Array([assistant, output])) = ir.field(value, "messages")
  ir.field(assistant, "reasoning_content")
  |> should.equal(Some(ir.String("synthetic reasoning")))
  ir.field(output, "tool_call_id") |> should.equal(Some(ir.String("call_1")))
  let assert Some(ir.Array([call])) = ir.field(assistant, "tool_calls")
  let assert Some(function) = ir.field(call, "function")
  ir.field(function, "arguments")
  |> should.equal(Some(ir.String("{\"q\":  \"synthetic\"}")))
}

pub fn local_schema_reference_is_supported_but_orphan_result_is_not_test() {
  transform.request(
    chat(
      ",\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"parameters\":{\"$ref\":\"#/$defs/x\",\"$defs\":{\"x\":{\"type\":\"object\"}}}}}]",
    ),
    "kimi-k2.8",
    "chat",
    False,
  )
  |> should.be_ok
  transform.request(
    "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"tool\",\"tool_call_id\":\"orphan\",\"content\":\"synthetic\"}]}",
    "kimi-k2.8",
    "chat",
    False,
  )
  |> should.be_error
}

pub fn responses_history_is_native_not_chat_projection_test() {
  let body =
    "{\"model\":\"kimi-k2.8\",\"input\":[{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"synthetic reasoning\"}]},{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":\"synthetic\"}],\"tools\":[{\"type\":\"function\",\"name\":\"lookup\",\"parameters\":{\"type\":\"object\"}}],\"reasoning\":{\"effort\":\"max\"},\"native_extension\":true}"
  let assert Ok(transformed) =
    transform.request(body, "kimi-k2.8", "responses", False)
  let assert Ok(before) = ir.parse(body)
  let assert Ok(after) = ir.parse(transformed)
  ir.field(after, "input") |> should.equal(ir.field(before, "input"))
  ir.field(after, "tools") |> should.equal(ir.field(before, "tools"))
  ir.field(after, "native_extension") |> should.equal(Some(ir.Boolean(True)))
}

pub fn inline_and_remote_images_are_forwarded_without_fetch_test() {
  list.each(
    [
      "data:image/png;base64,c3ludGhldGlj",
      "https://synthetic.invalid/image.png",
    ],
    fn(url) {
      let body =
        "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\""
        <> url
        <> "\"}}]}]}"
      transform.request(body, "kimi-k2.8", "chat", False) |> should.be_ok
    },
  )
  transform.request(
    "{\"model\":\"kimi-k2.8\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"c3ludGhldGlj\"}}]}]}",
    "kimi-k2.8",
    "responses",
    False,
  )
  |> should.be_error
}

pub fn stream_usage_requested_and_continuation_denied_test() {
  let assert Ok(body) =
    transform.request(chat(",\"stream\":true"), "kimi-k2.8", "chat", True)
  let assert Ok(value) = ir.parse(body)
  let assert Some(options) = ir.field(value, "stream_options")
  ir.field(options, "include_usage") |> should.equal(Some(ir.Boolean(True)))
  transform.request(
    chat(",\"stream\":true,\"stream_options\":{\"include_usage\":false}"),
    "kimi-k2.8",
    "chat",
    True,
  )
  |> should.be_error
  transform.request(
    "{\"model\":\"kimi-k2.8\",\"input\":\"synthetic\",\"previous_response_id\":\"resp_other\"}",
    "kimi-k2.8",
    "responses",
    False,
  )
  |> should.be_error
}

pub fn ambiguous_duplicate_keys_fail_before_transform_test() {
  transform.request(
    "{\"model\":\"kimi-k2.8\",\"model\":\"kimi-k2.8\",\"input\":\"synthetic\"}",
    "kimi-k2.8",
    "responses",
    False,
  )
  |> should.be_error
}

pub fn restoration_only_touches_protocol_model_slots_test() {
  let assert Ok(value) =
    ir.parse(
      "{\"type\":\"response.created\",\"model\":\"kimi-for-coding\",\"response\":{\"model\":\"kimi-for-coding\"},\"arguments\":{\"model\":\"user data\"}}",
    )
  let restored = transform.restore(value, "kimi-k2.8")
  ir.field(restored, "model") |> should.equal(Some(ir.String("kimi-k2.8")))
  ir.field(restored, "arguments") |> should.equal(ir.field(value, "arguments"))
}

pub fn buffered_restore_preserves_response_named_extensions_test() {
  let assert Ok(value) =
    ir.parse(
      "{\"model\":\"kimi-for-coding\",\"type\":\"response.created\",\"response\":{\"model\":\"customer-model\"}}",
    )
  let assert Ok(restored) = transform.restore_checked(value, "kimi-k2.8")
  ir.field(restored, "response") |> should.equal(ir.field(value, "response"))
  transform.restore_response_event(value, "kimi-k2.8") |> should.be_error
}

pub fn upstream_model_switch_is_not_hidden_by_restoration_test() {
  let assert Ok(value) = ir.parse("{\"model\":\"unrelated-model\"}")
  transform.restore_checked(value, "kimi-k2.8") |> should.be_error
}

pub fn tool_outputs_and_reasoning_cannot_bypass_media_policy_test() {
  list.each(
    [
      "{\"type\":\"input_audio\",\"input_audio\":{\"data\":\"synthetic\"}}",
      "{\"type\":\"input_image\",\"file_id\":\"file_synthetic\"}",
    ],
    fn(part) {
      let body =
        "{\"model\":\"kimi-k2.8\",\"input\":[{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"lookup\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_1\",\"output\":["
        <> part
        <> "]}]}"
      transform.request(body, "kimi-k2.8", "responses", False)
      |> should.be_error
      transform.request(
        "{\"model\":\"kimi-k2.8\",\"input\":[{\"type\":\"reasoning\",\"summary\":["
          <> part
          <> "]}]}",
        "kimi-k2.8",
        "responses",
        False,
      )
      |> should.be_error
    },
  )
}
