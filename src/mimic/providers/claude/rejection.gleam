/// F10's deliberately narrow, body-aware inference 429 admission rule.
/// Decisions contain only normalized scope/timing, never upstream text.
import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/claude/oauth
import mimic/types.{type Header, Header}

pub const max_body_bytes = 49_152

/// Reserve one 16 KiB framer pull to prove EOF without exceeding this budget.
pub const max_read_bytes = 65_536

/// Includes the EOF pull; the existing framer performs at most three OS reads
/// per pull (size, data, separator; the terminal size/trailer uses two).
pub const max_read_events = 32

pub const total_time_ms = 500

pub const max_retry_ms = 604_800_000

const fallback_ms = 60_000

const prefix = "anthropic-ratelimit-unified-"

pub type Decision {
  RequestScoped
  Unknown
  SharedQuota(retry_after_ms: Int, rejected_windows: List(String))
}

type Scope {
  Shared(List(String))
  ModelOnly
  Inconsistent
  Unqualified
}

@external(erlang, "mimic_quota_ffi", "http_date_ms")
fn http_date_ms(value: String) -> Result(Int, Nil)

@external(erlang, "mimic_quota_ffi", "rfc3339_ms")
fn rfc3339_ms(value: String) -> Result(Int, Nil)

/// A supplied, single JSON media type is required for inference classification.
/// Reuse F08's corrected raw media/encoding/duplicate-JSON guard unchanged.
/// Timing syntax is checked before reading, but timing never establishes scope.
pub fn admissible_headers(headers: List(Header)) -> Bool {
  let critical = [
    "content-type",
    "content-encoding",
    "content-length",
    "transfer-encoding",
    "retry-after",
    "retry-after-ms",
    prefix <> "status",
    prefix <> "reset",
    prefix <> "representative-claim",
    prefix <> "overage-disabled-reason",
    prefix <> "overage-status",
    ..list.flat_map(["5h", "7d", "7d_oi"], fn(window) {
      [
        prefix <> window <> "-status",
        prefix <> window <> "-reset",
        prefix <> window <> "-utilization",
      ]
    })
  ]
  list.all(critical, fn(name) {
    case values(headers, name) {
      [] -> True
      [value] ->
        string.byte_size(value) <= 256
        && ascii(bit_array.from_string(value))
        && string.trim(value) != ""
      _ -> False
    }
  })
  && list.length(values(headers, "content-type")) == 1
  // This inference path uses Retry-After seconds/date, not the refresh ms hint.
  && values(headers, "retry-after-ms") == []
  && list.all(["", "5h-", "7d-", "7d_oi-", "overage-"], fn(window) {
    case field(headers, window <> "status") {
      None -> True
      Some(value) ->
        list.contains(["allowed", "allowed_warning", "rejected"], value)
    }
  })
  && list.all(["5h", "7d", "7d_oi"], fn(window) {
    case single(headers, prefix <> window <> "-utilization") {
      None -> True
      Some(raw) -> result.is_ok(utilization(raw))
    }
  })
  && list.all(["", "5h-", "7d-", "7d_oi-"], fn(window) {
    case single(headers, prefix <> window <> "reset") {
      None -> True
      Some(raw) -> result.is_ok(reset(raw))
    }
  })
  && case single(headers, "retry-after") {
    None -> True
    Some(raw) -> result.is_ok(retry_time(raw))
  }
  && result.is_ok(oauth.response_json(oauth.TokenResponse(429, headers, "{}")))
}

/// `wall_now_ms` is Unix milliseconds, used ONLY for relative reset hints.
/// Body-read deadlines use the independent egress monotonic clock in transport.
/// Missing headers, a 429, or rate_limit_error alone never authorize replay.
pub fn classify(
  headers: List(Header),
  body: String,
  wall_now_ms: Int,
) -> Decision {
  let decision = {
    use _ <- result.try(case admissible_headers(headers) {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use _ <- result.try(case string.byte_size(body) <= max_body_bytes {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use value <- result.try(
      oauth.response_json(oauth.TokenResponse(429, headers, body))
      |> result.replace_error(Nil),
    )
    use message <- result.try(known_error(value))
    let credits = fast_refusal(message)
    case header_scope(headers) {
      Shared(windows) -> {
        // Only explicit shared 5h/7d rejection has source-tested precedence
        // over Fast entitlement text. Aggregate-only contradictory text is
        // deliberately not a replay permit.
        use _ <- result.try(case credits && windows == [] {
          True -> Error(Nil)
          False -> Ok(Nil)
        })
        use delay <- result.try(cooldown(headers, windows, wall_now_ms))
        Ok(SharedQuota(delay, windows))
      }
      ModelOnly -> Ok(RequestScoped)
      Inconsistent -> Ok(Unknown)
      Unqualified ->
        case credits {
          True -> Ok(RequestScoped)
          False -> Ok(Unknown)
        }
    }
  }
  result.unwrap(decision, Unknown)
}

fn known_error(value: ir.Value) -> Result(String, Nil) {
  use root <- result.try(ir.as_object(value) |> result.replace_error(Nil))
  use _ <- result.try(
    case
      list.all(root, fn(pair) {
        list.contains(["type", "error", "request_id"], pair.0)
      })
      && case ir.field(value, "type") {
        None | Some(ir.String("error")) -> True
        _ -> False
      }
      && case ir.field(value, "request_id") {
        None -> True
        Some(ir.String(id)) -> string.byte_size(id) <= 1024
        _ -> False
      }
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  use error <- result.try(
    ir.required(value, "error") |> result.replace_error(Nil),
  )
  use fields <- result.try(ir.as_object(error) |> result.replace_error(Nil))
  use message <- result.try(
    ir.string_field(error, "message") |> result.replace_error(Nil),
  )
  case
    list.all(fields, fn(pair) { list.contains(["type", "message"], pair.0) })
    && ir.field(error, "type") == Some(ir.String("rate_limit_error"))
    && string.trim(message) != ""
    && string.byte_size(message) <= 16_384
  {
    True -> Ok(string.lowercase(message))
    False -> Error(Nil)
  }
}

fn fast_refusal(message: String) -> Bool {
  string.contains(message, "fast request rejected")
  || {
    string.contains(message, "fast")
    && {
      string.contains(message, "usage credits")
      || string.contains(message, "credits are required")
    }
  }
}

fn header_scope(headers: List(Header)) -> Scope {
  let unified = field(headers, "status")
  let shared =
    list.filter(["5h", "7d"], fn(window) {
      field(headers, window <> "-status") == Some("rejected")
    })
  let both_healthy = healthy(headers, "5h") && healthy(headers, "7d")
  let overage =
    field(headers, "7d_oi-status") == Some("rejected")
    || field(headers, "overage-status") == Some("rejected")
    || single(headers, prefix <> "overage-disabled-reason") != None
    || case field(headers, "representative-claim") {
      Some(value) -> string.contains(value, "overage")
      None -> False
    }
  case shared, unified {
    // An aggregate "allowed" contradicts a simultaneously rejected shared
    // window. Do not resolve corrupt evidence into credential availability.
    [_, ..], Some("allowed") | [_, ..], Some("allowed_warning") -> Inconsistent
    [_, ..], _ -> Shared(shared)
    [], Some("rejected") ->
      case overage, both_healthy {
        True, True -> ModelOnly
        True, False -> Inconsistent
        False, True -> Inconsistent
        False, False -> Shared([])
      }
    [], _ ->
      case both_healthy {
        True -> ModelOnly
        False -> Unqualified
      }
  }
}

fn healthy(headers: List(Header), window: String) -> Bool {
  case field(headers, window <> "-status") {
    Some("allowed") | Some("allowed_warning") -> True
    None ->
      case single(headers, prefix <> window <> "-utilization") {
        Some(raw) ->
          case utilization(raw) {
            Ok(value) -> value <. 1.0
            Error(_) -> False
          }
        None -> False
      }
    _ -> False
  }
}

fn cooldown(
  headers: List(Header),
  windows: List(String),
  now: Int,
) -> Result(Int, Nil) {
  use retry <- result.try(case single(headers, "retry-after") {
    None -> Ok(0)
    Some(raw) -> {
      use time <- result.try(retry_time(raw))
      case time {
        Relative(ms) -> bounded_delay(ms)
        Absolute(ms) -> bounded_delay(int.max(0, ms - now))
      }
    }
  })
  // Latest applicable reset, not earliest. Allowed shared resets are ignored.
  // Fable reset may contribute only once actual shared quota is qualified.
  let applicable = [
    "reset",
    ..list.map(windows, fn(window) { window <> "-reset" })
  ]
  let applicable = case field(headers, "7d_oi-status") {
    Some("rejected") -> ["7d_oi-reset", ..applicable]
    _ -> applicable
  }
  use latest <- result.try(
    list.try_fold(applicable, retry, fn(latest, name) {
      case single(headers, prefix <> name) {
        None -> Ok(latest)
        Some(raw) -> {
          use timestamp <- result.try(reset(raw))
          use delay <- result.try(bounded_delay(int.max(0, timestamp - now)))
          Ok(int.max(latest, delay))
        }
      }
    }),
  )
  // Runtime's existing observation has a 60s floor. Align the public hint with
  // the actual persisted cooldown and ceil fractional milliseconds once.
  Ok(int.max(fallback_ms, { latest + 999 } / 1000 * 1000))
}

fn bounded_delay(ms: Int) -> Result(Int, Nil) {
  case ms >= 0 && ms <= max_retry_ms {
    True -> Ok(ms)
    False -> Error(Nil)
  }
}

type RetryTime {
  Relative(Int)
  Absolute(Int)
}

fn retry_time(raw: String) -> Result(RetryTime, Nil) {
  case decimal_ms(raw, max_retry_ms) {
    Ok(ms) -> Ok(Relative(ms))
    Error(_) -> timestamp(raw) |> result.map(Absolute)
  }
}

fn reset(raw: String) -> Result(Int, Nil) {
  // Reset numeric units are UNIX SECONDS, never guessed milliseconds.
  case decimal_ms(raw, 253_402_300_799_000) {
    Ok(ms) if ms > 0 -> Ok(ms)
    _ -> timestamp(raw)
  }
}

fn timestamp(raw: String) -> Result(Int, Nil) {
  // Conversion is NOT admission: OTP accepts HTTP prefixes and normalizes
  // invalid calendar/offset components. Validate the entire bounded spelling
  // first for every reset and Retry-After, then reuse the unchanged primitives.
  use _ <- result.try(
    case string.byte_size(raw) <= 256 && ascii(bit_array.from_string(raw)) {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  let parsed = case http_date_shape(raw) {
    True -> http_date_ms(raw)
    False ->
      case rfc3339_shape(bit_array.from_string(raw)) {
        True -> rfc3339_ms(raw)
        False -> Error(Nil)
      }
  }
  use ms <- result.try(parsed)
  case ms > 0 && ms <= 253_402_300_799_000 {
    True -> Ok(ms)
    False -> Error(Nil)
  }
}

fn http_date_shape(raw: String) -> Bool {
  // Preserve all three HTTP-date forms already supported by the converter.
  // Exact separators/zone/end prevent combined values and prefix acceptance.
  case string.split(raw, " ") {
    [weekday, day, month, year, clock, "GMT"] ->
      list.contains(
        ["Mon,", "Tue,", "Wed,", "Thu,", "Fri,", "Sat,", "Sun,"],
        weekday,
      )
      && string.byte_size(day) == 2
      && date_shape(year, month_number(month), day)
      && clock_shape(clock)
    [weekday, date, clock, "GMT"] ->
      list.contains(
        [
          "Monday,", "Tuesday,", "Wednesday,", "Thursday,", "Friday,",
          "Saturday,", "Sunday,",
        ],
        weekday,
      )
      && case string.split(date, "-") {
        [day, month, year] ->
          // Keep the existing OTP RFC850 conversion's 20YY interpretation.
          string.byte_size(day) == 2
          && result.is_ok(fixed_unsigned(year, 2))
          && date_shape("20" <> year, month_number(month), day)
          && clock_shape(clock)
        _ -> False
      }
    [weekday, month, day, clock, year] ->
      short_weekday(weekday)
      && string.byte_size(day) == 2
      && date_shape(year, month_number(month), day)
      && clock_shape(clock)
    [weekday, month, "", day, clock, year] ->
      short_weekday(weekday)
      && string.byte_size(day) == 1
      && date_shape(year, month_number(month), day)
      && clock_shape(clock)
    _ -> False
  }
}

fn short_weekday(raw: String) -> Bool {
  list.contains(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], raw)
}

fn month_number(raw: String) -> Int {
  case raw {
    "Jan" -> 1
    "Feb" -> 2
    "Mar" -> 3
    "Apr" -> 4
    "May" -> 5
    "Jun" -> 6
    "Jul" -> 7
    "Aug" -> 8
    "Sep" -> 9
    "Oct" -> 10
    "Nov" -> 11
    "Dec" -> 12
    _ -> 0
  }
}

fn date_shape(year: String, month: Int, day: String) -> Bool {
  let valid = {
    use year <- result.try(fixed_unsigned(year, 4))
    use day <- result.try(unsigned(day))
    let days = case month {
      2 ->
        case year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 } {
          True -> 29
          False -> 28
        }
      4 | 6 | 9 | 11 -> 30
      1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
      _ -> 0
    }
    Ok(day >= 1 && day <= days)
  }
  result.unwrap(valid, False)
}

fn clock_shape(raw: String) -> Bool {
  case string.split(raw, ":") {
    [hour, minute, second] -> clock_parts(hour, minute, second)
    _ -> False
  }
}

fn clock_parts(hour: String, minute: String, second: String) -> Bool {
  bounded_component(hour, 23)
  && bounded_component(minute, 59)
  // Explicit F10 narrowing: no :60 (even a real leap spelling). POSIX-ms
  // conversion cannot establish a leap event; pinned CPA Go also rejects it.
  && bounded_component(second, 59)
}

fn fixed_unsigned(raw: String, width: Int) -> Result(Int, Nil) {
  case string.byte_size(raw) == width {
    True -> unsigned(raw)
    False -> Error(Nil)
  }
}

fn bounded_component(raw: String, maximum: Int) -> Bool {
  case fixed_unsigned(raw, 2) {
    Ok(value) -> value <= maximum
    Error(_) -> False
  }
}

fn rfc3339_shape(raw: BitArray) -> Bool {
  case raw {
    <<
      year:bytes-size(4),
      "-",
      month:bytes-size(2),
      "-",
      day:bytes-size(2),
      separator,
      hour:bytes-size(2),
      ":",
      minute:bytes-size(2),
      ":",
      second:bytes-size(2),
      zone:bytes,
    >>
      if separator == 84 || separator == 116 || separator == 32
    -> {
      let month = unsigned(text(month)) |> result.unwrap(0)
      date_shape(text(year), month, text(day))
      && clock_parts(text(hour), text(minute), text(second))
      && case zone {
        <<".", rest:bytes>> -> fraction_zone(rest, 0)
        _ -> zone_shape(zone)
      }
    }
    _ -> False
  }
}

fn text(bytes: BitArray) -> String {
  bit_array.to_string(bytes) |> result.unwrap("")
}

fn fraction_zone(raw: BitArray, digits: Int) -> Bool {
  // Keep existing date-fraction precision/conversion (not numeric hint's 3
  // digits). The enclosing 256-byte admission cap bounds this lexical walk.
  case raw {
    <<digit, rest:bytes>> if digit >= 48 && digit <= 57 ->
      fraction_zone(rest, digits + 1)
    _ -> digits > 0 && zone_shape(raw)
  }
}

fn zone_shape(raw: BitArray) -> Bool {
  case raw {
    <<"Z">> | <<"z">> -> True
    <<sign, hour:bytes-size(2), ":", minute:bytes-size(2)>>
      if sign == 43 || sign == 45
    -> bounded_component(text(hour), 23) && bounded_component(text(minute), 59)
    _ -> False
  }
}

fn decimal_ms(raw: String, limit: Int) -> Result(Int, Nil) {
  let parts = string.split(string.trim(raw), ".")
  let parsed = case parts {
    [whole] -> {
      use seconds <- result.try(unsigned(whole))
      Ok(seconds * 1000)
    }
    [whole, fraction] -> {
      use _ <- result.try(case string.byte_size(fraction) <= 3 {
        True -> Ok(Nil)
        False -> Error(Nil)
      })
      use seconds <- result.try(unsigned(whole))
      use partial <- result.try(unsigned(fraction))
      let scale = case string.byte_size(fraction) {
        1 -> 100
        2 -> 10
        _ -> 1
      }
      Ok(seconds * 1000 + partial * scale)
    }
    _ -> Error(Nil)
  }
  use ms <- result.try(parsed)
  case ms <= limit {
    True -> Ok(ms)
    False -> Error(Nil)
  }
}

fn unsigned(raw: String) -> Result(Int, Nil) {
  case
    raw != ""
    && string.byte_size(raw) <= 12
    && list.all(string.to_graphemes(raw), fn(char) {
      string.contains("0123456789", char)
    })
  {
    True -> int.parse(raw) |> result.replace_error(Nil)
    False -> Error(Nil)
  }
}

fn utilization(raw: String) -> Result(Float, Nil) {
  let raw = string.trim(raw)
  use _ <- result.try(case string.split(raw, ".") {
    [whole] -> unsigned(whole) |> result.map(fn(_) { Nil })
    [whole, fraction] -> {
      use _ <- result.try(case string.byte_size(fraction) <= 6 {
        True -> Ok(Nil)
        False -> Error(Nil)
      })
      use _ <- result.try(unsigned(whole))
      unsigned(fraction) |> result.map(fn(_) { Nil })
    }
    _ -> Error(Nil)
  })
  // Gleam float.parse requires a decimal point, while the provider may use
  // valid integer-form utilization (notably "0"). Syntax was checked above.
  let decimal = case string.contains(raw, ".") {
    True -> raw
    False -> raw <> ".0"
  }
  use value <- result.try(float.parse(decimal) |> result.replace_error(Nil))
  case value >=. 0.0 && value <=. 1_000_000.0 {
    True -> Ok(value)
    False -> Error(Nil)
  }
}

/// Only new, canonical headers are transferred to runtime. No original header
/// list, body, request id, overage reason or utilization leaves the classifier.
pub fn sanitized_headers(
  retry_after_ms: Int,
  windows: List(String),
) -> List(Header) {
  [
    Header("Retry-After", int.to_string({ retry_after_ms + 999 } / 1000)),
    ..list.map(windows, fn(window) {
      Header(prefix <> window <> "-status", "rejected")
    })
  ]
}

/// The classified constructor invokes this only for its closed, qualified 429.
/// Validate canonical normalized output again rather than reuse OAuth's 5m cap.
pub fn retry_after(headers: List(Header)) -> Option(Int) {
  case values(headers, "retry-after") {
    [raw] ->
      case unsigned(raw) {
        Ok(seconds) if seconds >= 60 && seconds <= 604_800 ->
          Some(seconds * 1000)
        _ -> None
      }
    _ -> None
  }
}

fn values(headers: List(Header), name: String) -> List(String) {
  headers
  |> list.filter(fn(header) { string.lowercase(header.name) == name })
  |> list.map(fn(header) { header.value })
}

fn single(headers: List(Header), name: String) -> Option(String) {
  case values(headers, name) {
    [raw] -> Some(string.trim(raw))
    _ -> None
  }
}

fn field(headers: List(Header), suffix: String) -> Option(String) {
  single(headers, prefix <> suffix) |> option.map(string.lowercase)
}

fn ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte >= 32 && byte <= 126 -> ascii(rest)
    _ -> False
  }
}
