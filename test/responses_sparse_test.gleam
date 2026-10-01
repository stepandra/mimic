import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/responses/http
import mimic/protocol/responses/sparse
import mimic/protocol/responses/stream
import mimic/protocol/responses/websocket as ws

// Exact synthetic event data from pinned codex_native_fidelity_test.go:31-33.
// These are executor fixture bytes, not captured provider or gateway traffic.
pub fn metadata() -> String {
  "{\"type\":\"codex.response.metadata\",\"headers\":{\"x-models-etag\":\"models-v1\",\"x-codex-turn-state\":\"turn-1\",\"x-codex-safety-buffering-enabled\":\"true\",\"x-codex-safety-buffering-faster-model\":\"fixture-model\"},\"future\":{\"ok\":true}}"
}

pub fn done() -> String {
  "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}"
}

pub fn completed() -> String {
  "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"output\":[],\"future\":{\"ok\":true},\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}"
}

pub fn policy(projection: sparse.Projection) -> stream.Policy {
  stream.NativeSparse(projection, 65_536, 100)
}

fn sequence(
  projection: sparse.Projection,
) -> #(stream.Stream, List(stream.WireEvent)) {
  let assert Ok(state) = stream.new_with_policy(policy(projection))
  list.fold([metadata(), done(), completed()], #(state, []), fn(acc, data) {
    let assert Ok(#(state, event)) = stream.push_json(acc.0, data)
    #(state, list.append(acc.1, [event]))
  })
}

pub fn pinned_executor_data_preserved_but_not_authorized_test() {
  let #(state, events) = sequence(sparse.Transparent)
  list.map(events, stream.wire_data)
  |> should.equal([metadata(), done(), completed()])
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Some(report) = stream.terminal_report(state)
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.MissingCreated]))
  let assert sparse.Reconstructed(response) = sparse.reconstruction(report)
  response.id |> should.equal("resp_1")
  list.length(response.output) |> should.equal(1)
  response.usage |> should.not_equal(None)
  ir.field(response.document, "future") |> should.not_equal(None)
}

pub fn source_handler_projection_is_separate_from_executor_test() {
  let #(state, events) = sequence(sparse.HydrateCompleted)
  let assert Ok(terminal) = list.last(events)
  let event = stream.wire_event(terminal)
  let assert Some(response) = ir.field(event.document, "response")
  let assert Some(ir.Array([item])) = ir.field(response, "output")
  ir.field(item, "id") |> should.equal(Some(ir.String("msg_1")))
  let assert Some(report) = stream.terminal_report(state)
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.MissingCreated]))
  // Projection does not invent object/created/lifecycle events on the wire.
  ir.field(response, "object") |> should.equal(None)
  list.length(events) |> should.equal(3)
}

pub fn strict_still_denies_pinned_sparse_fixture_test() {
  stream.push_json(stream.new(), metadata()) |> should.be_error
}

pub fn fragmented_sse_and_ws_share_the_observer_test() {
  let data =
    "data: "
    <> metadata()
    <> "\n\n"
    <> "data: "
    <> done()
    <> "\n\n"
    <> "data: "
    <> completed()
    <> "\n\n"
  let assert Ok(state) = stream.new_with_policy(policy(sparse.Transparent))
  let #(state, events) = feed_bytes(state, bit_array.from_string(data), [])
  list.map(events, stream.wire_data)
  |> should.equal([metadata(), done(), completed()])
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Some(report) = stream.terminal_report(state)
  sparse.status(report) |> should.equal(responses.Completed)
}

fn fresh() -> stream.Stream {
  let assert Ok(state) = stream.new_with_policy(policy(sparse.Transparent))
  state
}

fn push(state: stream.Stream, json: String) -> stream.Stream {
  let assert Ok(#(state, _)) = stream.push_json(state, json)
  state
}

fn created() -> String {
  "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}"
}

fn finished(state: stream.Stream, json: String) -> sparse.Report {
  let state = push(state, json)
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  let assert Some(report) = stream.terminal_report(state)
  report
}

fn item_event(name: String, index: Int, item: ir.Value) -> String {
  ir.stringify(
    ir.Object([
      #("type", ir.String(name)),
      #("output_index", ir.Integer(index)),
      #("item", item),
    ]),
  )
}

fn json(source: String) -> ir.Value {
  let assert Ok(value) = ir.parse(source)
  value
}

pub fn no_observations_never_fabricate_empty_output_test() {
  let report = finished(fresh(), completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.MissingOutput]))
  sparse.authority(report)
  |> should.equal(
    sparse.Ineligible([sparse.MissingOutput, sparse.MissingCreated]),
  )
  let report =
    finished(
      push(fresh(), created()),
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\"}}",
    )
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.MissingOutput]))
  // A native [] summary is still ambiguous with created. Strict is unchanged.
  let report = finished(push(fresh(), created()), completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.MissingOutput]))
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.MissingOutput]))
}

pub fn missing_or_conflicting_terminal_identity_status_and_output_reject_test() {
  let state = push(fresh(), created())
  list.each(
    [
      "{\"type\":\"response.completed\",\"response\":{}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"other\",\"output\":[]}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"failed\",\"output\":[]}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"object\":\"chat.completion\",\"output\":[]}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":null}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":{}}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"usage\":{\"input_tokens\":-1,\"output_tokens\":0}}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"usage\":{\"input_tokens\":1}}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":3}}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"error\":{\"message\":\"SYNTHETIC\"}}}",
      "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[],\"incomplete_details\":{\"reason\":\"SYNTHETIC\"}}}",
    ],
    fn(event) { stream.push_json(state, event) |> should.be_error },
  )
  let terminal = push(state, completed())
  stream.push_json(terminal, completed()) |> should.be_error
  stream.push_json(terminal, metadata()) |> should.be_error
}

pub fn ordering_duplicate_items_and_response_ids_reject_test() {
  let item =
    json(
      "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}",
    )
  stream.push_json(fresh(), item_event("response.output_item.done", 1, item))
  |> should.be_error
  stream.push_json(fresh(), item_event("response.output_item.done", -1, item))
  |> should.be_error
  let state = push(fresh(), done())
  stream.push_json(state, done()) |> should.be_error
  stream.push_json(state, item_event("response.output_item.done", 1, item))
  |> should.be_error
  stream.push_json(state, created()) |> should.be_error
  let state =
    push(
      fresh(),
      "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"resp_1\"}}",
    )
  stream.push_json(
    state,
    "{\"type\":\"response.queued\",\"response\":{\"id\":\"other\"}}",
  )
  |> should.be_error
  let state = push(fresh(), "{\"type\":\"keepalive\",\"sequence_number\":2}")
  list.each(["2", "1", "-1"], fn(number) {
    stream.push_json(
      state,
      "{\"type\":\"keepalive\",\"sequence_number\":" <> number <> "}",
    )
    |> should.be_error
  })
  stream.push_json(fresh(), "{\"type\":\"keepalive\",\"sequence_number\":-1}")
  |> should.be_error
}

pub fn initial_reasoning_is_never_erased_or_promoted_test() {
  let initial =
    json(
      "{\"id\":\"rs\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"observed\"}],\"encrypted_content\":\"synthetic-opaque\"}",
    )
  let state =
    push(fresh(), item_event("response.output_item.added", 0, initial))
  // Withdrawn 3190bc review reproducer: omitted final item must NOT promote seed.
  stream.push_json(
    state,
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item_id\":\"rs\"}",
  )
  |> should.be_error
  stream.push_json(
    state,
    item_event(
      "response.output_item.done",
      0,
      json(
        "{\"id\":\"rs\",\"type\":\"reasoning\",\"encrypted_content\":\"synthetic-opaque\"}",
      ),
    ),
  )
  |> should.be_error
  let report = finished(state, completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.OpenItems]))
  let state = push(state, item_event("response.output_item.done", 0, initial))
  let report = finished(state, completed())
  let assert sparse.Reconstructed(response) = sparse.reconstruction(report)
  response.output |> should.equal([initial])
}

pub fn initial_and_final_content_cannot_disagree_test() {
  let initial =
    json(
      "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"observed\",\"annotations\":[{\"synthetic\":true}]}]}",
    )
  let state =
    push(fresh(), item_event("response.output_item.added", 0, initial))
  list.each(
    [
      "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}",
      "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"different\",\"annotations\":[{\"synthetic\":true}]}]}",
      "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"observed\",\"annotations\":[]}]}",
      "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"refusal\",\"refusal\":\"observed\"}]}",
    ],
    fn(item) {
      stream.push_json(
        state,
        item_event("response.output_item.done", 0, json(item)),
      )
      |> should.be_error
    },
  )
}

pub fn sparse_text_delta_requires_full_consistent_final_snapshot_test() {
  let delta =
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"ok\"}"
  let state = push(push(fresh(), created()), delta)
  let report = finished(state, completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.OpenItems]))
  stream.push_json(
    state,
    string.replace(delta, "ok", "wrong")
      |> string.replace("\"delta\":", "\"text\":")
      |> string.replace(".delta", ".done"),
  )
  |> should.be_error
  let state = push(state, done())
  let report = finished(state, completed())
  let assert sparse.ContinuationEligible(response) = sparse.authority(report)
  list.length(response.output) |> should.equal(1)
  stream.push_json(state, delta) |> should.be_error
  let changed = string.replace(done(), "\"ok\"", "\"changed\"")
  stream.push_json(push(fresh(), delta), changed) |> should.be_error
}

pub fn refusal_reasoning_text_and_summary_preserved_test() {
  list.each(
    [
      #(
        "refusal",
        "content",
        "refusal",
        "message",
        "\"role\":\"assistant\",",
        "refusal",
      ),
      #("reasoning_text", "content", "reasoning_text", "reasoning", "", "text"),
      #(
        "reasoning_summary_text",
        "summary",
        "summary_text",
        "reasoning",
        "\"encrypted_content\":\"synthetic-opaque\",",
        "text",
      ),
    ],
    fn(vector) {
      let #(event, group, part_kind, item_kind, extra, field) = vector
      let delta =
        "{\"type\":\"response."
        <> event
        <> ".delta\",\"output_index\":0,\"item_id\":\"s\",\""
        <> group
        <> "_index\":0,\"delta\":\"SYNTHETIC λ\"}"
      let item =
        json(
          "{\"id\":\"s\",\"type\":\""
          <> item_kind
          <> "\","
          <> extra
          <> "\""
          <> group
          <> "\":[{\"type\":\""
          <> part_kind
          <> "\",\""
          <> field
          <> "\":\"SYNTHETIC λ\"}]}",
        )
      let state = push(fresh(), delta)
      let state = push(state, item_event("response.output_item.done", 0, item))
      let report = finished(state, completed())
      let assert sparse.Reconstructed(response) = sparse.reconstruction(report)
      response.output |> should.equal([item])
    },
  )
}

pub fn full_part_snapshot_closes_sparse_text_but_not_the_item_test() {
  let part =
    "{\"type\":\"response.content_part.done\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"ok\"}}"
  let state = push(fresh(), part)
  sparse.reconstruction(finished(state, completed()))
  |> should.equal(sparse.Unknown([sparse.OpenItems]))
  stream.push_json(state, part) |> should.be_error
  let delta =
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"x\"}"
  stream.push_json(state, delta) |> should.be_error
  let state = push(state, done())
  let report = finished(state, completed())
  let assert sparse.Reconstructed(_) = sparse.reconstruction(report)
}

pub fn raw_tool_identity_is_checked_before_alias_restoration_test() {
  let initial =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"name\":\"raw__namespace_tool\",\"call_id\":\"call\",\"arguments\":\"\"}",
    )
  let state =
    push(fresh(), item_event("response.output_item.added", 0, initial))
  let good =
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc\",\"name\":\"raw__namespace_tool\",\"call_id\":\"call\",\"delta\":\"{}\"}"
  stream.push_json(
    state,
    string.replace(good, "raw__namespace_tool", "friendly"),
  )
  |> should.be_error
  stream.push_json(
    state,
    string.replace(good, "\"call_id\":\"call\"", "\"call_id\":\"other\""),
  )
  |> should.be_error
  stream.push_json(
    state,
    string.replace(good, "\"name\":\"raw__namespace_tool\"", "\"name\":null"),
  )
  |> should.be_error
  let state = push(state, good)
  let final =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"name\":\"raw__namespace_tool\",\"call_id\":\"call\",\"arguments\":\"{}\"}",
    )
  let state = push(state, item_event("response.output_item.done", 0, final))
  let report = finished(state, completed())
  let assert sparse.Reconstructed(response) = sparse.reconstruction(report)
  response.output |> should.equal([final])
}

pub fn function_and_custom_tool_input_integrity_and_pairing_test() {
  list.each(
    [
      #("function_call", "function_call_arguments", "arguments"),
      #("custom_tool_call", "custom_tool_call_input", "input"),
    ],
    fn(vector) {
      let #(kind, event, field) = vector
      let delta =
        "{\"type\":\"response."
        <> event
        <> ".delta\",\"output_index\":0,\"item_id\":\"fc\",\"name\":\"tool\",\"call_id\":\"call\",\"delta\":\"{}\"}"
      let item =
        json(
          "{\"id\":\"fc\",\"type\":\""
          <> kind
          <> "\",\"name\":\"tool\",\"call_id\":\"call\",\""
          <> field
          <> "\":\"{}\"}",
        )
      let state = push(push(fresh(), created()), delta)
      let changed =
        item_event("response.output_item.done", 0, item)
        |> string.replace("\"{}\"", "\"different\"")
      stream.push_json(state, changed) |> should.be_error
      let state = push(state, item_event("response.output_item.done", 0, item))
      let report = finished(state, completed())
      let assert sparse.ContinuationEligible(response) =
        sparse.authority(report)
      let assert Ok([call]) = responses.output_calls(response)
      call.id |> should.equal("call")
      stream.push_json(
        state,
        item_event(
          "response.output_item.done",
          1,
          json(string.replace(
            ir.stringify(item),
            "\"id\":\"fc\"",
            "\"id\":\"other\"",
          )),
        ),
      )
      |> should.be_error
    },
  )
}

pub fn supplied_terminal_snapshot_validates_all_observed_content_test() {
  let delta =
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"ok\"}"
  let state = push(push(fresh(), created()), delta)
  let terminal =
    string.replace(
      completed(),
      "\"output\":[]",
      "\"output\":[{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]",
    )
  let report = finished(state, terminal)
  let assert sparse.ContinuationEligible(_) = sparse.authority(report)
  stream.push_json(state, string.replace(terminal, "\"ok\"", "\"different\""))
  |> should.be_error
  let state = push(state, done())
  stream.push_json(state, string.replace(terminal, "\"ok\"", "\"different\""))
  |> should.be_error
}

pub fn unknown_output_is_preserved_without_claiming_reconstruction_test() {
  let item =
    json(
      "{\"id\":\"future\",\"type\":\"future_provider_tool\",\"future\":{\"synthetic\":true}}",
    )
  let state =
    push(
      push(fresh(), created()),
      item_event("response.output_item.done", 0, item),
    )
  let report = finished(state, completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.UnknownExtension]))
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.UnknownExtension]))
  stream.push_json(fresh(), "{\"type\":\"response.future_unknown\"}")
  |> should.be_error
}

pub fn pinned_duplex_idless_items_remain_unknown_not_fabricated_test() {
  // Exact response item shape in pinned codex_websockets_duplex_test.go:82.
  let idless =
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"STEER_OK\"}]}}"
  let state = push(push(fresh(), created()), idless)
  let report = finished(state, completed())
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.MissingItemIdentity]))
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.MissingItemIdentity]))
  let idless_tool =
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"lookup\",\"arguments\":\"{}\"}]}}"
  let report = finished(push(fresh(), created()), idless_tool)
  sparse.reconstruction(report)
  |> should.equal(sparse.Unknown([sparse.MissingItemIdentity]))
  let assert Ok(#(_, event)) = stream.push_json(fresh(), idless)
  stream.wire_data(event) |> should.equal(idless)
}

pub fn every_noncompleted_terminal_is_receipt_ineligible_test() {
  list.each(
    [
      #("incomplete", stream.Incomplete),
      #("failed", stream.Failed),
      #("cancelled", stream.Cancelled),
    ],
    fn(vector) {
      let #(status, outcome) = vector
      let state = fresh() |> push(created()) |> push(done())
      let terminal = completed() |> string.replace("completed", status)
      let state = push(state, terminal)
      stream.finish(state) |> should.equal(Ok(outcome))
      let assert Some(report) = stream.terminal_report(state)
      sparse.authority(report)
      |> should.equal(sparse.Ineligible([sparse.NonCompleted]))
    },
  )
  let state =
    push(fresh(), "{\"type\":\"error\",\"error\":{\"message\":\"SYNTHETIC\"}}")
  stream.finish(state) |> should.equal(Ok(stream.RemoteError))
  let assert Some(report) = stream.terminal_report(state)
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.NonCompleted]))
}

pub fn added_nonempty_text_and_tool_placeholders_are_not_lost_test() {
  let item =
    json(
      "{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"o\"}]}",
    )
  let delta =
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"k\"}"
  let state =
    fresh()
    |> push(item_event("response.output_item.added", 0, item))
    |> push(delta)
    |> push(done())
  let assert sparse.Reconstructed(response) =
    sparse.reconstruction(finished(state, completed()))
  let assert [item] = response.output
  ir.field(item, "content")
  |> should.equal(
    Some(ir.Array([json("{\"type\":\"output_text\",\"text\":\"ok\"}")])),
  )
  let initial =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"name\":\"tool\",\"call_id\":\"call\",\"arguments\":\"\"}",
    )
  let state =
    fresh() |> push(item_event("response.output_item.added", 0, initial))
  let state =
    push(
      state,
      "{\"type\":\"response.function_call_arguments.done\",\"output_index\":0,\"item_id\":\"fc\",\"arguments\":\"{}\"}",
    )
  let final =
    json(
      "{\"id\":\"fc\",\"type\":\"function_call\",\"name\":\"tool\",\"call_id\":\"call\",\"arguments\":\"{}\"}",
    )
  let report =
    finished(
      push(state, item_event("response.output_item.done", 0, final)),
      completed(),
    )
  let assert sparse.Reconstructed(response) = sparse.reconstruction(report)
  response.output |> should.equal([final])
}

pub fn item_id_response_id_and_part_index_conflicts_reject_test() {
  let delta =
    "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"msg_1\",\"content_index\":0,\"delta\":\"ok\"}"
  let state = push(fresh(), delta)
  stream.push_json(state, string.replace(delta, "msg_1", "changed"))
  |> should.be_error
  stream.push_json(
    state,
    string.replace(delta, "\"content_index\":0", "\"content_index\":2"),
  )
  |> should.be_error
  let state =
    push(fresh(), "{\"type\":\"keepalive\",\"response_id\":\"resp_1\"}")
  stream.push_json(
    state,
    "{\"type\":\"keepalive\",\"response_id\":\"different\"}",
  )
  |> should.be_error
  stream.push_json(state, "{\"type\":\"keepalive\",\"response_id\":null}")
  |> should.be_error
}

pub fn late_tool_ids_are_unique_before_done_is_emitted_test() {
  let delta =
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"item_id\":\"fc1\",\"delta\":\"{}\"}"
  let final =
    json(
      "{\"id\":\"fc1\",\"type\":\"function_call\",\"name\":\"tool\",\"call_id\":\"shared\",\"arguments\":\"{}\"}",
    )
  let state =
    fresh()
    |> push(delta)
    |> push(item_event("response.output_item.done", 0, final))
  let second_delta =
    delta
    |> string.replace("\"output_index\":0", "\"output_index\":1")
    |> string.replace("fc1", "fc2")
  let state = push(state, second_delta)
  stream.push_json(
    state,
    item_event(
      "response.output_item.done",
      1,
      json(string.replace(ir.stringify(final), "fc1", "fc2")),
    ),
  )
  |> should.be_error
}

pub fn limits_count_actual_data_bytes_events_items_and_parts_test() {
  let raw = " \n" <> metadata() <> "  "
  let size = bit_array.byte_size(bit_array.from_string(raw))
  let assert Ok(state) =
    stream.new_with_policy(stream.NativeSparse(sparse.Transparent, size - 1, 10))
  stream.push_json(state, raw) |> should.be_error
  let assert Ok(state) =
    stream.new_with_policy(stream.NativeSparse(sparse.Transparent, size, 1))
  let state = push(state, raw)
  stream.push_json(state, metadata()) |> should.be_error
  let assert Ok(state) =
    stream.new_with_policy_and_limits(policy(sparse.Transparent), 1024, 1, 1)
  let state = push(state, done())
  stream.push_json(
    state,
    string.replace(done(), "\"output_index\":0", "\"output_index\":1")
      |> string.replace("msg_1", "msg_2"),
  )
  |> should.be_error
  let item =
    json(
      "{\"id\":\"r\",\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"1\"},{\"type\":\"summary_text\",\"text\":\"2\"}]}",
    )
  stream.push_json(
    fresh_with_parts_limit(),
    item_event("response.output_item.done", 0, item),
  )
  |> should.be_error
  list.each(
    [
      stream.NativeSparse(sparse.Transparent, 0, 1),
      stream.NativeSparse(sparse.Transparent, 16_777_217, 1),
      stream.NativeSparse(sparse.Transparent, 1, 100_001),
    ],
    fn(policy) { stream.new_with_policy(policy) |> should.be_error },
  )
}

fn fresh_with_parts_limit() -> stream.Stream {
  let assert Ok(state) =
    stream.new_with_policy_and_limits(policy(sparse.Transparent), 1024, 4, 1)
  state
}

pub fn hydration_respects_the_projected_frame_limit_test() {
  let first = done()
  let second =
    first
    |> string.replace("\"output_index\":0", "\"output_index\":1")
    |> string.replace("msg_1", "msg_2")
  let limit = bit_array.byte_size(bit_array.from_string(completed())) + 10
  let assert Ok(state) =
    stream.new_with_policy_and_limits(
      policy(sparse.HydrateCompleted),
      limit,
      4,
      4,
    )
  let state = state |> push(first) |> push(second)
  stream.push_json(state, completed())
  |> should.equal(Error("Responses projected event exceeds byte limit"))
}

pub fn multiline_utf8_data_round_trips_without_json_reencoding_test() {
  let raw = "{\n \"type\": \"codex.response.metadata\", \"future\": \"λ😀\" \n}"
  let assert Ok(#(_, event)) = stream.push_json(fresh(), raw)
  stream.wire_data(event) |> should.equal(raw)
  let batch =
    stream.feed_wire_partial(
      fresh(),
      bit_array.from_string(stream.encode_wire_event(event)),
    )
  let assert [received] = batch.events
  stream.wire_data(received) |> should.equal(raw)
  batch.next |> should.be_ok
}

pub fn malformed_coalesced_frames_preserve_only_valid_prefix_test() {
  let bytes = "data: " <> metadata() <> "\n\ndata: {invalid}\n\n"
  let batch = stream.feed_wire_partial(fresh(), bit_array.from_string(bytes))
  list.map(batch.events, stream.wire_data) |> should.equal([metadata()])
  batch.next |> should.be_error
  let batch =
    stream.feed_wire_partial(
      fresh(),
      bit_array.from_string(
        "data: "
        <> metadata()
        <> "\n\nevent: response.failed\ndata: "
        <> done()
        <> "\n\n",
      ),
    )
  list.length(batch.events) |> should.equal(1)
  batch.next |> should.be_error
  let batch =
    stream.feed_wire_partial(fresh(), <<
      "data: {\"type\":\"keepalive\",\"x\":1,\"x\":2}\n\n":utf8,
    >>)
  batch.next |> should.be_error
}

pub fn cancellation_clears_observations_and_all_authority_test() {
  let state = push(fresh(), done()) |> stream.cancel
  stream.finish(state) |> should.equal(Ok(stream.Cancelled))
  stream.terminal_report(state) |> should.equal(None)
  stream.push_json(state, completed()) |> should.be_error
  let completed =
    fresh() |> push(created()) |> push(done()) |> push(completed())
  stream.terminal_report(completed) |> should.not_equal(None)
  stream.terminal_report(stream.cancel(completed)) |> should.equal(None)
}

fn next_chunk(chunks: List(BitArray)) {
  case chunks {
    [] -> Ok(None)
    [chunk, ..rest] -> Ok(Some(#(chunk, rest)))
  }
}

fn fixture_bytes() -> BitArray {
  bit_array.from_string(
    "data: "
    <> metadata()
    <> "\n\n"
    <> "data: "
    <> done()
    <> "\n\ndata: "
    <> completed()
    <> "\n\n",
  )
}

pub fn http_clean_eof_is_required_before_returning_report_test() {
  let events = process.new_subject()
  let cancellation = process.new_subject()
  let run = fn(chunks) {
    http.run_wire_fold(
      fresh(),
      chunks,
      next_chunk,
      fn(_) { process.send(cancellation, Nil) },
      [],
      fn(acc, event) {
        process.send(events, stream.wire_event(event).name)
        Ok(#(list.append(acc, [stream.wire_data(event)]), http.Continue))
      },
    )
  }
  let assert Ok(#(stream.Completed, Some(report), output)) =
    run([fixture_bytes()])
  sparse.authority(report)
  |> should.equal(sparse.Ineligible([sparse.MissingCreated]))
  output |> should.equal([metadata(), done(), completed()])
  process.receive(cancellation, 0) |> should.equal(Ok(Nil))
  let failure = run([fixture_bytes(), <<"data: {invalid}\n\n":utf8>>])
  failure |> should.equal(Error(http.Protocol("invalid JSON")))
  process.receive(cancellation, 0) |> should.equal(Ok(Nil))
  // Valid prefix is emitted in both runs; failing run returns no accumulator.
  list.each([1, 2, 3, 4, 5, 6], fn(_) {
    process.receive(events, 0) |> should.be_ok
  })
}

pub fn http_cancel_downstream_and_transport_errors_return_no_authority_test() {
  let cancelled = process.new_subject()
  let result =
    http.run_wire_fold(
      fresh(),
      [fixture_bytes()],
      next_chunk,
      fn(_) { process.send(cancelled, Nil) },
      0,
      fn(acc, _) { Ok(#(acc + 1, http.Cancel)) },
    )
  result |> should.equal(Ok(#(stream.Cancelled, None, 1)))
  process.receive(cancelled, 0) |> should.equal(Ok(Nil))
  let failure =
    http.run_wire_fold(
      fresh(),
      [fixture_bytes()],
      next_chunk,
      fn(_) { process.send(cancelled, Nil) },
      0,
      fn(_, _) { Error("synthetic write failure") },
    )
  failure |> should.equal(Error(http.Downstream("synthetic write failure")))
  process.receive(cancelled, 0) |> should.equal(Ok(Nil))
  let failure =
    http.run_wire_fold(
      fresh(),
      False,
      fn(read) {
        case read {
          False -> Ok(Some(#(fixture_bytes(), True)))
          True -> Error("synthetic read failure")
        }
      },
      fn(_) { process.send(cancelled, Nil) },
      0,
      fn(acc, _) { Ok(#(acc + 1, http.Continue)) },
    )
  failure |> should.equal(Error(http.Upstream("synthetic read failure")))
  process.receive(cancelled, 0) |> should.equal(Ok(Nil))
}

fn scope() -> ws.Scope {
  ws.Scope("tenant", "codex", "credential", "account", "synthetic", "client")
}

fn create_request(previous: String) -> String {
  "{\"type\":\"response.create\",\"model\":\"synthetic\",\"input\":[]"
  <> previous
  <> "}"
}

fn ws_active() -> ws.Session {
  let assert Ok(session) =
    ws.new_with_policy(
      scope(),
      "physical-generation",
      policy(sparse.Transparent),
    )
  let assert Ok(#(session, _)) =
    ws.create(session, scope(), "physical-generation", create_request(""))
  session
}

pub fn ws_wire_completion_without_created_cannot_grant_a_cursor_test() {
  let session =
    list.fold(
      [metadata(), done(), completed()],
      ws_active(),
      fn(session, message) {
        let assert Ok(#(session, event)) =
          ws.receive_wire(session, scope(), "physical-generation", message)
        stream.wire_data(event) |> should.equal(message)
        session
      },
    )
  ws.create(
    session,
    scope(),
    "physical-generation",
    create_request(",\"previous_response_id\":\"resp_1\""),
  )
  |> should.be_error
  ws.create(session, scope(), "physical-generation", create_request(""))
  |> should.be_ok
}

pub fn ws_eligible_cursor_still_requires_same_scope_generation_and_open_socket_test() {
  let session =
    list.fold(
      [created(), done(), completed()],
      ws_active(),
      fn(session, message) {
        let assert Ok(#(session, _)) =
          ws.receive_wire(session, scope(), "physical-generation", message)
        session
      },
    )
  let followup = create_request(",\"previous_response_id\":\"resp_1\"")
  ws.create(session, scope(), "physical-generation", followup) |> should.be_ok
  ws.create(session, scope(), "different-generation", followup)
  |> should.be_error
  ws.create(
    session,
    ws.Scope(..scope(), account: "other-account"),
    "physical-generation",
    followup,
  )
  |> should.be_error
  let #(session, close) = ws.cancel(session)
  close |> should.be_true
  ws.create(session, scope(), "physical-generation", followup)
  |> should.be_error
}

fn feed_bytes(
  state: stream.Stream,
  bytes: BitArray,
  events: List(stream.WireEvent),
) -> #(stream.Stream, List(stream.WireEvent)) {
  case bytes {
    <<>> -> #(state, events)
    <<byte:8, rest:bits>> -> {
      let batch = stream.feed_wire_partial(state, <<byte:8>>)
      let assert Ok(state) = batch.next
      feed_bytes(state, rest, list.append(events, batch.events))
    }
    _ -> panic as "test input must be byte aligned"
  }
}

type TestModule {
  ResponsesSparseTest
  ResponsesSparseScenario
}

type EunitOption {
  Verbose
  ScaleTimeouts(Int)
}

@external(erlang, "gleeunit_ffi", "run_eunit")
fn run_eunit(
  modules: List(TestModule),
  options: List(EunitOption),
) -> Result(Nil, Nil)

/// Focused entrypoint; never runs unrelated provider/native/live scenarios.
pub fn main() {
  let assert Ok(_) =
    run_eunit([ResponsesSparseTest, ResponsesSparseScenario], [
      Verbose,
      ScaleTimeouts(10),
    ])
  Nil
}
