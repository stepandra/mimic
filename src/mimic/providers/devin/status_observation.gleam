/// F28 numeric-only operator observations. Provider identity/plan strings,
/// tokens, raw protobuf, and arbitrary upstream diagnostics never leave here.
import gleam/json
import gleam/option.{type Option, None, Some}
import mimic/providers/devin/status
import mimic/providers/devin/tokens

pub type Observation {
  Observation(
    account: String,
    observed_at_ms: Int,
    daily_remaining_percent: Option(Int),
    weekly_remaining_percent: Option(Int),
    daily_reset_seconds: Option(Int),
    weekly_reset_seconds: Option(Int),
    plan_start_seconds: Option(Int),
    plan_end_seconds: Option(Int),
  )
}

pub fn from_status(
  configured_account: String,
  value: status.Observation,
) -> Observation {
  Observation(
    configured_account,
    value.observed_at_ms,
    value.daily_remaining_percent,
    value.weekly_remaining_percent,
    value.daily_reset_seconds,
    value.weekly_reset_seconds,
    value.plan_start_seconds,
    value.plan_end_seconds,
  )
}

/// Null means unknown; a present zero quota means exhausted. Reset/plan
/// values are exact source Unix seconds, NOT grant expiry or cooldowns.
pub fn to_json(value: Observation) -> String {
  json.object([
    #("provider", json.string("devin")),
    #("account", json.string(value.account)),
    #("observed_at_ms", json.int(value.observed_at_ms)),
    #("daily_remaining_percent", optional_int(value.daily_remaining_percent)),
    #("weekly_remaining_percent", optional_int(value.weekly_remaining_percent)),
    #("daily_reset_seconds", optional_int(value.daily_reset_seconds)),
    #("weekly_reset_seconds", optional_int(value.weekly_reset_seconds)),
    #("plan_start_seconds", optional_int(value.plan_start_seconds)),
    #("plan_end_seconds", optional_int(value.plan_end_seconds)),
    #("quota_enforcement", json.bool(False)),
    #("grant_rotated", json.bool(False)),
  ])
  |> json.to_string
}

/// Separate pure count projection. Status has no token counts; never invent
/// one from its protobuf body. CPA's payload bytes / 4 is only an estimate.
pub fn estimated_tokens(payload: String) -> String {
  let value = tokens.estimate(payload)
  json.object([
    #("estimated_input_tokens", json.int(value.input_tokens)),
    #("payload_bytes", json.int(value.payload_bytes)),
    #("estimate", json.bool(True)),
    #("exact", json.bool(False)),
    #("method", json.string("payload_utf8_bytes_div_4")),
  ])
  |> json.to_string
}

fn optional_int(value: Option(Int)) -> json.Json {
  case value {
    None -> json.null()
    Some(value) -> json.int(value)
  }
}
