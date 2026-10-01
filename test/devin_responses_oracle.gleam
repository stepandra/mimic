/// SYNTHETIC independent content reconstruction. Shared strict Responses/S6
/// checks framing/lifecycle/raw identity; this accumulator additionally compares
/// append-built content against done/terminal snapshots instead of trusting them.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir
import mimic/protocol/responses/stream as strict
import mimic/providers/devin/responses_request.{ensure}

type State {
  State(
    created: Option(ir.Value),
    items: List(ir.Value),
    terminal: Option(ir.Value),
  )
}

pub fn reconstruct(frames: List(String)) -> Result(ir.Value, String) {
  use #(observer, events) <- result.try(
    list.try_fold(frames, #(strict.new(), []), fn(acc, frame) {
      use #(observer, events) <- result.try(strict.feed(
        acc.0,
        bit_array.from_string(frame),
      ))
      Ok(#(observer, list.append(acc.1, events)))
    }),
  )
  use outcome <- result.try(strict.finish(observer))
  use _ <- result.try(ensure(
    outcome == strict.Completed || outcome == strict.Incomplete,
    "oracle: failure is not a response",
  ))
  use state <- result.try(list.try_fold(events, State(None, [], None), apply))
  option.to_result(state.terminal, "oracle: missing terminal")
}

fn apply(state: State, event: strict.Event) -> Result(State, String) {
  let value = event.document
  case event.name {
    "response.created" -> {
      use response <- result.try(ir.required(value, "response"))
      Ok(State(..state, created: Some(response)))
    }
    "response.output_item.added" -> {
      use item <- result.try(ir.required(value, "item"))
      Ok(State(..state, items: [item, ..state.items]))
    }
    "response.completed" | "response.incomplete" -> {
      use terminal <- result.try(ir.required(value, "response"))
      use _ <- result.try(ensure(
        ir.field(terminal, "output")
          == Some(ir.Array(list.reverse(state.items))),
        "oracle: terminal did not match append-built output",
      ))
      use created <- result.try(option.to_result(
        state.created,
        "oracle: no created",
      ))
      use _ <- result.try(
        list.try_each(
          ["id", "object", "created_at", "model", "usage", "devin"],
          fn(key) {
            ensure(
              ir.field(created, key) == ir.field(terminal, key),
              "oracle: created/terminal metadata changed",
            )
          },
        ),
      )
      Ok(State(..state, terminal: Some(terminal)))
    }
    _ -> {
      use item <- result.try(
        list.first(state.items)
        |> result.replace_error("oracle: no current item"),
      )
      use index <- result.try(
        ir.required(value, "output_index") |> result.try(ir.as_int),
      )
      use _ <- result.try(ensure(
        index == list.length(state.items) - 1,
        "oracle: nonserial output item",
      ))
      use item <- result.try(item_event(item, event))
      let assert [_, ..rest] = state.items
      Ok(State(..state, items: [item, ..rest]))
    }
  }
}

fn item_event(item: ir.Value, event: strict.Event) -> Result(ir.Value, String) {
  let value = event.document
  case event.name {
    "response.output_item.done" -> {
      use done <- result.try(ir.required(value, "item"))
      // Only the final status may change; text/arguments are independently
      // reconstructed from deltas. No terminal overwrite may repair content.
      let item = case ir.field(done, "status") {
        Some(status) -> put(item, "status", status)
        None -> item
      }
      use _ <- result.try(ensure(
        item == done,
        "oracle: item done content mismatch",
      ))
      Ok(done)
    }
    "response.function_call_arguments.delta" -> {
      use delta <- result.try(ir.string_field(value, "delta"))
      use previous <- result.try(ir.string_field(item, "arguments"))
      Ok(put(item, "arguments", ir.String(previous <> delta)))
    }
    "response.function_call_arguments.done" -> {
      use _ <- result.try(ensure(
        ir.field(value, "arguments") == ir.field(item, "arguments"),
        "oracle: tool arguments done mismatch",
      ))
      Ok(item)
    }
    _ -> {
      let group = case ir.field(item, "type") {
        Some(ir.String("reasoning")) -> "summary"
        _ -> "content"
      }
      case event.name {
        "response.content_part.added"
        | "response.reasoning_summary_part.added" -> {
          use part <- result.try(ir.required(value, "part"))
          Ok(put(item, group, ir.Array([part])))
        }
        "response.output_text.delta"
        | "response.reasoning_summary_text.delta" -> {
          use part <- result.try(single_part(item, group))
          use previous <- result.try(ir.string_field(part, "text"))
          use delta <- result.try(ir.string_field(value, "delta"))
          Ok(put(
            item,
            group,
            ir.Array([
              put(part, "text", ir.String(previous <> delta)),
            ]),
          ))
        }
        "response.output_text.done" | "response.reasoning_summary_text.done" -> {
          use part <- result.try(single_part(item, group))
          use _ <- result.try(ensure(
            ir.field(part, "text") == ir.field(value, "text"),
            "oracle: text done mismatch",
          ))
          Ok(item)
        }
        "response.content_part.done" | "response.reasoning_summary_part.done" -> {
          use part <- result.try(single_part(item, group))
          use _ <- result.try(ensure(
            Some(part) == ir.field(value, "part"),
            "oracle: part done mismatch",
          ))
          Ok(item)
        }
        _ -> Error("oracle: unsupported event")
      }
    }
  }
}

fn single_part(item: ir.Value, group: String) -> Result(ir.Value, String) {
  case ir.field(item, group) {
    Some(ir.Array([part])) -> Ok(part)
    _ -> Error("oracle: missing or ambiguous part")
  }
}

fn put(value: ir.Value, key: String, updated: ir.Value) -> ir.Value {
  let assert ir.Object(fields) = value
  ir.Object(
    list.map(fields, fn(field) {
      case field.0 == key {
        True -> #(key, updated)
        False -> field
      }
    }),
  )
}
