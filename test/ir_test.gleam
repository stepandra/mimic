import gleam/option.{None, Some}
import mimic/ir

pub fn arbitrary_json_tree_roundtrip_test() {
  // Synthetic fixture: recursion and numeric kinds must survive JSON encoding.
  let source = "{\"a\":[null,true,1,1.25,{\"unknown\":{\"nested\":\"✓\"}}]}"
  let assert Ok(parsed) = ir.parse(source)
  let assert Ok(encoded) = ir.parse(ir.stringify(parsed))
  assert parsed == encoded
}

pub fn canonical_turn_and_stream_event_test() {
  let turn =
    ir.Turn(
      "assistant",
      [
        ir.Thinking("private", Some("synthetic-signature"), []),
        ir.Text("hello", []),
        ir.ToolCall(
          "call-1",
          "lookup",
          ir.Object([#("x", ir.Integer(1))]),
          None,
          [],
        ),
      ],
      False,
      [],
    )
  let request =
    ir.Request(
      "synthetic-model",
      None,
      "system",
      [turn],
      Some(64),
      "max_tokens",
      Some(True),
      [],
      ir.Constructed,
    )
  assert request.turns == [turn]
  let delta = ir.ToolInputDelta(1, "{\"x\":")
  assert delta == ir.ToolInputDelta(1, "{\"x\":")
}
