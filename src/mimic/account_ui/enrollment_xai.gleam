/// Grok Build device authorization, under the existing coordinator/S5 ticket.
/// No manager, credential record, browser secret or ambient endpoint is added.
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/account_ui/enrollment
import mimic/account_ui/primitives as os
import mimic/providers/contracts.{type AuthMaterial}
import mimic/providers/xai/bridge
import mimic/providers/xai/enrollment as configured
import mimic/providers/xai/oauth

pub fn adapter(config: oauth.Config, send: oauth.Send) -> enrollment.Adapter {
  enrollment.Adapter(fn(emit, deadline, clock) {
    use _ <- result.try(
      configured.validate(config) |> result.replace_error("failed"),
    )
    use _ <- result.try(before(deadline, clock))
    use discovery <- result.try(
      oauth.discover(config, send) |> result.replace_error("failed"),
    )
    use _ <- result.try(
      configured.validate_endpoint(discovery.device_endpoint, config.policy)
      |> result.replace_error("failed"),
    )
    use _ <- result.try(
      configured.validate_endpoint(discovery.token_endpoint, config.policy)
      |> result.replace_error("failed"),
    )
    use _ <- result.try(before(deadline, clock))
    use device <- result.try(
      oauth.start(config, discovery, send, clock())
      |> result.replace_error("failed"),
    )
    let deadline = int.min(deadline, oauth.device_deadline(device))
    use _ <- result.try(before(deadline, clock))
    let #(code, uri) = oauth.user_prompt(device)
    use _ <- result.try(
      case string.byte_size(code) <= 256 && string.byte_size(uri) <= 2048 {
        True -> Ok(Nil)
        False -> Error("failed")
      },
    )
    emit(Some(enrollment.DeviceCode(code, uri)), deadline)
    poll(config, discovery, device, send, emit, deadline, clock)
  })
}

fn before(deadline: Int, clock: enrollment.Clock) -> Result(Nil, String) {
  case clock() < deadline {
    True -> Ok(Nil)
    False -> Error("expired")
  }
}

fn poll(
  config: oauth.Config,
  discovery: oauth.Discovery,
  device: oauth.Device,
  send: oauth.Send,
  emit: enrollment.Emit,
  deadline: Int,
  clock: enrollment.Clock,
) -> Result(AuthMaterial, String) {
  use _ <- result.try(before(deadline, clock))
  use step <- result.try(
    oauth.poll_at(config, device, send, clock(), os.epoch_ms(), False)
    |> result.map_error(fn(error) {
      case error {
        "xAI device authorization expired" -> "expired"
        "xAI device authorization denied" -> "denied"
        _ -> "failed"
      }
    }),
  )
  use _ <- result.try(before(deadline, clock))
  case step {
    oauth.Pending(next, wait) -> {
      process.sleep(int.max(0, int.min(250, int.min(wait, deadline - clock()))))
      poll(config, discovery, next, send, emit, deadline, clock)
    }
    oauth.Authorized(credential) -> {
      emit(None, deadline)
      bridge.oauth_material(config, discovery, credential)
      |> result.replace_error("failed")
    }
  }
}
