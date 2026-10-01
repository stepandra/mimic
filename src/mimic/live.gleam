/// F04 entrypoint. Synthetic execution is usable; live/native admission is
/// blocked pending real F02/F03 and explicit live inputs, not marked complete.
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir/json_guard
import mimic/live/admission
import mimic/live/budget
import mimic/live/http
import mimic/live/identity
import mimic/live/policy
import mimic/live/runner

@external(erlang, "mimic_live_ffi", "read_regular")
fn read_regular(
  path: String,
  maximum: Int,
  private: Bool,
) -> Result(String, String)

type Input {
  Input(
    approval: policy.Approval,
    candidate: identity.Claim,
    reference: identity.Claim,
    attempts: List(String),
  )
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["synthetic", approval_path, contract_path, body_path] ->
      run_synthetic(approval_path, contract_path, body_path)
    ["run", approved_by, account, endpoint, scenario] ->
      admission.live(admission.LiveInputs(
        approved_by,
        account,
        endpoint,
        scenario,
      ))
      |> result.map(fn(_) { "unreachable_without_verified_live_admission" })
    ["native", approved_by, account, endpoint, scenario] ->
      admission.native(admission.LiveInputs(
        approved_by,
        account,
        endpoint,
        scenario,
      ))
      |> result.map(fn(_) { "unreachable_without_verified_native_admission" })
    _ ->
      Error(
        "live: synthetic <private-approval.json> <F01-contract.json> <private-body.json> | run <approved-by> <account-label> <endpoint> <scenario> (blocked: F02/F03) | native <approved-by> <account-label> <endpoint> <scenario> (blocked: F02)",
      )
  }
}

fn run_synthetic(
  approval_path: String,
  contract_path: String,
  body_path: String,
) -> Result(String, String) {
  use approval_text <- result.try(read_regular(approval_path, 16_384, True))
  use input <- result.try(parse_input(approval_text))
  use allowed <- result.try(admission.synthetic(input.approval.endpoint))
  use contract_bytes <- result.try(read_regular(contract_path, 1_048_576, False))
  use binding <- result.try(identity.bind(
    contract_bytes,
    input.approval.contract_sha256,
    input.approval.case_id,
    input.candidate,
    input.reference,
  ))
  use body <- result.try(read_regular(body_path, 16_384, True))
  let selected = identity.selected(binding)
  let request =
    policy.Request(
      input.approval.account,
      input.approval.scenario,
      input.approval.endpoint,
      selected.method,
      selected.path,
      "HTTP/1.1",
      body,
    )
  // All static authorization/quote checks finish before actor/socket creation.
  use _ <- result.try(policy.authorize(
    allowed,
    input.approval,
    binding,
    request,
  ))
  use running <- result.try(runner.start(
    allowed,
    input.approval,
    binding,
    http.transport(),
  ))
  let outcomes =
    list.map(input.attempts, fn(id) {
      #(id, runner.execute(running, id, request))
    })
  let final = runner.close(running)
  use final <- result.try(final)
  Ok(encode_report(binding, final, outcomes))
}

fn limits_decoder() -> decode.Decoder(policy.Limits) {
  use requests <- decode.field("requests", decode.int)
  use input <- decode.field("input_tokens", decode.int)
  use output <- decode.field("output_tokens", decode.int)
  use cost <- decode.field("cost_nano_usd", decode.int)
  use duration <- decode.field("duration_ms", decode.int)
  use request <- decode.field("request_ms", decode.int)
  use bytes <- decode.field("response_bytes", decode.int)
  use chunks <- decode.field("stream_chunks", decode.int)
  decode.success(policy.Limits(
    requests,
    input,
    output,
    cost,
    duration,
    request,
    bytes,
    chunks,
  ))
}

fn price_decoder() -> decode.Decoder(policy.Price) {
  let scope = {
    use account <- decode.field("account", decode.string)
    use endpoint <- decode.field("endpoint", decode.string)
    use model <- decode.field("model", decode.string)
    use method <- decode.field("method", decode.string)
    use path <- decode.field("path", decode.string)
    decode.success(policy.Scope(account, endpoint, model, method, path))
  }
  use scope <- decode.field("scope", scope)
  use input <- decode.field("input_nano_usd", decode.int)
  use output <- decode.field("output_nano_usd", decode.int)
  use fixed <- decode.field("fixed_nano_usd", decode.int)
  decode.success(policy.Price(scope, input, output, fixed))
}

fn ceiling_decoder() -> decode.Decoder(policy.Ceilings) {
  use rule <- decode.field("rule", decode.string)
  use input <- decode.field("input", decode.int)
  use output <- decode.field("output", decode.int)
  case rule {
    "synthetic-bytes/v1" -> decode.success(policy.SyntheticBytes(input, output))
    _ -> decode.failure(policy.SyntheticBytes(0, 0), "known token ceiling rule")
  }
}

fn parse_input(text: String) -> Result(Input, String) {
  use _ <- result.try(
    json_guard.validate(text, 16_384, 8, 512)
    |> result.replace_error("live_approval_json_invalid"),
  )
  use fields <- result.try(
    json.parse(text, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("live_approval_object_required"),
  )
  let required = [
    "schema", "allowed_data", "approved_by", "account", "scenario", "endpoint",
    "endpoint_allowlist", "case_id", "contract_sha256", "body_sha256", "model",
    "price", "ceilings", "limits", "candidate_claim", "reference_claim",
    "attempt_ids",
  ]
  use _ <- result.try(
    case
      list.length(dict.keys(fields)) == list.length(required)
      && list.all(dict.keys(fields), fn(key) { list.contains(required, key) })
    {
      True -> Ok(Nil)
      False -> Error("live_approval_fields_invalid")
    },
  )
  let decoder = {
    use schema <- decode.field("schema", decode.string)
    use data <- decode.field("allowed_data", decode.string)
    use approved_by <- decode.field("approved_by", decode.string)
    use account <- decode.field("account", decode.string)
    use scenario <- decode.field("scenario", decode.string)
    use endpoint <- decode.field("endpoint", decode.string)
    use allowlist <- decode.field(
      "endpoint_allowlist",
      decode.list(decode.string),
    )
    use case_id <- decode.field("case_id", decode.string)
    use contract_hash <- decode.field("contract_sha256", decode.string)
    use body_hash <- decode.field("body_sha256", decode.string)
    use model <- decode.field("model", decode.string)
    use price <- decode.field("price", decode.optional(price_decoder()))
    use ceilings <- decode.field("ceilings", decode.optional(ceiling_decoder()))
    use limits <- decode.field("limits", limits_decoder())
    use candidate <- decode.field("candidate_claim", identity.claim_decoder())
    use reference <- decode.field("reference_claim", identity.claim_decoder())
    use attempts <- decode.field("attempt_ids", decode.list(decode.string))
    decode.success(#(
      schema,
      data,
      Input(
        policy.Approval(
          approved_by,
          account,
          scenario,
          endpoint,
          allowlist,
          case_id,
          contract_hash,
          body_hash,
          model,
          price,
          ceilings,
          limits,
        ),
        candidate,
        reference,
        attempts,
      ),
    ))
  }
  use parsed <- result.try(
    json.parse(text, decoder)
    |> result.replace_error("live_approval_values_invalid"),
  )
  let #(schema, data, input) = parsed
  case
    schema == "mimic.f04-approval/v1"
    && data == "synthetic-only"
    && input.attempts != []
    && list.length(input.attempts) <= 1024
  {
    True -> Ok(input)
    False -> Error("live_synthetic_approval_required")
  }
}

pub fn encode_report(
  binding: identity.Binding,
  snapshot: budget.Snapshot,
  outcomes: List(#(String, Result(runner.Outcome, String))),
) -> String {
  json.object([
    #("schema", json.string("mimic.f04-execution/v1")),
    #("evidence_class", json.string("synthetic-budget-enforcement")),
    #("live_admission", json.string("blocked_verified_f02_f03_missing")),
    #("case_assertions", json.string("not_evaluated")),
    #("identity", identity.encode(binding)),
    #(
      "lifecycle",
      json.string(case snapshot.lifecycle {
        budget.Open -> "open"
        budget.Closed(reason) -> reason
      }),
    ),
    #("requests_reserved", json.int(snapshot.requests_reserved)),
    #("input_reserved", json.int(snapshot.input_reserved)),
    #("output_reserved", json.int(snapshot.output_reserved)),
    #("cost_reserved_nano_usd", json.int(snapshot.cost_reserved_nano_usd)),
    #(
      "outcomes",
      json.array(outcomes, fn(pair) {
        let #(id, outcome) = pair
        let fields = [#("attempt_id", json.string(id))]
        case outcome {
          Error(error) ->
            json.object([#("denied", json.string(error)), ..fields])
          Ok(outcome) ->
            json.object([
              #(
                "delivery",
                json.string(case outcome.delivery {
                  runner.NotSent -> "not_sent"
                  runner.Sent -> "sent"
                  runner.Uncertain -> "uncertain"
                }),
              ),
              #("reason", json.string(reason(outcome.reason))),
              #("response_bytes", json.int(outcome.response_bytes)),
              #("usage", case outcome.usage {
                None -> json.null()
                Some(usage) ->
                  json.object([
                    #("input_tokens", json.int(usage.input_tokens)),
                    #("output_tokens", json.int(usage.output_tokens)),
                  ])
              }),
              #("observed_cost_nano_usd", case outcome.observed_cost_nano_usd {
                None -> json.null()
                Some(cost) -> json.int(cost)
              }),
              ..fields
            ])
        }
      }),
    ),
  ])
  |> json.to_string
}

fn reason(reason: runner.Reason) -> String {
  case reason {
    runner.Completed -> "transport_completed_not_a_parity_pass"
    runner.ConnectFailed -> "connect_failed"
    runner.WriteFailed -> "write_failed"
    runner.ReadFailed -> "read_failed"
    runner.ResponseRejected -> "response_rejected"
    runner.ResponseLimit -> "response_limit"
    runner.UsageLimit -> "usage_limit"
    runner.UsageNonMonotonic -> "usage_non_monotonic"
    runner.UsageInvalid -> "usage_contract_unsupported"
    runner.TimedOut -> "timed_out"
    runner.Cancelled -> "cancelled"
    runner.WorkerFailed -> "worker_failed"
  }
}
