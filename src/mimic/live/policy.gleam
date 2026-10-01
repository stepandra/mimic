/// Single request authority and worst-case quote. Arbitrary raw route/body
/// controls are not delegated to transport adapters.
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/ir/json_guard
import mimic/live/admission
import mimic/live/identity

pub type Limits {
  Limits(
    requests: Int,
    input_tokens: Int,
    output_tokens: Int,
    cost_nano_usd: Int,
    duration_ms: Int,
    request_ms: Int,
    response_bytes: Int,
    stream_chunks: Int,
  )
}

pub type Scope {
  Scope(
    account: String,
    endpoint: String,
    model: String,
    method: String,
    path: String,
  )
}

pub type Price {
  Price(
    scope: Scope,
    input_nano_usd: Int,
    output_nano_usd: Int,
    fixed_nano_usd: Int,
  )
}

/// Synthetic fixture convention only: one input token per raw request byte.
/// This is NOT a tokenizer estimate or an upper-bound claim for real providers.
/// A live adapter must supply a separately verified route/token-ceiling rule.
pub type Ceilings {
  SyntheticBytes(input: Int, output: Int)
}

pub type Approval {
  Approval(
    approved_by: String,
    account: String,
    scenario: String,
    endpoint: String,
    endpoint_allowlist: List(String),
    case_id: String,
    contract_sha256: String,
    body_sha256: String,
    model: String,
    price: Option(Price),
    ceilings: Option(Ceilings),
    limits: Limits,
  )
}

pub type Request {
  Request(
    account: String,
    scenario: String,
    endpoint: String,
    method: String,
    path: String,
    protocol: String,
    body: String,
  )
}

pub opaque type Plan {
  Plan(
    request: Request,
    input_ceiling: Int,
    output_ceiling: Int,
    cost_ceiling: Int,
    price: Price,
    streaming: Bool,
    limits: Limits,
  )
}

pub fn valid_limits(limits: Limits) -> Bool {
  limits.requests > 0
  && limits.requests <= 1024
  && limits.input_tokens > 0
  && limits.input_tokens <= 1_000_000
  && limits.output_tokens > 0
  && limits.output_tokens <= 1_000_000
  && limits.cost_nano_usd > 0
  && limits.cost_nano_usd <= 1_000_000_000
  && limits.duration_ms > 0
  && limits.duration_ms <= 60_000
  && limits.request_ms > 0
  && limits.request_ms <= limits.duration_ms
  && limits.response_bytes > 0
  && limits.response_bytes <= 65_536
  && limits.stream_chunks > 0
  && limits.stream_chunks <= 1024
}

pub fn authorize(
  admission: admission.Admission,
  approval: Approval,
  binding: identity.Binding,
  request: Request,
) -> Result(Plan, String) {
  let selected = identity.selected(binding)
  use _ <- result.try(
    case
      string.trim(approval.approved_by) != ""
      && approval.account != ""
      && approval.scenario != ""
      && approval.model == "synthetic-model"
      && valid_limits(approval.limits)
      && list.length(approval.endpoint_allowlist) <= 16
      && list.contains(approval.endpoint_allowlist, approval.endpoint)
      && admission.endpoint(admission) == approval.endpoint
      && request.endpoint == approval.endpoint
      && request.account == approval.account
      && request.scenario == approval.scenario
      && selected.id == approval.case_id
      && identity.contract_sha256(binding) == approval.contract_sha256
      && request.method == selected.method
      && request.path == selected.path
      && list.contains(["http", "sse"], selected.transport)
      && request.protocol == "HTTP/1.1"
      && identity.valid_digest(approval.body_sha256)
      && string.byte_size(request.body) <= 16_384
      && identity.sha256(request.body) == approval.body_sha256
    {
      True -> Ok(Nil)
      False -> Error("live_approval_route_identity_or_body_mismatch")
    },
  )
  use price <- result.try(case approval.price {
    Some(price) -> Ok(price)
    None -> Error("live_unknown_pricing")
  })
  use ceilings <- result.try(case approval.ceilings {
    Some(ceilings) -> Ok(ceilings)
    None -> Error("live_unknown_token_ceiling")
  })
  let SyntheticBytes(input, output) = ceilings
  use _ <- result.try(
    case
      price.scope
      == Scope(
        request.account,
        request.endpoint,
        approval.model,
        request.method,
        request.path,
      )
      && price.input_nano_usd >= 0
      && price.output_nano_usd >= 0
      && price.fixed_nano_usd >= 0
      && price.input_nano_usd <= 1_000_000_000
      && price.output_nano_usd <= 1_000_000_000
      && price.fixed_nano_usd <= 1_000_000_000
      && input > 0
      && input <= approval.limits.input_tokens
      && output > 0
      && output <= approval.limits.output_tokens
      && string.byte_size(request.body) <= input
    {
      True -> Ok(Nil)
      False -> Error("live_pricing_route_or_ceiling_invalid")
    },
  )
  use streaming <- result.try(validate_body(request, approval.model, output))
  use _ <- result.try(case streaming == { selected.transport == "sse" } {
    True -> Ok(Nil)
    False -> Error("live_f01_stream_mode_mismatch")
  })
  let cost =
    input
    * price.input_nano_usd
    + output
    * price.output_nano_usd
    + price.fixed_nano_usd
  use _ <- result.try(case cost <= approval.limits.cost_nano_usd {
    True -> Ok(Nil)
    False -> Error("live_worst_case_exceeds_cost_budget")
  })
  Ok(Plan(request, input, output, cost, price, streaming, approval.limits))
}

fn validate_body(
  request: Request,
  model: String,
  output: Int,
) -> Result(Bool, String) {
  use output_key <- result.try(case request.method, request.path {
    "POST", "/v1/messages" | "POST", "/v1/chat/completions" -> Ok("max_tokens")
    "POST", "/v1/responses" -> Ok("max_output_tokens")
    _, _ -> Error("live_unknown_or_unsupported_route")
  })
  use _ <- result.try(
    json_guard.validate(request.body, 16_384, 8, 512)
    |> result.replace_error("live_request_json_invalid"),
  )
  use keys <- result.try(
    json.parse(request.body, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("live_request_object_required"),
  )
  let input_key = case request.path {
    "/v1/responses" -> "input"
    _ -> "messages"
  }
  use _ <- result.try(
    case
      list.all(dict.keys(keys), fn(key) {
        list.contains(["model", output_key, input_key, "stream"], key)
      })
    {
      True -> Ok(Nil)
      False -> Error("live_unapproved_request_controls")
    },
  )
  let message = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use role <- decode.field("role", decode.string)
    use content <- decode.field("content", decode.string)
    decode.success(
      role == "user"
      && content != ""
      && list.sort(dict.keys(fields), fn(a, b) { string.compare(a, b) })
      == ["content", "role"],
    )
  }
  let decoder = {
    use body_model <- decode.field("model", decode.string)
    use maximum <- decode.field(output_key, decode.int)
    use streaming <- decode.optional_field("stream", False, decode.bool)
    use valid_input <- decode.field(input_key, case request.path {
      "/v1/responses" -> decode.map(decode.string, fn(text) { text != "" })
      _ ->
        decode.map(decode.list(message), fn(messages) {
          messages != []
          && list.length(messages) <= 16
          && list.all(messages, fn(valid) { valid })
        })
    })
    decode.success(#(body_model, maximum, streaming, valid_input))
  }
  use values <- result.try(
    json.parse(request.body, decoder)
    |> result.replace_error("live_request_token_controls_invalid"),
  )
  let #(body_model, maximum, streaming, valid_input) = values
  case body_model == model && maximum > 0 && maximum <= output && valid_input {
    True -> Ok(streaming)
    False -> Error("live_request_token_controls_invalid")
  }
}

pub fn request(plan: Plan) -> Request {
  plan.request
}

pub fn limits(plan: Plan) -> Limits {
  plan.limits
}

pub fn input_ceiling(plan: Plan) -> Int {
  plan.input_ceiling
}

pub fn output_ceiling(plan: Plan) -> Int {
  plan.output_ceiling
}

pub fn cost_ceiling(plan: Plan) -> Int {
  plan.cost_ceiling
}

pub fn usage_cost(plan: Plan, input: Int, output: Int) -> Int {
  input
  * plan.price.input_nano_usd
  + output
  * plan.price.output_nano_usd
  + plan.price.fixed_nano_usd
}

pub fn streaming(plan: Plan) -> Bool {
  plan.streaming
}
