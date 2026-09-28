import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/workshop
import simplifile

@external(erlang, "mimic_f_test_ffi", "dir")
fn test_dir() -> String

@external(erlang, "mimic_f_test_ffi", "sign_review")
fn sign_review(id: String, reviewer: String, candidate: String) -> String

@external(erlang, "mimic_f_test_ffi", "sign_abandon")
fn sign_abandon(id: String, reason: String) -> String

@external(erlang, "mimic_f_test_ffi", "sign_rollback")
fn sign_rollback(provider: String) -> String

@external(erlang, "mimic_f_test_ffi", "remove_active")
fn remove_active(dir: String, provider: String) -> Nil

@external(erlang, "mimic_f_test_ffi", "replace_active")
fn replace_active(dir: String, provider: String, owner: String) -> Nil

@external(erlang, "mimic_f_test_ffi", "remove_artifact")
fn remove_artifact(dir: String, digest: String) -> Nil

@external(erlang, "mimic_f_test_ffi", "seed_registry")
fn seed_registry(
  dir: String,
  provider: String,
  current: String,
  previous: String,
) -> Nil

@external(erlang, "mimic_f_test_ffi", "poison_artifact")
fn poison_artifact(dir: String, content: String) -> Nil

@external(erlang, "mimic_f_test_ffi", "symlink_state")
fn symlink_state(dir: String) -> String

@external(erlang, "mimic_f_test_ffi", "crash_advance")
fn crash_advance(dir: String, id: String, budget: workshop.Budget) -> Nil

@external(erlang, "mimic_f_test_ffi", "clear_effect")
fn clear_effect(dir: String, id: String) -> Nil

@external(erlang, "mimic_f_test_ffi", "fresh_load")
fn fresh_load(dir: String, id: String) -> Bool

@external(erlang, "mimic_f_test_ffi", "corrupt_evidence")
fn corrupt_evidence(dir: String, id: String) -> Nil

fn evidence(dir, stage, class) {
  let assert Ok(id) = workshop.artifact(dir, "synthetic stage evidence")
  Ok(workshop.Evidence(stage, id, True, class, "synthetic-local-lab"))
}

pub fn cli_queues_without_stage_execution_test() {
  let dir = test_dir()
  let assert Ok(_) =
    workshop.cli([
      "run", "pb", dir, "goal-run", "p", "--goal", "synthetic version bump",
    ])
  let assert Ok(run) = workshop.load(dir, "goal-run")
  run.completed |> list.length |> should.equal(0)
  run.goal |> should.equal(Some("synthetic version bump"))
  let assert Ok(status) = workshop.cli(["status", dir, "goal-run"])
  let assert False = string.contains(status, "synthetic version bump")
}

pub fn resume_and_budget_before_callback_test() {
  let dir = test_dir()
  let assert Ok(_) = workshop.start(dir, "r1", "synthetic-lab", workshop.PB)
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(first) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  first.completed |> list.length |> should.equal(1)
  let assert Ok(reloaded) = workshop.load(dir, "r1")
  reloaded.completed |> list.length |> should.equal(1)
  let assert Ok(first_evidence) = list.first(reloaded.completed)
  let assert Ok(content) =
    workshop.read_artifact(dir, first_evidence.artifact_id)
  content |> should.equal("synthetic stage evidence")
  let assert Error(_) = workshop.start(dir, "r2", "synthetic-lab", workshop.PB)
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, Some(workshop.Trivial))
    })
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let blocked = fn(_, _) { panic as "callback must not run before budget check" }
  let assert Ok(paused) =
    workshop.advance(dir, "r1", workshop.Budget(0, 0, 10, True), blocked)
  paused.status |> should.equal(workshop.Paused("budget exhausted: tokens"))
  let assert Ok(_) = workshop.resume(dir, "r1")
  let assert Ok(_) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(done) =
    workshop.advance(dir, "r1", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  done.status |> should.equal(workshop.Complete)
  fresh_load(dir, "r1") |> should.be_true
  let assert Ok(_) = workshop.promote_lab(dir, "r1")
  let assert Ok(_) = workshop.promote_lab(dir, "r1")
  let assert Error(_) = workshop.rollback(dir, "synthetic-lab", "unsigned")
  let assert Error(_) = workshop.promote(dir, "r1", "fake signature")
}

pub fn major_and_breaking_gate_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "major", "p", workshop.PB)
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, Some(workshop.Major))
    })
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let blocked = fn(_, _) { panic as "human gate bypassed" }
  let assert Ok(paused) = workshop.advance(dir, "major", budget, blocked)
  paused.status |> should.equal(workshop.Paused("human review required"))
  fresh_load(dir, "major") |> should.be_true
  let assert Error(_) =
    workshop.cli(["approve", dir, "major", "reviewer", "unsigned"])
  let assert Error(_) = workshop.approve(dir, "major", "reviewer", "unsigned")
  let assert Ok(candidate) =
    list.find(paused.completed, fn(e) { e.stage == workshop.Hypothesis })
  let assert Error(_) =
    workshop.approve(
      dir,
      "major",
      "reviewer",
      sign_review("major", "reviewer", "wrong candidate"),
    )
  let assert Ok(_) =
    workshop.approve(
      dir,
      "major",
      "reviewer",
      sign_review("major", "reviewer", candidate.artifact_id),
    )
  let assert Ok(_) =
    workshop.advance(dir, "major", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) = workshop.start(dir, "breaking", "q", workshop.PB)
  let assert Ok(_) =
    workshop.advance(dir, "breaking", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "breaking", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "breaking", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "breaking", budget, fn(stage, _) {
      let assert Ok(id) = workshop.artifact(dir, "synthetic rejected replay")
      Ok(workshop.Evidence(
        stage,
        id,
        False,
        Some(workshop.Breaking),
        "synthetic-local-lab",
      ))
    })
  let assert Ok(alerts) = simplifile.read_directory(dir <> "/alerts")
  alerts |> list.length |> should.equal(1)
  fresh_load(dir, "breaking") |> should.be_true
  let assert Error(_) = workshop.resume(dir, "breaking")
  let assert Error(_) =
    workshop.abandon(dir, "breaking", "remediation queued", "unsigned")
  let assert Ok(closed) =
    workshop.abandon(
      dir,
      "breaking",
      "remediation queued",
      sign_abandon("breaking", "remediation queued"),
    )
  let assert workshop.Failed(_) = closed.status
  let assert Error(_) = workshop.promote(dir, "breaking", "unsigned")
  let assert Ok(_) = workshop.start(dir, "repair", "q", workshop.PB)
}

pub fn costly_failure_is_reserved_once_and_survives_restart_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "cost", "p", workshop.PB)
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, Some(workshop.Trivial))
    })
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "cost", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Error("synthetic oracle failed") =
    workshop.advance(dir, "cost", budget, fn(stage, reserved) {
      stage |> should.equal(workshop.Oracle)
      reserved.spent_oracle_runs |> should.equal(1)
      reserved.spent_tokens |> should.equal(10)
      let assert Ok(reloaded) = workshop.load(dir, "cost")
      reloaded.status |> should.equal(workshop.InFlight(workshop.Oracle))
      Error("synthetic oracle failed")
    })
  let assert Ok(restarted) = workshop.load(dir, "cost")
  restarted.spent_oracle_runs |> should.equal(1)
  restarted.spent_tokens |> should.equal(10)
  let blocked = fn(_, _) { panic as "unknown outcome cannot rerun" }
  let assert Error(_) = workshop.advance(dir, "cost", budget, blocked)
  let assert Error(_) = workshop.advance(dir, "cost", budget, blocked)
  let assert Error(_) = workshop.resume(dir, "cost")
  let assert Error(_) = workshop.abandon(dir, "cost", "unknown", "unsigned")
  let assert Ok(failed) =
    workshop.abandon(dir, "cost", "unknown", sign_abandon("cost", "unknown"))
  failed.spent_oracle_runs |> should.equal(1)
  let assert Ok(_) = workshop.start(dir, "cost-repair", "p", workshop.PB)
}

pub fn hard_crash_keeps_costly_reservation_and_requires_inspected_recovery_test() {
  let dir = test_dir()
  let budget = workshop.Budget(0, 10, 10, True)
  let assert Ok(_) = workshop.start(dir, "crash", "p", workshop.CO)
  let assert Ok(_) =
    workshop.advance(dir, "crash", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  let assert Ok(_) =
    workshop.advance(dir, "crash", budget, fn(stage, _) {
      evidence(dir, stage, None)
    })
  crash_advance(dir, "crash", budget)
  let assert Ok(persisted) = workshop.load(dir, "crash")
  persisted.status |> should.equal(workshop.InFlight(workshop.BurnIn))
  persisted.spent_tokens |> should.equal(10)
  fresh_load(dir, "crash") |> should.be_true
  let assert Error(_) =
    workshop.advance(dir, "crash", budget, fn(_, _) {
      panic as "crashed callback must not rerun"
    })
  let signature = sign_abandon("crash", "effect outcome unknown")
  let assert Error(_) =
    workshop.abandon(dir, "crash", "effect outcome unknown", signature)
  clear_effect(dir, "crash")
  let assert Ok(_) =
    workshop.abandon(dir, "crash", "effect outcome unknown", signature)
  let assert Ok(_) = workshop.start(dir, "new", "p", workshop.CO)
}

pub fn concurrent_advance_cannot_execute_twice_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "r", "p", workshop.PB)
  let assert Ok(done) =
    workshop.advance(dir, "r", budget, fn(stage, _) {
      let assert Error(_) =
        workshop.advance(dir, "r", budget, fn(_, _) {
          panic as "concurrent callback ran"
        })
      let assert Error(_) =
        workshop.abandon(
          dir,
          "r",
          "cannot abandon live callback",
          sign_abandon("r", "cannot abandon live callback"),
        )
      evidence(dir, stage, None)
    })
  done.completed |> list.length |> should.equal(1)
}

pub fn create_boundary_and_owner_mismatch_fail_closed_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "r", "p", workshop.PB)
  remove_active(dir, "p")
  let assert Error(_) = workshop.start(dir, "other", "p", workshop.PB)
  let assert Ok(_) = workshop.start(dir, "r", "p", workshop.PB)
  replace_active(dir, "p", "another")
  let assert Error(_) =
    workshop.advance(dir, "r", budget, fn(_, _) { panic as "wrong owner" })
  let assert Error(_) = workshop.start(dir, "other", "p", workshop.PB)
}

pub fn owner_change_during_callback_cannot_complete_or_release_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "r", "p", workshop.PB)
  let assert Error(_) =
    workshop.advance(dir, "r", budget, fn(stage, _) {
      replace_active(dir, "p", "other")
      evidence(dir, stage, None)
    })
  let assert Ok(checkpoint) = workshop.load(dir, "r")
  checkpoint.status |> should.equal(workshop.InFlight(workshop.Acquire))
  let assert Error(_) = workshop.start(dir, "new", "p", workshop.PB)
}

pub fn terminal_checkpoint_with_stale_owner_reconciles_on_next_start_test() {
  let dir = test_dir()
  let budget = workshop.Budget(1, 100, 10, True)
  let assert Ok(_) = workshop.start(dir, "old", "p", workshop.PB)
  let assert Ok(failed) =
    workshop.advance(dir, "old", budget, fn(stage, _) {
      let assert Ok(id) = workshop.artifact(dir, "synthetic failure")
      Ok(workshop.Evidence(stage, id, False, None, "synthetic-local-lab"))
    })
  let assert workshop.Failed(_) = failed.status
  replace_active(dir, "p", "old")
  let assert Ok(_) = workshop.start(dir, "new", "p", workshop.PB)
}

pub fn rollback_requires_authorization_and_valid_previous_artifact_test() {
  let dir = test_dir()
  let assert Ok(first) = workshop.artifact(dir, "synthetic candidate one")
  let assert Ok(second) = workshop.artifact(dir, "synthetic candidate two")
  seed_registry(dir, "synthetic-lab", second, first)
  let assert Error(_) = workshop.rollback(dir, "synthetic-lab", "unsigned")
  let signature = sign_rollback("synthetic-lab")
  let assert Ok(first) = workshop.rollback(dir, "synthetic-lab", signature)
  seed_registry(dir, "synthetic-lab", second, first)
  remove_artifact(dir, first)
  let assert Error(_) = workshop.rollback(dir, "synthetic-lab", signature)
  let assert Ok(pointer) = workshop.pointer(dir, "synthetic-lab")
  pointer |> should.equal(second)
}

pub fn partial_artifact_slot_cannot_be_promoted_or_silently_replaced_test() {
  let dir = test_dir()
  let content = "synthetic interrupted artifact"
  let assert Ok(_) = workshop.artifact(dir, "seed directory")
  poison_artifact(dir, content)
  let assert Error(_) = workshop.artifact(dir, content)
  let assert Ok(clean) = workshop.artifact(dir, "another synthetic artifact")
  let assert Ok(_) = workshop.read_artifact(dir, clean)
}

pub fn symlinked_state_root_fails_closed_test() {
  let dir = test_dir()
  let assert Ok(_) = workshop.start(dir, "one", "p", workshop.PB)
  let link = symlink_state(dir)
  let assert Error(_) = workshop.start(link, "two", "q", workshop.PB)
  let assert Error(_) = workshop.artifact(link, "synthetic data")
  let assert Error(_) = workshop.load(link, "one")
}

pub fn checkpoint_schema_rejects_unknown_stage_test() {
  let dir = test_dir()
  let assert Ok(_) = workshop.start(dir, "schema", "p", workshop.PB)
  corrupt_evidence(dir, "schema")
  let assert Error(_) = workshop.load(dir, "schema")
  fresh_load(dir, "schema") |> should.be_false
}
