/// Test-only boot of the actual assembled ingress and credential store.
/// Never replaced with an echo implementation. Synthetic values only.
import argv
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/string
import mimic/auth
import mimic/auth/storage
import mimic/ingress
import simplifile

@external(erlang, "mimic_parity_ffi", "pid")
fn pid() -> String

pub fn main() {
  let assert [phase, directory, origin] = argv.load().arguments
  let assert True = string.starts_with(origin, "http://127.0.0.1:")
  let assert Ok(store) = storage.new(directory)
  let first =
    auth.Credential(
      "synthetic-upstream-a",
      "synthetic-refresh-a",
      9_999_999_999_999,
    )
  let second =
    auth.Credential(
      "synthetic-upstream-b",
      "synthetic-refresh-b",
      9_999_999_999_999,
    )
  let marker = directory <> "/test-process-id"
  case phase {
    "exercise" -> {
      let assert Error(_) = simplifile.read(marker)
      let assert Ok(_) = auth.save(store, "synthetic-a", first)
      let assert Ok(_) = auth.save(store, "synthetic-b", second)
      let assert Ok(_) = simplifile.write(marker, pid())
      Nil
    }
    "restart" -> {
      let assert Ok(old_pid) = simplifile.read(marker)
      let assert True = old_pid != pid()
      // Deliberately no auth.save in this branch.
      Nil
    }
    _ -> panic as "unknown parity phase"
  }
  let assert Ok(a) = auth.load(store, "synthetic-a")
  let assert Ok(b) = auth.load(store, "synthetic-b")
  let assert True = a == first && b == second && a != b
  let assert Ok(port) =
    ingress.start(0, origin, "synthetic-client-key", a.access_token)
  json.object([
    #("port", json.int(port)),
    #("pid", json.string(pid())),
    #("persisted_credentials", json.bool(True)),
    #("credential_values_isolated", json.bool(True)),
    #("fresh_process_no_reseed", json.bool(True)),
  ])
  |> json.to_string
  |> io.println
  process.sleep_forever()
}
