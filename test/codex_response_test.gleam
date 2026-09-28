import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/fixtures
import mimic/providers/codex/local
import mimic/providers/codex/normalize
import mimic/providers/codex/request
import mimic/providers/codex/response
import mimic/providers/codex/routes
import mimic/providers/codex/session

fn prepared() {
  let assert Ok(decoded) = responses.decode_request(fixtures.request)
  let assert Ok(prepared) =
    request.prepare(
      decoded.document,
      request.Context(
        session.Scope("tenant", "credential", "account", "gpt-5.5", "session"),
        "synthetic-token",
        "synthetic-test/1",
        None,
      ),
      routes.Route(routes.Responses, routes.Http, True),
      None,
      ["high"],
    )
  prepared
}

pub fn codex_shared_sse_one_byte_chunks_preserve_terminal_tools_reasoning_usage_test() {
  let prepared = prepared()
  let assert Ok(initial) = response.new(prepared)
  let bytes = bit_array.from_string(fixtures.sse())
  let assert Ok(collector) = feed_bytes(initial, bytes)
  let assert Ok(completed) = response.finish(collector)
  let assert Ok(expected) = responses.decode_response(fixtures.completed)
  completed.response |> should.equal(expected)
  let assert Some(usage) = completed.response.usage
  usage.input_tokens |> should.equal(12)
  usage.output_tokens |> should.equal(4)
  let assert Ok(pending) =
    session.validate(
      Some(completed.continuation),
      prepared.identity,
      "resp_synthetic",
    )
  pending
  |> should.equal([responses.PendingCall("call_synthetic", responses.Function)])
  let assert Ok(history) = session.replay(completed.continuation)
  list.length(history) |> should.equal(3)
  let assert [_, last, ..] = history
  ir.field(last, "encrypted_content")
  |> should.equal(Some(ir.String("synthetic-opaque-not-a-signature")))
  session.validate_connection(Some(completed.continuation), Some("any-socket"))
  |> should.be_error
}

fn feed_bytes(collector, bytes) {
  case bytes {
    <<>> -> Ok(collector)
    <<byte:bytes-size(1), rest:bytes>> -> {
      use next <- result.try(response.feed(collector, byte))
      feed_bytes(next.0, rest)
    }
    _ -> Error("unaligned synthetic bytes")
  }
}

pub fn codex_shared_codec_rejects_missing_tool_arguments_done_test() {
  let without_done =
    fixtures.sse()
    |> string.split("\n\n")
    |> list.filter(fn(frame) {
      !string.starts_with(frame, "event: response.function_call_arguments.done")
    })
    |> string.join("\n\n")
  let assert Ok(collector) = response.new(prepared())
  response.feed(collector, bit_array.from_string(without_done))
  |> should.be_error
}

pub fn codex_shared_codec_rejects_eof_sparse_terminal_and_model_mismatch_test() {
  let assert Ok(collector) = response.new(prepared())
  response.finish(collector) |> should.be_error
  let assert [created, ..] = string.split(fixtures.sse(), "\n\n")
  let assert Ok(started) =
    response.feed(collector, bit_array.from_string(created <> "\n\n"))
  response.finish(started.0) |> should.be_error
  let sparse =
    created
    <> "\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":"
    <> fixtures.completed
    <> "}\n\n"
  response.feed(collector, bit_array.from_string(sparse)) |> should.be_error
  let wrong_model =
    string.replace(
      fixtures.sse(),
      "\"model\":\"gpt-5.5\"",
      "\"model\":\"wrong-model\"",
    )
  response.feed(collector, bit_array.from_string(wrong_model))
  |> should.be_error
}

pub fn codex_failed_incomplete_cancelled_and_error_events_never_create_receipts_test() {
  let assert Ok(collector) = response.new(prepared())
  let assert [created, ..] = string.split(fixtures.sse(), "\n\n")
  list.each(["failed", "incomplete", "cancelled"], fn(status) {
    let event =
      "event: response."
      <> status
      <> "\ndata: {\"type\":\"response."
      <> status
      <> "\",\"response\":{\"id\":\"resp_synthetic\",\"object\":\"response\",\"status\":\""
      <> status
      <> "\",\"output\":[]}}\n\n"
    let assert Ok(decoded) =
      response.feed(
        collector,
        bit_array.from_string(created <> "\n\n" <> event),
      )
    response.finish(decoded.0) |> should.be_error
  })
  let assert Ok(failed) =
    response.feed(
      collector,
      bit_array.from_string(
        "event: error\ndata: {\"type\":\"error\",\"code\":\"usage_limit_reached\",\"message\":\"synthetic-secret\"}\n\n",
      ),
    )
  response.finish(failed.0)
  |> should.equal(Error("Codex response did not complete successfully"))
}

pub fn codex_cancellation_invalidates_even_a_completed_collector_test() {
  let assert Ok(collector) = response.new(prepared())
  let assert Ok(decoded) =
    response.feed(collector, bit_array.from_string(fixtures.sse()))
  response.finish(decoded.0) |> should.be_ok
  let cancelled = response.cancel(decoded.0)
  response.finish(cancelled) |> should.be_error
  response.feed(cancelled, <<>>) |> should.be_error
  response.feed(decoded.0, bit_array.from_string("data: {}\n\n"))
  |> should.be_error
}

pub fn codex_compact_uses_separate_shared_document_codec_test() {
  let assert Ok(decoded) = responses.decode_compact_response(fixtures.compact)
  decoded.id |> should.equal("cmp_synthetic")
  responses.decode_response(fixtures.compact) |> should.be_error
  responses.decode_compact_response(fixtures.completed) |> should.be_error
  let plan = prepared()
  response.new(
    request.Prepared(..plan, target: "/backend-api/codex/responses/compact"),
  )
  |> should.be_error
}

pub fn codex_native_compact_absent_output_is_preserved_test() {
  let source =
    "{\"id\":\"cmp_synthetic_empty\",\"object\":\"response.compaction\"}"
  let assert Ok(decoded) = responses.decode_compact_response(source)
  ir.field(decoded.document, "output") |> should.equal(None)
  let assert Ok(roundtrip) =
    ir.parse(responses.encode_compact_response(decoded))
  ir.field(roundtrip, "output") |> should.equal(None)
  responses.decode_compact_response(
    "{\"id\":\"cmp_bad\",\"object\":\"response.compaction\",\"output\":null}",
  )
  |> should.be_error
}

pub fn codex_receipt_rejects_reused_completed_historical_call_id_test() {
  let plan = prepared()
  let assert Ok(history) =
    ir.parse(
      "[{\"type\":\"function_call\",\"call_id\":\"call_synthetic\",\"name\":\"lookup\",\"arguments\":\"{}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_synthetic\",\"output\":\"old result\"}]",
    )
  let plan =
    request.Prepared(..plan, body: normalize.put(plan.body, "input", history))
  let assert Ok(collector) = response.new(plan)
  response.feed(collector, bit_array.from_string(fixtures.sse()))
  |> should.be_error
}

pub fn codex_selected_attempt_plan_must_match_successful_runtime_account_test() {
  let plans = process.new_subject()
  let rejected = prepared()
  let chosen =
    request.Prepared(
      ..rejected,
      identity: session.Identity("chosen-session", "chosen-cache"),
    )
  process.send(plans, #("account-a", rejected))
  process.send(plans, #("account-b", chosen))
  local.take_plan(plans, "account-b") |> should.equal(Ok(chosen))
  process.receive(plans, 0) |> should.equal(Error(Nil))
}

pub fn codex_non_success_terminal_preserves_document_details_and_usage_test() {
  let assert Ok(collector) = response.new(prepared())
  let assert [created, ..] = string.split(fixtures.sse(), "\n\n")
  list.each(["incomplete", "failed", "cancelled"], fn(status) {
    let document =
      "{\"id\":\"resp_synthetic\",\"object\":\"response\",\"status\":\""
      <> status
      <> "\",\"output\":[],\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":12,\"output_tokens\":4,\"output_tokens_details\":{\"reasoning_tokens\":2}}}"
    let assert Ok(expected) = responses.decode_response(document)
    let frame =
      created
      <> "\n\nevent: response."
      <> status
      <> "\ndata: {\"type\":\"response."
      <> status
      <> "\",\"response\":"
      <> document
      <> "}\n\n"
    let assert Ok(decoded) =
      response.feed(collector, bit_array.from_string(frame))
    response.finish_terminal(decoded.0)
    |> should.equal(Ok(response.Unsuccessful(expected)))
    response.finish(decoded.0) |> should.be_error
  })
}
