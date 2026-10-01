/// Dedicated offline tests. F01 bytes are read as public input; no F01 runner,
/// provider, native executable, paid endpoint or containment backend is used.
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/live
import mimic/live/admission
import mimic/live/budget
import mimic/live/http
import mimic/live/identity
import mimic/live/policy
import mimic/live/synthetic
import simplifile

pub fn fixture() -> #(policy.Approval, identity.Binding, policy.Request) {
  let assert Ok(contract) =
    simplifile.read("docs/parity/final-v1/contract.json")
  let assert Ok(fixture) =
    synthetic.setup(
      contract,
      "claude-messages.final-v1",
      "http://127.0.0.1:39051",
      False,
    )
  fixture
}

pub fn plan(
  approval: policy.Approval,
  binding: identity.Binding,
  request: policy.Request,
) -> policy.Plan {
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let assert Ok(plan) = policy.authorize(allowed, approval, binding, request)
  plan
}

pub fn binding_uses_exact_bytes_and_versioned_unambiguous_encoding_test() {
  let #(approval, binding, _) = fixture()
  let encoded =
    json.array(
      ["mimic.f04-case-binding/v1", approval.contract_sha256, approval.case_id],
      json.string,
    )
    |> json.to_string
    |> identity.sha256
  identity.case_binding_sha256(binding) |> should.equal(encoded)
  let assert Ok(contract) =
    simplifile.read("docs/parity/final-v1/contract.json")
  let digest = identity.sha256("synthetic-not-an-executable")
  let claim = identity.Claim(digest, digest, digest, digest)
  identity.bind(
    contract <> "\n",
    approval.contract_sha256,
    approval.case_id,
    claim,
    claim,
  )
  |> should.be_error
  identity.bind(
    contract,
    approval.contract_sha256,
    "missing.final-v1",
    claim,
    claim,
  )
  |> should.be_error
  let report = identity.encode(binding) |> json.to_string
  string.contains(report, "\"running_identity\":\"unverified\"")
  |> should.be_true
  string.contains(report, "\"native\":\"not_run\"") |> should.be_true
  string.contains(report, "\"live\":\"not_run\"") |> should.be_true
}

pub fn admission_is_not_a_qualification_flag_test() {
  list.each(
    [
      "http://127.0.0.1:8317", "https://localhost:8317",
      "http://localhost:39051", "http://127.0.0.1:39051/",
      "http://127.0.0.1:39051?x=1", "http://127.0.0.1:39051#x",
      "http://user@127.0.0.1:39051", "http://127.0.0.1:039051",
      "http://127.0.0.1:39051\n", "http://127.0.0.1:39051http://127.0.0.1:39052",
    ],
    fn(endpoint) { admission.synthetic(endpoint) |> should.be_error },
  )
  admission.synthetic("http://127.0.0.1:39051") |> should.be_ok
  let inputs =
    admission.LiveInputs(
      "operator",
      "selected-account",
      "https://approved.invalid",
      "chosen-case",
    )
  admission.live(inputs) |> should.be_error
  admission.native(inputs) |> should.be_error
  live.cli([
    "run",
    "operator",
    "account",
    "https://approved.invalid",
    "chosen-case",
  ])
  |> should.equal(Error(
    "live_admission_blocked_verified_f02_boundary_and_running_identity_missing",
  ))
}

pub fn unknown_price_route_and_token_ceiling_fail_closed_test() {
  let #(approval, binding, request) = fixture()
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  policy.authorize(
    allowed,
    policy.Approval(..approval, price: None),
    binding,
    request,
  )
  |> should.equal(Error("live_unknown_pricing"))
  policy.authorize(
    allowed,
    policy.Approval(..approval, ceilings: None),
    binding,
    request,
  )
  |> should.equal(Error("live_unknown_token_ceiling"))
  let assert Some(price) = approval.price
  let price =
    policy.Price(..price, scope: policy.Scope(..price.scope, path: "/unpriced"))
  policy.authorize(
    allowed,
    policy.Approval(..approval, price: Some(price)),
    binding,
    request,
  )
  |> should.be_error
  list.each(
    [
      policy.Request(..request, path: "//other.invalid/v1/messages"),
      policy.Request(
        ..request,
        path: "/v1/messages?redirect=http://other.invalid",
      ),
      policy.Request(..request, method: "GET"),
      policy.Request(..request, protocol: "HTTP/2"),
      policy.Request(..request, endpoint: "http://127.0.0.1:39052"),
      policy.Request(..request, account: "other-account"),
      policy.Request(..request, scenario: "other-case"),
    ],
    fn(request) {
      policy.authorize(allowed, approval, binding, request) |> should.be_error
    },
  )
  policy.authorize(
    allowed,
    policy.Approval(..approval, endpoint_allowlist: []),
    binding,
    request,
  )
  |> should.be_error
}

pub fn body_cannot_expand_authority_or_output_test() {
  let #(approval, binding, request) = fixture()
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let base =
    "\"model\":\"synthetic-model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]"
  list.each(
    [
      "{" <> base <> ",\"max_tokens\":1000000}",
      "{" <> base <> ",\"proxy\":\"http://outside.invalid\"}",
      "{" <> base <> ",\"url\":\"http://outside.invalid\"}",
      "{" <> base <> ",\"max_output_tokens\":1000000}",
      "{" <> base <> ",\"tools\":[{\"type\":\"web_search\"}]}",
      "{\"model\":\"other-model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}",
      "{\"model\":\"synthetic-model\",\"max_tokens\":33,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}",
      "{\"model\":\"synthetic-model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"url\":\"http://outside.invalid\"}]}]}",
    ],
    fn(body) {
      // Even a newly approved exact body hash cannot authorize unsafe controls.
      let approval =
        policy.Approval(
          ..approval,
          body_sha256: identity.sha256(body),
          ceilings: Some(policy.SyntheticBytes(1024, 32)),
          limits: policy.Limits(
            ..approval.limits,
            input_tokens: 2048,
            cost_nano_usd: 10_000,
          ),
        )
      policy.authorize(
        allowed,
        approval,
        binding,
        policy.Request(..request, body: body),
      )
      |> should.be_error
    },
  )
  policy.authorize(
    allowed,
    approval,
    binding,
    policy.Request(..request, body: request.body <> " "),
  )
  |> should.be_error
}

pub fn worst_case_ledger_is_monotonic_bounded_and_no_duplicate_replay_test() {
  let #(approval, binding, request) = fixture()
  let plan = plan(approval, binding, request)
  let assert Ok(empty) = budget.new(approval.limits, 1000)
  let assert Ok(first) = budget.reserve(empty, "attempt-1", plan, 1001)
  budget.snapshot(first).cost_reserved_nano_usd
  |> should.equal(policy.cost_ceiling(plan))
  budget.snapshot(first).input_reserved
  |> should.equal(policy.input_ceiling(plan))
  budget.snapshot(first).output_reserved
  |> should.equal(policy.output_ceiling(plan))
  budget.reserve(first, "attempt-1", plan, 1002) |> should.be_error
  let assert Ok(second) = budget.reserve(first, "attempt-2", plan, 1002)
  budget.reserve(second, "attempt-3", plan, 1003)
  |> should.equal(Error("live_budget_exhausted"))
  let closed = budget.close(second, "operator_cancel")
  budget.snapshot(closed).cost_reserved_nano_usd
  |> should.equal(policy.cost_ceiling(plan) * 2)
  budget.reserve(closed, "attempt-4", plan, 1004)
  |> should.equal(Error("live_run_closed"))
  budget.reserve(empty, "attempt-5", plan, 3000) |> should.be_error
}

pub fn each_budget_dimension_independently_stops_admission_test() {
  let #(approval, binding, request) = fixture()
  let plan = plan(approval, binding, request)
  list.each(
    [
      policy.Limits(..approval.limits, requests: 1),
      policy.Limits(..approval.limits, input_tokens: policy.input_ceiling(plan)),
      policy.Limits(
        ..approval.limits,
        output_tokens: policy.output_ceiling(plan),
      ),
      policy.Limits(..approval.limits, cost_nano_usd: policy.cost_ceiling(plan)),
    ],
    fn(limits) {
      let assert Ok(empty) = budget.new(limits, 1000)
      let assert Ok(first) = budget.reserve(empty, "one", plan, 1001)
      budget.reserve(first, "two", plan, 1002)
      |> should.equal(Error("live_budget_exhausted"))
    },
  )
  budget.new(policy.Limits(..approval.limits, duration_ms: 0), 0)
  |> should.be_error
  budget.new(policy.Limits(..approval.limits, cost_nano_usd: 1_000_000_001), 0)
  |> should.be_error
}

/// Dedicated bounded validation entrypoint; normal `gleam test` also discovers
/// these tests. Do not run this while another worker owns the validation slot.
pub fn main() {
  binding_uses_exact_bytes_and_versioned_unambiguous_encoding_test()
  admission_is_not_a_qualification_flag_test()
  unknown_price_route_and_token_ceiling_fail_closed_test()
  body_cannot_expand_authority_or_output_test()
  worst_case_ledger_is_monotonic_bounded_and_no_duplicate_replay_test()
  each_budget_dimension_independently_stops_admission_test()
  exact_crlf_header_and_chunk_parsing_preserves_final_content_test()
  http_header_names_require_rfc_tchar_test()
}

pub fn exact_crlf_header_and_chunk_parsing_preserves_final_content_test() {
  http.parse_header("Content-Type: application/json\r\n")
  |> should.equal(Ok(#("content-type", "application/json")))
  http.parse_header("Content-Length: 45\r\n")
  |> should.equal(Ok(#("content-length", "45")))
  http.parse_header("X-Synthetic: Z\r\n")
  |> should.equal(Ok(#("x-synthetic", "Z")))
  http.chunk_size("0\r\n") |> should.equal(Ok(0))
  http.chunk_size("F\r\n") |> should.equal(Ok(15))
  http.chunk_size("10\r\n") |> should.equal(Ok(16))
  list.each(
    [
      "F\n",
      "F\r\r\n",
      "F\r\ntrailing",
      "F;extension=x\r\n",
      "\r\n",
      "0\r\n\r\n",
    ],
    fn(raw) { http.chunk_size(raw) |> should.be_error },
  )
  list.each(
    [
      "Content-Length: 45\n",
      "Content-Length: 45\r\r\n",
      "Content-Length: 45\r\nextra",
      "Bad\rName: value\r\n",
    ],
    fn(raw) { http.parse_header(raw) |> should.be_error },
  )
}

pub fn http_header_names_require_rfc_tchar_test() {
  http.parse_header("!#$%&'*+-.^_`|~Az09: value\r\n")
  |> should.equal(Ok(#("!#$%&'*+-.^_`|~az09", "value")))
  list.each(
    [
      "Bad(Name): value\r\n", "Bad)Name: value\r\n", "Bad[Name]: value\r\n",
      "Bad]Name: value\r\n", "Bad{Name}: value\r\n", "Bad}Name: value\r\n",
      "Bad/Name: value\r\n", "Bad\\Name: value\r\n", "Bad€Name: value\r\n",
      "Bad,Name: value\r\n", "Bad;Name: value\r\n", "Bad=Name: value\r\n",
      "Bad?Name: value\r\n", "Bad@Name: value\r\n", "Bad\"Name: value\r\n",
      "Bad Name: value\r\n", "Bad\tName: value\r\n", ": value\r\n",
      "Bad\u{7f}Name: value\r\n", "Bad\u{0}Name: value\r\n",
    ],
    fn(raw) { http.parse_header(raw) |> should.be_error },
  )
}
