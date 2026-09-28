import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/stream

// All fixtures in this module are synthetic. No account/provider captures.
fn json(source: String) -> ir.Value {
  let assert Ok(value) = ir.parse(source)
  value
}

fn response(status: String, output: List(ir.Value)) -> ir.Value {
  ir.Object([
    #("id", ir.String("resp_synthetic")),
    #("object", ir.String("response")),
    #("status", ir.String(status)),
    #("output", ir.Array(output)),
    #(
      "usage",
      ir.Object([
        #("input_tokens", ir.Integer(11)),
        #("output_tokens", ir.Integer(7)),
        #("total_tokens", ir.Integer(18)),
        #(
          "output_tokens_details",
          ir.Object([#("reasoning_tokens", ir.Integer(3))]),
        ),
      ]),
    ),
  ])
}

fn event(name: String, fields: List(#(String, ir.Value))) -> ir.Value {
  ir.Object([#("type", ir.String(name)), ..fields])
}

fn created() -> ir.Value {
  event("response.created", [#("response", response("in_progress", []))])
}

fn completed(items: List(ir.Value)) -> ir.Value {
  event("response.completed", [#("response", response("completed", items))])
}

fn frame(value: ir.Value) -> String {
  "data: " <> ir.stringify(value) <> "\n\n"
}

fn started() -> stream.Stream {
  let assert Ok(#(state, _)) = stream.push(stream.new(), created())
  state
}

fn message() -> ir.Value {
  json(
    "{\"id\":\"msg_synthetic\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}",
  )
}

fn added(item: ir.Value) -> ir.Value {
  event("response.output_item.added", [
    #("output_index", ir.Integer(0)),
    #("item", item),
  ])
}

fn done(item: ir.Value) -> ir.Value {
  event("response.output_item.done", [
    #("output_index", ir.Integer(0)),
    #("item", item),
  ])
}

fn text_fields() -> List(#(String, ir.Value)) {
  [
    #("output_index", ir.Integer(0)),
    #("item_id", ir.String("msg_synthetic")),
    #("content_index", ir.Integer(0)),
  ]
}

fn text_fixture() -> List(ir.Value) {
  let final_item =
    json(
      "{\"id\":\"msg_synthetic\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"synthetic λ🚀\",\"annotations\":[]}]}",
    )
  [
    created(),
    added(message()),
    event("response.content_part.added", [
      #(
        "part",
        json("{\"type\":\"output_text\",\"text\":\"\",\"annotations\":[]}"),
      ),
      ..text_fields()
    ]),
    event("response.output_text.delta", [
      #("delta", ir.String("synthetic λ🚀")),
      ..text_fields()
    ]),
    event("response.output_text.done", [
      #("text", ir.String("synthetic λ🚀")),
      ..text_fields()
    ]),
    event("response.content_part.done", [
      #(
        "part",
        json(
          "{\"type\":\"output_text\",\"text\":\"synthetic λ🚀\",\"annotations\":[]}",
        ),
      ),
      ..text_fields()
    ]),
    done(final_item),
    completed([final_item]),
  ]
}

fn push_all(
  values: List(ir.Value),
) -> Result(#(stream.Stream, List(stream.Event)), String) {
  list.try_fold(values, #(stream.new(), []), fn(acc, value) {
    use pair <- result.try(stream.push(acc.0, value))
    Ok(#(pair.0, list.append(acc.1, [pair.1])))
  })
}

pub fn native_request_preserves_unknown_reasoning_tools_and_multimodal_test() {
  let source =
    "{\"model\":\"synthetic\",\"stream\":true,\"previous_response_id\":\"resp_prior\",\"reasoning\":{\"effort\":\"high\"},\"vendor\":{\"opaque\":[1,true]},\"tools\":[{\"type\":\"namespace\",\"name\":\"lab\",\"tools\":[{\"type\":\"function\",\"name\":\"f\"}]}],\"input\":[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[],\"encrypted_content\":\"synthetic-ciphertext\"},{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"data:synthetic\"}]}]}"
  let assert Ok(request) = responses.decode_request(source)
  request.previous_response_id |> should.equal(Some("resp_prior"))
  responses.encode_request(request)
  |> ir.parse
  |> should.equal(ir.parse(source))
  responses.to_ir(request) |> should.be_error
}

pub fn native_response_preserves_reasoning_encrypted_content_and_usage_test() {
  let item =
    json(
      "{\"type\":\"reasoning\",\"id\":\"rs_1\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"synthetic\"}],\"encrypted_content\":\"synthetic-encrypted\",\"vendor\":{\"x\":1}}",
    )
  let document = response("completed", [item])
  let assert Ok(decoded) = responses.response_from_value(document)
  decoded.output |> should.equal([item])
  let assert Some(usage) = decoded.usage
  usage.input_tokens |> should.equal(11)
  ir.field(ir.Object(usage.extensions), "output_tokens_details")
  |> should.equal(Some(json("{\"reasoning_tokens\":3}")))
  responses.encode_response(decoded)
  |> ir.parse
  |> should.equal(ir.parse(ir.stringify(document)))
}

pub fn malformed_known_fields_are_not_extensions_test() {
  list.each(
    [
      "{\"model\":4,\"input\":[]}",
      "{\"model\":\"x\",\"stream\":\"true\"}",
      "{\"model\":\"x\",\"input\":42}",
      "{\"model\":\"x\",\"input\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"arguments\":\"{}\"}]}",
      "{\"model\":\"x\",\"input\":[{\"type\":\"reasoning\",\"encrypted_content\":42}]}",
      "{\"model\":\"x\",\"previous_response_id\":\"\"}",
    ],
    fn(source) { responses.decode_request(source) |> should.be_error },
  )
}

pub fn function_and_custom_call_pairing_test() {
  let assert Ok(request) =
    responses.decode_request(
      "{\"model\":\"x\",\"input\":[{\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"ok\"},{\"type\":\"custom_tool_call\",\"call_id\":\"custom\",\"name\":\"f\",\"input\":\"raw\"}]}",
    )
  responses.pair_input(request, [])
  |> should.equal(Ok([responses.PendingCall("custom", responses.Custom)]))
}

pub fn orphan_duplicate_and_cross_kind_results_are_rejected_test() {
  let assert Ok(request) =
    responses.decode_request(
      "{\"model\":\"x\",\"input\":[{\"type\":\"custom_tool_call_output\",\"call_id\":\"c\",\"output\":\"ok\"}]}",
    )
  responses.pair_input(request, []) |> should.be_error
  responses.pair_input(request, [responses.PendingCall("c", responses.Function)])
  |> should.be_error
  responses.pair_input(request, [responses.PendingCall("c", responses.Custom)])
  |> should.equal(Ok([]))
  let assert Ok(duplicate) =
    responses.decode_request(
      "{\"model\":\"x\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"ok\"},{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"ok\"}]}",
    )
  responses.pair_input(duplicate, [
    responses.PendingCall("c", responses.Function),
  ])
  |> should.be_error
}

pub fn compact_has_separate_contract_and_preserves_ciphertext_test() {
  responses.decode_compact_request("{\"model\":\"x\",\"stream\":true}")
  |> should.be_error
  responses.decode_compact_request("{\"model\":\"x\",\"input\":[]}")
  |> should.be_ok
  let source =
    "{\"id\":\"cmp_synthetic\",\"object\":\"response.compaction\",\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"synthetic-ciphertext\"}],\"usage\":{\"input_tokens\":8,\"output_tokens\":2,\"total_tokens\":10},\"vendor\":true}"
  let assert Ok(compact) = responses.decode_compact_response(source)
  responses.encode_compact_response(compact)
  |> ir.parse
  |> should.equal(ir.parse(source))
  responses.decode_response(source) |> should.be_error
}

pub fn text_events_have_order_ids_and_terminal_usage_test() {
  let assert Ok(#(state, events)) = push_all(text_fixture())
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  list.map(events, fn(e) { e.document }) |> should.equal(text_fixture())
  let assert Ok(last) = list.last(events)
  let assert Ok(response) = stream.terminal_response(last)
  response.id |> should.equal("resp_synthetic")
  response.usage |> should.not_equal(None)
}

pub fn every_byte_boundary_including_utf8_is_supported_test() {
  let bytes =
    text_fixture()
    |> list.map(frame)
    |> string.join("")
    |> bit_array.from_string
  let total = bit_array.byte_size(bytes)
  list.each(indices(total + 1), fn(at) {
    let assert Ok(left) = bit_array.slice(bytes, 0, at)
    let assert Ok(right) = bit_array.slice(bytes, at, total - at)
    let assert Ok(#(state, before)) = stream.feed(stream.new(), left)
    let assert Ok(#(state, after)) = stream.feed(state, right)
    stream.finish(state) |> should.equal(Ok(stream.Completed))
    list.map(list.append(before, after), fn(e) { e.document })
    |> should.equal(list.map(text_fixture(), fn(v) { json(ir.stringify(v)) }))
  })
}

pub fn one_byte_chunks_and_crlf_cr_multiline_bom_test() {
  let source =
    "\u{FEFF}: synthetic heartbeat\r\n\r\n"
    <> "event: response.created\r\ndata: {\"type\":\"response.created\",\r\ndata: \"response\":"
    <> ir.stringify(response("in_progress", []))
    <> "}\r\n\r\n"
    <> string.replace(frame(completed([])), "\n", "\r")
  let bytes = bit_array.from_string(source)
  let chunks =
    indices(bit_array.byte_size(bytes))
    |> list.map(fn(at) {
      let assert Ok(byte) = bit_array.slice(bytes, at, 1)
      byte
    })
  let assert Ok(#(state, count)) =
    list.try_fold(chunks, #(stream.new(), 0), fn(acc, chunk) {
      use pair <- result.try(stream.feed(acc.0, chunk))
      Ok(#(pair.0, acc.1 + list.length(pair.1)))
    })
  count |> should.equal(2)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
}

pub fn sse_emits_before_eof_and_never_requires_entire_stream_test() {
  let assert Ok(#(state, events)) =
    stream.feed(stream.new(), bit_array.from_string(frame(created())))
  list.length(events) |> should.equal(1)
  stream.finish(state) |> should.be_error
  let assert Ok(#(state, events)) =
    stream.feed(state, bit_array.from_string(frame(completed([]))))
  list.length(events) |> should.equal(1)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
}

pub fn incomplete_failed_error_and_cancel_are_distinct_test() {
  list.each(
    [
      #("incomplete", stream.Incomplete),
      #("failed", stream.Failed),
      #("cancelled", stream.Cancelled),
    ],
    fn(pair) {
      let value =
        event("response." <> pair.0, [#("response", response(pair.0, []))])
      let assert Ok(#(state, _)) = stream.push(started(), value)
      stream.finish(state) |> should.equal(Ok(pair.1))
    },
  )
  let assert Ok(#(state, _)) =
    stream.push(
      stream.new(),
      json(
        "{\"type\":\"error\",\"error\":{\"code\":\"synthetic_error\",\"message\":\"synthetic\"}}",
      ),
    )
  stream.finish(state) |> should.equal(Ok(stream.RemoteError))
  stream.cancel(started())
  |> stream.cancel
  |> stream.finish
  |> should.equal(Ok(stream.Cancelled))
}

pub fn eof_done_and_partial_frame_are_not_completion_test() {
  stream.finish(stream.new()) |> should.be_error
  stream.finish(started()) |> should.be_error
  stream.feed(started(), <<"data: [DONE]\n\n":utf8>>) |> should.be_error
  let assert Ok(#(state, _)) =
    stream.feed(started(), <<"data: {\"type\":":utf8>>)
  stream.finish(state) |> should.be_error
}

pub fn post_terminal_and_post_cancel_events_are_rejected_test() {
  let assert Ok(#(state, _)) = stream.push(started(), completed([]))
  stream.push(state, created()) |> should.be_error
  stream.push(stream.cancel(started()), completed([])) |> should.be_error
  let assert Ok(#(state, _)) =
    stream.feed(state, <<"data: [DONE]\n\n: keepalive\n\n":utf8>>)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
}

pub fn frame_limits_include_partial_lines_and_ignored_fields_test() {
  let state = stream.new_with_limits(8, 10, 10)
  let assert Ok(#(state, _)) = stream.feed(state, <<": 123":utf8>>)
  stream.feed(state, <<"456789":utf8>>) |> should.be_error
  stream.feed(stream.new_with_limits(8, 10, 10), <<"id: 12345\n":utf8>>)
  |> should.be_error
  stream.feed(stream.new(), <<255, 10, 10>>) |> should.be_error
}

pub fn name_sequence_and_response_identity_mismatches_rejected_test() {
  stream.feed(
    stream.new(),
    bit_array.from_string("event: error\n" <> frame(created())),
  )
  |> should.be_error
  let first =
    event("response.created", [
      #("sequence_number", ir.Integer(9)),
      #("response", response("in_progress", [])),
    ])
  let assert Ok(#(state, _)) = stream.push(stream.new(), first)
  let repeated = event("keepalive", [#("sequence_number", ir.Integer(9))])
  stream.push(state, repeated) |> should.be_error
  stream.push(state, created()) |> should.be_error
  let changed =
    json(
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"other\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}",
    )
  stream.push(state, changed) |> should.be_error
}

pub fn item_identity_and_lifecycle_rejected_test() {
  stream.push(stream.new(), added(message())) |> should.be_error
  let assert Ok(#(state, _)) = stream.push(started(), added(message()))
  stream.push(state, added(message())) |> should.be_error
  stream.push(state, completed([message()])) |> should.be_error
  stream.push(
    state,
    json(
      "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"other\",\"content_index\":0,\"delta\":\"x\"}",
    ),
  )
  |> should.be_error
  stream.push(
    state,
    event("response.output_text.delta", [
      #("delta", ir.String("x")),
      ..text_fields()
    ]),
  )
  |> should.be_error
  let assert Ok(#(state, _)) = stream.push(state, done(message()))
  stream.push(state, done(message())) |> should.be_error
}

pub fn tool_stream_requires_done_and_stable_call_identity_test() {
  let tool =
    json(
      "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"synthetic\",\"arguments\":\"\"}",
    )
  let assert Ok(#(state, _)) = stream.push(started(), added(tool))
  stream.push(state, done(tool)) |> should.be_error
  let args =
    json(
      "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc_1\",\"arguments\":\"{\\\"value\\\":42}\"}",
    )
  let assert Ok(#(state, _)) = stream.push(state, args)
  stream.push(state, args) |> should.be_error
  let final_tool =
    json(
      "{\"id\":\"fc_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"synthetic\",\"arguments\":\"{\\\"value\\\":42}\"}",
    )
  let assert Ok(#(state, _)) = stream.push(state, done(final_tool))
  let assert Ok(#(state, terminal)) =
    stream.push(state, completed([final_tool]))
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Ok(response) = stream.terminal_response(terminal)
  responses.output_calls(response)
  |> should.equal(Ok([responses.PendingCall("call_1", responses.Function)]))
}

pub fn unknown_native_events_preserved_but_not_terminal_test() {
  let extension =
    json(
      "{\"type\":\"response.vendor_extension\",\"payload\":{\"synthetic\":true}}",
    )
  let assert Ok(#(state, event)) = stream.push(started(), extension)
  event.document |> should.equal(extension)
  stream.finish(state) |> should.be_error
  stream.terminal_response(event) |> should.be_error
}

pub fn incomplete_can_end_open_items_without_success_test() {
  let assert Ok(#(state, _)) = stream.push(started(), added(message()))
  let terminal =
    event("response.incomplete", [
      #("response", response("incomplete", [message()])),
    ])
  let assert Ok(#(state, _)) = stream.push(state, terminal)
  stream.finish(state) |> should.equal(Ok(stream.Incomplete))
}

pub fn independent_streams_do_not_share_ids_or_terminal_state_test() {
  let assert Ok(#(a, _)) = stream.push(started(), added(message()))
  let assert Ok(#(b, _)) = stream.push(started(), completed([]))
  stream.finish(b) |> should.equal(Ok(stream.Completed))
  stream.finish(a) |> should.be_error
  stream.finish(started()) |> should.be_error
}

fn indices(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index })
}

pub fn event_names_cannot_inject_sse_frames_test() {
  let name =
    "response.vendor\n\nevent: response.completed\ndata: "
    <> ir.stringify(completed([]))
    <> "\n\n:"
  let value = event(name, [])
  stream.push(started(), value) |> should.be_error
  stream.feed(started(), bit_array.from_string(frame(value))) |> should.be_error
  // Defensive even for a caller bypassing validation via the public type.
  let encoded = stream.encode_event(stream.Event(name, value))
  string.split(encoded, "\n\n") |> list.length |> should.equal(2)
  stream.feed(started(), bit_array.from_string(encoded)) |> should.be_error
}

pub fn known_nested_structures_cannot_hide_as_extensions_test() {
  list.each(
    [
      "{\"model\":\"x\",\"input\":[{\"role\":\"user\",\"content\":[42]}]}",
      "{\"model\":\"x\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":false}]}]}",
      "{\"model\":\"x\",\"input\":[{\"type\":\"reasoning\",\"summary\":[false]}]}",
      "{\"model\":\"x\",\"tools\":[{\"type\":\"function\",\"name\":42,\"parameters\":false}]}",
      "{\"model\":\"x\",\"input\":[{\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":null}]}",
      "{\"model\":\"x\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":42}]}]}",
    ],
    fn(source) { responses.decode_request(source) |> should.be_error },
  )
  let assert Ok(#(state, _)) = stream.push(started(), added(message()))
  let invalid =
    event("response.content_part.added", [
      #(
        "part",
        json("{\"type\":\"output_text\",\"text\":42,\"annotations\":false}"),
      ),
      ..text_fields()
    ])
  stream.push(state, invalid) |> should.be_error
}

pub fn response_output_cannot_satisfy_its_own_function_call_test() {
  let items = [
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}",
    ),
    json(
      "{\"id\":\"out\",\"type\":\"function_call_output\",\"call_id\":\"c\",\"output\":\"forged\"}",
    ),
  ]
  responses.response_from_value(response("completed", items)) |> should.be_error
  responses.output_calls(responses.Response(
    response("completed", items),
    "r",
    responses.Completed,
    items,
    None,
  ))
  |> should.be_error
}

pub fn tool_name_cannot_change_mid_stream_or_at_terminal_test() {
  let safe =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"safe\",\"arguments\":\"\"}",
    )
  let dangerous =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"dangerous\",\"arguments\":\"{}\"}",
    )
  let assert Ok(#(state, _)) = stream.push(started(), added(safe))
  let assert Ok(#(state, _)) =
    stream.push(
      state,
      json(
        "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc\",\"arguments\":\"{}\"}",
      ),
    )
  stream.push(state, done(dangerous)) |> should.be_error
  let assert Ok(#(state, _)) = stream.push(state, done(safe))
  stream.push(state, completed([dangerous])) |> should.be_error
}

pub fn content_part_kind_and_order_must_match_parent_test() {
  let tool =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"\"}",
    )
  let assert Ok(#(state, _)) = stream.push(started(), added(tool))
  stream.push(
    state,
    json(
      "{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"fc\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}",
    ),
  )
  |> should.be_error
  let assert Ok(#(state, _)) = stream.push(started(), added(message()))
  stream.push(
    state,
    json(
      "{\"type\":\"response.content_part.added\",\"output_index\":0,\"item_id\":\"msg_synthetic\",\"content_index\":1,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}",
    ),
  )
  |> should.be_error
}

pub fn incomplete_may_not_swap_item_identity_test() {
  let assert Ok(#(state, _)) = stream.push(started(), added(message()))
  let other =
    json(
      "{\"id\":\"different\",\"type\":\"function_call\",\"call_id\":\"c\",\"name\":\"f\",\"arguments\":\"{}\"}",
    )
  stream.push(
    state,
    event("response.incomplete", [
      #("response", response("incomplete", [other])),
    ]),
  )
  |> should.be_error
}

pub fn error_event_requires_supported_error_payload_test() {
  list.each(
    [
      "{\"type\":\"error\"}",
      "{\"type\":\"error\",\"message\":42,\"code\":[],\"error\":false}",
    ],
    fn(source) { stream.push(stream.new(), json(source)) |> should.be_error },
  )
  let assert Ok(#(state, _)) =
    stream.push(
      stream.new(),
      json(
        "{\"type\":\"error\",\"message\":\"synthetic flat error\",\"code\":\"bad_request\"}",
      ),
    )
  stream.finish(state) |> should.equal(Ok(stream.RemoteError))
}

pub fn frame_limit_counts_all_delimiters_even_across_chunks_test() {
  list.each([":123456\n\n", ":123456\r\n\r\n"], fn(source) {
    let bytes = bit_array.from_string(source)
    let size = bit_array.byte_size(bytes)
    stream.feed(stream.new_with_limits(8, 10, 10), bytes) |> should.be_error
    list.each(indices(size + 1), fn(at) {
      let assert Ok(left) = bit_array.slice(bytes, 0, at)
      let assert Ok(right) = bit_array.slice(bytes, at, size - at)
      let result = case stream.feed(stream.new_with_limits(8, 10, 10), left) {
        Error(error) -> Error(error)
        Ok(#(state, _)) -> stream.feed(state, right)
      }
      result |> should.be_error
    })
    stream.feed(stream.new_with_limits(size, 10, 10), bytes) |> should.be_ok
  })
}

pub fn valid_prefix_before_malformed_frame_is_chunk_independent_test() {
  let bytes = bit_array.from_string(frame(created()) <> "data: {\"type\":\n\n")
  let count = bit_array.byte_size(bytes)
  list.each(indices(count + 1), fn(at) {
    let assert Ok(left) = bit_array.slice(bytes, 0, at)
    let assert Ok(right) = bit_array.slice(bytes, at, count - at)
    let first = stream.feed_partial(stream.new(), left)
    let #(events, next) = case first.next {
      Error(error) -> #(first.events, Error(error))
      Ok(state) -> {
        let second = stream.feed_partial(state, right)
        #(list.append(first.events, second.events), second.next)
      }
    }
    list.map(events, fn(e) { e.name }) |> should.equal(["response.created"])
    next |> should.equal(Error("invalid JSON"))
  })
}

pub fn compact_absent_output_is_preserved_not_null_or_empty_array_test() {
  let source =
    "{\"id\":\"cmp_synthetic\",\"object\":\"response.compaction\",\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"total_tokens\":3}}"
  let assert Ok(compact) = responses.decode_compact_response(source)
  compact.output |> should.equal([])
  ir.field(compact.document, "output") |> should.equal(None)
  responses.encode_compact_response(compact)
  |> ir.parse
  |> should.equal(ir.parse(source))
  responses.decode_compact_response(
    "{\"id\":\"cmp\",\"object\":\"response.compaction\",\"output\":null}",
  )
  |> should.be_error
  responses.decode_compact_response(
    "{\"id\":\"cmp\",\"object\":\"response.compaction\",\"output\":42}",
  )
  |> should.be_error
  responses.decode_response(
    "{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\"}",
  )
  |> should.be_error
}

pub fn reasoning_summary_stream_retains_encrypted_terminal_item_test() {
  let initial = json("{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[]}")
  let final_item =
    json(
      "{\"type\":\"reasoning\",\"id\":\"rs\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"synthetic reasoning\"}],\"encrypted_content\":\"synthetic-ciphertext\",\"opaque\":{\"version\":1}}",
    )
  let values = [
    created(),
    added(initial),
    json(
      "{\"type\":\"response.reasoning_summary_part.added\",\"output_index\":0,\"item_id\":\"rs\",\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}",
    ),
    json(
      "{\"type\":\"response.reasoning_summary_text.delta\",\"output_index\":0,\"item_id\":\"rs\",\"summary_index\":0,\"delta\":\"synthetic reasoning\"}",
    ),
    json(
      "{\"type\":\"response.reasoning_summary_text.done\",\"output_index\":0,\"item_id\":\"rs\",\"summary_index\":0,\"text\":\"synthetic reasoning\"}",
    ),
    json(
      "{\"type\":\"response.reasoning_summary_part.done\",\"output_index\":0,\"item_id\":\"rs\",\"summary_index\":0,\"part\":{\"type\":\"summary_text\",\"text\":\"synthetic reasoning\"}}",
    ),
    done(final_item),
    completed([final_item]),
  ]
  let assert Ok(#(state, events)) = push_all(values)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Ok(last) = list.last(events)
  let assert Ok(response) = stream.terminal_response(last)
  response.output |> should.equal([final_item])
}

pub fn custom_tool_stream_preserves_non_json_input_test() {
  let initial =
    json(
      "{\"type\":\"custom_tool_call\",\"id\":\"custom\",\"call_id\":\"call_custom\",\"name\":\"patch\",\"input\":\"\"}",
    )
  let final_item =
    json(
      "{\"type\":\"custom_tool_call\",\"id\":\"custom\",\"call_id\":\"call_custom\",\"name\":\"patch\",\"input\":\"*** synthetic patch\\nnot JSON\"}",
    )
  let assert Ok(#(state, events)) =
    push_all([
      created(),
      added(initial),
      json(
        "{\"type\":\"response.custom_tool_call_input.delta\",\"output_index\":0,\"item_id\":\"custom\",\"delta\":\"*** synthetic patch\\nnot JSON\"}",
      ),
      json(
        "{\"type\":\"response.custom_tool_call_input.done\",\"output_index\":0,\"item_id\":\"custom\",\"input\":\"*** synthetic patch\\nnot JSON\"}",
      ),
      done(final_item),
      completed([final_item]),
    ])
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Ok(last) = list.last(events)
  let assert Ok(response) = stream.terminal_response(last)
  responses.output_calls(response)
  |> should.equal(Ok([responses.PendingCall("call_custom", responses.Custom)]))
}
