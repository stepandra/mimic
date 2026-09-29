/// Synthetic regression for top-level argument-event tool names. Restoration
/// runs AFTER shared raw wire identity validation, never instead of it.
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/xai/request
import mimic/providers/xai/tools

pub fn named_argument_events_restore_only_identity_fields_test() {
  let refs = [
    tools.Ref("shell__run", "run", "shell"),
    tools.Ref("clientfn_web_search_1", "web_search", ""),
  ]
  list.each(
    [
      #("response.function_call_arguments.delta", "delta"),
      #("response.function_call_arguments.done", "arguments"),
    ],
    fn(kind) {
      list.each(refs, fn(ref) {
        let event =
          ir.Object([
            #("type", ir.String(kind.0)),
            #("name", ir.String(ref.wire_name)),
            #("item_id", ir.String("item_synthetic")),
            #("call_id", ir.String("call_synthetic")),
            #("output_index", ir.Integer(0)),
            #("sequence_number", ir.Integer(4)),
            #(kind.1, ir.String("{\"name\":\"shell__run\"}")),
            #("extension", ir.Object([#("name", ir.String("shell__run"))])),
          ])
        let restored = request.restore_event(event, refs)
        ir.string_field(restored, "name") |> should.equal(Ok(ref.name))
        ir.field(restored, "namespace")
        |> should.equal(case ref.namespace {
          "" -> None
          value -> Some(ir.String(value))
        })
        tools.remove(restored, ["name", "namespace"])
        |> should.equal(tools.remove(event, ["name", "namespace"]))
        // Without this selected request's ref, do not guess a mapping.
        request.restore_event(event, []) |> should.equal(event)
      })
    },
  )
}

pub fn unrelated_and_unnamed_events_are_not_rewritten_test() {
  let refs = [tools.Ref("shell__run", "run", "shell")]
  list.each(
    [
      "keepalive",
      "response.output_text.delta",
      "response.custom_tool_call_input.done",
    ],
    fn(kind) {
      let event =
        ir.Object([
          #("type", ir.String(kind)),
          #("name", ir.String("shell__run")),
          #("delta", ir.String("shell__run")),
        ])
      request.restore_event(event, refs) |> should.equal(event)
    },
  )
  let unnamed =
    ir.Object([
      #("type", ir.String("response.function_call_arguments.done")),
      #("item_id", ir.String("item_synthetic")),
      #("arguments", ir.String("{\"name\":\"shell__run\"}")),
    ])
  request.restore_event(unnamed, refs) |> should.equal(unnamed)
}

pub fn main() {
  named_argument_events_restore_only_identity_fields_test()
  unrelated_and_unnamed_events_are_not_rewritten_test()
  io.println("xAI exact argument-event restoration regressions passed")
}
