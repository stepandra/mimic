import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/xai/errors
import mimic/providers/xai/events
import mimic/types

fn value(body) {
  let assert Ok(value) = ir.parse(body)
  value
}

pub fn grok_keepalive_policy_test() {
  let event = value("{\"type\":\"keepalive\",\"sequence_number\":3}")
  events.keepalive_as_comment(
    [types.Header("User-Agent", "GROK-PAGER/1.0")],
    event,
  )
  |> should.be_true
  events.keepalive_as_comment(
    [types.Header("user-agent", "grok-shell/0.2.120")],
    event,
  )
  |> should.be_true
  events.keepalive_as_comment([types.Header("User-Agent", "curl/8")], event)
  |> should.be_false
  events.keepalive_as_comment(
    [types.Header("User-Agent", "grok-shell/1")],
    value("{\"type\":\"response.completed\"}"),
  )
  |> should.be_false
}

pub fn reasoning_events_normalize_without_losing_indices_test() {
  let event =
    value(
      "{\"type\":\"response.reasoning_text.delta\",\"item_id\":\"r1\",\"output_index\":0,\"content_index\":2,\"delta\":\"think\"}",
    )
  let assert [delta] = events.normalize(event, [])
  ir.string_field(delta, "type")
  |> should.equal(Ok("response.reasoning_summary_text.delta"))
  ir.field(delta, "summary_index") |> should.equal(Some(ir.Integer(2)))
  ir.field(delta, "content_index") |> should.equal(None)
  ir.string_field(delta, "delta") |> should.equal(Ok("think"))
  let done =
    value(
      "{\"type\":\"response.reasoning_text.done\",\"content_index\":2,\"text\":\"think\"}",
    )
  let assert [text_done, part_done] = events.normalize(done, [])
  ir.string_field(text_done, "type")
  |> should.equal(Ok("response.reasoning_summary_text.done"))
  ir.string_field(part_done, "type")
  |> should.equal(Ok("response.reasoning_summary_part.done"))
  let assert Ok(part) = ir.required(part_done, "part")
  ir.string_field(part, "text") |> should.equal(Ok("think"))
}

pub fn errors_are_classified_without_echoing_payloads_test() {
  errors.classify(
    403,
    value(
      "{\"error\":{\"code\":\"unauthenticated:bad-credentials\",\"message\":\"private\"}}",
    ),
  )
  |> should.equal(errors.Status(401, None, True))
  errors.classify(403, value("{\"code\":\"permission_denied\"}"))
  |> should.equal(errors.Status(403, None, False))
  errors.classify(
    429,
    value(
      "{\"code\":\"subscription:free-usage-exhausted\",\"error\":\"private\"}",
    ),
  )
  |> should.equal(errors.Status(429, Some(86_400_000), False))
  errors.classify(429, value("{\"code\":\"rate_limit\"}"))
  |> should.equal(errors.Status(429, None, False))
}
