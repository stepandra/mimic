/// Explicitly SYNTHETIC budget fixtures. No executable/CPA/provider identity or
/// paid tariff is measured by these helpers. They do not launch anything.
import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/live/identity
import mimic/live/policy
import mimic/live/runner

pub fn setup(
  contract_bytes: String,
  case_id: String,
  endpoint: String,
  streaming: Bool,
) -> Result(#(policy.Approval, identity.Binding, policy.Request), String) {
  let candidate_digest =
    identity.sha256("synthetic-candidate-not-an-executable")
  let reference_digest = identity.sha256("synthetic-reference-not-CPA")
  let candidate =
    identity.Claim(
      candidate_digest,
      candidate_digest,
      candidate_digest,
      candidate_digest,
    )
  let reference =
    identity.Claim(
      reference_digest,
      reference_digest,
      reference_digest,
      reference_digest,
    )
  use binding <- result.try(identity.bind(
    contract_bytes,
    identity.sha256(contract_bytes),
    case_id,
    candidate,
    reference,
  ))
  let selected = identity.selected(binding)
  let fields = case selected.path {
    "/v1/responses" -> [
      #("model", json.string("synthetic-model")),
      #("max_output_tokens", json.int(32)),
      #("input", json.string("ping")),
    ]
    _ -> [
      #("model", json.string("synthetic-model")),
      #("max_tokens", json.int(32)),
      #(
        "messages",
        json.array(
          [
            json.object([
              #("role", json.string("user")),
              #("content", json.string("ping")),
            ]),
          ],
          fn(value) { value },
        ),
      ),
    ]
  }
  let fields = case streaming {
    True -> list.append(fields, [#("stream", json.bool(True))])
    False -> fields
  }
  let body = json.object(fields) |> json.to_string
  let input = string.byte_size(body)
  let ceiling = input * 2 + 32 * 3
  let approval =
    policy.Approval(
      "synthetic-fixture-operator",
      "synthetic-account",
      "synthetic-budget-case",
      endpoint,
      [endpoint],
      case_id,
      identity.contract_sha256(binding),
      identity.sha256(body),
      "synthetic-model",
      Some(policy.Price(
        policy.Scope(
          "synthetic-account",
          endpoint,
          "synthetic-model",
          selected.method,
          selected.path,
        ),
        2,
        3,
        0,
      )),
      Some(policy.SyntheticBytes(input, 32)),
      policy.Limits(2, input * 2, 64, ceiling * 2, 2000, 1000, 4096, 32),
    )
  let request =
    policy.Request(
      approval.account,
      approval.scenario,
      endpoint,
      selected.method,
      selected.path,
      "HTTP/1.1",
      body,
    )
  Ok(#(approval, binding, request))
}

/// Actual runner execution with injectable in-memory fixture transport, not a
/// budget simulation. The concrete socket transport is separate (`live/http`).
pub fn transport(
  usage: Option(runner.Usage),
  on_send: fn(policy.Plan) -> Nil,
  on_cancel: fn() -> Nil,
) -> runner.Transport(Int) {
  runner.Transport(
    fn(_, _) { Ok(0) },
    fn(connection, plan, _) {
      on_send(plan)
      Ok(connection)
    },
    fn(connection, _, _) {
      case connection {
        0 -> Ok(runner.Head(200, 1))
        1 -> Ok(runner.Data(bit_array.from_string("synthetic"), 2))
        _ -> Ok(runner.End(usage))
      }
    },
    fn(_) { on_cancel() },
  )
}

/// Generate synthetic CLI fixture metadata with the same typed inputs used by
/// execution tests. These supplied SHA claims do not attest running identity.
pub fn approval_json(
  approval: policy.Approval,
  binding: identity.Binding,
  attempts: List(String),
) -> String {
  let #(candidate, reference) = identity.claims(binding)
  let limits = approval.limits
  json.object([
    #("schema", json.string("mimic.f04-approval/v1")),
    #("allowed_data", json.string("synthetic-only")),
    #("approved_by", json.string(approval.approved_by)),
    #("account", json.string(approval.account)),
    #("scenario", json.string(approval.scenario)),
    #("endpoint", json.string(approval.endpoint)),
    #(
      "endpoint_allowlist",
      json.array(approval.endpoint_allowlist, json.string),
    ),
    #("case_id", json.string(approval.case_id)),
    #("contract_sha256", json.string(approval.contract_sha256)),
    #("body_sha256", json.string(approval.body_sha256)),
    #("model", json.string(approval.model)),
    #("price", case approval.price {
      None -> json.null()
      Some(price) ->
        json.object([
          #(
            "scope",
            json.object([
              #("account", json.string(price.scope.account)),
              #("endpoint", json.string(price.scope.endpoint)),
              #("model", json.string(price.scope.model)),
              #("method", json.string(price.scope.method)),
              #("path", json.string(price.scope.path)),
            ]),
          ),
          #("input_nano_usd", json.int(price.input_nano_usd)),
          #("output_nano_usd", json.int(price.output_nano_usd)),
          #("fixed_nano_usd", json.int(price.fixed_nano_usd)),
        ])
    }),
    #("ceilings", case approval.ceilings {
      None -> json.null()
      Some(policy.SyntheticBytes(input, output)) ->
        json.object([
          #("rule", json.string("synthetic-bytes/v1")),
          #("input", json.int(input)),
          #("output", json.int(output)),
        ])
    }),
    #(
      "limits",
      json.object([
        #("requests", json.int(limits.requests)),
        #("input_tokens", json.int(limits.input_tokens)),
        #("output_tokens", json.int(limits.output_tokens)),
        #("cost_nano_usd", json.int(limits.cost_nano_usd)),
        #("duration_ms", json.int(limits.duration_ms)),
        #("request_ms", json.int(limits.request_ms)),
        #("response_bytes", json.int(limits.response_bytes)),
        #("stream_chunks", json.int(limits.stream_chunks)),
      ]),
    ),
    #("candidate_claim", identity.encode_claim(candidate)),
    #("reference_claim", identity.encode_claim(reference)),
    #("attempt_ids", json.array(attempts, json.string)),
  ])
  |> json.to_string
}
