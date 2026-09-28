import gleam/list
import gleam/option.{Some}
import gleam/string
import mimic/dialect
import mimic/dialect/anthropic
import mimic/dialect/openai
import mimic/ir

fn equal_json(left: String, right: String) -> Bool {
  case ir.parse(left), ir.parse(right) {
    Ok(left), Ok(right) -> left == right
    _, _ -> False
  }
}

pub fn anthropic_request_extensions_roundtrip_test() {
  // Synthetic fixture, not a capture. Includes known and unknown nested fields.
  let body =
    "{\"model\":\"synthetic\",\"max_tokens\":64,\"stream\":true,\"system\":[{\"type\":\"text\",\"text\":\"rules\",\"cache_control\":{\"type\":\"ephemeral\"}}],\"messages\":[{\"role\":\"user\",\"content\":\"hi\",\"custom_message\":{\"x\":[1,2]}},{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"reason\",\"signature\":\"synthetic-signature\",\"custom_thinking\":true},{\"type\":\"text\",\"text\":\"answer\",\"citations\":[{\"start\":0}]},{\"type\":\"tool_use\",\"id\":\"call-1\",\"name\":\"lookup\",\"input\":{\"nested\":{\"a\":1}},\"custom_tool\":3},{\"type\":\"future_block\",\"payload\":{\"deep\":[null,false]}}]}],\"tools\":[{\"name\":\"lookup\",\"input_schema\":{\"type\":\"object\"}}],\"unknown_root\":{\"deep\":\"value\"}}"
  let assert Ok(decoded) = anthropic.decode_request(body)
  let assert Ok(encoded) = anthropic.encode_request(decoded)
  assert equal_json(body, encoded)
  let assert [_, assistant] = decoded.turns
  let assert [
    ir.Thinking(_, _, _),
    ir.Text(_, _),
    ir.ToolCall(_, _, _, _, _),
    ir.Unknown(_),
  ] = assistant.content
  assert openai.encode_request(decoded) != Ok(encoded)
}

pub fn anthropic_response_extensions_roundtrip_test() {
  let body =
    "{\"type\":\"message\",\"role\":\"assistant\",\"id\":\"msg-synthetic\",\"model\":\"synthetic\",\"content\":[{\"type\":\"text\",\"text\":\"ok\",\"future_annotation\":{\"a\":1}},{\"type\":\"redacted_thinking\",\"data\":\"synthetic\"}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":5,\"output_tokens\":8,\"cache_read_input_tokens\":2},\"future_response\":true}"
  let assert Ok(decoded) = anthropic.decode_response(body)
  let assert Ok(encoded) = anthropic.encode_response(decoded)
  assert equal_json(body, encoded)
  assert openai.encode_response(decoded) != Ok(encoded)
}

pub fn openai_tool_request_roundtrip_and_cross_dialect_test() {
  let body =
    "{\"model\":\"synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"},{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"x\\\": 1}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"call-1\",\"content\":\"found\"}],\"max_completion_tokens\":64,\"stream\":true}"
  let assert Ok(decoded) = openai.decode_request(body)
  let assert Ok(encoded) = openai.encode_request(decoded)
  assert equal_json(body, encoded)
  let assert Ok(anthropic_body) = anthropic.encode_request(decoded)
  let assert Ok(anthropic_request) = anthropic.decode_request(anthropic_body)
  let assert [_, assistant, tool] = anthropic_request.turns
  let assert [ir.ToolCall("call-1", "lookup", _, _, _)] = assistant.content
  let assert [ir.ToolResult("call-1", _, _)] = tool.content
}

pub fn openai_response_roundtrip_test() {
  let body =
    "{\"id\":\"chatcmpl-synthetic\",\"model\":\"synthetic\",\"object\":\"chat.completion\",\"created\":10,\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello\",\"refusal\":null},\"finish_reason\":\"stop\",\"logprobs\":null}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2,\"total_tokens\":6,\"prompt_tokens_details\":{\"cached_tokens\":1}}}"
  let assert Ok(decoded) = openai.decode_response(body)
  let assert Ok(encoded) = openai.encode_response(decoded)
  assert equal_json(body, encoded)
  assert anthropic.encode_response(decoded) != Ok(encoded)
}

pub fn unsupported_cross_dialect_thinking_test() {
  let body =
    "{\"model\":\"synthetic\",\"max_tokens\":8,\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private\",\"signature\":\"synthetic\"}]}]}"
  let assert Ok(decoded) = anthropic.decode_request(body)
  let assert Error(_) = openai.encode_request(decoded)
}

pub fn unsupported_cross_dialect_stop_reason_test() {
  let body =
    "{\"id\":\"msg-synthetic\",\"model\":\"synthetic\",\"content\":[],\"stop_reason\":\"pause_turn\"}"
  let assert Ok(decoded) = anthropic.decode_response(body)
  let assert Error(_) = openai.encode_response(decoded)
}

pub fn openai_legacy_tokens_and_developer_role_test() {
  let body =
    "{\"model\":\"synthetic\",\"max_tokens\":12,\"messages\":[{\"role\":\"developer\",\"content\":\"rules\"},{\"role\":\"user\",\"content\":\"hi\"}],\"extra\":{\"nested\":true}}"
  let assert Ok(decoded) = openai.decode_request(body)
  let assert Ok(encoded) = openai.encode_request(decoded)
  assert equal_json(body, encoded)
  let assert Error(_) = anthropic.encode_request(decoded)
}

pub fn tool_definitions_translate_both_ways_test() {
  let body =
    "{\"model\":\"synthetic\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"description\":\"synthetic\",\"parameters\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"}}}}}],\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":\"lookup\"}},\"stop\":[\"END\"],\"temperature\":0.5}"
  let assert Ok(openai_request) = openai.decode_request(body)
  let assert Ok(anthropic_body) = anthropic.encode_request(openai_request)
  let assert Ok(anthropic_request) = anthropic.decode_request(anthropic_body)
  let assert Ok(encoded) = openai.encode_request(anthropic_request)
  assert equal_json(body, encoded)
}

pub fn anthropic_tool_result_translates_test() {
  let body =
    "{\"model\":\"synthetic\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"call-1\",\"content\":\"found\"}]}]}"
  let assert Ok(request) = anthropic.decode_request(body)
  let assert Ok(encoded) = openai.encode_request(request)
  let assert Ok(openai_request) = openai.decode_request(encoded)
  let assert [turn] = openai_request.turns
  let assert [ir.ToolResult("call-1", _, _)] = turn.content
}

pub fn plain_response_translates_both_ways_test() {
  let anthropic_body =
    "{\"type\":\"message\",\"role\":\"assistant\",\"id\":\"msg-synthetic\",\"model\":\"synthetic\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}],\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":1,\"cache_read_input_tokens\":0}}"
  let assert Ok(decoded) = anthropic.decode_response(anthropic_body)
  let assert Ok(openai_body) = openai.encode_response(decoded)
  let assert Ok(translated) = openai.decode_response(openai_body)
  assert translated.stop_reason == Some("end_turn")
  let assert Some(ir.Usage(2, 1, _)) = translated.usage

  let openai_body =
    "{\"id\":\"chat-synthetic\",\"model\":\"synthetic\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3}}"
  let assert Ok(decoded) = openai.decode_response(openai_body)
  let assert Ok(anthropic_body) = anthropic.encode_response(decoded)
  let assert Ok(translated) = anthropic.decode_response(anthropic_body)
  let assert Some("end_turn") = translated.stop_reason
}

pub fn thinking_null_signature_and_unknown_block_preserved_test() {
  let body =
    "{\"model\":\"synthetic\",\"messages\":[{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"private\",\"signature\":null,\"vendor\":{\"deep\":[2]}},{\"type\":\"future\",\"data\":1}]}]}"
  let assert Ok(decoded) = anthropic.decode_request(body)
  let assert Ok(encoded) = anthropic.encode_request(decoded)
  assert equal_json(body, encoded)
}

fn feed_one_byte_at_a_time(
  stream: dialect.Stream,
  chars: List(String),
  output: List(String),
) -> Result(#(dialect.Stream, List(String)), String) {
  case chars {
    [] -> Ok(#(stream, output))
    [char, ..rest] -> {
      let assert Ok(pair) = dialect.feed(stream, char)
      feed_one_byte_at_a_time(pair.0, rest, list.append(output, pair.1))
    }
  }
}

pub fn anthropic_stream_tool_json_chunks_test() {
  // Synthetic events deliberately mix framing boundaries and partial tool JSON.
  let events = [
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"type\":\"message\",\"id\":\"msg-1\",\"model\":\"synthetic\",\"role\":\"assistant\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":1,\"output_tokens\":0,\"cache_read_input_tokens\":0}}}\n\n",
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool-1\",\"name\":\"lookup\",\"input\":{}}}\n\n",
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\"}}\n\n",
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"1}\"}}\n\n",
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n",
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  ]
  let whole = string.join(events, "")
  let assert Ok(pair) =
    feed_one_byte_at_a_time(
      dialect.new_stream(dialect.Anthropic, dialect.Openai),
      string.to_graphemes(whole),
      [],
    )
  let assert Ok([]) = dialect.finish(pair.0)
  let output = string.join(pair.1, "")
  assert string.contains(output, "\"arguments\":\"{\\\"a\\\":\"")
  assert string.contains(output, "\"arguments\":\"1}\"")
  assert string.contains(output, "\"prompt_tokens\":1")
  assert string.contains(output, "\"completion_tokens\":2")
  assert string.contains(output, "data: [DONE]\n\n")
  assert list.length(pair.1) >= 5
}

pub fn openai_stream_multi_event_and_terminal_test() {
  let start =
    "data: {\"id\":\"chat-1\",\"object\":\"chat.completion.chunk\",\"model\":\"synthetic\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hi\"},\"finish_reason\":null}]}\n\n"
  let tool =
    "data: {\"id\":\"chat-1\",\"model\":\"synthetic\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"a\\\":\"}}]},\"finish_reason\":null}]}\n\n"
  let partial =
    "data: {\"id\":\"chat-1\",\"model\":\"synthetic\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n"
  let assert Ok(pair) =
    dialect.feed(
      dialect.new_stream(dialect.Openai, dialect.Anthropic),
      start <> tool <> partial <> "data: [DONE]\n\n",
    )
  let assert Ok([]) = dialect.finish(pair.0)
  let output = string.join(pair.1, "")
  assert string.contains(output, "event: message_start")
  assert string.contains(output, "event: content_block_start")
  assert string.contains(output, "event: content_block_delta")
  assert string.contains(output, "event: content_block_stop")
  assert string.contains(output, "event: message_stop")
}

pub fn stream_errors_are_explicit_test() {
  let stream = dialect.new_stream(dialect.Anthropic, dialect.Openai)
  let assert Error(_) =
    dialect.feed(
      stream,
      "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"synthetic\"}}\n\n",
    )
  let assert Error(_) = dialect.finish(stream)
  let assert Error(_) =
    dialect.feed(
      stream,
      "event: content_block_delta\ndata: {\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private\"}}\n\n",
    )
  let assert Ok(pair) =
    dialect.feed(
      dialect.new_stream(dialect.Openai, dialect.Openai),
      "data: [DONE]\r\n\r\n",
    )
  let assert Ok([]) = dialect.finish(pair.0)
  let assert Error(_) =
    dialect.feed(
      dialect.new_stream(dialect.Openai, dialect.Openai),
      "data: [DONE]\n\ndata: {}\n\n",
    )
  let assert Error("Gemini dialect is not implemented") =
    dialect.feed(dialect.new_stream(dialect.Gemini, dialect.Openai), "")
  let assert Error(_) =
    dialect.feed(
      dialect.new_stream(dialect.Openai, dialect.Anthropic),
      "data: {\"id\":\"chat-synthetic\",\"model\":\"synthetic\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"user\"},\"finish_reason\":null}]}\n\n",
    )
}
