import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/check
import mimic/control
import mimic/corpus
import mimic/demo
import mimic/differ
import mimic/lab
import mimic/persona
import mimic/policy
import mimic/replay
import mimic/types
import mimic/wire
import mimic/workshop

pub type Scenario {
  VersionBump
  RejectedBaseline
}

type Context {
  Context(
    directory: String,
    port: Int,
    baseline: types.Capture,
    candidate: types.Capture,
    profile: persona.Persona,
  )
}

/// A synthetic PB integration run, not a native binary acquisition or a
/// production canary. It can only publish to the isolated synthetic-lab registry.
pub fn run(
  directory: String,
  id: String,
  scenario: Scenario,
) -> Result(String, String) {
  let required = case scenario {
    VersionBump -> []
    RejectedBaseline -> [types.Header("x-synthetic-required", "expected")]
  }
  let config =
    lab.Config(
      required_headers: required,
      failure_status: 400,
      status: 200,
      response_body: "{}",
      sse_events: [],
    )
  use port <- result.try(lab.start_with(0, config))
  let outcome = run_on(directory, id, port, required)
  let stopped = lab.stop(port)
  use report <- result.try(outcome)
  use _ <- result.try(stopped)
  Ok(report)
}

fn run_on(
  directory: String,
  id: String,
  port: Int,
  required: List(types.Header),
) -> Result(String, String) {
  use baseline <- result.try(demo.fixture(port))
  let candidate =
    types.Capture(
      ..baseline,
      version: "1.0.1",
      headers: list.append(
        list.map(baseline.headers, fn(header) {
          case header.name {
            "User-Agent" -> types.Header("User-Agent", "mimic-synthetic/1.0.1")
            _ -> header
          }
        }),
        required,
      ),
    )
  use profile <- result.try(persona.draft([candidate]))
  let context = Context(directory, port, baseline, candidate, profile)
  use started <- result.try(workshop.start(
    directory,
    id,
    "synthetic-lab",
    workshop.PB,
  ))
  use _ <- result.try(advance(context, started))
  use _ <- result.try(workshop.promote_lab(directory, id))
  use digest <- result.try(workshop.pointer(directory, "synthetic-lab"))
  Ok(
    json.object([
      #("run_id", json.string(id)),
      #("provider", json.string("synthetic-lab")),
      #("source", json.string("synthetic-local-lab")),
      #("status", json.string("promoted")),
      #("candidate_digest", json.string(digest)),
      #("production_validated", json.bool(False)),
    ])
    |> json.to_string,
  )
}

fn advance(
  context: Context,
  run: workshop.Run,
) -> Result(workshop.Run, String) {
  case workshop.next(run) {
    None -> Ok(run)
    Some(_) -> {
      // Reserve one conservative budget unit per local gate. These are
      // synthetic estimates, not measured model/provider token usage.
      let budget =
        workshop.Budget(
          oracle_runs: 2,
          tokens: 2,
          estimate_tokens: 1,
          canary_allowed: True,
        )
      use updated <- result.try(
        workshop.advance(context.directory, run.id, budget, fn(stage, _) {
          execute(context, stage)
        }),
      )
      advance(context, updated)
    }
  }
}

fn execute(
  context: Context,
  stage: workshop.Stage,
) -> Result(workshop.Evidence, String) {
  case stage {
    workshop.Acquire -> {
      // The artifact is our built-in fixture specification, not a claim that a
      // native client binary was downloaded or authenticated.
      store(
        context,
        stage,
        "{\"fixture\":\"mimic-synthetic\",\"versions\":[\"1.0.0\",\"1.0.1\"],\"native_binary\":false}",
        True,
      )
    }
    workshop.Capture -> capture(context)
    workshop.Diff -> {
      use report <- result.try(differ.diff(context.baseline, context.candidate))
      use evidence <- result.try(store(
        context,
        stage,
        differ.report_json(report),
        True,
      ))
      use _ <- result.try(control.record_drift(
        context.directory,
        evidence.artifact_id,
      ))
      Ok(evidence)
    }
    workshop.Classify -> {
      use verdict <- result.try(check.run(
        context.baseline.endpoint,
        [context.baseline],
        5000,
      ))
      let class =
        policy.classify(context.baseline, context.candidate, verdict.passed)
      use id <- result.try(workshop.artifact(
        context.directory,
        json.object([
          #("baseline_accepted", json.bool(verdict.passed)),
          #(
            "version_only",
            json.bool(policy.version_only(context.baseline, context.candidate)),
          ),
        ])
          |> json.to_string,
      ))
      Ok(workshop.Evidence(stage, id, True, Some(class), "synthetic-local-lab"))
    }
    workshop.Hypothesis ->
      store(context, stage, persona.render(context.profile), True)
    workshop.Lint -> {
      let errors = persona.lint(context.profile)
      store(
        context,
        stage,
        json.array(errors, json.string) |> json.to_string,
        errors == [],
      )
    }
    workshop.Oracle -> acceptance(context, stage, 1)
    workshop.Canary -> acceptance(context, stage, 3)
    _ -> Error("the local PB runner cannot execute non-PB stages")
  }
}

fn capture(context: Context) -> Result(workshop.Evidence, String) {
  use _ <- result.try(replay.send(context.baseline.endpoint, context.baseline))
  use _ <- result.try(replay.send(context.candidate.endpoint, context.candidate))
  use frames <- result.try(lab.requests(context.port))
  use ids <- result.try(
    list.try_map(
      list.index_map(frames, fn(frame, index) { #(frame, index) }),
      fn(item) {
        let #(frame, index) = item
        use observed <- result.try(wire.parse_request(
          frame,
          "mimic-synthetic",
          "1.0." <> int.to_string(index),
          context.baseline.endpoint,
          "main",
        ))
        corpus.add(context.directory <> "/corpus", observed)
      },
    ),
  )
  store(
    context,
    workshop.Capture,
    json.object([
      #("source", json.string("actual loopback requests; synthetic client")),
      #("capture_ids", json.array(ids, json.string)),
    ])
      |> json.to_string,
    list.length(ids) == 2,
  )
}

fn acceptance(
  context: Context,
  stage: workshop.Stage,
  count: Int,
) -> Result(workshop.Evidence, String) {
  use request <- result.try(replay.materialize(
    context.profile,
    context.candidate,
  ))
  use verdict <- result.try(check.run(
    context.candidate.endpoint,
    list.repeat(request, count),
    5000,
  ))
  store(
    context,
    stage,
    json.object([
      #("scope", json.string("synthetic loopback only")),
      #("accepted", json.int(verdict.accepted)),
      #("total", json.int(verdict.total)),
      #("passed", json.bool(verdict.passed)),
      #("production_slo_window", json.bool(False)),
    ])
      |> json.to_string,
    verdict.passed,
  )
}

fn store(
  context: Context,
  stage: workshop.Stage,
  content: String,
  passed: Bool,
) -> Result(workshop.Evidence, String) {
  use id <- result.try(workshop.artifact(context.directory, content))
  Ok(workshop.Evidence(stage, id, passed, None, "synthetic-local-lab"))
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [directory, id] | [directory, id, "trivial"] ->
      run(directory, id, VersionBump)
    [directory, id, "breaking"] -> run(directory, id, RejectedBaseline)
    _ ->
      Error(
        "usage: mimic workshop lab-bump <state-directory> <run-id> [trivial|breaking]",
      )
  }
}
