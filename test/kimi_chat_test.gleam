/// Synthetic Kimi events over the actual shared-core snapshot-2 Chat codec.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/protocol/chat/http
import mimic/protocol/chat/stream
import mimic/protocol/responses/http as lifecycle
import mimic/providers/kimi/transform
import mimic/types.{Header}

fn restore(document: ir.Value) {
  Ok(transform.restore(document, "kimi-k2.8"))
}

fn event(choices: String, extra: String) {
  "data: {\"id\":\"synthetic-chat\",\"object\":\"chat.completion.chunk\",\"model\":\"kimi-for-coding\",\"choices\":"
  <> choices
  <> extra
  <> "}\n\n"
}

fn fixture() {
  event(
    "[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"reasoning_content\":\"synthetic 思考\"},\"finish_reason\":null}]",
    "",
  )
  <> event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{\\\"q\\\":\"}}]},\"finish_reason\":null}]",
    "",
  )
  <> event(
    "[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"synthetic\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]",
    "",
  )
  <> event(
    "[]",
    ",\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5},\"native_extension\":true",
  )
  <> "data: [DONE]\n\n"
}

pub fn all_byte_splits_preserve_kimi_tools_reasoning_usage_and_model_test() {
  let wire = bit_array.from_string(fixture())
  int.range(0, bit_array.byte_size(wire) + 1, Nil, fn(_, at) {
    let assert Ok(first) = bit_array.slice(wire, 0, at)
    let assert Ok(last) =
      bit_array.slice(wire, at, bit_array.byte_size(wire) - at)
    let one = stream.feed_partial(stream.new(), first, restore)
    let assert Ok(state) = one.next
    let two = stream.feed_partial(state, last, restore)
    let assert Ok(state) = two.next
    stream.finish(state) |> should.equal(Ok(stream.Completed))
    let events = list.append(one.events, two.events)
    list.length(events) |> should.equal(5)
    list.each(events, fn(event) {
      case event {
        stream.Event(document) ->
          ir.field(document, "model")
          |> should.equal(Some(ir.String("kimi-k2.8")))
        _ -> Nil
      }
    })
    let encoded = list.map(events, stream.encode_event)
    let batch =
      stream.feed_partial(
        stream.new(),
        bit_array.from_string(string.join(encoded, "")),
        fn(v) { Ok(v) },
      )
    batch.next
    |> result.try(stream.finish)
    |> should.equal(Ok(stream.Completed))
  })
}

pub fn valid_prefix_is_not_lost_on_malformed_event_test() {
  let first =
    event(
      "[{\"index\":0,\"delta\":{\"content\":\"synthetic\"},\"finish_reason\":null}]",
      "",
    )
  let batch =
    stream.feed_partial(
      stream.new(),
      bit_array.from_string(first <> "data: {bad}\n\n"),
      restore,
    )
  list.length(batch.events) |> should.equal(1)
  batch.next |> should.be_error
}

pub fn disconnected_chat_never_becomes_completed_test() {
  let batch =
    stream.feed_partial(
      stream.new(),
      bit_array.from_string(event(
        "[{\"index\":0,\"delta\":{\"content\":\"synthetic\"},\"finish_reason\":\"stop\"}]",
        "",
      )),
      restore,
    )
  let assert Ok(state) = batch.next
  stream.finish(state) |> should.be_error
}

pub fn synchronous_downstream_cancel_stops_before_next_chunk_test() {
  let assert Ok(state) =
    http.open_sse(200, [Header("Content-Type", "text/event-stream")])
  let result =
    http.run(
      state,
      0,
      fn(index) {
        case index {
          0 ->
            Ok(
              Some(#(
                bit_array.from_string(event(
                  "[{\"index\":0,\"delta\":{\"content\":\"synthetic\"},\"finish_reason\":null}]",
                  "",
                )),
                1,
              )),
            )
          _ -> panic as "cancel must stop before another pull"
        }
      },
      fn(_) { Nil },
      restore,
      fn(_) { Ok(lifecycle.Cancel) },
    )
  result |> should.equal(Ok(stream.Cancelled))
}
