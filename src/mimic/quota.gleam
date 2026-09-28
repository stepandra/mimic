import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mimic/auth/storage
import mimic/types.{type Header, type WireResponse, Header}

pub type Window {
  Window(
    name: String,
    utilization: Option(Float),
    reset_at_ms: Option(Int),
    status: String,
  )
}

pub type Entry {
  Entry(credential_id: String, windows: List(Window), cooldown_until_ms: Int)
}

pub type Ledger {
  Ledger(entries: List(Entry))
}

pub fn empty() -> Ledger {
  Ledger([])
}

pub fn lookup(ledger: Ledger, id: String) -> Option(Entry) {
  let Ledger(entries) = ledger
  list.find(entries, fn(entry) { entry.credential_id == id })
  |> option_from_result
}

pub fn cooldown_until(ledger: Ledger, id: String) -> Int {
  case lookup(ledger, id) {
    Some(entry) -> entry.cooldown_until_ms
    None -> 0
  }
}

/// Unknown headers leave previous windows untouched. Rejected windows and
/// 429/529 responses initiate cooldown. Reset is a Unix seconds or milliseconds
/// timestamp; malformed values are never guessed from the wall clock.
pub fn observe(
  ledger: Ledger,
  id: String,
  response: WireResponse,
  now_ms: Int,
) -> Ledger {
  let previous = case lookup(ledger, id) {
    Some(value) -> value
    None -> Entry(id, [], 0)
  }
  let windows =
    list.map(["5h", "7d", "7d_oi"], fn(name) {
      parse_window(name, response.headers, previous.windows)
    })
  let retry = retry_after_ms(response.headers, now_ms)
  let rejected =
    list.any(windows, fn(window) { window.status == "rejected" })
    || case header(response.headers, "anthropic-ratelimit-unified-status") {
      Some(value) -> string.lowercase(value) == "rejected"
      None -> False
    }
  let reset =
    list.fold(windows, now_ms, fn(latest, window) {
      case window.status, window.reset_at_ms {
        "rejected", Some(timestamp) if timestamp > latest -> timestamp
        _, _ -> latest
      }
    })
  let fallback = case
    response.status == 429 || response.status == 529 || rejected
  {
    True -> now_ms + 60_000
    False -> now_ms
  }
  let until = max(max(previous.cooldown_until_ms, reset), max(retry, fallback))
  let Ledger(entries) = ledger
  Ledger([
    Entry(id, windows, until),
    ..list.filter(entries, fn(entry) { entry.credential_id != id })
  ])
}

fn parse_window(
  name: String,
  headers: List(Header),
  old: List(Window),
) -> Window {
  let previous = case list.find(old, fn(window) { window.name == name }) {
    Ok(value) -> value
    Error(_) -> Window(name, None, None, "unknown")
  }
  let prefix = "anthropic-ratelimit-unified-" <> name <> "-"
  let utilization = case header(headers, prefix <> "utilization") {
    Some(value) ->
      case float.parse(value) {
        Ok(n) if n >=. 0.0 && n <=. 1.0 -> Some(n)
        _ -> previous.utilization
      }
    None -> previous.utilization
  }
  let reset_at_ms = case header(headers, prefix <> "reset") {
    Some(value) ->
      case int.parse(value) {
        Ok(n) if n > 10_000_000_000 -> Some(n)
        Ok(n) if n > 0 -> Some(n * 1000)
        _ ->
          case rfc3339_ms(value) {
            Ok(timestamp) -> Some(timestamp)
            Error(_) -> None
          }
      }
    None -> previous.reset_at_ms
  }
  let status = case header(headers, prefix <> "status") {
    Some(value) ->
      case string.lowercase(value) {
        "allowed" -> "allowed"
        "allowed_warning" -> "allowed_warning"
        "rejected" -> "rejected"
        _ -> previous.status
      }
    None -> previous.status
  }
  Window(name, utilization, reset_at_ms, status)
}

fn header(headers: List(Header), wanted: String) -> Option(String) {
  case headers {
    [] -> None
    [Header(name, value), ..rest] ->
      case string.lowercase(name) == wanted {
        True -> Some(string.trim(value))
        False -> header(rest, wanted)
      }
  }
}

fn retry_after_ms(headers: List(Header), now_ms: Int) -> Int {
  case header(headers, "retry-after") {
    Some(value) ->
      case int.parse(value) {
        Ok(seconds) if seconds > 0 && seconds < 604_800 ->
          now_ms + seconds * 1000
        _ ->
          case http_date_ms(value) {
            Ok(timestamp) if timestamp > now_ms -> timestamp
            _ -> now_ms
          }
      }
    None -> now_ms
  }
}

@external(erlang, "mimic_quota_ffi", "http_date_ms")
fn http_date_ms(value: String) -> Result(Int, Nil)

@external(erlang, "mimic_quota_ffi", "rfc3339_ms")
fn rfc3339_ms(value: String) -> Result(Int, Nil)

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn option_from_result(value: Result(a, e)) -> Option(a) {
  case value {
    Ok(x) -> Some(x)
    Error(_) -> None
  }
}

/// Ledger contains no token values; still private by default to avoid leaking
/// account identifiers and utilization. Shares the secure atomic file backend.
pub fn save(store: storage.Store, ledger: Ledger) -> Result(Nil, String) {
  let Ledger(entries) = ledger
  let contents =
    json.array(entries, fn(entry) {
      json.object([
        #("id", json.string(entry.credential_id)),
        #("cooldown_until_ms", json.int(entry.cooldown_until_ms)),
        #(
          "windows",
          json.array(entry.windows, fn(window) {
            json.object([
              #("name", json.string(window.name)),
              #("status", json.string(window.status)),
              #("utilization", json.nullable(window.utilization, json.float)),
              #("reset_at_ms", json.nullable(window.reset_at_ms, json.int)),
            ])
          }),
        ),
      ])
    })
    |> json.to_string
  storage.write_quota_ledger(store, contents)
}

pub fn load(store: storage.Store) -> Result(Ledger, String) {
  case storage.read_quota_ledger(store) {
    Ok(contents) ->
      case json.parse(contents, decode.list(entry_decoder())) {
        Ok(entries) -> Ok(Ledger(entries))
        Error(_) -> Error("Invalid quota ledger")
      }
    Error(error) -> Error(error)
  }
}

/// Missing is distinct from malformed, unreadable, nonprivate or symlinked.
pub fn load_or_empty(store: storage.Store) -> Result(Ledger, String) {
  case load(store) {
    Error("Quota ledger missing") -> Ok(empty())
    other -> other
  }
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use id <- decode.field("id", decode.string)
  use cooldown <- decode.field("cooldown_until_ms", decode.int)
  use windows <- decode.field("windows", decode.list(window_decoder()))
  decode.success(Entry(id, windows, cooldown))
}

fn window_decoder() -> decode.Decoder(Window) {
  use name <- decode.field("name", decode.string)
  use status <- decode.field("status", decode.string)
  use utilization <- decode.field("utilization", decode.optional(decode.float))
  use reset <- decode.field("reset_at_ms", decode.optional(decode.int))
  decode.success(Window(name, utilization, reset, status))
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] ->
      Ok(
        "quota ledger requires an explicit state directory and is exposed through the fleet library",
      )
    _ -> Error("Usage: mimic quota")
  }
}
