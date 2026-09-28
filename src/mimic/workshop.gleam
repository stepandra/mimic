import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Kind {
  PB
  PO
  CO
}

pub type Stage {
  Acquire
  Capture
  Diff
  Classify
  Hypothesis
  Lint
  Oracle
  Canary
  Intake
  AuthCapture
  Census
  Author
  EnrollTemplates
  Login
  Verify
  BurnIn
  Enroll
  Probation
}

pub type DriftClass {
  Trivial
  Minor
  Major
  Breaking
}

pub type Status {
  Running
  InFlight(Stage)
  Paused(String)
  Failed(String)
  Complete
}

/// Evidence is supplied by an actual stage adapter, not by the CLI or model.
/// artifact_id must refer to an immutable artifact stored by `artifact`.
pub type Evidence {
  Evidence(
    stage: Stage,
    artifact_id: String,
    passed: Bool,
    classification: Option(DriftClass),
    source: String,
  )
}

pub type Run {
  Run(
    id: String,
    provider: String,
    kind: Kind,
    classification: Option(DriftClass),
    completed: List(Evidence),
    approved_by: Option(String),
    status: Status,
    spent_oracle_runs: Int,
    spent_tokens: Int,
    goal: Option(String),
  )
}

/// Caller-supplied allowance is checked before invoking a costly stage.
/// A production adapter must reserve the allowance in the shared quota ledger;
/// these bounds are not a replacement for that ledger.
pub type Budget {
  Budget(
    oracle_runs: Int,
    tokens: Int,
    estimate_tokens: Int,
    canary_allowed: Bool,
  )
}

@external(erlang, "mimic_workshop_ffi", "create")
fn create(
  dir: String,
  id: String,
  provider: String,
  run: Run,
) -> Result(Run, String)

@external(erlang, "mimic_workshop_ffi", "load")
pub fn load(dir: String, id: String) -> Result(Run, String)

@external(erlang, "mimic_workshop_ffi", "update")
fn update(
  dir: String,
  id: String,
  change: fn(Run) -> Result(Run, String),
) -> Result(Run, String)

@external(erlang, "mimic_workshop_ffi", "with_effect")
fn with_effect(
  dir: String,
  id: String,
  work: fn() -> Result(Run, String),
) -> Result(Run, String)

@external(erlang, "mimic_workshop_ffi", "effect_idle")
fn effect_idle(dir: String, id: String) -> Bool

@external(erlang, "mimic_workshop_ffi", "artifact")
pub fn artifact(dir: String, content: String) -> Result(String, String)

@external(erlang, "mimic_workshop_ffi", "has_artifact")
fn has_artifact(dir: String, id: String) -> Bool

@external(erlang, "mimic_workshop_ffi", "read_artifact")
pub fn read_artifact(dir: String, id: String) -> Result(String, String)

@external(erlang, "mimic_workshop_ffi", "swap")
fn swap(
  dir: String,
  provider: String,
  candidate: String,
  signature: String,
) -> Result(String, String)

@external(erlang, "mimic_workshop_ffi", "lab_swap")
fn lab_swap(
  dir: String,
  provider: String,
  candidate: String,
) -> Result(String, String)

@external(erlang, "mimic_workshop_ffi", "pointer")
pub fn pointer(dir: String, provider: String) -> Result(String, String)

pub fn start(
  dir: String,
  id: String,
  provider: String,
  kind: Kind,
) -> Result(Run, String) {
  case string.is_empty(id) || string.is_empty(provider) {
    True -> Error("run id and provider are required")
    False ->
      create(
        dir,
        id,
        provider,
        Run(id, provider, kind, None, [], None, Running, 0, 0, None),
      )
  }
}

pub fn start_with_goal(
  dir: String,
  id: String,
  provider: String,
  kind: Kind,
  goal: String,
) -> Result(Run, String) {
  case
    string.is_empty(goal) || string.is_empty(id) || string.is_empty(provider)
  {
    True -> Error("run id, provider, and goal are required")
    False ->
      create(
        dir,
        id,
        provider,
        Run(id, provider, kind, None, [], None, Running, 0, 0, Some(goal)),
      )
  }
}

pub fn plan(kind: Kind) -> List(Stage) {
  case kind {
    PB -> [Acquire, Capture, Diff, Classify, Hypothesis, Lint, Oracle, Canary]
    PO -> [
      Intake,
      AuthCapture,
      Census,
      Author,
      Lint,
      Oracle,
      Canary,
      EnrollTemplates,
    ]
    CO -> [Login, Verify, BurnIn, Enroll, Probation]
  }
}

pub fn next(run: Run) -> Option(Stage) {
  case list.first(list.drop(plan(run.kind), list.length(run.completed))) {
    Ok(stage) -> Some(stage)
    Error(_) -> None
  }
}

fn needs_review(run: Run) -> Bool {
  case run.kind, run.classification {
    PB, Some(Trivial) -> False
    _, _ -> True
  }
}

fn costly(stage: Stage) -> Bool {
  stage == Oracle || stage == Canary || stage == BurnIn || stage == Probation
}

fn budget_error(stage: Stage, run: Run, budget: Budget) -> Option(String) {
  case costly(stage) {
    False -> None
    True -> {
      case
        budget.estimate_tokens <= 0
        || budget.tokens - run.spent_tokens < budget.estimate_tokens
      {
        True -> Some("budget exhausted: tokens")
        False ->
          case
            stage == Oracle && budget.oracle_runs - run.spent_oracle_runs <= 0
          {
            True -> Some("budget exhausted: oracle runs")
            False ->
              case
                { stage == Canary || stage == Probation }
                && !budget.canary_allowed
              {
                True -> Some("canary window not authorized")
                False -> None
              }
          }
      }
    }
  }
}

pub fn advance(
  dir: String,
  id: String,
  budget: Budget,
  execute: fn(Stage, Run) -> Result(Evidence, String),
) -> Result(Run, String) {
  with_effect(dir, id, fn() { advance_reserved(dir, id, budget, execute) })
}

fn advance_reserved(
  dir: String,
  id: String,
  budget: Budget,
  execute: fn(Stage, Run) -> Result(Evidence, String),
) -> Result(Run, String) {
  use reserved <- result.try(
    update(dir, id, fn(run) {
      case run.status, next(run) {
        Running, Some(stage) -> {
          case
            needs_review(run)
            && { stage == Oracle || stage == EnrollTemplates }
            && run.approved_by == None
          {
            True -> Ok(Run(..run, status: Paused("human review required")))
            False -> {
              case budget_error(stage, run, budget) {
                Some(reason) -> Ok(Run(..run, status: Paused(reason)))
                None -> {
                  let spent_tokens = case costly(stage) {
                    True -> run.spent_tokens + budget.estimate_tokens
                    False -> run.spent_tokens
                  }
                  let spent_oracle_runs = case stage {
                    Oracle -> run.spent_oracle_runs + 1
                    _ -> run.spent_oracle_runs
                  }
                  Ok(
                    Run(
                      ..run,
                      status: InFlight(stage),
                      spent_tokens: spent_tokens,
                      spent_oracle_runs: spent_oracle_runs,
                    ),
                  )
                }
              }
            }
          }
        }
        Paused(_), _ -> Error("run paused; explicit resume required")
        InFlight(_), _ ->
          Error("stage in flight or outcome unknown; explicit abandon required")
        Failed(_), _ -> Error("run failed")
        Complete, _ -> Error("run complete")
        _, None -> Error("no remaining stages")
      }
    }),
  )
  case reserved.status {
    InFlight(stage) -> {
      // Persist reservation before invoking an effect. Unknown outcomes do
      // not get a free retry.
      use evidence <- result.try(execute(stage, reserved))
      case
        evidence.stage == stage
        && !string.is_empty(evidence.artifact_id)
        && !string.is_empty(evidence.source)
        && has_artifact(dir, evidence.artifact_id)
        && { stage != Classify || evidence.classification != None }
      {
        False -> Error("invalid stage evidence or missing immutable artifact")
        True ->
          update(dir, id, fn(run) {
            case run.status {
              InFlight(current) if current == stage -> {
                let classification = case stage {
                  Classify -> evidence.classification
                  _ -> run.classification
                }
                let status = case evidence.passed, classification {
                  _, Some(Breaking) ->
                    Paused(
                      "BREAKING: production alert and human intervention required",
                    )
                  False, _ -> Failed("stage evidence failed")
                  True, _ -> {
                    case
                      list.length(run.completed) + 1
                      == list.length(plan(run.kind))
                    {
                      True -> Complete
                      False -> Running
                    }
                  }
                }
                Ok(
                  Run(
                    ..run,
                    classification: classification,
                    completed: list.append(run.completed, [evidence]),
                    status: status,
                  ),
                )
              }
              _ -> Error("in-flight stage changed; evidence not accepted")
            }
          })
      }
    }
    _ -> Ok(reserved)
  }
}

/// Resuming a BREAKING run requires a separate remediation run, never this API.
pub fn resume(dir: String, id: String) -> Result(Run, String) {
  update(dir, id, fn(run) {
    case run.status {
      Paused(reason) -> {
        case string.starts_with(reason, "BREAKING") {
          True -> Error("BREAKING cannot be resumed automatically")
          False -> Ok(Run(..run, status: Running))
        }
      }
      _ -> Error("run is not paused")
    }
  })
}

/// Record an unknown or BREAKING outcome as terminal before starting a
/// separate remediation run. Never refund or retry the original stage.
pub fn abandon(
  dir: String,
  id: String,
  reason: String,
  signature: String,
) -> Result(Run, String) {
  case string.is_empty(reason) {
    True -> Error("abandonment reason required")
    False -> {
      use _ <- result.try(authorize_abandon(id, reason, signature))
      update(dir, id, fn(run) {
        case run.status {
          InFlight(_) ->
            case effect_idle(dir, id) {
              True -> Ok(Run(..run, status: Failed(reason)))
              False -> Error("stage callback may still be active")
            }
          Paused(message) ->
            case string.starts_with(message, "BREAKING") {
              True -> Ok(Run(..run, status: Failed("BREAKING: " <> reason)))
              False ->
                Error("only an in-flight or BREAKING run can be abandoned")
            }
          _ -> Error("only an in-flight or BREAKING run can be abandoned")
        }
      })
    }
  }
}

pub fn approve(
  dir: String,
  id: String,
  reviewer: String,
  signature: String,
) -> Result(Run, String) {
  case string.is_empty(reviewer) {
    True -> Error("reviewer identity required")
    False -> {
      use checkpoint <- result.try(load(dir, id))
      let candidate_stage = case checkpoint.kind {
        PB -> Hypothesis
        PO -> Author
        CO -> Author
      }
      use candidate <- result.try(
        case evidence_for(checkpoint, candidate_stage) {
          Some(evidence) -> Ok(evidence.artifact_id)
          None -> Error("candidate artifact missing")
        },
      )
      use _ <- result.try(case has_artifact(dir, candidate) {
        True -> Ok(Nil)
        False -> Error("candidate artifact missing")
      })
      use _ <- result.try(authorize_review(id, reviewer, candidate, signature))
      update(dir, id, fn(run) {
        case run.status, run.classification {
          Paused("human review required"), _ ->
            case evidence_for(run, candidate_stage) {
              Some(evidence) if evidence.artifact_id == candidate ->
                Ok(Run(..run, approved_by: Some(reviewer), status: Running))
              _ -> Error("candidate changed during review")
            }
          _, _ -> Error("review not applicable")
        }
      })
    }
  }
}

fn evidence_for(run: Run, stage: Stage) -> Option(Evidence) {
  case list.find(run.completed, fn(e) { e.stage == stage }) {
    Ok(evidence) -> Some(evidence)
    Error(_) -> None
  }
}

fn passed(run: Run, stage: Stage) -> Bool {
  case evidence_for(run, stage) {
    Some(e) -> e.passed
    None -> False
  }
}

/// Promotion is only possible after every relevant gate completed. The pointer
/// swap is atomic and retains the prior pointer for rollback.
pub fn promote(
  dir: String,
  id: String,
  signature: String,
) -> Result(String, String) {
  use run <- result.try(load(dir, id))
  case
    run.status == Complete
    && run.kind != CO
    && run.classification != Some(Breaking)
    && { !needs_review(run) || run.approved_by != None }
    && passed(run, Lint)
    && passed(run, Oracle)
    && passed(run, Canary)
    && !list.any(run.completed, fn(e) {
      string.starts_with(e.source, "synthetic-")
    })
    && !string.is_empty(signature)
  {
    False -> Error("promotion gates incomplete")
    True -> {
      let candidate_stage = case run.kind {
        PB -> Hypothesis
        PO -> Author
        CO -> Author
      }
      case evidence_for(run, candidate_stage) {
        Some(evidence) ->
          swap(dir, run.provider, evidence.artifact_id, signature)
        None -> Error("candidate artifact missing")
      }
    }
  }
}

pub fn promote_lab(dir: String, id: String) -> Result(String, String) {
  use run <- result.try(load(dir, id))
  case
    run.provider == "synthetic-lab"
    && run.kind == PB
    && run.classification == Some(Trivial)
    && run.status == Complete
    && passed(run, Lint)
    && passed(run, Oracle)
    && passed(run, Canary)
    && list.all(run.completed, fn(e) {
      string.starts_with(e.source, "synthetic-local-lab")
    })
  {
    False -> Error("synthetic lab promotion gates incomplete")
    True ->
      case evidence_for(run, Hypothesis) {
        Some(e) -> lab_swap(dir, run.provider, e.artifact_id)
        None -> Error("candidate artifact missing")
      }
  }
}

@external(erlang, "mimic_workshop_ffi", "rollback")
pub fn rollback(
  dir: String,
  provider: String,
  signature: String,
) -> Result(String, String)

@external(erlang, "mimic_workshop_ffi", "authorize_review")
fn authorize_review(
  id: String,
  reviewer: String,
  candidate: String,
  signature: String,
) -> Result(Nil, String)

@external(erlang, "mimic_workshop_ffi", "authorize_abandon")
fn authorize_abandon(
  id: String,
  reason: String,
  signature: String,
) -> Result(Nil, String)

fn queued(
  dir: String,
  id: String,
  provider: String,
  kind: Kind,
) -> Result(String, String) {
  use _ <- result.try(start(dir, id, provider, kind))
  Ok("queued " <> id <> "; stage adapter required to execute")
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["run", "pb", dir, id, provider] -> queued(dir, id, provider, PB)
    ["run", "po", dir, id, provider] -> queued(dir, id, provider, PO)
    ["run", "co", dir, id, provider] -> queued(dir, id, provider, CO)
    ["run", "pb", dir, id, provider, "--goal", goal] -> {
      use _ <- result.try(start_with_goal(dir, id, provider, PB, goal))
      Ok("queued " <> id <> "; stage adapter required to execute")
    }
    ["status", dir, id] ->
      load(dir, id)
      |> result.map(fn(run) { string.inspect(Run(..run, goal: None)) })
    ["resume", dir, id] ->
      resume(dir, id) |> result.map(fn(_) { "resumed " <> id })
    ["abandon", dir, id, reason, signature] ->
      abandon(dir, id, reason, signature)
      |> result.map(fn(_) { "abandoned " <> id })
    ["approve", dir, id, reviewer, signature] -> {
      use _ <- result.try(approve(dir, id, reviewer, signature))
      Ok("approved " <> id)
    }
    ["promote", dir, id, signature] -> promote(dir, id, signature)
    ["rollback", dir, provider, signature] -> {
      rollback(dir, provider, signature)
    }
    ["pointer", dir, provider] -> pointer(dir, provider)
    _ ->
      Error(
        "workshop: run pb|po|co <dir> <id> <provider> [--goal <text>] | status|resume <dir> <id> | abandon <dir> <id> <reason> <hmac> | approve <dir> <id> <reviewer> <hmac> | promote <dir> <id> <hmac> | pointer <dir> <provider> | rollback <dir> <provider> <hmac>",
      )
  }
}
