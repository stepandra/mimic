import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import mimic/containment/docker
import mimic/containment/os
import mimic/containment/policy
import mimic/containment/protocol

pub type Report {
  Report(image: String, checks: List(String), elapsed_ms: Int)
}

const checks = [
  "filesystem_isolated",
  "owner_channel_denied",
  "root_write_denied",
  "workspace_allowed",
  "environment_clean",
  "target_unprivileged",
  "no_new_privileges",
  "capabilities_dropped",
  "approved_tcp_allowed",
  "denied_tcp_rejected",
  "approved_bind_allowed",
  "denied_bind_rejected",
  "unix_socket_rejected",
  "udp_socket_rejected",
  "resources_bounded",
]

/// No stored boolean/receipt can authorize execution. The actual suite runs
/// against the same immutable image and explicit backend for every execute().
pub fn run(backend: policy.Backend, image: String) -> Result(Report, String) {
  use _ <- result.try(case policy.immutable_image(image) {
    True -> Ok(Nil)
    False -> Error("containment_selftest_requires_immutable_image")
  })
  use _ <- result.try(docker.ready(backend, image))
  let started = os.clock()
  use baseline <- result.try(baseline(backend, image))
  use _ <- result.try(lifetime(backend, image, "parent_sigkill"))
  use _ <- result.try(lifetime(backend, image, "lease_expired"))
  use _ <- result.try(lifetime(backend, image, "timeout"))
  use _ <- result.try(lifetime(backend, image, "early_exit"))
  use _ <- result.try(lifetime(backend, image, "setsid"))
  use _ <- result.try(cleanup_failure(backend, image))
  Ok(Report(
    image,
    list.append(baseline, [
      "parent_sigkill", "lease_expired", "timeout", "early_exit", "setsid",
      "cleanup_failure",
    ]),
    os.clock() - started,
  ))
}

fn plan(image, case_name, wall_ms) {
  policy.authorize(policy.Request(
    image,
    "/usr/local/bin/python3",
    ["/qa/containment_faults.py", case_name],
    policy.Network([39_003], [39_001]),
    policy.Limits(..policy.default_limits(), wall_ms: wall_ms),
  ))
}

fn baseline(backend, image) {
  use plan <- result.try(plan(image, "baseline", 10_000))
  use receipt <- result.try(docker.run(backend, plan, True))
  use _ <- result.try(require(
    receipt.code == 0 && receipt.reason == "leader_exited",
    "containment_selftest_blocked:" <> receipt.reason,
  ))
  list.try_map(checks, fn(name) {
    let decoder = {
      use value <- decode.field(name, decode.bool)
      decode.success(value)
    }
    case json.parse(receipt.output, decoder) {
      Ok(True) -> Ok(name)
      _ -> Error("containment_selftest_failed:" <> name)
    }
  })
}

fn lifetime(backend, image, case_name) {
  let wall_ms = case case_name {
    "timeout" -> 5000
    _ -> 15_000
  }
  use plan <- result.try(plan(image, case_name, wall_ms))
  use container <- result.try(docker.create(backend, plan, True))
  let outcome = lifetime_in(container, case_name)
  docker.finish(outcome, docker.remove(container))
}

fn lifetime_in(container, case_name) {
  let mode = case case_name {
    "lease_expired" -> "lease_expired"
    _ -> "pump"
  }
  use companion <- result.try(
    os.companion(list.append(docker.companion_args(container), [mode])),
  )
  let outcome = {
    use _ <- result.try(wait_descendant(container, case_name, os.clock() + 6000))
    case case_name {
      "parent_sigkill" -> {
        use _ <- result.try(os.kill_owned(companion))
        use exit <- result.try(collect(companion, os.clock() + 3000, ""))
        use _ <- result.try(require(
          exit.0 == 137,
          "containment_parent_sigkill_not_observed",
        ))
        docker.wait_stopped(container, os.clock() + 5000)
      }
      _ -> {
        use value <- result.try(collect(companion, os.clock() + 20_000, ""))
        use receipt <- result.try(protocol.decode(value.1, docker.id(container)))
        let #(code, reason) = case case_name {
          "timeout" -> #(124, "deadline_exceeded")
          "lease_expired" -> #(125, "lease_expired")
          _ -> #(0, "leader_exited")
        }
        use _ <- result.try(require(
          value.0 == code && receipt.code == code && receipt.reason == reason,
          "containment_lifetime_fault_failed:" <> case_name,
        ))
        docker.stopped(container)
      }
    }
  }
  // Recovery is bounded even when an assertion fails. Namespace removal below
  // remains authoritative. Do not signal any PID other than our companion.
  let _ = os.kill_owned(companion)
  os.close(companion)
  outcome
}

fn wait_descendant(container, case_name, deadline) {
  use top <- result.try(
    docker.invoke(docker.backend(container), [
      "top",
      docker.id(container),
      "-eo",
      "pid,ppid,sid,args",
    ]),
  )
  case top.0 == 0 && descendant_seen(top.1, case_name == "setsid") {
    True -> Ok(Nil)
    False ->
      case os.clock() >= deadline {
        True -> Error("containment_fault_descendant_not_observed")
        False -> {
          sleep(50)
          wait_descendant(container, case_name, deadline)
        }
      }
  }
}

/// Parse bounded OS observation, not an inference from the requested argv.
/// The setsid case must observe BOTH a different session and reparenting after
/// the intermediate child exits; merely seeing the marker is not enough.
pub fn descendant_seen(top: String, require_setsid: Bool) -> Bool {
  let rows =
    top
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case
        line
        |> string.replace("\t", " ")
        |> string.split(" ")
        |> list.filter(fn(item) { item != "" })
      {
        [pid, ppid, sid, ..args] ->
          Ok(#(pid, ppid, sid, string.join(args, " ")))
        _ -> Error(Nil)
      }
    })
  let leaders =
    list.filter(rows, fn(row) {
      string.contains(row.3, "/qa/containment_faults.py")
    })
  list.any(rows, fn(child) {
    string.contains(child.3, "f02-adversarial-descendant")
    && case require_setsid {
      False -> True
      True ->
        list.any(leaders, fn(leader) {
          child.2 != leader.2 && child.1 != leader.0
        })
    }
  })
}

fn collect(handle, deadline, output) {
  case os.clock() >= deadline {
    True -> Error("containment_fault_companion_timeout")
    False ->
      case os.receive_event(handle, 25) {
        os.Data(data) ->
          case string.byte_size(output) + string.byte_size(data) <= 100_000 {
            True -> collect(handle, deadline, output <> data)
            False -> Error("containment_fault_output_limit")
          }
        os.Exited(code) -> Ok(#(code, output))
        os.Idle -> collect(handle, deadline, output)
        _ -> Error("containment_fault_companion_failed")
      }
  }
}

fn cleanup_failure(backend, image) {
  use plan <- result.try(plan(image, "baseline", 10_000))
  use container <- result.try(docker.create(backend, plan, True))
  let outcome = {
    use receipt <- result.try(docker.run_attached(container))
    use _ <- result.try(require(
      receipt.code == 0,
      "containment_cleanup_fixture_failed",
    ))
    // Fault injection makes the actual Docker removal command fail, while
    // leaving our stopped container available for the independent safety check.
    use failed <- result.try(
      docker.invoke(backend, [
        "rm",
        "--f02-injected-cleanup-failure",
        docker.id(container),
      ]),
    )
    use _ <- result.try(require(
      failed.0 != 0,
      "containment_cleanup_fault_not_injected",
    ))
    use _ <- result.try(docker.stopped(container))
    case docker.finish(Ok(receipt), Error("containment_cleanup_failed")) {
      Error("containment_cleanup_failed") -> Ok(Nil)
      _ -> Error("containment_cleanup_failure_was_waived")
    }
  }
  // A second, normal removal is explicit test recovery, not a passing cleanup.
  docker.finish(outcome, docker.remove(container))
}

pub fn encode(report: Report) -> String {
  json.object([
    #("schema", json.string("mimic.containment-selftest/v1")),
    #("synthetic", json.bool(True)),
    #("image", json.string(report.image)),
    #("checks", json.array(report.checks, json.string)),
    #("elapsed_ms", json.int(report.elapsed_ms)),
  ])
  |> json.to_string
}

fn require(ok, error) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil
