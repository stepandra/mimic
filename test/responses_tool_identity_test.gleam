import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/protocol/responses/stream

// Synthetic raw provider identities. Restore aliases only after validation.
fn created() -> ir.Value {
  ir.Object([
    #("type", ir.String("response.created")),
    #(
      "response",
      ir.Object([
        #("id", ir.String("response_synthetic")),
        #("object", ir.String("response")),
        #("status", ir.String("in_progress")),
        #("output", ir.Array([])),
      ]),
    ),
  ])
}

fn added(custom: Bool) -> ir.Value {
  let #(kind, field) = case custom {
    True -> #("custom_tool_call", "input")
    False -> #("function_call", "arguments")
  }
  ir.Object([
    #("type", ir.String("response.output_item.added")),
    #("output_index", ir.Integer(0)),
    #(
      "item",
      ir.Object([
        #("id", ir.String("tool_synthetic")),
        #("type", ir.String(kind)),
        #("call_id", ir.String("call_synthetic")),
        #("name", ir.String("shell__run")),
        #(field, ir.String("")),
      ]),
    ),
  ])
}

fn state(custom: Bool) -> stream.Stream {
  let assert Ok(#(state, _)) = stream.push(stream.new(), created())
  let assert Ok(#(state, _)) = stream.push(state, added(custom))
  state
}

fn arguments(
  custom: Bool,
  done: Bool,
  extra: List(#(String, ir.Value)),
) -> ir.Value {
  let prefix = case custom {
    True -> "response.custom_tool_call_input."
    False -> "response.function_call_arguments."
  }
  let suffix = case done {
    True -> "done"
    False -> "delta"
  }
  let field = case done, custom {
    False, _ -> "delta"
    True, False -> "arguments"
    True, True -> "input"
  }
  ir.Object([
    #("type", ir.String(prefix <> suffix)),
    #("output_index", ir.Integer(0)),
    #("item_id", ir.String("tool_synthetic")),
    #(field, ir.String("{}")),
    ..extra
  ])
}

pub fn supplied_tool_name_cannot_change_on_delta_or_done_test() {
  list.each([False, True], fn(custom) {
    list.each([False, True], fn(done) {
      stream.push(
        state(custom),
        arguments(custom, done, [
          #("name", ir.String("other__run")),
        ]),
      )
      |> should.be_error
    })
  })
}

pub fn supplied_call_id_cannot_change_on_delta_or_done_test() {
  list.each([False, True], fn(custom) {
    list.each([False, True], fn(done) {
      stream.push(
        state(custom),
        arguments(custom, done, [
          #("call_id", ir.String("other_call")),
        ]),
      )
      |> should.be_error
    })
  })
}

pub fn optional_identities_must_be_strings_if_present_test() {
  list.each([False, True], fn(custom) {
    list.each([False, True], fn(done) {
      list.each(["name", "call_id"], fn(key) {
        list.each(
          [
            ir.Null,
            ir.Integer(1),
            ir.Boolean(True),
            ir.Array([]),
            ir.Object([]),
            ir.String(""),
          ],
          fn(invalid) {
            stream.push(
              state(custom),
              arguments(custom, done, [#(key, invalid)]),
            )
            |> should.be_error
          },
        )
      })
    })
  })
}

pub fn absent_or_matching_optional_identities_preserve_native_event_test() {
  list.each([False, True], fn(custom) {
    list.each(
      [
        [],
        [#("name", ir.String("shell__run"))],
        [#("call_id", ir.String("call_synthetic"))],
        [
          #("name", ir.String("shell__run")),
          #("call_id", ir.String("call_synthetic")),
        ],
      ],
      fn(identity) {
        let extra = [
          #("vendor", ir.Object([#("opaque", ir.Boolean(True))])),
          ..identity
        ]
        let delta = arguments(custom, False, extra)
        let final = arguments(custom, True, extra)
        let assert Ok(#(next, event)) = stream.push(state(custom), delta)
        event.document |> should.equal(delta)
        let assert Ok(#(next, event)) = stream.push(next, final)
        event.document |> should.equal(final)
        stream.push(next, final) |> should.be_error
      },
    )
  })
}

pub fn item_id_and_function_custom_event_kind_checks_remain_enforced_test() {
  list.each([False, True], fn(custom) {
    stream.push(state(custom), arguments(!custom, True, [])) |> should.be_error
    let valid = arguments(custom, True, [])
    let wrong =
      ir.Object([
        #("item_id", ir.String("wrong-item")),
        ..ir.extras(valid, ["item_id"])
      ])
    stream.push(state(custom), wrong) |> should.be_error
  })
}

pub fn mismatched_name_sse_retains_valid_prefix_at_every_byte_split_test() {
  let prefix = [created(), added(False), arguments(False, False, [])]
  let invalid = arguments(False, True, [#("name", ir.String("other__run"))])
  let bytes =
    list.append(prefix, [invalid])
    |> list.map(fn(value) { "data: " <> ir.stringify(value) <> "\n\n" })
    |> string.join("")
    |> bit_array.from_string
  list.repeat(Nil, bit_array.byte_size(bytes) + 1)
  |> list.index_map(fn(_, index) { index })
  |> list.each(fn(at) {
    let assert Ok(left) = bit_array.slice(bytes, 0, at)
    let assert Ok(right) =
      bit_array.slice(bytes, at, bit_array.byte_size(bytes) - at)
    let first = stream.feed_partial(stream.new(), left)
    let events = case first.next {
      Error(_) -> first.events
      Ok(next) -> {
        let second = stream.feed_partial(next, right)
        second.next |> should.be_error
        list.append(first.events, second.events)
      }
    }
    list.map(events, fn(event) { event.name })
    |> should.equal([
      "response.created",
      "response.output_item.added",
      "response.function_call_arguments.delta",
    ])
    let assert Ok(last) = list.last(events)
    ir.field(last.document, "delta") |> should.equal(Some(ir.String("{}")))
  })
}
