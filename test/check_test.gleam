import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/check
import mimic/types.{type Capture, Capture, Header, Transport, WireResponse}

fn sample(headers) {
  Capture(
    "synthetic",
    "0",
    "lab",
    "messages",
    "POST",
    "/v1/messages",
    "HTTP/1.1",
    headers,
    "{}",
    Transport("http/1.1", None),
  )
}

pub fn verdict_changes_for_bad_header_test() {
  let good = sample([Header("Anthropic-Version", "2023-06-01")])
  let bad = sample([Header("Anthropic-Version", "invalid")])
  let sender = fn(_endpoint, capture: Capture) {
    case capture.headers {
      [Header(_, "2023-06-01")] -> Ok(WireResponse(200, [], "{}", 8))
      _ -> Ok(WireResponse(400, [], "{\"error\":\"invalid header\"}", 8))
    }
  }
  let assert Ok(pass) = check.run_with("http://127.0.0.1:1", [good], 20, sender)
  pass.passed |> should.be_true
  let assert Ok(fail) =
    check.run_with("http://127.0.0.1:1", [good, bad], 20, sender)
  fail.passed |> should.be_false
  fail.accepted |> should.equal(1)
  let rendered = check.to_json(fail)
  string.contains(rendered, "\"reason\":\"invalid_header\"") |> should.be_true
}

pub fn ttft_and_status_classes_test() {
  let slow = check.classify(WireResponse(200, [], "{}", 101), 100)
  slow.reason |> should.equal("ttft_out_of_envelope")
  let limited = check.classify(WireResponse(429, [], "{}", 10), 100)
  limited.class |> should.equal("4xx")
  limited.reason |> should.equal("rate_limit")
  let broken = check.classify(WireResponse(503, [], "{}", 10), 100)
  broken.class |> should.equal("5xx")
}
