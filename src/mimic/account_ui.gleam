/// The loopback operator panel enrolls configured Kimi, Codex and Grok accounts
/// into the existing gateway runtime store. It neither starts another gateway
/// runtime nor owns refresh. No token/identity/session value is accepted in argv.
import argv
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import mimic/account_ui/coordinator
import mimic/account_ui/enrollment_adapters as adapters
import mimic/account_ui/http
import mimic/account_ui/primitives as os
import mimic/auth/crypto
import mimic/auth/storage
import mimic/gateway
import mimic/gateway/config
import mimic/ir
import mimic/providers/kimi/json_guard as strict_json
import mimic/providers/kimi/oauth
import mist

/// A bounded operator roster, one session and one active enrollment per server.
pub const max_accounts = 64

pub opaque type Server {
  Server(
    port: Int,
    listener: process.Pid,
    coordinator: coordinator.Coordinator,
    bootstrap_path: String,
    lifecycle: process.Pid,
  )
}

pub fn port(server: Server) -> Int {
  server.port
}

/// The returned path contains no secret. The one-time code is read locally
/// from this newly-created 0600 file; never print its contents.
pub fn bootstrap_path(server: Server) -> String {
  server.bootstrap_path
}

pub fn start(
  settings: config.Config,
  private_identity_path: String,
  listen_port: Int,
) -> Result(Server, String) {
  start_with_transport(
    settings,
    private_identity_path,
    listen_port,
    adapters.production_transports().kimi,
  )
}

/// Synthetic Kimi test seam only. Production CLI uses approved transports.
/// Injection does not bypass endpoint, identity, session or S5 store validation.
pub fn start_with_transport(
  settings: config.Config,
  private_identity_path: String,
  listen_port: Int,
  send: oauth.Send,
) -> Result(Server, String) {
  start_with_transports(
    settings,
    private_identity_path,
    listen_port,
    adapters.with_kimi(adapters.production_transports(), send),
  )
}

/// Synthetic multi-provider seam, preserving the recovered F05/F06 APIs.
pub fn start_with_transports(
  settings: config.Config,
  private_identity_path: String,
  listen_port: Int,
  transports: adapters.Transports,
) -> Result(Server, String) {
  use _ <- result.try(case listen_port > 0 && listen_port < 65_536 {
    True -> Ok(Nil)
    False -> Error("invalid loopback operator port")
  })
  use store <- result.try(
    storage.new(settings.state_dir)
    |> result.replace_error("private gateway state directory required"),
  )
  let accounts = list.filter(settings.accounts, adapters.supported)
  use _ <- result.try(case list.is_empty(accounts) {
    True ->
      Error(
        "at least one explicitly configured supported OAuth account required",
      )
    False -> Ok(Nil)
  })
  use _ <- result.try(
    case
      list.length(accounts) <= max_accounts
      && list.length(list.unique(list.map(accounts, fn(a) { a.id })))
      == list.length(accounts)
      && list.all(accounts, fn(a) {
        string.byte_size(a.id) > 0 && string.byte_size(a.id) <= 256
      })
    {
      True -> Ok(Nil)
      False -> Error("bounded unique account roster required (maximum 64)")
    },
  )
  use identity <- result.try(
    case list.any(accounts, fn(a) { a.provider == "kimi" }) {
      True -> device_identity(private_identity_path)
      False -> Ok("")
    },
  )
  use _ <- result.try(
    list.try_each(accounts, fn(account) {
      adapters.validate(account, identity, listen_port)
    }),
  )
  let name = "account-ui-bootstrap-" <> crypto.random_url_token() <> ".txt"
  let token = crypto.random_url_token()
  use _ <- result.try(
    os.create_private(store.directory, name, token)
    |> result.replace_error("cannot create private operator bootstrap"),
  )
  case
    coordinator.start_with_transports_clock(
      store,
      accounts,
      identity,
      transports,
      name,
      token,
      coordinator.default_limits(),
      os.monotonic_ms,
    )
  {
    Error(error) -> {
      let _ = os.remove_private(store.directory, name, token)
      Error(error)
    }
    Ok(engine) -> {
      let ready = process.new_subject()
      let builder =
        mist.new(fn(req) { http.handle(req, engine, listen_port) })
        |> mist.bind("127.0.0.1")
        |> mist.port(listen_port)
        |> mist.after_start(fn(actual, _, _) { process.send(ready, actual) })
      case mist.start(builder) {
        Error(_) -> {
          let _ = coordinator.stop(engine)
          Error("loopback operator listener failed")
        }
        Ok(listener) -> {
          process.unlink(listener.pid)
          case process.receive(ready, 5000) {
            Error(_) -> {
              process.send_exit(listener.pid)
              let _ = coordinator.stop(engine)
              Error("loopback operator listener unavailable")
            }
            Ok(actual) -> {
              let owner = process.self()
              let lifecycle =
                process.spawn_unlinked(fn() {
                  watch(
                    owner,
                    listener.pid,
                    engine,
                    store.directory,
                    name,
                    token,
                  )
                })
              Ok(Server(
                actual,
                listener.pid,
                engine,
                store.directory <> "/" <> name,
                lifecycle,
              ))
            }
          }
        }
      }
    }
  }
}

fn watch(
  owner: process.Pid,
  listener: process.Pid,
  engine: coordinator.Coordinator,
  directory: String,
  name: String,
  token: String,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(process.monitor(owner), fn(_) { Nil })
    |> process.select_specific_monitor(process.monitor(listener), fn(_) { Nil })
    |> process.select_specific_monitor(
      process.monitor(coordinator.pid(engine)),
      fn(_) { Nil },
    )
  let _ = process.selector_receive_forever(selector)
  let _ = coordinator.stop(engine)
  process.send_exit(listener)
  // Exact comparison never deletes an operator-replaced file.
  let _ = os.remove_private(directory, name, token)
  Nil
}

pub fn stop(server: Server) -> Result(Nil, String) {
  let monitor = process.monitor(server.lifecycle)
  let stopped = coordinator.stop(server.coordinator)
  process.send_exit(server.listener)
  // Join the lifecycle cleanup before main returns and the CLI VM can halt.
  // Otherwise an unlinked bootstrap mutation could strand its filesystem guard.
  let joined =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(12_000)
  process.demonitor_process(monitor)
  use _ <- result.try(stopped)
  joined |> result.replace_error("operator lifecycle cleanup unconfirmed")
}

fn device_identity(path: String) -> Result(String, String) {
  use bytes <- result.try(
    os.private_read(path)
    |> result.replace_error("regular private 0600 identity file required"),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error("invalid private identity"),
  )
  use _ <- result.try(case string.byte_size(text) <= 2048 {
    True -> Ok(Nil)
    False -> Error("private identity too large")
  })
  use value <- result.try(
    strict_json.parse(text) |> result.replace_error("invalid private identity"),
  )
  case value {
    ir.Object([#("device_id", ir.String(device))]) ->
      case string.byte_size(device) > 0 && string.byte_size(device) <= 1024 {
        True -> Ok(device)
        False -> Error("invalid private device identity")
      }
    _ ->
      Error("private identity must contain only the existing device_id field")
  }
}

/// Minimal root admission: ["accounts", "ui", ..rest] -> account_ui.cli(rest).
/// The port is explicit; there is no proposed/default 9091 service.
pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    // Codex/Grok rosters need no Kimi device identity file. A roster containing
    // Kimi still fails closed in device_identity before any enrollment I/O.
    ["serve", path, raw_port] -> cli(["serve", path, "", raw_port])
    ["serve", path, private_identity_path, raw_port] -> {
      use port <- result.try(
        int.parse(raw_port) |> result.replace_error("invalid operator port"),
      )
      use _ <- result.try(
        case port > 0 && port < 65_536 && int.to_string(port) == raw_port {
          True -> Ok(Nil)
          False -> Error("explicit numeric loopback operator port required")
        },
      )
      use settings <- result.try(gateway.load(path))
      use _ <- result.try(os.install_signal())
      case start(settings, private_identity_path, port) {
        Error(error) -> {
          os.restore_signal()
          Error(error)
        }
        Ok(server) -> {
          io.println(
            "MIMIC account operator UI: http://127.0.0.1:"
            <> int.to_string(server.port),
          )
          io.println(
            "One-time operator code file (0600): " <> server.bootstrap_path,
          )
          let outcome = os.await_signal()
          let stopped = stop(server)
          os.restore_signal()
          use _ <- result.try(outcome)
          use _ <- result.try(stopped)
          Ok("Account operator UI stopped")
        }
      }
    }
    _ -> Error("usage: accounts ui serve CONFIG [PRIVATE_DEVICE_IDENTITY] PORT")
  }
}

/// Independent root-equivalent entrypoint until coordinator root dispatch.
/// Feature code never exits the VM or accepts credentials in argv.
pub fn main() -> Nil {
  let outcome = case argv.load().arguments {
    ["accounts", "ui", ..args] -> cli(args)
    args -> cli(args)
  }
  case outcome {
    Ok(message) -> io.println(message)
    Error(message) -> io.println_error("mimic: " <> message)
  }
}
