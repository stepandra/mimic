/// Foreground device enrollment. Credentials persist only through runtime_store;
/// the runtime remains the sole refresh scheduler and authoritative store.
import gleam/erlang/process
import gleam/int
import gleam/result
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/gateway/refresh
import mimic/ir
import mimic/providers/kimi/oauth

pub fn kimi(
  config: oauth.Config,
  store: storage.Store,
  key: String,
  identity: ir.Value,
  announce: fn(String) -> Nil,
) -> Result(Nil, String) {
  use device <- result.try(ir.string_field(identity, "device_id"))
  let config = oauth.Config(..config, device_id: device)
  use pending <- result.try(oauth.start(config, refresh.kimi, now_ms()))
  let prompt = oauth.user_prompt(pending)
  announce("Open " <> prompt.1 <> " and authorize code " <> prompt.0)
  poll(
    config,
    pending,
    store,
    key,
    monotonic_ms(Millisecond) + oauth.max_poll_ms,
  )
}

fn poll(
  config: oauth.Config,
  pending: oauth.Device,
  store: storage.Store,
  key: String,
  deadline: Int,
) -> Result(Nil, String) {
  let remaining = deadline - monotonic_ms(Millisecond)
  case remaining <= 0 {
    True -> Error("Kimi enrollment timed out")
    False -> {
      use next <- result.try(oauth.poll(
        config,
        pending,
        refresh.kimi,
        now_ms(),
        False,
      ))
      case next {
        oauth.Pending(next, wait) -> {
          process.sleep(int.min(remaining, wait))
          poll(config, next, store, key, deadline)
        }
        oauth.Authorized(credential) -> {
          use material <- result.try(oauth.material(config, credential))
          runtime_store.save(store, key, material)
          |> result.replace_error("Kimi credential persistence failed")
        }
      }
    }
  }
}

type Unit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_ms(unit: Unit) -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
