import argv
import gleam/int
import gleam/io
import gleam/result
import mimic/containment/docker
import mimic/containment/os
import mimic/containment/policy

/// Synthetic fault-test coordinator only. It starts no target on the host.
/// A separate VM is essential: killing a BEAM process is not parent SIGKILL.
pub fn boot() -> Int {
  case argv.load().arguments {
    [executable, socket, id, token, lease, wall, mode] ->
      case run(executable, socket, id, token, lease, wall, mode) {
        Ok(#(code, output)) -> {
          io.print(output)
          code
        }
        Error(_) -> 126
      }
    _ -> 126
  }
}

fn run(executable, socket, id, token, lease, wall, mode) {
  let backend = policy.Backend(executable, socket)
  use _ <- result.try(policy.validate_backend(backend))
  use lease <- result.try(
    int.parse(lease) |> result.map_error(fn(_) { "invalid_lease" }),
  )
  use wall <- result.try(
    int.parse(wall) |> result.map_error(fn(_) { "invalid_wall" }),
  )
  use handle <- result.try(os.open(
    executable,
    docker.prefix(backend, ["start", "--attach", "--interactive", id]),
  ))
  case mode {
    "pump" -> docker.pump(handle, token, lease, os.clock() + wall + 10_000)
    "lease_expired" -> {
      // Keep the attachment/pipe alive, but stop renewing. This distinguishes
      // actual lease expiry from mere stdin EOF propagation.
      use _ <- result.try(os.send(handle, token <> "\n"))
      os.wait(handle, wall + 10_000, 100_000)
    }
    _ -> {
      os.close(handle)
      Error("invalid_companion_mode")
    }
  }
}
