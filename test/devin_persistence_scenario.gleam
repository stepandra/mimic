/// Two fresh BEAM invocations share only an explicit private synthetic state
/// directory. Never run this against an operator credential directory.
import argv
import gleam/io
import gleam/list
import gleam/option.{None}
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/providers/contracts as c

pub fn main() {
  case argv.load().arguments {
    ["seed", path] -> {
      let assert Ok(store) = storage.new(path)
      list.each(["a", "b"], fn(account) {
        let key = credentials.key("devin", "session_token", account)
        let assert Error(_) = runtime_store.load(store, key)
        let assert Ok(_) = runtime_store.save(store, key, material(account))
      })
      io.println(
        "{\"scope\":\"devin_permanent_session_restart\",\"synthetic\":true,\"phase\":\"seed\",\"live_verified\":false}",
      )
    }
    ["restore", path] -> {
      let assert Ok(store) = storage.new(path)
      list.each(["a", "b"], fn(account) {
        let key = credentials.key("devin", "session_token", account)
        let assert Ok(loaded) = runtime_store.load(store, key)
        let assert True = loaded == material(account)
        let assert Ok(runtime_store.Metadata("session_token", None)) =
          runtime_store.metadata(store, key)
        let assert Ok(runtime_store.Ready) =
          runtime_store.refresh_status(store, key)
      })
      io.println(
        "{\"scope\":\"devin_permanent_session_restart\",\"synthetic\":true,\"phase\":\"restore\",\"accounts_isolated\":true,\"reseeded\":false,\"expiry_invented\":false,\"live_verified\":false}",
      )
    }
    _ ->
      panic as "expected seed|restore and explicit synthetic private state directory"
  }
}

fn material(account: String) -> c.AuthMaterial {
  c.SessionToken("synthetic-restart-" <> account, [
    #("user_id", "synthetic-user-" <> account),
  ])
}
