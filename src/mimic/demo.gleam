import gleam/int
import gleam/json
import gleam/result
import mimic/corpus
import mimic/lab
import mimic/persona
import mimic/replay
import mimic/types.{type Capture}
import mimic/wire

/// An entirely local vertical slice. The fixture is deliberately synthetic:
/// this demonstrates our plumbing, not any vendor's observed wire profile.
pub fn run(root: String) -> Result(String, String) {
  use port <- result.try(lab.start(0))
  let outcome = run_on(root, port)
  let stopped = lab.stop(port)
  use report <- result.try(outcome)
  use _ <- result.try(stopped)
  Ok(report)
}

pub fn fixture(port: Int) -> Result(Capture, String) {
  let host = "127.0.0.1:" <> int.to_string(port)
  wire.parse_request(
    "POST /v1/messages HTTP/1.1\r\n"
      <> "Host: "
      <> host
      <> "\r\n"
      <> "Content-Type: application/json\r\n"
      <> "User-Agent: mimic-synthetic/1.0.0\r\n"
      <> "anthropic-version: 2023-06-01\r\n"
      <> "Authorization: Bearer synthetic-runtime-fixture-only\r\n"
      <> "Content-Length: 2\r\n\r\n{}",
    "mimic-synthetic",
    "1.0.0",
    "http://" <> host,
    "main",
  )
}

fn run_on(root: String, port: Int) -> Result(String, String) {
  use capture <- result.try(fixture(port))
  use id <- result.try(corpus.add(root, capture))
  use repeated_id <- result.try(corpus.add(root, capture))
  use _ <- result.try(case id == repeated_id {
    True -> Ok(Nil)
    False -> Error("corpus deduplication invariant failed")
  })
  use stored <- result.try(corpus.load(root, id))
  use draft <- result.try(persona.draft([stored]))
  use parsed <- result.try(persona.parse(persona.render(draft)))
  use _ <- result.try(case persona.lint(parsed) {
    [] -> Ok(Nil)
    _ -> Error("the synthetic corpus produced an invalid persona")
  })
  // Redacted values are unknown, not inferred constants. This synthetic
  // runtime request supplies its safe Host/User-Agent fields explicitly.
  use request <- result.try(replay.materialize(parsed, capture))
  use response <- result.try(replay.send(capture.endpoint, request))
  case response.status {
    200 -> {
      Ok(
        json.object([
          #("fixture", json.string("synthetic; not a native-client capture")),
          #("capture_id", json.string(id)),
          #("deduplicated", json.bool(id == repeated_id)),
          #("persona_lint", json.string("passed")),
          #("replay_status", json.int(response.status)),
          #("ttft_ms", json.int(response.ttft_ms)),
          #("endpoint", json.string(capture.endpoint)),
        ])
        |> json.to_string,
      )
    }
    _ -> Error("local lab rejected the synthetic replay")
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [root] -> run(root)
    _ -> Error("usage: mimic demo <corpus-directory>")
  }
}
