import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mimic/containment/os
import mimic/containment/policy
import mimic/containment/protocol

pub opaque type Container {
  Container(
    backend: policy.Backend,
    id: String,
    name: String,
    token: String,
    request: policy.Request,
  )
}

pub fn id(container: Container) -> String {
  container.id
}

pub fn backend(container: Container) -> policy.Backend {
  container.backend
}

pub fn companion_args(container: Container) -> List(String) {
  [
    container.backend.executable,
    container.backend.socket,
    container.id,
    container.token,
    int.to_string(container.request.limits.lease_ms),
    int.to_string(container.request.limits.wall_ms),
  ]
}

pub fn invoke(
  backend: policy.Backend,
  args: List(String),
) -> Result(#(Int, String), String) {
  os.command(backend.executable, prefix(backend, args), 3000, 1_048_576)
}

pub fn prefix(backend: policy.Backend, args: List(String)) -> List(String) {
  ["--host", "unix://" <> backend.socket, ..args]
}

pub fn ready(backend: policy.Backend, image: String) -> Result(Nil, String) {
  use _ <- result.try(policy.validate_backend(backend))
  use info <- result.try(invoke(backend, ["info", "--format", "{{.OSType}}"]))
  use _ <- result.try(require(
    info == #(0, "linux\n"),
    "containment_backend_unavailable",
  ))
  use inspected <- result.try(
    invoke(backend, [
      "image", "inspect", "--format", "{{.Id}} {{json .Config.Volumes}}", image,
    ]),
  )
  require(
    inspected == #(0, image <> " null\n") || inspected == #(0, image <> " {}\n"),
    "containment_local_image_missing_or_declares_volumes",
  )
}

/// No host binds, Docker socket, published ports, host networking, privileged
/// mode, inherited env, healthcheck, pulls, restart policy or PID-sharing.
/// Trusted root PID1 retains only the two capabilities needed by the launcher
/// to switch the target to a distinct unprivileged UID with *zero* capabilities.
pub fn create_args(
  request: policy.Request,
  name: String,
  token: String,
  selftest: Bool,
) -> List(String) {
  let memory = int.to_string(request.limits.memory_mb) <> "m"
  let mode = case selftest {
    True -> "selftest"
    False -> "run"
  }
  [
    "create",
    "--name",
    name,
    "--interactive",
    "--pull",
    "never",
    "--network",
    "none",
    "--read-only",
    "--cap-drop",
    "ALL",
    "--cap-add",
    "SETUID",
    "--cap-add",
    "SETGID",
    "--security-opt",
    "no-new-privileges",
    "--user",
    "0:0",
    "--pids-limit",
    int.to_string(request.limits.pids),
    "--memory",
    memory,
    "--memory-swap",
    memory,
    "--cpus",
    "2",
    "--ulimit",
    "core=0:0",
    "--ulimit",
    "nofile=256:256",
    "--ipc",
    "private",
    "--cgroupns",
    "private",
    "--restart",
    "no",
    "--no-healthcheck",
    "--stop-timeout",
    "1",
    "--log-driver",
    "none",
    "--workdir",
    "/tmp",
    "--tmpfs",
    "/work:rw,nosuid,nodev,size="
      <> int.to_string(request.limits.work_mb)
      <> "m,uid=10001,gid=10001,mode=700",
    "--tmpfs",
    "/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777",
    "--entrypoint",
    "/usr/local/bin/erl",
    request.image,
    "-noshell",
    "-noinput",
    "+S",
    "1:1",
    "+A",
    "1",
    "-pa",
    "/boundary/mimic/ebin",
    "/boundary/gleam_stdlib/ebin",
    "/boundary/gleam_json/ebin",
    "/boundary/argv/ebin",
    "-eval",
    "mimic_containment_boot:boot().",
    "-extra",
    mode,
    request.image,
    int.to_string(request.limits.wall_ms),
    int.to_string(request.limits.lease_ms),
    int.to_string(request.limits.output_bytes),
    policy.port_argument(request.network.bind_ports),
    policy.port_argument(request.network.connect_ports),
    token,
    request.executable,
    ..request.args
  ]
}

pub fn create(
  backend: policy.Backend,
  plan: policy.Plan,
  selftest: Bool,
) -> Result(Container, String) {
  let request = policy.request(plan)
  let token = os.nonce()
  let name = "mimic-f02-" <> os.nonce()
  case invoke(backend, create_args(request, name, token, selftest)) {
    Ok(#(0, output)) -> {
      let id = string.trim(output)
      case valid_id(id) {
        True -> Ok(Container(backend, id, name, token, request))
        False -> {
          // A malformed/partial create result may still have created the name.
          use _ <- result.try(remove_name(backend, name))
          Error("containment_create_identity_invalid")
        }
      }
    }
    _ -> {
      use _ <- result.try(remove_name(backend, name))
      Error("containment_create_failed")
    }
  }
}

fn valid_id(id: String) -> Bool {
  string.length(id) == 64
  && list.all(string.to_graphemes(id), fn(char) {
    string.contains("0123456789abcdef", char)
  })
}

pub fn attach(container: Container) -> Result(os.Handle, String) {
  os.open(
    container.backend.executable,
    prefix(container.backend, [
      "start",
      "--attach",
      "--interactive",
      container.id,
    ]),
  )
}

/// The lease is renewed by the caller's process, never a detached watchdog.
/// If the whole parent VM dies, the pipe closes; if the CLI survives or EOF is
/// delayed, the in-container lease expires independently.
pub fn pump(
  handle: os.Handle,
  token: String,
  lease_ms: Int,
  deadline: Int,
) -> Result(#(Int, String), String) {
  pump_loop(handle, token, lease_ms, deadline, os.clock(), "", 0)
}

fn pump_loop(handle, token, lease_ms, deadline, next, output, bytes) {
  let now = os.clock()
  case now >= deadline {
    True -> {
      os.close(handle)
      Error("containment_host_deadline_exceeded")
    }
    False -> {
      let renewed = case now >= next {
        True -> os.send(handle, token <> "\n")
        False -> Ok(Nil)
      }
      case renewed {
        Error(error) -> {
          os.close(handle)
          Error(error)
        }
        Ok(_) -> {
          let next = case now >= next {
            True -> now + lease_ms / 4
            False -> next
          }
          case os.receive_event(handle, 25) {
            os.Data(data) -> {
              let size = bytes + string.byte_size(data)
              // JSON escaping may expand each captured byte to six characters.
              case size <= 6_400_000 {
                True ->
                  pump_loop(
                    handle,
                    token,
                    lease_ms,
                    deadline,
                    next,
                    output <> data,
                    size,
                  )
                False -> {
                  os.close(handle)
                  Error("containment_owner_output_exceeded")
                }
              }
            }
            os.Exited(code) -> {
              use output <- result.try(os.utf8(output))
              Ok(#(code, output))
            }
            os.Idle ->
              pump_loop(handle, token, lease_ms, deadline, next, output, bytes)
            _ -> {
              os.close(handle)
              Error("containment_attach_failed")
            }
          }
        }
      }
    }
  }
}

pub fn run_attached(container: Container) -> Result(protocol.Receipt, String) {
  use handle <- result.try(attach(container))
  use value <- result.try(pump(
    handle,
    container.token,
    container.request.limits.lease_ms,
    os.clock() + container.request.limits.wall_ms + 10_000,
  ))
  let #(code, output) = value
  use receipt <- result.try(protocol.decode(output, container.id))
  use _ <- result.try(require(
    code == receipt.code,
    "containment_owner_exit_mismatch",
  ))
  use _ <- result.try(stopped(container))
  Ok(receipt)
}

pub fn stopped(container: Container) -> Result(Nil, String) {
  use state <- result.try(
    invoke(container.backend, [
      "inspect", "--format", "{{.State.Running}} {{.State.Pid}}", container.id,
    ]),
  )
  require(state == #(0, "false 0\n"), "containment_namespace_stop_unverified")
}

pub fn wait_stopped(
  container: Container,
  deadline: Int,
) -> Result(Nil, String) {
  case stopped(container) {
    Ok(_) -> Ok(Nil)
    Error(_) ->
      case os.clock() >= deadline {
        True -> Error("containment_namespace_survived_parent_death")
        False -> {
          sleep(50)
          wait_stopped(container, deadline)
        }
      }
  }
}

@external(erlang, "timer", "sleep")
fn sleep(ms: Int) -> Nil

pub fn remove(container: Container) -> Result(Nil, String) {
  use result <- result.try(
    invoke(container.backend, ["rm", "--force", container.id]),
  )
  use _ <- result.try(require(
    result.0 == 0,
    "containment_cleanup_failed:" <> container.id,
  ))
  absent(container.backend, container.name)
}

fn remove_name(backend, name) {
  // Used only after uncertain create. A successful daemon listing distinguishes
  // absence from daemon failure; inspect's generic nonzero status does not.
  case absent(backend, name) {
    Ok(_) -> Ok(Nil)
    Error(_) -> {
      use removed <- result.try(invoke(backend, ["rm", "--force", name]))
      use _ <- result.try(require(
        removed.0 == 0,
        "containment_cleanup_failed:" <> name,
      ))
      absent(backend, name)
    }
  }
}

fn absent(backend, name) {
  use listed <- result.try(
    invoke(backend, [
      "container",
      "ls",
      "--all",
      "--quiet",
      "--filter",
      "name=^/" <> name <> "$",
    ]),
  )
  require(listed == #(0, ""), "containment_cleanup_unverified:" <> name)
}

/// Cleanup is authoritative, even when a target otherwise appeared successful.
pub fn finish(
  outcome: Result(a, String),
  cleanup: Result(Nil, String),
) -> Result(a, String) {
  case cleanup {
    Ok(_) -> outcome
    Error(error) -> Error(error)
  }
}

pub fn run(
  backend: policy.Backend,
  plan: policy.Plan,
  selftest: Bool,
) -> Result(protocol.Receipt, String) {
  use container <- result.try(create(backend, plan, selftest))
  let outcome = run_attached(container)
  finish(outcome, remove(container))
}

fn require(ok: Bool, error: String) -> Result(Nil, String) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
