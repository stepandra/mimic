/// Caller-owned cache validation. Never walk tool schemas/inputs as protocol.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/claude/policy

pub type Summary {
  Summary(breakpoints: Int, has_one_hour: Bool)
}

/// CPA's non-cloaked selector only adds defaults when no explicit marker exists.
/// Unlike CPA's lossy cap/TTL repairs, invalid explicit layouts fail unchanged.
/// One-hour selection requires operator approval as well as selected OAuth.
pub fn ensure_translated(
  body: ir.Value,
  oauth: Bool,
  selected: policy.Policy,
) -> Result(ir.Value, String) {
  use summary <- result.try(validate(body))
  use _ <- result.try(case selected.cache, oauth, selected.turn {
    policy.ApprovedOneHour, False, _
    | policy.ApprovedOneHour, _, policy.Helper
    ->
      Error(
        "Claude 1h cache selection requires approved OAuth non-helper policy",
      )
    _, _, _ -> Ok(Nil)
  })
  case summary.breakpoints > 0 || selected.cache == policy.PreserveCache {
    True -> Ok(body)
    False -> {
      let control = case selected.cache {
        policy.ApprovedOneHour ->
          ir.Object([
            #("type", ir.String("ephemeral")),
            #("ttl", ir.String("1h")),
          ])
        _ -> ir.Object([#("type", ir.String("ephemeral"))])
      }
      let system = ir.field(body, "system")
      let cacheable_system = case system {
        Some(ir.Array(items)) -> !list.is_empty(items)
        Some(ir.String(text)) -> string.trim(text) != ""
        _ -> False
      }
      use body <- result.try(case cacheable_system, system {
        True, Some(content) -> {
          use content <- result.try(mark_content(content, control))
          Ok(policy.set(body, "system", content))
        }
        _, _ ->
          case ir.field(body, "tools") {
            None -> Ok(body)
            Some(ir.Array(tools)) -> {
              use tools <- result.try(
                mark_last(tools, control, fn(tool) {
                  ir.field(tool, "defer_loading") != Some(ir.Boolean(True))
                }),
              )
              Ok(policy.set(body, "tools", ir.Array(tools)))
            }
            _ -> Error("Claude tools must be an array")
          }
      })
      let messages = array_field(body, "messages")
      let has_eligible = list.any(messages, eligible_message)
      let final_system = case list.last(messages) {
        Ok(message) ->
          ir.string_field(message, "role") == Ok("system")
          && case ir.field(message, "content") {
            Some(ir.String(text)) -> string.trim(text) != ""
            _ -> False
          }
        _ -> False
      }
      use messages <- result.try(mark_message(
        list.reverse(messages),
        control,
        has_eligible && final_system,
      ))
      let body = policy.set(body, "messages", ir.Array(list.reverse(messages)))
      use _ <- result.try(validate(body))
      Ok(body)
    }
  }
}

fn eligible_message(message: ir.Value) -> Bool {
  let role = ir.string_field(message, "role") |> result.unwrap("")
  let content = ir.field(message, "content")
  let eligible = case content {
    Some(ir.String(_)) -> True
    Some(ir.Array(blocks)) ->
      case list.last(blocks) {
        Ok(block) -> {
          let kind = ir.string_field(block, "type") |> result.unwrap("")
          role != "assistant"
          || !list.contains(["thinking", "redacted_thinking"], kind)
        }
        _ -> False
      }
    _ -> False
  }
  list.contains(["user", "assistant"], role) && eligible
}

fn mark_message(
  messages: List(ir.Value),
  control: ir.Value,
  final_system: Bool,
) {
  case messages {
    [] -> Ok([])
    [message, ..rest] ->
      case final_system || eligible_message(message) {
        True -> {
          use content <- result.try(ir.required(message, "content"))
          use content <- result.try(mark_content(content, control))
          Ok([policy.set(message, "content", content), ..rest])
        }
        False -> {
          use rest <- result.try(mark_message(rest, control, False))
          Ok([message, ..rest])
        }
      }
  }
}

fn mark_content(content: ir.Value, control: ir.Value) {
  case content {
    ir.String(text) ->
      Ok(
        ir.Array([
          ir.Object([
            #("type", ir.String("text")),
            #("text", ir.String(text)),
            #("cache_control", control),
          ]),
        ]),
      )
    ir.Array(blocks) ->
      mark_last(blocks, control, fn(_) { True }) |> result.map(ir.Array)
    _ -> Error("Unsupported Claude cache host")
  }
}

fn mark_last(
  blocks: List(ir.Value),
  control: ir.Value,
  eligible: fn(ir.Value) -> Bool,
) {
  mark_first(list.reverse(blocks), control, eligible)
  |> result.map(list.reverse)
}

fn mark_first(
  blocks: List(ir.Value),
  control: ir.Value,
  eligible: fn(ir.Value) -> Bool,
) {
  case blocks {
    [] -> Ok([])
    [block, ..rest] ->
      case eligible(block) {
        True -> {
          use _ <- result.try(ir.as_object(block))
          Ok([policy.set(block, "cache_control", control), ..rest])
        }
        False -> {
          use rest <- result.try(mark_first(rest, control, eligible))
          Ok([block, ..rest])
        }
      }
  }
}

pub fn validate(body: ir.Value) -> Result(Summary, String) {
  use _ <- result.try(case ir.field(body, "cache_control") {
    None -> Ok(Nil)
    Some(_) -> Error("Claude automatic top-level caching is not supported")
  })
  let tools = array_field(body, "tools")
  let system = array_field(body, "system")
  let messages =
    array_field(body, "messages")
    |> list.flat_map(fn(message) { array_field(message, "content") })
  let blocks = list.append(tools, list.append(system, messages))
  use ttls <- result.try(list.try_map(blocks, cache_ttl))
  let ttls =
    list.filter_map(ttls, fn(ttl) {
      case ttl {
        Some(ttl) -> Ok(ttl)
        None -> Error(Nil)
      }
    })
  case list.length(ttls) > 4 {
    True -> Error("Claude allows at most four explicit cache breakpoints")
    False -> {
      use _ <- result.try(check_order(ttls, False))
      Ok(Summary(list.length(ttls), list.contains(ttls, "1h")))
    }
  }
}

fn array_field(value: ir.Value, key: String) -> List(ir.Value) {
  case ir.field(value, key) {
    Some(ir.Array(items)) -> items
    _ -> []
  }
}

fn cache_ttl(block: ir.Value) {
  case ir.field(block, "cache_control") {
    None -> Ok(None)
    Some(control) -> {
      use kind <- result.try(ir.string_field(control, "type"))
      use ttl <- result.try(ir.optional_string(control, "ttl"))
      case kind, ttl {
        "ephemeral", None -> Ok(Some("5m"))
        "ephemeral", Some("5m") -> Ok(Some("5m"))
        "ephemeral", Some("1h") -> Ok(Some("1h"))
        _, _ -> Error("Unsupported Claude cache type or TTL")
      }
    }
  }
}

fn check_order(ttls: List(String), seen_short: Bool) -> Result(Nil, String) {
  case ttls {
    [] -> Ok(Nil)
    ["1h", ..] if seen_short ->
      Error("Claude 1h cache breakpoint follows a 5m breakpoint")
    [ttl, ..rest] -> check_order(rest, seen_short || ttl == "5m")
  }
}
