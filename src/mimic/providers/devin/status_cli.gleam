/// Authenticated LOCAL operator CLI. Ordinary ingress key + local config/file
/// possession, not an elevated admin role, HTTP route or live dashboard.
import gleam/list
import gleam/result
import mimic/auth/storage
import mimic/gateway
import mimic/gateway/config
import mimic/ingress/keys
import mimic/providers/devin/status_gateway as status
import mimic/providers/devin/status_observation as observation
import mimic/providers/registry
import mimic/providers/runtime

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [path, account] -> {
      use settings <- result.try(
        gateway.load(path)
        |> result.replace_error("Devin status configuration unavailable"),
      )
      use secret <- result.try(
        environment("MIMIC_INGRESS_KEY")
        |> result.replace_error("Devin status unauthorized"),
      )
      run(settings, account, secret)
    }
    _ ->
      Error(
        "Usage: providers status <config> <account-id>; "
        <> "authenticate with MIMIC_INGRESS_KEY; configured loopback Devin only",
      )
  }
}

/// Verify BEFORE account selection, store creation, runtime or credential
/// acquisition. Never put `operator_key` in argv, captures or diagnostics.
pub fn run(
  settings: config.Config,
  account_id: String,
  operator_key: String,
) -> Result(String, String) {
  use _ <- result.try(case keys.verify(settings.state_dir, operator_key) {
    Ok(True) -> Ok(Nil)
    _ -> Error("Devin status unauthorized")
  })
  use account <- result.try(
    case
      config.runtime_accounts(settings)
      |> list.filter(fn(account) { account.id == account_id })
    {
      [account] -> Ok(account)
      _ -> Error("Devin status account is not uniquely configured")
    },
  )
  use scope <- result.try(status.scope(account))
  use store <- result.try(
    storage.new(settings.state_dir)
    |> result.replace_error("Devin status store unavailable"),
  )
  use registered <- result.try(
    registry.new([status.registration(scope)])
    |> result.replace_error("Devin status registry unavailable"),
  )
  use engine <- result.try(
    runtime.start(store, registered, [
      runtime.Account(..account, models: [status.registration(scope).id]),
    ])
    |> result.replace_error(
      "Devin status store busy or unavailable; existing gateway is not stopped",
    ),
  )
  let outcome =
    status.fetch(engine, scope, fn(_) { Nil })
    |> result.map(observation.to_json)
    |> result.map_error(status.message)
  use _ <- result.try(
    runtime.stop(engine) |> result.replace_error("Devin status cleanup failed"),
  )
  outcome
}

@external(erlang, "mimic_auth_ffi", "get_env")
fn environment(name: String) -> Result(String, String)
