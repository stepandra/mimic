import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/auth
import mimic/auth/storage
import mimic/ingress/keys
import mimic/management
import mimic/persona
import mimic/quota
import mimic/workshop

/// All three directories are explicit operator configuration. Credentials use
/// the private auth store; immutable reports and key hashes never share it.
pub fn backend(
  state_dir: String,
  auth_dir: String,
  key_dir: String,
) -> Result(management.Backend, String) {
  use store <- result.try(storage.new(auth_dir))
  Ok(
    management.Backend(
      create_persona: fn(_provider, content) {
        use profile <- result.try(persona.parse(content))
        case persona.lint(profile) {
          [] -> workshop.artifact(state_dir, content)
          _ -> Error("persona draft failed lint")
        }
      },
      active_persona: fn(provider) { workshop.pointer(state_dir, provider) },
      promote: fn(run_id, signature) {
        workshop.promote(state_dir, run_id, signature)
        |> result.map(fn(_) { Nil })
      },
      credentials: fn() {
        auth.list_metadata(store)
        |> result.map(fn(entries) {
          list.map(entries, fn(entry) {
            management.CredentialMetadata(entry.id, entry.expires_at_ms)
          })
        })
      },
      create_credential: fn(input) {
        auth.save(
          store,
          input.id,
          auth.Credential(
            input.access_token,
            input.refresh_token,
            input.expires_at_ms,
          ),
        )
      },
      delete_credential: fn(id) { auth.delete(store, id) },
      keys: fn() {
        keys.list_metadata(key_dir)
        |> result.map(fn(entries) { list.map(entries, fn(entry) { entry.id }) })
      },
      create_key: fn(id, secret) { keys.create(key_dir, id, secret) },
      delete_key: fn(id) { keys.revoke(key_dir, id) },
      quotas: fn() { quota_metrics(store) },
      drift: fn() { drift_metrics(state_dir) },
    ),
  )
}

fn quota_metrics(store: storage.Store) -> Result(List(#(String, Int)), String) {
  use ledger <- result.try(quota.load_or_empty(store))
  Ok(
    list.flat_map(ledger.entries, fn(entry) {
      [
        #(entry.credential_id <> ":cooldown_until_ms", entry.cooldown_until_ms),
        ..list.filter_map(entry.windows, fn(window) {
          case window.reset_at_ms {
            Some(reset) ->
              Ok(#(
                entry.credential_id <> ":" <> window.name <> ":reset_at_ms",
                reset,
              ))
            None -> Error(Nil)
          }
        })
      ]
    }),
  )
}

/// A typed index of drift report IDs, not a generic artifact listing. Stage
/// adapters call this only after storing an actual structured differ report.
pub fn record_drift(
  state_dir: String,
  report_id: String,
) -> Result(Nil, String) {
  use _ <- result.try(report_count(state_dir, report_id))
  put_drift(state_dir, report_id)
}

fn report_count(state_dir: String, id: String) -> Result(Int, String) {
  use content <- result.try(workshop.read_artifact(state_dir, id))
  let decoder = {
    use changes <- decode.field("changes", decode.list(decode.dynamic))
    decode.success(list.length(changes))
  }
  json.parse(content, decoder)
  |> result.map_error(fn(_) { "indexed artifact is not a drift report" })
}

fn drift_metrics(state_dir: String) -> Result(List(#(String, Int)), String) {
  use ids <- result.try(list_drift(state_dir))
  list.try_map(ids, fn(id) {
    report_count(state_dir, id)
    |> result.map(fn(count) { #(id, count) })
  })
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["serve", state_dir] -> serve(state_dir, state_dir, state_dir, 9090)
    ["serve", state_dir, port] -> {
      use port <- result.try(
        int.parse(port)
        |> result.map_error(fn(_) { "management port must be an integer" }),
      )
      serve(state_dir, state_dir, state_dir, port)
    }
    ["serve", state_dir, auth_dir, key_dir] ->
      serve(state_dir, auth_dir, key_dir, 9090)
    ["serve", state_dir, auth_dir, key_dir, port] -> {
      use port <- result.try(
        int.parse(port)
        |> result.map_error(fn(_) { "management port must be an integer" }),
      )
      serve(state_dir, auth_dir, key_dir, port)
    }
    _ ->
      Error(
        "usage: mimic management serve <private-state-dir> [port]\n"
        <> "       mimic management serve <workshop-state> <private-auth-dir> <key-state-dir> [port]\n"
        <> "Supply MIMIC_MANAGEMENT_KEY through the environment (at least 32 characters).",
      )
  }
}

fn serve(
  state_dir: String,
  auth_dir: String,
  key_dir: String,
  port: Int,
) -> Result(String, String) {
  case port < 1 || port > 65_535 {
    True -> Error("management port must be between 1 and 65535")
    False -> {
      use backend <- result.try(backend(state_dir, auth_dir, key_dir))
      management.serve_with(port, backend)
    }
  }
}

@external(erlang, "mimic_control_ffi", "put_drift")
fn put_drift(directory: String, id: String) -> Result(Nil, String)

@external(erlang, "mimic_control_ffi", "list_drift")
fn list_drift(directory: String) -> Result(List(String), String)
