/// A run has ONE monotonic worst-case ledger. Usage, cancellation, timeouts and
/// even proven pre-send failures never create another request's allowance.
import gleam/list
import mimic/live/policy

pub type Lifecycle {
  Open
  Closed(reason: String)
}

pub type Snapshot {
  Snapshot(
    lifecycle: Lifecycle,
    requests_reserved: Int,
    input_reserved: Int,
    output_reserved: Int,
    cost_reserved_nano_usd: Int,
    deadline_ms: Int,
  )
}

pub opaque type Budget {
  Budget(snapshot: Snapshot, limits: policy.Limits, attempts: List(String))
}

pub fn new(limits: policy.Limits, now_ms: Int) -> Result(Budget, String) {
  case policy.valid_limits(limits) {
    True ->
      Ok(
        Budget(
          Snapshot(Open, 0, 0, 0, 0, now_ms + limits.duration_ms),
          limits,
          [],
        ),
      )
    False -> Error("live_budget_limits_invalid")
  }
}

/// Only the runner's serialized owner calls this. Never copy a Budget into
/// workers: immutable copies would admit competing spends independently.
pub fn reserve(
  budget: Budget,
  attempt: String,
  plan: policy.Plan,
  now_ms: Int,
) -> Result(Budget, String) {
  let before = budget.snapshot
  case before.lifecycle {
    Closed(_) -> Error("live_run_closed")
    Open ->
      case
        now_ms < before.deadline_ms
        && attempt != ""
        && !list.contains(budget.attempts, attempt)
      {
        False -> Error("live_expired_or_duplicate_attempt")
        True -> {
          let after =
            Snapshot(
              Open,
              before.requests_reserved + 1,
              before.input_reserved + policy.input_ceiling(plan),
              before.output_reserved + policy.output_ceiling(plan),
              before.cost_reserved_nano_usd + policy.cost_ceiling(plan),
              before.deadline_ms,
            )
          case
            after.requests_reserved <= budget.limits.requests
            && after.input_reserved <= budget.limits.input_tokens
            && after.output_reserved <= budget.limits.output_tokens
            && after.cost_reserved_nano_usd <= budget.limits.cost_nano_usd
          {
            True ->
              Ok(Budget(after, budget.limits, [attempt, ..budget.attempts]))
            False -> Error("live_budget_exhausted")
          }
        }
      }
  }
}

pub fn close(budget: Budget, reason: String) -> Budget {
  case budget.snapshot.lifecycle {
    Open ->
      Budget(
        Snapshot(..budget.snapshot, lifecycle: Closed(reason)),
        budget.limits,
        budget.attempts,
      )
    Closed(_) -> budget
  }
}

pub fn snapshot(budget: Budget) -> Snapshot {
  budget.snapshot
}
