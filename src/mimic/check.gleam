import gleam/int
import gleam/json
import gleam/list
import gleam/string
import mimic/corpus
import mimic/replay
import mimic/types.{type Capture, type WireResponse, WireResponse}

pub type Sample {
  Sample(
    status: Int,
    class: String,
    reason: String,
    ttft_ms: Int,
    accepted: Bool,
  )
}

pub type Verdict {
  Verdict(passed: Bool, accepted: Int, total: Int, samples: List(Sample))
}

/// Evaluates real replay responses; no endpoint is contacted unless explicitly
/// passed by the caller. An empty selection is not a successful acceptance gate.
pub fn run(
  endpoint: String,
  captures: List(Capture),
  max_ttft_ms: Int,
) -> Result(Verdict, String) {
  run_with(endpoint, captures, max_ttft_ms, replay.send)
}

pub fn run_with(
  endpoint: String,
  captures: List(Capture),
  max_ttft_ms: Int,
  send: fn(String, Capture) -> Result(WireResponse, String),
) -> Result(Verdict, String) {
  case captures, max_ttft_ms >= 0 {
    [], _ -> Error("acceptance selection is empty")
    _, False -> Error("max_ttft_ms must be nonnegative")
    _, True -> {
      use samples <- result_map(
        list.try_map(captures, fn(capture) {
          use response <- result_map(send(endpoint, capture))
          Ok(classify(response, max_ttft_ms))
        }),
      )
      let accepted =
        list.length(list.filter(samples, fn(sample) { sample.accepted }))
      Ok(Verdict(
        accepted == list.length(samples),
        accepted,
        list.length(samples),
        samples,
      ))
    }
  }
}

pub fn classify(response: WireResponse, max_ttft_ms: Int) -> Sample {
  let WireResponse(status, _, body, ttft_ms) = response
  let class = case status {
    value if value >= 200 && value < 300 -> "2xx"
    value if value >= 300 && value < 400 -> "3xx"
    value if value >= 400 && value < 500 -> "4xx"
    value if value >= 500 && value < 600 -> "5xx"
    _ -> "invalid"
  }
  let reason = case class {
    "4xx" -> client_reason(status, body)
    "5xx" -> "upstream_failure"
    "3xx" -> "redirect"
    "invalid" -> "invalid_status"
    _ ->
      case ttft_ms < 0 || ttft_ms > max_ttft_ms {
        True -> "ttft_out_of_envelope"
        False -> "accepted"
      }
  }
  Sample(status, class, reason, ttft_ms, reason == "accepted")
}

fn client_reason(status: Int, body: String) -> String {
  let body = string.lowercase(body)
  case status {
    401 | 403 -> "authentication"
    429 -> "rate_limit"
    _ ->
      case string.contains(body, "beta") {
        True -> "invalid_beta"
        False ->
          case string.contains(body, "header") {
            True -> "invalid_header"
            False -> "client_error"
          }
      }
  }
}

pub fn to_json(verdict: Verdict) -> String {
  json.object([
    #("passed", json.bool(verdict.passed)),
    #("accepted", json.int(verdict.accepted)),
    #("total", json.int(verdict.total)),
    #(
      "samples",
      json.array(verdict.samples, fn(sample) {
        json.object([
          #("status", json.int(sample.status)),
          #("class", json.string(sample.class)),
          #("reason", json.string(sample.reason)),
          #("ttft_ms", json.int(sample.ttft_ms)),
          #("accepted", json.bool(sample.accepted)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [root, endpoint] -> {
      use captures <- result_map(corpus.list(root))
      use verdict <- result_map(run(endpoint, captures, 10_000))
      Ok(to_json(verdict))
    }
    [root, endpoint, limit] -> {
      use ms <- result_map(
        int.parse(limit) |> map_error("max-ttft-ms must be an integer"),
      )
      use captures <- result_map(corpus.list(root))
      use verdict <- result_map(run(endpoint, captures, ms))
      Ok(to_json(verdict))
    }
    [root, endpoint, "--id", id, limit] -> {
      use ms <- result_map(
        int.parse(limit) |> map_error("max-ttft-ms must be an integer"),
      )
      use capture <- result_map(corpus.load(root, id))
      use verdict <- result_map(run(endpoint, [capture], ms))
      Ok(to_json(verdict))
    }
    _ ->
      Error(
        "usage: check <corpus-root> <explicit-endpoint> [max-ttft-ms] | check <corpus-root> <explicit-endpoint> --id <id> <max-ttft-ms>",
      )
  }
}

fn map_error(value: Result(a, Nil), message: String) -> Result(a, String) {
  case value {
    Ok(v) -> Ok(v)
    Error(_) -> Error(message)
  }
}

fn result_map(
  value: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case value {
    Ok(v) -> next(v)
    Error(e) -> Error(e)
  }
}
