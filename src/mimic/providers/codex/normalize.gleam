/// Codex backend policy applied to the shared Responses JSON tree, not a second
/// Responses codec. Unknown fields and opaque reasoning data remain intact.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir

pub fn put(root: ir.Value, key: String, value: ir.Value) -> ir.Value {
  ir.Object([#(key, value), ..ir.extras(root, [key])])
}

pub fn remove(root: ir.Value, fields: List(String)) -> ir.Value {
  ir.Object(ir.extras(root, fields))
}

pub fn input(value: ir.Value) -> Result(List(ir.Value), String) {
  case value {
    ir.String(text) ->
      Ok([
        ir.Object([
          #("type", ir.String("message")),
          #("role", ir.String("user")),
          #(
            "content",
            ir.Array([
              ir.Object([
                #("type", ir.String("input_text")),
                #("text", ir.String(text)),
              ]),
            ]),
          ),
        ]),
      ])
    ir.Array(items) -> list.try_map(items, input_item)
    _ -> Error("Codex input must be a string or array")
  }
}

fn input_item(item: ir.Value) -> Result(ir.Value, String) {
  use _ <- result.try(ir.as_object(item))
  let item = remove(item, ["prompt_cache_breakpoint"])
  let item = case ir.field(item, "role") {
    Some(ir.String("system")) -> put(item, "role", ir.String("developer"))
    _ -> item
  }
  Ok(
    list.fold(["content", "output"], item, fn(item, key) {
      case ir.field(item, key) {
        Some(ir.Array(parts)) ->
          put(
            item,
            key,
            ir.Array(
              list.map(parts, fn(part) {
                case part {
                  ir.Object(_) -> remove(part, ["prompt_cache_breakpoint"])
                  _ -> part
                }
              }),
            ),
          )
        _ -> item
      }
    }),
  )
}

pub fn tools(root: ir.Value) -> Result(ir.Value, String) {
  use root <- result.try(case ir.field(root, "tools") {
    None -> Ok(root)
    Some(ir.Array(tools)) ->
      list.try_map(tools, tool)
      |> result.map(fn(tools) { put(root, "tools", ir.Array(tools)) })
    _ -> Error("Codex tools must be an array")
  })
  case ir.field(root, "tool_choice") {
    Some(ir.Object(_) as choice) -> {
      use choice <- result.try(tool(choice))
      use choice <- result.try(case ir.field(choice, "tools") {
        Some(ir.Array(choices)) ->
          list.try_map(choices, tool)
          |> result.map(fn(choices) { put(choice, "tools", ir.Array(choices)) })
        None -> Ok(choice)
        _ -> Error("Codex allowed tools must be an array")
      })
      Ok(put(root, "tool_choice", choice))
    }
    _ -> Ok(root)
  }
}

fn tool(value: ir.Value) -> Result(ir.Value, String) {
  use _ <- result.try(ir.as_object(value))
  case ir.field(value, "type") {
    Some(ir.String("web_search_preview"))
    | Some(ir.String("web_search_preview_2025_03_11")) ->
      Ok(put(value, "type", ir.String("web_search")))
    _ -> Ok(value)
  }
}

pub fn reasoning(
  root: ir.Value,
  allowed_efforts: List(String),
) -> Result(Nil, String) {
  case ir.field(root, "reasoning") {
    None -> Ok(Nil)
    Some(value) -> {
      use _ <- result.try(ir.as_object(value))
      use effort <- result.try(ir.optional_string(value, "effort"))
      use summary <- result.try(ir.optional_string(value, "summary"))
      case effort {
        Some(effort) if effort == "" -> Error("empty Codex reasoning effort")
        Some(effort) -> {
          use _ <- result.try(case list.contains(allowed_efforts, effort) {
            True -> Ok(Nil)
            False -> Error("unsupported Codex model reasoning effort")
          })
          summary_valid(summary)
        }
        None -> summary_valid(summary)
      }
    }
  }
}

fn summary_valid(summary) -> Result(Nil, String) {
  case summary {
    None | Some("auto") | Some("concise") | Some("detailed") | Some("none") ->
      Ok(Nil)
    _ -> Error("unsupported Codex reasoning summary")
  }
}
