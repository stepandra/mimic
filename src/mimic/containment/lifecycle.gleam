/// The same rule governs EOF, missing renewals, timeout, leader exit and faults:
/// finish the namespace owner. Killing a process group is never a terminal fence.
pub type StopReason {
  LeaderExited(code: Int)
  ParentGone
  LeaseExpired
  DeadlineExceeded
  OutputExceeded
  LaunchFailed
}

pub type State {
  AwaitingLease(deadline: Int, lease_deadline: Int)
  Running(deadline: Int, lease_deadline: Int)
  Stopping(reason: StopReason)
}

pub type Event {
  Renew
  InputClosed
  LeaderDone(code: Int)
  OutputLimit
  LaunchError
  Tick
}

pub type Action {
  Wait
  SpawnTarget
  ExitNamespace(reason: StopReason)
}

pub fn initial(now: Int, wall_ms: Int, lease_ms: Int) -> State {
  AwaitingLease(now + wall_ms, now + lease_ms)
}

pub fn step(
  state: State,
  event: Event,
  now: Int,
  lease_ms: Int,
) -> #(State, Action) {
  case state {
    Stopping(reason) -> #(state, ExitNamespace(reason))
    AwaitingLease(deadline, lease_deadline)
    | Running(deadline, lease_deadline) -> {
      // A buffered/late heartbeat can never revive an expired lease/deadline.
      case now >= deadline, now >= lease_deadline, event {
        True, _, _ -> stop(DeadlineExceeded)
        _, True, _ -> stop(LeaseExpired)
        _, _, InputClosed -> stop(ParentGone)
        _, _, LeaderDone(code) -> stop(LeaderExited(code))
        _, _, OutputLimit -> stop(OutputExceeded)
        _, _, LaunchError -> stop(LaunchFailed)
        _, _, Renew -> {
          let action = case state {
            AwaitingLease(..) -> SpawnTarget
            _ -> Wait
          }
          #(Running(deadline, now + lease_ms), action)
        }
        _, _, Tick -> #(state, Wait)
      }
    }
  }
}

fn stop(reason: StopReason) -> #(State, Action) {
  #(Stopping(reason), ExitNamespace(reason))
}

pub fn exit_code(reason: StopReason) -> Int {
  case reason {
    LeaderExited(code) -> code
    ParentGone | LeaseExpired -> 125
    DeadlineExceeded -> 124
    OutputExceeded | LaunchFailed -> 126
  }
}
