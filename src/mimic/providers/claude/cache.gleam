/// Caller-owned cache validation. Never walk tool schemas/inputs as protocol.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir

pub type Summary {
  Summary(breakpoints: Int, has_one_hour: Bool)
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
