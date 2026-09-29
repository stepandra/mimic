/// Source-derived policy, not a measured Claude Code fingerprint.
/// CPA acdace936fa7df2905500c7f5e0a97d683138dea, Claude Code 2.1.280.
/// Selection is trusted routing metadata, never inferred from caller headers.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub type Input {
  NativeMessages
  TranslatedMessages
}

pub type Turn {
  Conversation
  Subagent
  Helper
}

pub type Cache {
  PreserveCache
  DefaultFiveMinutes
  ApprovedOneHour
}

pub type Policy {
  Policy(input: Input, turn: Turn, cache: Cache)
}

pub fn native() -> Policy {
  Policy(NativeMessages, Conversation, PreserveCache)
}

/// No optimistic capability claims for future models.
pub type Model {
  Haiku
  Legacy
  Modern
  Progress
  Unknown
}

pub fn model(name: String) -> Model {
  let name =
    name
    |> string.trim
    |> string.lowercase
    |> string.split("/")
    |> list.last
    |> result.unwrap("")
  let haiku =
    string.starts_with(name, "claude-")
    && list.contains(string.split(name, "-"), "haiku")
  let legacy = string.starts_with(name, "claude-3-")
  let progress =
    matches(name, "claude-opus-5-5")
    || matches(name, "claude-fable-5-1")
    || matches(name, "claude-sonnet-5")
  let modern =
    matches(name, "claude-opus-4") || matches(name, "claude-sonnet-4")
  case haiku, legacy, progress, modern {
    True, _, _, _ -> Haiku
    _, True, _, _ -> Legacy
    _, _, True, _ -> Progress
    _, _, _, True -> Modern
    _, _, _, _ -> Unknown
  }
}

fn matches(name: String, family: String) -> Bool {
  name == family
  || string.starts_with(name, family <> "-")
  || string.starts_with(name, family <> "[")
}

pub fn normalize(body: ir.Value, policy: Policy) -> Result(ir.Value, String) {
  use _ <- result.try(validate_sampling(body))
  let body = case nested(body, "tool_choice", "type") {
    "any" | "tool" -> {
      let body = remove(body, "thinking")
      case ir.field(body, "output_config") {
        Some(ir.Object(fields)) ->
          case list.filter(fields, fn(f) { f.0 != "effort" }) {
            [] -> remove(body, "output_config")
            fields -> set(body, "output_config", ir.Object(fields))
          }
        None -> body
        _ -> body
      }
    }
    _ -> body
  }
  let active =
    list.contains(
      ["enabled", "adaptive", "auto"],
      nested(body, "thinking", "type"),
    )
  let body = case policy.input {
    TranslatedMessages -> body |> remove("temperature") |> remove("top_p")
    NativeMessages ->
      case active {
        True -> {
          let body = case ir.field(body, "temperature") {
            None | Some(ir.Integer(1)) | Some(ir.Decimal(1.0)) -> body
            _ -> remove(body, "temperature")
          }
          case ir.field(body, "top_p") {
            Some(ir.Decimal(value)) if value <. 0.95 -> remove(body, "top_p")
            Some(ir.Integer(value)) if value < 1 -> remove(body, "top_p")
            _ -> body
          }
        }
        False ->
          case ir.field(body, "temperature") {
            None -> body
            Some(_) -> remove(body, "top_p")
          }
      }
  }
  Ok(case active {
    True -> remove(body, "top_k")
    False -> body
  })
}

fn validate_sampling(body: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_map(["temperature", "top_p", "top_k"], fn(key) {
      case ir.field(body, key) {
        None | Some(ir.Integer(_)) | Some(ir.Decimal(_)) -> Ok(Nil)
        _ -> Error("Claude sampling controls must be numeric")
      }
    }),
  )
  case ir.field(body, "output_config") {
    None | Some(ir.Object(_)) -> Ok(Nil)
    _ -> Error("Claude output_config must be an object")
  }
}

pub fn nested(body: ir.Value, key: String, child: String) -> String {
  ir.required(body, key)
  |> result.try(fn(value) { ir.string_field(value, child) })
  |> result.unwrap("")
}

pub fn remove(body: ir.Value, key: String) -> ir.Value {
  ir.Object(ir.extras(body, [key]))
}

pub fn set(body: ir.Value, key: String, value: ir.Value) -> ir.Value {
  ir.Object(list.append(ir.extras(body, [key]), [#(key, value)]))
}
