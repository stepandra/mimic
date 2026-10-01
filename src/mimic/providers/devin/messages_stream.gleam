/// Delayed buffered-to-SSE, NOT token-latency native streaming. The native
/// lifecycle must supply Stop only after EOS + clean EOF. Until then retain
/// bounded logical content: exact initial usage and block completeness are
/// unavailable. No success prefix is exposed before all construction checks.
import gleam/list
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/claude/stream as shared
import mimic/providers/contracts as c
import mimic/providers/devin/messages
import mimic/providers/devin/response

pub opaque type State {
  State(builder: messages.Builder)
}

pub fn new(id: String, model: String) -> Result(State, String) {
  messages.new(id, model) |> result.map(State)
}

pub fn encode(
  state: State,
  event: response.Event,
) -> Result(#(State, List(String)), String) {
  use builder <- result.try(messages.push(state.builder, event))
  case event {
    response.Stop -> {
      use decoded <- result.try(messages.finish(builder))
      use body <- result.try(messages.encode_response(decoded))
      use final <- result.try(ir.parse(body))
      use fields <- result.try(ir.as_object(final))
      use content <- result.try(
        ir.required(final, "content") |> result.try(ir.as_array),
      )
      // Retain exact FINAL accounting in the initialized snapshot. There is no
      // invented initial zero. SDK cumulative deltas overwrite the same totals.
      let start =
        ir.Object(
          list.map(fields, fn(field) {
            case field.0 {
              "content" -> #("content", ir.Array([]))
              "stop_reason" -> #("stop_reason", ir.Null)
              _ -> field
            }
          }),
        )
      use blocks <- result.try(
        list.try_map(
          list.index_map(content, fn(block, index) { #(index, block) }),
          fn(pair) { block_frames(pair.0, pair.1) },
        ),
      )
      use usage <- result.try(ir.required(final, "usage"))
      use reason <- result.try(ir.required(final, "stop_reason"))
      let documents =
        list.flatten([
          [document("message_start", [#("message", start)])],
          list.flatten(blocks),
          [
            document("message_delta", [
              #(
                "delta",
                ir.Object([
                  #("stop_reason", reason),
                  #("stop_sequence", ir.Null),
                ]),
              ),
              #("usage", usage),
            ]),
            document("message_stop", []),
          ],
        ])
      use #(validator, frames) <- result.try(
        list.try_fold(documents, #(shared.new(), []), fn(acc, document) {
          use kind <- result.try(ir.string_field(document, "type"))
          let frame =
            "event: " <> kind <> "\ndata: " <> ir.stringify(document) <> "\n\n"
          use #(validator, output) <- result.try(shared.feed(acc.0, frame))
          Ok(#(validator, list.append(acc.1, output)))
        }),
      )
      use _ <- result.try(shared.finish(validator))
      use _ <- result.try(messages.ensure(
        string.byte_size(string.concat(frames)) <= messages.max_bytes,
        "Devin Messages aggregate SSE byte limit",
      ))
      Ok(#(State(builder), frames))
    }
    _ -> Ok(#(State(builder), []))
  }
}

fn block_frames(index: Int, block: ir.Value) -> Result(List(ir.Value), String) {
  use kind <- result.try(ir.string_field(block, "type"))
  use #(initial, deltas) <- result.try(case kind {
    "text" -> {
      use text <- result.try(ir.required(block, "text"))
      Ok(
        #(ir.Object([#("type", ir.String("text")), #("text", ir.String(""))]), [
          delta(index, "text_delta", [#("text", text)]),
        ]),
      )
    }
    "thinking" -> {
      use text <- result.try(ir.required(block, "thinking"))
      use signature <- result.try(ir.required(block, "signature"))
      Ok(
        #(
          ir.Object([
            #("type", ir.String("thinking")),
            #("thinking", ir.String("")),
            #("signature", ir.String("")),
          ]),
          [
            delta(index, "thinking_delta", [#("thinking", text)]),
            delta(index, "signature_delta", [#("signature", signature)]),
          ],
        ),
      )
    }
    "tool_use" -> {
      use id <- result.try(ir.required(block, "id"))
      use name <- result.try(ir.required(block, "name"))
      use input <- result.try(ir.required(block, "input"))
      Ok(
        #(
          ir.Object([
            #("type", ir.String(kind)),
            #("id", id),
            #("name", name),
            #("input", ir.Object([])),
          ]),
          [
            delta(index, "input_json_delta", [
              #("partial_json", ir.String(ir.stringify(input))),
            ]),
          ],
        ),
      )
    }
    _ -> Error("unsupported Devin Messages SSE block")
  })
  Ok(
    list.flatten([
      [
        document("content_block_start", [
          #("index", ir.Integer(index)),
          #("content_block", initial),
        ]),
      ],
      deltas,
      [document("content_block_stop", [#("index", ir.Integer(index))])],
    ]),
  )
}

fn delta(index: Int, kind: String, fields: List(#(String, ir.Value))) {
  document("content_block_delta", [
    #("index", ir.Integer(index)),
    #("delta", ir.Object([#("type", ir.String(kind)), ..fields])),
  ])
}

fn document(kind: String, fields: List(#(String, ir.Value))) {
  ir.Object([#("type", ir.String(kind)), ..fields])
}

pub fn failure(_error: c.Failure) -> String {
  "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Devin Messages stream failed\"}}\n\n"
}
