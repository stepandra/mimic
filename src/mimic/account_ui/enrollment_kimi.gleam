/// Recovered F05 device flow behind the common enrollment adapter.
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import mimic/account_ui/enrollment
import mimic/account_ui/primitives as os
import mimic/ir
import mimic/providers/contracts.{type AuthMaterial}
import mimic/providers/kimi/json_guard
import mimic/providers/kimi/oauth

pub fn adapter(config: oauth.Config, send: oauth.Send) -> enrollment.Adapter {
  enrollment.Adapter(fn(emit, deadline, clock) {
    enroll(config, send, emit, deadline, clock)
  })
}

fn enroll(
  config: oauth.Config,
  send: oauth.Send,
  emit: enrollment.Emit,
  deadline: Int,
  clock: enrollment.Clock,
) -> Result(AuthMaterial, String) {
  let observed = process.new_subject()
  let start_ms = clock()
  use device <- result.try(
    oauth.start(
      config,
      fn(plan) {
        use reply <- result.try(send(plan))
        // Keep only the expiry, not the private device code.
        let seconds =
          json_guard.parse(reply.body)
          |> result.try(fn(value) { ir.required(value, "expires_in") })
          |> result.try(ir.as_int)
          |> result.unwrap(0)
        process.send(observed, seconds)
        Ok(reply)
      },
      os.epoch_ms(),
    )
    |> result.replace_error("failed"),
  )
  use seconds <- result.try(
    process.receive(observed, 0) |> result.replace_error("failed"),
  )
  let deadline =
    int.min(deadline, start_ms + int.min(seconds * 1000, oauth.max_poll_ms))
  use _ <- result.try(case clock() < deadline {
    True -> Ok(Nil)
    False -> Error("expired")
  })
  let #(code, uri) = oauth.user_prompt(device)
  use _ <- result.try(
    case string.byte_size(code) <= 256 && string.byte_size(uri) <= 2048 {
      True -> Ok(Nil)
      False -> Error("failed")
    },
  )
  emit(Some(enrollment.DeviceCode(code, uri)), deadline)
  poll(config, device, send, deadline, clock)
}

fn poll(
  config: oauth.Config,
  device: oauth.Device,
  send: oauth.Send,
  deadline: Int,
  clock: enrollment.Clock,
) -> Result(AuthMaterial, String) {
  case clock() >= deadline {
    True -> Error("expired")
    False -> {
      use next <- result.try(
        oauth.poll(config, device, send, os.epoch_ms(), False)
        |> result.map_error(fn(error) {
          case error {
            "Kimi device authorization expired" -> "expired"
            "Kimi device authorization denied" -> "denied"
            _ -> "failed"
          }
        }),
      )
      case next {
        oauth.Pending(device, wait) -> {
          process.sleep(int.min(250, wait))
          poll(config, device, send, deadline, clock)
        }
        oauth.Authorized(credential) ->
          case clock() < deadline {
            True ->
              oauth.material(config, credential)
              |> result.replace_error("failed")
            False -> Error("expired")
          }
      }
    }
  }
}
