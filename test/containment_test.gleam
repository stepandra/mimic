import gleam/list
import gleam/string
import gleeunit/should
import mimic/containment
import mimic/containment/docker
import mimic/containment/lifecycle as lifetime
import mimic/containment/os
import mimic/containment/owner
import mimic/containment/policy
import mimic/containment/protocol
import mimic/containment/selftest

fn request() -> policy.Request {
  policy.Request(
    "sha256:"
      <> "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "/usr/local/bin/python3",
    ["/qa/harness.py"],
    policy.Network([8317, 9099], [8317, 9099]),
    policy.default_limits(),
  )
}

pub fn immutable_local_image_only_test() {
  policy.authorize(request()) |> should.be_ok
  for_images(["latest", "erlang:29", "name@sha256:bad", "--privileged"])
}

fn for_images(images: List(String)) {
  images
  |> list.each(fn(image) {
    policy.authorize(policy.Request(..request(), image: image))
    |> should.be_error
  })
}

pub fn explicit_backend_only_test() {
  policy.validate_backend(policy.Backend(
    "/usr/local/bin/docker",
    "/tmp/owned.sock",
  ))
  |> should.be_ok
  policy.validate_backend(policy.Backend("docker", "orbstack"))
  |> should.be_error
}

pub fn bound_ports_not_all_loopback_test() {
  policy.port_argument([]) |> should.equal("-")
  policy.port_argument([8317, 9099]) |> should.equal("8317,9099")
  list.each([[0], [65_536], [8317, 8317]], fn(ports) {
    policy.authorize(
      policy.Request(..request(), network: policy.Network([], ports)),
    )
    |> should.be_error
  })
}

pub fn resources_and_argv_fail_closed_test() {
  let base = request()
  policy.authorize(
    policy.Request(
      ..base,
      limits: policy.Limits(..base.limits, wall_ms: 300_001),
    ),
  )
  |> should.be_error
  policy.authorize(policy.Request(..base, args: ["bad\u{0000}arg"]))
  |> should.be_error
  policy.authorize(policy.Request(..base, executable: "/containment/owner"))
  |> should.be_error
  policy.authorize(policy.Request(..base, executable: "/tmp/../bin/target"))
  |> should.be_error
}

pub fn first_lease_precedes_target_test() {
  let state = lifetime.initial(100, 10_000, 1000)
  lifetime.step(state, lifetime.Tick, 101, 1000)
  |> should.equal(#(state, lifetime.Wait))
  lifetime.step(state, lifetime.Renew, 102, 1000)
  |> should.equal(#(lifetime.Running(10_100, 1102), lifetime.SpawnTarget))
}

pub fn eof_timeout_and_leader_exit_finish_namespace_test() {
  let state = lifetime.Running(10_000, 1000)
  list.each(
    [
      #(lifetime.InputClosed, 10, lifetime.ParentGone),
      #(lifetime.LeaderDone(0), 10, lifetime.LeaderExited(0)),
      #(lifetime.LeaderDone(9), 10, lifetime.LeaderExited(9)),
      #(lifetime.Tick, 1000, lifetime.LeaseExpired),
      #(lifetime.Renew, 10_000, lifetime.DeadlineExceeded),
      #(lifetime.OutputLimit, 10, lifetime.OutputExceeded),
    ],
    fn(item) {
      let #(event, now, reason) = item
      lifetime.step(state, event, now, 1000)
      |> should.equal(#(
        lifetime.Stopping(reason),
        lifetime.ExitNamespace(reason),
      ))
    },
  )
}

pub fn stale_lease_cannot_resurrect_owner_test() {
  lifetime.step(lifetime.Running(10_000, 1000), lifetime.Renew, 1000, 1000)
  |> should.equal(#(
    lifetime.Stopping(lifetime.LeaseExpired),
    lifetime.ExitNamespace(lifetime.LeaseExpired),
  ))
  let state = lifetime.Stopping(lifetime.ParentGone)
  lifetime.step(state, lifetime.Renew, 10, 1000)
  |> should.equal(#(state, lifetime.ExitNamespace(lifetime.ParentGone)))
}

pub fn renew_does_not_extend_absolute_deadline_test() {
  lifetime.step(lifetime.Running(10_000, 1000), lifetime.Renew, 999, 1000)
  |> should.equal(#(lifetime.Running(10_000, 1999), lifetime.Wait))
}

pub fn terminal_errors_always_exit_namespace_test() {
  lifetime.exit_code(lifetime.ParentGone) |> should.equal(125)
  lifetime.exit_code(lifetime.DeadlineExceeded) |> should.equal(124)
  lifetime.exit_code(lifetime.LeaseExpired) |> should.equal(125)
  lifetime.exit_code(lifetime.OutputExceeded) |> should.equal(126)
  lifetime.exit_code(lifetime.LaunchFailed) |> should.equal(126)
}

pub fn cleanup_failure_overrides_success_and_target_failure_test() {
  docker.finish(Ok("successful target"), Error("cleanup failed"))
  |> should.equal(Error("cleanup failed"))
  docker.finish(Error("target failed"), Error("cleanup failed"))
  |> should.equal(Error("cleanup failed"))
  docker.finish(Ok("successful target"), Ok(Nil))
  |> should.equal(Ok("successful target"))
}

pub fn container_has_no_host_mount_or_privilege_escape_test() {
  let args =
    docker.create_args(request(), "mimic-f02-synthetic", "token", False)
  list.each(
    ["--mount", "--volume", "-v", "--privileged", "--init", "--publish", "-p"],
    fn(flag) { list.contains(args, flag) |> should.be_false },
  )
  has_pair(args, "--network", "none") |> should.be_true
  has_pair(args, "--pull", "never") |> should.be_true
  has_pair(args, "--security-opt", "no-new-privileges") |> should.be_true
  has_pair(args, "--log-driver", "none") |> should.be_true
  has_pair(args, "--memory", "2048m") |> should.be_true
  has_pair(args, "--memory-swap", "2048m") |> should.be_true
  list.contains(args, "mimic_containment_boot:boot().") |> should.be_true
}

fn has_pair(args, first, second) {
  case args {
    [a, b, ..rest] ->
      { a == first && b == second } || has_pair([b, ..rest], first, second)
    _ -> False
  }
}

pub fn arguments_remain_arguments_not_shell_or_eval_text_test() {
  let malicious = "$(touch /tmp/f02-not-executed); --privileged"
  let base = request()
  let args =
    docker.create_args(
      policy.Request(..base, args: [malicious]),
      "mimic-f02-synthetic",
      "token",
      False,
    )
  list.last(args) |> should.equal(Ok(malicious))
  list.contains(args, "--privileged") |> should.be_false
}

pub fn unavailable_backend_blocks_before_target_test() {
  let assert Ok(plan) =
    policy.authorize(
      policy.Request(..request(), executable: "/f02-target-must-not-spawn"),
    )
  containment.execute(
    policy.Backend(
      "/f02-synthetic-missing/docker",
      "/f02-synthetic-missing/socket",
    ),
    plan,
  )
  |> should.equal(Error("containment_os_launch_unavailable"))
}

pub fn owner_refuses_host_execution_test() {
  os.owner_boundary() |> should.be_error
  let #(code, text) = owner.boot()
  code |> should.equal(126)
  let assert Ok(receipt) = protocol.decode(text, "synthetic")
  receipt.reason |> should.equal("containment_namespace_owner_boundary_missing")
  receipt.output |> should.equal("")
}

pub fn no_default_discovery_or_live_command_test() {
  containment.cli([]) |> should.be_error
  containment.cli(["live"]) |> should.be_error
  containment.cli(["run", "docker", "orbstack", "latest"]) |> should.be_error
}

pub fn report_is_bound_and_utf8_round_trips_test() {
  let text = protocol.encode(0, "leader_exited", "{\"synthetic\":\"☃\"}\n")
  protocol.decode(text, "exact-owned-container")
  |> should.equal(
    Ok(protocol.Receipt(
      0,
      "leader_exited",
      "{\"synthetic\":\"☃\"}\n",
      "exact-owned-container",
    )),
  )
  protocol.decode(
    "{\"schema\":\"untrusted\",\"code\":0,\"reason\":\"ok\",\"output\":\"\"}",
    "synthetic",
  )
  |> should.be_error
}

pub fn os_environment_is_fresh_not_operator_inherited_test() {
  let assert Ok(#(0, environment)) = os.command("/usr/bin/env", [], 1000, 4096)
  string.contains(environment, "HOME=/nonexistent\n") |> should.be_true
  string.contains(environment, "DOCKER_CONFIG=/nonexistent\n") |> should.be_true
  string.split(string.trim(environment), "\n") |> list.length |> should.equal(4)
}

pub fn os_command_output_is_bounded_test() {
  os.command("/usr/bin/env", [], 1000, 1)
  |> should.equal(Error("containment_os_output_limit"))
}

pub fn setsid_fault_requires_observed_session_escape_and_reparenting_test() {
  // Synthetic ps rows, not a claim that a kernel fault test executed.
  let leader =
    "PID PPID SID COMMAND\n10 1 10 python3 /qa/containment_faults.py setsid\n"
  selftest.descendant_seen(
    leader <> "11 10 10 python3 f02-adversarial-descendant\n",
    True,
  )
  |> should.be_false
  selftest.descendant_seen(
    leader <> "11 10 11 python3 f02-adversarial-descendant\n",
    True,
  )
  |> should.be_false
  selftest.descendant_seen(
    leader <> "12 1 11 python3 f02-adversarial-descendant\n",
    True,
  )
  |> should.be_true
}

pub fn lifetime_probe_requires_real_descendant_not_status_only_test() {
  selftest.descendant_seen("PID PPID SID COMMAND\n", False)
  |> should.be_false
  selftest.descendant_seen(
    "11 10 10 python3 f02-adversarial-descendant\n",
    False,
  )
  |> should.be_true
}
