/// Transport-independent executable core. The actor serializes ONLY authority
/// and reservation writes; cancellable workers own transport I/O. No retries.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import mimic/live/admission
import mimic/live/budget
import mimic/live/identity
import mimic/live/policy

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

pub type Frame(connection) {
  Head(status: Int, connection: connection)
  Data(bytes: BitArray, connection: connection)
  // The adapter accounts raw bytes with Data first. These are ordered
  // cumulative synthetic snapshots, not a second unmetered byte channel.
  ObservedUsage(usage: Usage, connection: connection)
  InvalidUsage
  End(usage: Option(Usage))
}

/// A trusted adapter is invoked once per admitted attempt. It must not retry,
/// redirect, expand authority, spawn unowned work or infer ambient credentials.
/// The only currently admitted adapter is standalone synthetic loopback.
pub type Transport(connection) {
  Transport(
    connect: fn(policy.Plan, Int) -> Result(connection, String),
    send: fn(connection, policy.Plan, Int) -> Result(connection, String),
    next: fn(connection, Int, Int) -> Result(Frame(connection), String),
    cancel: fn(connection) -> Nil,
  )
}

pub type Delivery {
  NotSent
  Sent
  Uncertain
}

pub type Reason {
  Completed
  ConnectFailed
  WriteFailed
  ReadFailed
  ResponseRejected
  ResponseLimit
  UsageLimit
  UsageNonMonotonic
  UsageInvalid
  TimedOut
  Cancelled
  WorkerFailed
}

pub type Outcome {
  Outcome(
    delivery: Delivery,
    reason: Reason,
    status: Option(Int),
    response_bytes: Int,
    usage: Option(Usage),
    observed_cost_nano_usd: Option(Int),
  )
}

pub opaque type Runner {
  Runner(subject: process.Subject(Message), pid: process.Pid, wait_ms: Int)
}

pub opaque type Attempt {
  Attempt(
    runner: Runner,
    id: String,
    reply: process.Subject(Result(Outcome, String)),
  )
}

type Pending {
  Pending(
    id: String,
    guard: process.Pid,
    monitor: process.Monitor,
    deadline: Int,
    reply: process.Subject(Result(Outcome, String)),
  )
}

type State(connection) {
  State(
    subject: process.Subject(Message),
    owner: process.Monitor,
    admission: admission.Admission,
    approval: policy.Approval,
    binding: identity.Binding,
    transport: Transport(connection),
    budget: budget.Budget,
    pending: List(Pending),
  )
}

type Message {
  Submit(String, policy.Request, process.Subject(Result(Outcome, String)))
  Finished(String, Outcome)
  Cancel(String, process.Subject(Result(Nil, String)))
  View(process.Subject(Result(budget.Snapshot, String)))
  Close(process.Subject(Result(budget.Snapshot, String)))
  Down(process.Down)
  Expire
  Retire
}

type Reply(value) {
  Answer(value)
  Unavailable
}

@external(erlang, "mimic_live_ffi", "now_ms")
pub fn now_ms() -> Int

pub fn start(
  admission: admission.Admission,
  approval: policy.Approval,
  binding: identity.Binding,
  transport: Transport(connection),
) -> Result(Runner, String) {
  use initial_budget <- result.try(budget.new(approval.limits, now_ms()))
  let owner = process.self()
  case
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = process.send_after(subject, approval.limits.duration_ms, Expire)
      // Closed snapshots remain queryable for at most one second. An abandoned
      // runner cannot retain timers/worker capabilities indefinitely.
      let _ =
        process.send_after(subject, approval.limits.duration_ms + 1000, Retire)
      let owner_monitor = process.monitor(owner)
      actor.initialised(
        State(
          subject,
          owner_monitor,
          admission,
          approval,
          binding,
          transport,
          initial_budget,
          [],
        ),
      )
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(Down),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> {
      process.unlink(started.pid)
      Ok(Runner(started.data, started.pid, approval.limits.request_ms + 1000))
    }
    Error(_) -> Error("live_runner_unavailable")
  }
}

/// Nonblocking submission supports explicit concurrent scenarios. The actor,
/// not the caller, validates and reserves before any worker is started.
pub fn submit(runner: Runner, id: String, request: policy.Request) -> Attempt {
  let reply = process.new_subject()
  process.send(runner.subject, Submit(id, request, reply))
  Attempt(runner, id, reply)
}

pub fn await(attempt: Attempt) -> Result(Outcome, String) {
  let answer =
    receive_reply(attempt.runner, attempt.reply, attempt.runner.wait_ms)
  case answer {
    Error(_) -> {
      // A lost reply does not mean NotSent, and does not refund reservation.
      let _ = cancel(attempt.runner, attempt.id)
      Error("live_reply_unknown_reservation_not_refunded")
    }
    Ok(value) -> value
  }
}

pub fn execute(
  runner: Runner,
  id: String,
  request: policy.Request,
) -> Result(Outcome, String) {
  await(submit(runner, id, request))
}

pub fn cancel(runner: Runner, id: String) -> Result(Nil, String) {
  let reply = process.new_subject()
  process.send(runner.subject, Cancel(id, reply))
  use answer <- result.try(receive_reply(runner, reply, 1000))
  answer
}

pub fn snapshot(runner: Runner) -> Result(budget.Snapshot, String) {
  let reply = process.new_subject()
  process.send(runner.subject, View(reply))
  use answer <- result.try(receive_reply(runner, reply, 1000))
  answer
}

pub fn close(runner: Runner) -> Result(budget.Snapshot, String) {
  let reply = process.new_subject()
  process.send(runner.subject, Close(reply))
  use answer <- result.try(receive_reply(runner, reply, 1000))
  answer
}

pub fn pid(runner: Runner) -> process.Pid {
  runner.pid
}

fn receive_reply(
  runner: Runner,
  reply: process.Subject(value),
  timeout: Int,
) -> Result(value, String) {
  let monitor = process.monitor(runner.pid)
  let answer =
    process.new_selector()
    |> process.select_map(reply, Answer)
    |> process.select_specific_monitor(monitor, fn(_) { Unavailable })
    |> process.selector_receive(timeout)
  process.demonitor_process(monitor)
  case answer {
    Ok(Answer(value)) -> Ok(value)
    _ -> Error("live_runner_unavailable_or_reply_timeout")
  }
}

fn handle(state: State(connection), message: Message) {
  case message {
    Submit(id, request, reply) ->
      actor.continue(begin(state, id, request, reply))
    Finished(id, outcome) -> actor.continue(complete(state, id, outcome))
    Cancel(id, reply) -> {
      let #(pending, active) =
        list.partition(state.pending, fn(pending) { pending.id == id })
      list.each(pending, fn(pending) {
        finish_pending(pending, uncertain(Cancelled))
      })
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, pending: active))
    }
    View(reply) -> {
      let state = expire_if_needed(state)
      process.send(reply, Ok(budget.snapshot(state.budget)))
      actor.continue(state)
    }
    Close(reply) -> {
      let state = stop_pending(state, Cancelled, "operator_closed")
      process.send(reply, Ok(budget.snapshot(state.budget)))
      actor.stop()
    }
    Expire -> actor.continue(stop_pending(state, TimedOut, "deadline"))
    Retire -> {
      let _ = stop_pending(state, Cancelled, "owner_or_lifetime_ended")
      actor.stop()
    }
    Down(down) if down.monitor == state.owner -> {
      let _ = stop_pending(state, Cancelled, "owner_ended")
      actor.stop()
    }
    Down(down) -> {
      let #(failed, active) =
        list.partition(state.pending, fn(pending) {
          pending.monitor == down.monitor
        })
      list.each(failed, fn(pending) {
        finish_pending(pending, uncertain(WorkerFailed))
      })
      actor.continue(State(..state, pending: active))
    }
  }
}

fn begin(
  state: State(connection),
  id: String,
  request: policy.Request,
  reply: process.Subject(Result(Outcome, String)),
) -> State(connection) {
  let state = expire_if_needed(state)
  let prepared = {
    use _ <- result.try(case id != "" && string.byte_size(id) <= 128 {
      True -> Ok(Nil)
      False -> Error("live_attempt_id_invalid")
    })
    use plan <- result.try(policy.authorize(
      state.admission,
      state.approval,
      state.binding,
      request,
    ))
    use reserved <- result.try(budget.reserve(state.budget, id, plan, now_ms()))
    Ok(#(plan, reserved))
  }
  case prepared {
    Error(error) -> {
      process.send(reply, Error(error))
      state
    }
    Ok(#(plan, reserved)) -> {
      // This is the ONLY launch site. Reservation is complete before spawn.
      let deadline =
        int.min(
          budget.snapshot(reserved).deadline_ms,
          now_ms() + policy.limits(plan).request_ms,
        )
      let owner = process.self()
      let guard =
        process.spawn_unlinked(fn() {
          guard_worker(
            owner,
            state.subject,
            id,
            plan,
            state.transport,
            deadline,
          )
        })
      let pending = Pending(id, guard, process.monitor(guard), deadline, reply)
      State(..state, budget: reserved, pending: [pending, ..state.pending])
    }
  }
}

fn expire_if_needed(state: State(connection)) -> State(connection) {
  case now_ms() >= budget.snapshot(state.budget).deadline_ms {
    True -> stop_pending(state, TimedOut, "deadline")
    False -> state
  }
}

fn finish_pending(pending: Pending, outcome: Outcome) -> Nil {
  process.demonitor_process(pending.monitor)
  process.kill(pending.guard)
  process.send(pending.reply, Ok(outcome))
}

fn complete(
  state: State(connection),
  id: String,
  outcome: Outcome,
) -> State(connection) {
  let #(finished, active) =
    list.partition(state.pending, fn(pending) { pending.id == id })
  list.each(finished, fn(pending) {
    finish_pending(pending, case now_ms() >= pending.deadline {
      True -> uncertain(TimedOut)
      False -> outcome
    })
  })
  let state = State(..state, pending: active)
  case finished {
    [] -> expire_if_needed(state)
    _ ->
      case outcome.reason {
        UsageLimit -> stop_pending(state, Cancelled, "usage_ceiling_violated")
        UsageNonMonotonic | UsageInvalid ->
          stop_pending(state, Cancelled, "usage_contract_violated")
        _ -> expire_if_needed(state)
      }
  }
}

fn stop_pending(
  state: State(connection),
  reason: Reason,
  closed: String,
) -> State(connection) {
  list.each(state.pending, fn(pending) {
    finish_pending(pending, uncertain(reason))
  })
  State(..state, budget: budget.close(state.budget, closed), pending: [])
}

pub fn uncertain(reason: Reason) -> Outcome {
  Outcome(Uncertain, reason, None, 0, None, None)
}

type GuardEvent {
  ParentDown
  ExecutionDown
  IgnoredExit
}

fn guard_worker(
  owner: process.Pid,
  subject: process.Subject(Message),
  id: String,
  plan: policy.Plan,
  transport: Transport(connection),
  deadline: Int,
) -> Nil {
  // Separate from blocking I/O: owner death or cancellation kills the linked
  // execution process and its sockets. This is BEAM lifetime hygiene, NOT F02
  // containment of native descendants/filesystem/network/resources.
  process.trap_exits(True)
  let owner_monitor = process.monitor(owner)
  let ready = process.new_subject()
  let guard = process.self()
  let execution =
    process.spawn_unlinked(fn() {
      process.link(guard)
      let kickoff = process.new_subject()
      process.send(ready, kickoff)
      case process.receive(kickoff, int.max(1, deadline - now_ms())) {
        Error(_) -> Nil
        Ok(Nil) -> {
          let outcome = perform(plan, transport, deadline)
          process.send(subject, Finished(id, outcome))
          process.sleep_forever()
        }
      }
    })
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_) { ParentDown })
    |> process.select_specific_monitor(process.monitor(execution), fn(_) {
      ExecutionDown
    })
    |> process.select_trapped_exits(fn(_) { IgnoredExit })
  case process.receive(ready, int.max(1, deadline - now_ms())) {
    Ok(kickoff) -> {
      case deadline > now_ms() {
        True -> {
          process.send(kickoff, Nil)
          guard_loop(selector, subject, id, execution, deadline)
        }
        False -> {
          process.kill(execution)
          process.send(subject, Finished(id, uncertain(TimedOut)))
        }
      }
    }
    _ -> {
      process.kill(execution)
      process.send(subject, Finished(id, uncertain(TimedOut)))
    }
  }
}

fn guard_loop(
  selector: process.Selector(GuardEvent),
  subject: process.Subject(Message),
  id: String,
  execution: process.Pid,
  deadline: Int,
) -> Nil {
  case process.selector_receive(selector, int.max(1, deadline - now_ms())) {
    Ok(IgnoredExit) -> guard_loop(selector, subject, id, execution, deadline)
    Ok(ParentDown) -> process.kill(execution)
    Ok(ExecutionDown) ->
      process.send(subject, Finished(id, uncertain(WorkerFailed)))
    Error(_) -> {
      process.kill(execution)
      process.send(subject, Finished(id, uncertain(TimedOut)))
    }
  }
}

fn perform(
  plan: policy.Plan,
  transport: Transport(connection),
  deadline: Int,
) -> Outcome {
  case now_ms() >= deadline {
    True -> Outcome(NotSent, TimedOut, None, 0, None, None)
    False ->
      case transport.connect(plan, deadline) {
        Error(_) -> Outcome(NotSent, ConnectFailed, None, 0, None, None)
        Ok(connection) -> {
          let outcome = case now_ms() >= deadline {
            True -> Outcome(NotSent, TimedOut, None, 0, None, None)
            False ->
              case transport.send(connection, plan, deadline) {
                Error(_) -> uncertain(WriteFailed)
                Ok(sent) ->
                  collect(
                    plan,
                    transport,
                    sent,
                    deadline,
                    Received(None, 0, 0, None, 0),
                  )
              }
          }
          transport.cancel(connection)
          outcome
        }
      }
  }
}

type Received {
  Received(
    status: Option(Int),
    bytes: Int,
    chunks: Int,
    usage: Option(Usage),
    observations: Int,
  )
}

fn collect(
  plan: policy.Plan,
  transport: Transport(connection),
  connection: connection,
  deadline: Int,
  received: Received,
) -> Outcome {
  let limits = policy.limits(plan)
  case now_ms() >= deadline {
    True -> rejected(received, TimedOut)
    False ->
      case
        transport.next(
          connection,
          limits.response_bytes - received.bytes,
          deadline,
        )
      {
        Error(_) -> rejected(received, ReadFailed)
        Ok(Head(code, next)) ->
          case
            received.status == None
            && code >= 200
            && code < 300
            && received.bytes == 0
          {
            True ->
              collect(
                plan,
                transport,
                next,
                deadline,
                Received(..received, status: Some(code)),
              )
            False ->
              rejected(
                Received(..received, status: Some(code)),
                ResponseRejected,
              )
          }
        Ok(Data(chunk, next)) -> {
          let size = bit_array.byte_size(chunk)
          case
            received.status != None
            && size > 0
            && size <= limits.response_bytes - received.bytes
            && received.chunks < limits.stream_chunks
          {
            True ->
              collect(
                plan,
                transport,
                next,
                deadline,
                Received(
                  ..received,
                  bytes: received.bytes + size,
                  chunks: received.chunks + 1,
                ),
              )
            False -> rejected(received, ResponseLimit)
          }
        }
        Ok(ObservedUsage(usage, next)) ->
          case received.status != None && received.observations < 1024 {
            False -> rejected(received, ResponseLimit)
            True ->
              case validate_usage(plan, received.usage, usage) {
                Error(reason) -> rejected_usage(received, usage, reason)
                Ok(_) ->
                  collect(
                    plan,
                    transport,
                    next,
                    deadline,
                    Received(
                      ..received,
                      usage: Some(usage),
                      observations: received.observations + 1,
                    ),
                  )
              }
          }
        Ok(InvalidUsage) -> rejected(received, UsageInvalid)
        Ok(End(usage)) ->
          case received.status {
            None -> rejected(received, ResponseRejected)
            Some(_) ->
              case usage {
                None -> finish_usage(plan, received)
                Some(usage) ->
                  case received.observations < 1024 {
                    False -> rejected(received, ResponseLimit)
                    True ->
                      case validate_usage(plan, received.usage, usage) {
                        Error(reason) -> rejected_usage(received, usage, reason)
                        Ok(_) ->
                          finish_usage(
                            plan,
                            Received(..received, usage: Some(usage)),
                          )
                      }
                  }
              }
          }
      }
  }
}

fn validate_usage(
  plan: policy.Plan,
  previous: Option(Usage),
  usage: Usage,
) -> Result(Nil, Reason) {
  use _ <- result.try(case usage.input_tokens >= 0 && usage.output_tokens >= 0 {
    True -> Ok(Nil)
    False -> Error(UsageInvalid)
  })
  case
    usage.input_tokens <= policy.input_ceiling(plan)
    && usage.output_tokens <= policy.output_ceiling(plan)
  {
    False -> Error(UsageLimit)
    True ->
      case previous {
        Some(previous)
          if usage.input_tokens < previous.input_tokens
          || usage.output_tokens < previous.output_tokens
        -> Error(UsageNonMonotonic)
        _ -> Ok(Nil)
      }
  }
}

fn rejected_usage(received: Received, usage: Usage, reason: Reason) -> Outcome {
  case reason {
    // Keep the known over-ceiling evidence. Invalid/decreasing assertions
    // cannot replace already validated cumulative counts.
    UsageLimit -> rejected(Received(..received, usage: Some(usage)), reason)
    _ -> rejected(received, reason)
  }
}

fn rejected(received: Received, reason: Reason) -> Outcome {
  Outcome(Sent, reason, received.status, received.bytes, received.usage, None)
}

fn finish_usage(plan: policy.Plan, received: Received) -> Outcome {
  let cost = case received.usage {
    None -> None
    Some(usage) ->
      Some(policy.usage_cost(plan, usage.input_tokens, usage.output_tokens))
  }
  Outcome(
    Sent,
    Completed,
    received.status,
    received.bytes,
    received.usage,
    cost,
  )
}
