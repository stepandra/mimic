import argv
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/containment/lifecycle
import mimic/containment/os
import mimic/containment/policy
import mimic/containment/protocol

const launcher = "/containment/launch"

/// Only the dedicated `mimic_containment_boot` executable owns VM shutdown.
/// Feature modules return; they never halt a user's VM.
pub fn boot() -> #(Int, String) {
  case run(argv.load().arguments) {
    Ok(#(code, reason, output)) ->
      case os.utf8(output) {
        Ok(output) -> #(code, protocol.encode(code, reason, output))
        Error(_) -> #(
          126,
          protocol.encode(126, "unsupported_binary_output", ""),
        )
      }
    Error(error) -> #(126, protocol.encode(126, error, ""))
  }
}

fn run(args: List(String)) -> Result(#(Int, String, String), String) {
  use _ <- result.try(os.owner_boundary())
  use parsed <- result.try(parse(args))
  let #(plan, token, selftest) = parsed
  // The absence of a port-filtering primitive must block BEFORE target spawn.
  // setpriv's filesystem-only Landlock support does not meet this contract.
  use checked <- result.try(
    os.command(launcher, ["--check"], 1500, 128)
    |> result.map_error(fn(_) {
      "containment_tcp_filesystem_launcher_unavailable"
    }),
  )
  use _ <- result.try(case checked {
    #(0, "mimic.containment-launch/v1\n") -> Ok(Nil)
    _ -> Error("containment_tcp_filesystem_launcher_unavailable")
  })
  use _ <- result.try(case selftest {
    True -> os.fixtures()
    False -> Ok(Nil)
  })
  let request = policy.request(plan)
  use _ <- result.try(os.record_boundary(
    "mimic.containment/v1 bind="
    <> policy.port_argument(request.network.bind_ports)
    <> " connect="
    <> policy.port_argument(request.network.connect_ports)
    <> "\n",
  ))
  use input <- result.try(os.stdin())
  let state =
    lifecycle.initial(
      os.clock(),
      request.limits.wall_ms,
      request.limits.lease_ms,
    )
  Ok(loop(request, token, input, None, state, ""))
}

fn parse(args) {
  case args {
    [mode, image, wall, lease, output, bind, connect, token, executable, ..args] -> {
      use wall <- result.try(integer(wall))
      use lease <- result.try(integer(lease))
      use output <- result.try(integer(output))
      use bind <- result.try(ports(bind))
      use connect <- result.try(ports(connect))
      use _ <- result.try(case mode == "run" || mode == "selftest" {
        True -> Ok(Nil)
        False -> Error("containment_owner_mode_invalid")
      })
      use _ <- result.try(
        case
          string.length(token) == 48
          && list.all(string.to_graphemes(token), fn(char) {
            string.contains("0123456789abcdef", char)
          })
        {
          True -> Ok(Nil)
          False -> Error("containment_owner_lease_invalid")
        },
      )
      use plan <- result.try(
        policy.authorize(policy.Request(
          image,
          executable,
          args,
          policy.Network(bind, connect),
          policy.Limits(
            ..policy.default_limits(),
            wall_ms: wall,
            lease_ms: lease,
            output_bytes: output,
          ),
        )),
      )
      Ok(#(plan, token, mode == "selftest"))
    }
    _ -> Error("containment_owner_arguments_invalid")
  }
}

fn integer(text) {
  int.parse(text)
  |> result.map_error(fn(_) { "containment_owner_integer_invalid" })
}

fn ports(text) {
  case text {
    "-" -> Ok([])
    _ -> text |> string.split(",") |> list.try_map(integer)
  }
}

fn launch(request: policy.Request) -> Result(os.Handle, String) {
  os.open(launcher, [
    "--bind-ports",
    policy.port_argument(request.network.bind_ports),
    "--connect-ports",
    policy.port_argument(request.network.connect_ports),
    "--cpu-seconds",
    "40",
    "--file-bytes",
    "8388608",
    "--no-files",
    "256",
    "--",
    request.executable,
    ..request.args
  ])
}

fn loop(
  request: policy.Request,
  token: String,
  input: os.Handle,
  target: Option(os.Handle),
  state: lifecycle.State,
  output: String,
) -> #(Int, String, String) {
  let #(event, output) =
    target_event(target, output, request.limits.output_bytes)
  let event = case event {
    lifecycle.Tick ->
      case os.receive_event(input, 25) {
        os.Data(line) ->
          case line == token {
            True -> lifecycle.Renew
            False -> lifecycle.InputClosed
          }
        os.Idle -> lifecycle.Tick
        _ -> lifecycle.InputClosed
      }
    _ -> event
  }
  let #(state, action) =
    lifecycle.step(state, event, os.clock(), request.limits.lease_ms)
  case action {
    lifecycle.ExitNamespace(reason) -> {
      // Do NOT wait for descendants or a process group. Returning boot's code
      // causes PID1 to exit, and Linux kills every task in this PID namespace.
      #(lifecycle.exit_code(reason), reason_name(reason), output)
    }
    lifecycle.SpawnTarget ->
      case launch(request) {
        Ok(handle) -> loop(request, token, input, Some(handle), state, output)
        Error(_) -> #(126, "launch_failed", "")
      }
    lifecycle.Wait -> loop(request, token, input, target, state, output)
  }
}

fn target_event(target, output, limit) {
  case target {
    None -> #(lifecycle.Tick, output)
    Some(handle) ->
      case os.receive_event(handle, 0) {
        os.Data(data) ->
          case string.byte_size(output) + string.byte_size(data) <= limit {
            True -> #(lifecycle.Tick, output <> data)
            False -> #(lifecycle.OutputLimit, "")
          }
        os.Exited(code) -> #(lifecycle.LeaderDone(code), output)
        os.Idle -> #(lifecycle.Tick, output)
        _ -> #(lifecycle.LaunchError, "")
      }
  }
}

fn reason_name(reason: lifecycle.StopReason) -> String {
  case reason {
    lifecycle.LeaderExited(_) -> "leader_exited"
    lifecycle.ParentGone -> "parent_gone"
    lifecycle.LeaseExpired -> "lease_expired"
    lifecycle.DeadlineExceeded -> "deadline_exceeded"
    lifecycle.OutputExceeded -> "output_exceeded"
    lifecycle.LaunchFailed -> "launch_failed"
  }
}
