/// Source-backed history projection, not CPA's permissive interactions parser.
/// Unknown extensions and orphan results fail rather than disappear or change role.
import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/devin/protobuf as pb

pub fn system(value: ir.Value) -> Result(String, String) {
  case value {
    ir.String(text) -> Ok(text)
    ir.Array(parts) -> {
      use texts <- result.try(
        list.try_map(parts, fn(part) {
          use _ <- result.try(only(part, ["type", "text"]))
          use kind <- result.try(ir.string_field(part, "type"))
          case kind {
            "text" -> ir.string_field(part, "text")
            _ -> Error("unsupported devin system block")
          }
        }),
      )
      Ok(string.join(texts, "\n"))
    }
    _ -> Error("unsupported devin system")
  }
}

pub fn history(
  turns: List(ir.Turn),
  message_id: fn(Int) -> String,
) -> Result(List(pb.Field), String) {
  use _ <- result.try(case list.length(turns) {
    0 -> Error("devin conversation required")
    n if n > 1024 -> Error("devin history limit")
    _ -> Ok(Nil)
  })
  use state <- result.try(
    list.try_fold(turns, #([], [], [], 0), fn(state, turn) {
      let #(out, pending, seen, index) = state
      use _ <- result.try(case turn.extensions {
        [] -> Ok(Nil)
        _ -> Error("unsupported devin turn extensions")
      })
      use source <- result.try(case turn.role {
        "user" -> Ok(1)
        "assistant" -> Ok(2)
        "tool" -> Ok(4)
        _ -> Error("unsupported devin role")
      })
      // Anthropic result blocks are user-role; emit each as its own native tool
      // prompt. Mixing result and user text would otherwise reorder semantics.
      let results =
        list.filter(turn.content, fn(part) {
          case part {
            ir.ToolResult(..) -> True
            _ -> False
          }
        })
      case results {
        [_, ..] -> {
          use _ <- result.try(case source != 2 && results == turn.content {
            True -> Ok(Nil)
            False -> Error("unsupported mixed devin tool results")
          })
          use pair <- result.try(
            list.try_fold(results, #(out, pending), fn(acc, part) {
              let assert ir.ToolResult(id, content, extras) = part
              use _ <- result.try(
                case extras == [] && list.contains(acc.1, id) {
                  True -> Ok(Nil)
                  False -> Error("orphan or unsupported devin tool result")
                },
              )
              use text <- result.try(system(content))
              let prompt =
                pb.message(3, [
                  pb.text(1, message_id(list.length(acc.0))),
                  pb.Varint(2, 4),
                  pb.text(3, text),
                  pb.text(7, id),
                ])
              Ok(#([prompt, ..acc.0], list.filter(acc.1, fn(x) { x != id })))
            }),
          )
          Ok(#(pair.0, pair.1, seen, index + 1))
        }
        [] -> {
          use _ <- result.try(case source == 4 {
            True -> Error("devin tool result required")
            False -> Ok(Nil)
          })
          use fields <- result.try(parts(turn.content, source))
          let ids =
            list.filter_map(turn.content, fn(part) {
              case part {
                ir.ToolCall(id, ..) -> Ok(id)
                _ -> Error(Nil)
              }
            })
          use _ <- result.try(
            case
              list.unique(ids) == ids
              && !list.any(ids, fn(id) { list.contains(seen, id) })
            {
              True -> Ok(Nil)
              False -> Error("duplicate devin tool call ID")
            },
          )
          let prompt =
            pb.message(3, [
              pb.text(1, message_id(index)),
              pb.Varint(2, source),
              ..fields
            ])
          Ok(#(
            [prompt, ..out],
            list.append(pending, ids),
            list.append(seen, ids),
            index + 1,
          ))
        }
      }
    }),
  )
  Ok(list.reverse(state.0))
}

fn parts(
  content: List(ir.Content),
  source: Int,
) -> Result(List(pb.Field), String) {
  // Native prompts have one text slot and separate attachment/tool slots.
  // Never move later text backwards across an intervening semantic block.
  use _ <- result.try(
    list.try_fold(content, #(False, False), fn(state, part) {
      case part {
        ir.Text(..) ->
          case state.1 {
            True -> Error("interleaved devin text content is unsupported")
            False -> Ok(#(True, False))
          }
        ir.ToolCall(..) -> Ok(#(state.0, True))
        _ -> Ok(#(state.0, state.1 || state.0))
      }
    }),
  )
  use fields <- result.try(
    list.try_map(content, fn(part) {
      case part {
        ir.Text(text, []) -> Ok([pb.text(3, text)])
        ir.ToolCall(id, name, input, raw, []) if source == 2 -> {
          use _ <- result.try(case id != "" && name != "" {
            True -> Ok(Nil)
            False -> Error("devin tool ID and name required")
          })
          let args = case raw {
            Some(raw) ->
              case ir.parse(raw) == Ok(input) {
                True -> raw
                False -> ir.stringify(input)
              }
            None -> ir.stringify(input)
          }
          Ok([
            pb.message(6, [pb.text(1, id), pb.text(2, name), pb.text(3, args)]),
          ])
        }
        ir.Thinking(text, signature, extensions) if source == 2 -> {
          let fields = case text {
            "" -> []
            _ -> [pb.text(11, text)]
          }
          case signature {
            None ->
              case extensions {
                [] -> Ok(fields)
                _ -> Error("unsupported devin thinking extensions")
              }
            Some(sig) -> {
              use pair <- result.try(case extensions {
                [] -> signature_bytes(sig)
                [
                  #("devin_signature_encoding", ir.String("base64")),
                  #("devin_signature_type", ir.String(kind)),
                ] -> {
                  use bytes <- result.try(
                    bit_array.base64_decode(sig)
                    |> result.replace_error("invalid devin signature base64"),
                  )
                  Ok(#(bytes, kind))
                }
                _ -> Error("unsupported devin thinking extensions")
              })
              Ok(
                list.append(fields, [pb.Bytes(12, pair.0), pb.text(18, pair.1)]),
              )
            }
          }
        }
        ir.Unknown(image) if source == 1 ->
          image_field(image) |> result.map(fn(x) { [x] })
        _ -> Error("unsupported devin content or role")
      }
    }),
  )
  // Prompt text is a singular protobuf field, not repeated fields (last-wins).
  let fields = list.flatten(fields)
  let texts =
    list.filter_map(fields, fn(field) {
      case field {
        pb.Bytes(3, text) -> bit_array.to_string(text)
        _ -> Error(Nil)
      }
    })
  let others =
    list.filter(fields, fn(field) {
      case field {
        pb.Bytes(3, _) -> False
        _ -> True
      }
    })
  // Multiple thinking/signature blocks cannot be represented without ambiguity.
  use _ <- result.try(
    case
      list.count(content, fn(part) {
        case part {
          ir.Thinking(..) -> True
          _ -> False
        }
      })
      <= 1
    {
      True -> Ok(Nil)
      False -> Error("multiple devin thinking blocks unsupported")
    },
  )
  Ok([pb.text(3, string.join(texts, "\n")), ..others])
}

/// Explicit signature forms only. Arbitrary binary is never decoded as UTF-8.
/// CPA guesses providers and decodes some base64 strings; we reject ambiguity.
pub fn signature_bytes(value: String) -> Result(#(BitArray, String), String) {
  case value {
    "claude#" <> rest -> Ok(#(bit_array.from_string(rest), "anthropic"))
    "gpt#" <> rest -> Ok(#(bit_array.from_string(rest), "openai"))
    "sealed.v1." <> _ -> Ok(#(bit_array.from_string(value), "sealed"))
    "CAQS" <> _ | "CAIS" <> _ ->
      Ok(#(bit_array.from_string(value), "anthropic"))
    "gAAAA" <> _ -> Ok(#(bit_array.from_string(value), "openai"))
    _ -> Error("unsupported ambiguous devin signature")
  }
}

pub fn image_field(value: ir.Value) -> Result(pb.Field, String) {
  use kind <- result.try(ir.string_field(value, "type"))
  use pair <- result.try(case kind {
    "image" -> {
      use _ <- result.try(only(value, ["type", "source"]))
      use source <- result.try(ir.required(value, "source"))
      use _ <- result.try(only(source, ["type", "media_type", "data"]))
      use kind <- result.try(ir.string_field(source, "type"))
      use mime <- result.try(ir.string_field(source, "media_type"))
      use data <- result.try(ir.string_field(source, "data"))
      case kind {
        "base64" -> Ok(#(mime, data))
        _ -> Error("unsupported remote devin image")
      }
    }
    "image_url" -> {
      use _ <- result.try(only(value, ["type", "image_url"]))
      use image <- result.try(ir.required(value, "image_url"))
      use _ <- result.try(only(image, ["url"]))
      use url <- result.try(ir.string_field(image, "url"))
      case string.split(url, ";base64,") {
        ["data:" <> mime, data] -> Ok(#(mime, data))
        _ -> Error("unsupported remote devin image")
      }
    }
    _ -> Error("unsupported devin media")
  })
  use _ <- result.try(
    case
      list.contains(
        ["image/png", "image/jpeg", "image/gif", "image/webp"],
        pair.0,
      )
      && string.byte_size(pair.1) <= 4_194_304
    {
      True -> Ok(Nil)
      False -> Error("unsupported devin image MIME or size")
    },
  )
  use bytes <- result.try(
    bit_array.base64_decode(pair.1)
    |> result.replace_error("invalid devin image base64"),
  )
  case bit_array.byte_size(bytes) > 0 {
    True -> Ok(pb.message(10, [pb.text(1, pair.1), pb.text(2, pair.0)]))
    False -> Error("empty devin image")
  }
}

pub fn tools(
  value: ir.Value,
  origin: ir.Origin,
) -> Result(List(pb.Field), String) {
  use values <- result.try(ir.as_array(value))
  use _ <- result.try(case values != [] && list.length(values) <= 128 {
    True -> Ok(Nil)
    False -> Error("devin tool definition count")
  })
  list.try_map(values, fn(value) {
    use value <- result.try(case origin {
      ir.Openai -> {
        use _ <- result.try(only(value, ["type", "function"]))
        use kind <- result.try(ir.string_field(value, "type"))
        case kind {
          "function" -> ir.required(value, "function")
          _ -> Error("unsupported devin tool definition")
        }
      }
      _ -> Ok(value)
    })
    let schema = case origin {
      ir.Openai -> "parameters"
      _ -> "input_schema"
    }
    use _ <- result.try(only(value, ["name", "description", schema]))
    use name <- result.try(ir.string_field(value, "name"))
    use _ <- result.try(
      case name != "" && !string.contains(name, "mcp__codex_app") {
        True -> Ok(Nil)
        False -> Error("unsupported devin tool name")
      },
    )
    use parameters <- result.try(ir.required(value, schema))
    use _ <- result.try(ir.as_object(parameters))
    use description <- result.try(ir.optional_string(value, "description"))
    let fields = [pb.text(1, name)]
    let fields = case description {
      None | Some("") -> fields
      Some(text) -> list.append(fields, [pb.text(2, text)])
    }
    Ok(pb.message(
      10,
      list.append(fields, [pb.text(3, ir.stringify(parameters))]),
    ))
  })
}

fn only(value: ir.Value, keys: List(String)) -> Result(Nil, String) {
  use _ <- result.try(ir.as_object(value))
  case ir.extras(value, keys) {
    [] -> Ok(Nil)
    _ -> Error("unsupported devin content extensions")
  }
}
