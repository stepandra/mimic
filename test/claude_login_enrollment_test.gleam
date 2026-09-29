/// Synthetic login race regression. Only the callback listener uses a socket;
/// token exchange is injected and never contacts an account/provider.
import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import gleeunit/should
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ir
import mimic/providers/claude/login
import mimic/providers/claude/oauth
import mimic/providers/contracts

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_auth_test_ffi", "free_port")
fn free_port() -> Int

type Mutation {
  Replace
  SameValue
  Delete
  InsertDelete
}

type Stage {
  AwaitingCallback
  Exchanging
}

pub fn main() {
  admin_mutation_defeats_pending_login_test()
  successful_first_and_existing_login_test()
  failure_cancels_only_its_ticket_preserving_existing_gate_test()
  failed_begin_never_announces_or_exchanges_test()
  io.println("PASS: Claude enrollment snapshot/admin-mutation matrix")
}

pub fn admin_mutation_defeats_pending_login_test() {
  let outcomes =
    list.flat_map([AwaitingCallback, Exchanging], fn(stage) {
      [
        #(True, Replace),
        #(True, SameValue),
        #(True, Delete),
        #(False, Replace),
        #(False, Delete),
        #(False, InsertDelete),
      ]
      |> list.map(fn(case_) { run_race(case_.0, case_.1, stage) })
    })
  // Boolean-only failure output: never render a grant or pending verifier.
  outcomes |> should.equal(list.repeat(#(True, True), 12))
}

fn old() {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-old",
        "synthetic-old-refresh",
        9_000_000_000_000,
      ),
      [
        #("device_id", string.repeat("a", 64)),
        #("account_uuid", "synthetic-account"),
      ],
    ),
  )
}

fn replacement() {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-admin",
        "synthetic-admin-refresh",
        9_000_000_000_000,
      ),
      [
        #("device_id", string.repeat("a", 64)),
        #("account_uuid", "synthetic-account"),
      ],
    ),
  )
}

fn mutate(store, key, mutation) {
  case mutation {
    Replace -> runtime_store.save(store, key, replacement())
    SameValue -> runtime_store.save(store, key, old())
    Delete ->
      case runtime_store.delete(store, key) {
        Ok(Nil) -> Ok(Nil)
        Error(_) ->
          // Before enrollment reservations exist, deleting a genuinely absent
          // synthetic slot fails. The race assertion still requires absence
          // after login; do not mistake that expected baseline for the bug.
          case storage.read_runtime_slot(store, key) {
            Ok(None) -> Ok(Nil)
            _ -> Error("Synthetic admin delete did not remove the record")
          }
      }
    InsertDelete -> {
      use _ <- result.try(runtime_store.save(store, key, old()))
      runtime_store.delete(store, key)
    }
  }
}

fn run_race(existing: Bool, mutation: Mutation, stage: Stage) -> #(Bool, Bool) {
  let assert Ok(store) = storage.new(directory())
  let key = "synthetic-claude-enrollment"
  case existing {
    True -> runtime_store.save(store, key, old()) |> should.be_ok
    False -> Nil
  }
  let port = free_port()
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  let config =
    auth.claude_config(
      "synthetic-client",
      origin <> "/authorize",
      origin <> "/token",
      origin <> "/callback",
    )
  let identity =
    ir.Object([
      #("device_id", ir.String(string.repeat("a", 64))),
      #("account_uuid", ir.String("synthetic-account")),
    ])
  let callbacks = process.new_subject()
  let sends = process.new_subject()
  let announce = fn(url) {
    case stage {
      AwaitingCallback -> mutate(store, key, mutation) |> should.be_ok
      Exchanging -> Nil
    }
    let assert Ok(uri.Uri(query: Some(query), ..)) = uri.parse(url)
    let assert Ok(pairs) = uri.parse_query(query)
    let assert Ok(state) = list.key_find(pairs, "state")
    // Complete the HTTP response while announce is active, before the
    // single-use listener is intentionally shut down by await_callback.
    let assert Ok(req) =
      request.to(
        origin <> "/callback?state=" <> state <> "&code=synthetic-code",
      )
    let assert Ok(response) = httpc.send(req)
    process.send(callbacks, response.status)
    Nil
  }
  let send = fn(_) {
    process.send(sends, Nil)
    case stage {
      Exchanging -> mutate(store, key, mutation) |> should.be_ok
      AwaitingCallback -> Nil
    }
    Ok(oauth.TokenResponse(
      200,
      [],
      "{\"access_token\":\"synthetic-login\",\"refresh_token\":\"synthetic-login-refresh\",\"expires_in\":3600,\"account\":{\"uuid\":\"synthetic-account\"}}",
    ))
  }
  let outcome = login.run(config, store, key, identity, 5000, announce, send)
  process.receive(callbacks, 5000) |> should.equal(Ok(200))
  process.receive(sends, 5000) |> should.equal(Ok(Nil))
  let preserved = case mutation, runtime_store.load(store, key) {
    Replace, Ok(material) -> material == replacement()
    SameValue, Ok(material) -> material == old()
    Delete, _ | InsertDelete, _ ->
      storage.read_runtime_slot(store, key) == Ok(None)
    _, _ -> False
  }
  #(result.is_error(outcome), preserved)
}

fn configuration() {
  let origin = "http://127.0.0.1:" <> int.to_string(free_port())
  auth.claude_config(
    "synthetic-client",
    origin <> "/authorize",
    origin <> "/token",
    origin <> "/callback",
  )
}

fn operator_identity() {
  ir.Object([
    #("device_id", ir.String(string.repeat("a", 64))),
    #("account_uuid", ir.String("synthetic-account")),
  ])
}

fn callback(config: auth.Config, url: String) {
  let assert Ok(uri.Uri(query: Some(query), ..)) = uri.parse(url)
  let assert Ok(pairs) = uri.parse_query(query)
  let assert Ok(state) = list.key_find(pairs, "state")
  let assert Ok(req) =
    request.to(
      config.redirect_uri <> "?state=" <> state <> "&code=synthetic-code",
    )
  let assert Ok(reply) = httpc.send(req)
  reply.status |> should.equal(200)
}

const success = "{\"access_token\":\"synthetic-login\",\"refresh_token\":\"synthetic-login-refresh\",\"expires_in\":3600,\"account\":{\"uuid\":\"synthetic-account\"}}"

pub fn successful_first_and_existing_login_test() {
  list.each([False, True], fn(existing) {
    let assert Ok(store) = storage.new(directory())
    let key = "synthetic-success"
    case existing {
      True -> runtime_store.save(store, key, old()) |> should.be_ok
      False -> Nil
    }
    let config = configuration()
    login.run(
      config,
      store,
      key,
      operator_identity(),
      5000,
      fn(url) { callback(config, url) },
      fn(_) { Ok(oauth.TokenResponse(200, [], success)) },
    )
    |> should.be_ok
    let assert Ok(contracts.OAuth(data)) = runtime_store.load(store, key)
    // Compare privately; failure diagnostics must not render token values.
    { data.credential.access_token == "synthetic-login" } |> should.be_true
    { data.credential.refresh_token == "synthetic-login-refresh" }
    |> should.be_true
    list.key_find(data.private_metadata, "account_uuid")
    |> should.equal(Ok("synthetic-account"))
    runtime_store.refresh_status(store, key)
    |> should.equal(Ok(runtime_store.Ready))
  })
}

type WorkflowFailure {
  Timeout
  InvalidConfig
  TransportFailure
  IdentityMismatch
  InvalidMaterial
}

pub fn failure_cancels_only_its_ticket_preserving_existing_gate_test() {
  list.each([False, True], fn(existing) {
    list.each(
      [
        Timeout,
        InvalidConfig,
        TransportFailure,
        IdentityMismatch,
        InvalidMaterial,
      ],
      fn(failure) {
        let assert Ok(store) = storage.new(directory())
        let key = "synthetic-failed-workflow"
        let previous = case existing {
          False -> None
          True -> {
            runtime_store.save(store, key, old()) |> should.be_ok
            let assert Ok(before) = runtime_store.load_record(store, key)
            let assert Ok(gated) =
              runtime_store.transition(
                store,
                key,
                before,
                old(),
                runtime_store.Deferred(9_000_000_000_000),
              )
            Some(gated)
          }
        }
        let config = configuration()
        let config = case failure {
          InvalidConfig -> auth.Config(..config, client_id: "")
          _ -> config
        }
        let announce = fn(url) {
          case failure {
            Timeout -> Nil
            _ -> callback(config, url)
          }
        }
        let send = fn(_) {
          case failure {
            TransportFailure -> Error("synthetic-private-transport-diagnostic")
            IdentityMismatch ->
              Ok(oauth.TokenResponse(
                200,
                [],
                string.replace(success, "synthetic-account", "other-account"),
              ))
            InvalidMaterial ->
              Ok(oauth.TokenResponse(
                200,
                [],
                string.replace(
                  success,
                  "synthetic-login\"",
                  string.repeat("x", 16_385) <> "\"",
                ),
              ))
            _ -> panic as "Timeout/invalid config must not exchange"
          }
        }
        let outcome =
          login.run(
            config,
            store,
            key,
            operator_identity(),
            case failure {
              Timeout -> 50
              _ -> 5000
            },
            announce,
            send,
          )
        let assert Error(error) = outcome
        string.contains(error, "synthetic-private") |> should.be_false
        case previous {
          None ->
            storage.read_runtime_slot(store, key) |> should.equal(Ok(None))
          Some(previous) -> {
            let assert Ok(current) = runtime_store.load_record(store, key)
            { runtime_store.record_material(current) == old() }
            |> should.be_true
            runtime_store.record_status(current)
            |> should.equal(runtime_store.record_status(previous))
            {
              runtime_store.revision(current)
              != runtime_store.revision(previous)
            }
            |> should.be_true
          }
        }
      },
    )
  })
}

pub fn failed_begin_never_announces_or_exchanges_test() {
  list.each([False, True], fn(pending) {
    let assert Ok(store) = storage.new(directory())
    let key = "synthetic-unsafe-slot"
    let ticket = case pending {
      True -> {
        let assert Ok(ticket) = runtime_store.begin_enrollment(store, key)
        Some(ticket)
      }
      False -> {
        storage.write_runtime(store, key, "synthetic-corrupt-record")
        |> should.be_ok
        None
      }
    }
    let before = storage.read_runtime(store, key)
    let visited = process.new_subject()
    login.run(
      configuration(),
      store,
      key,
      operator_identity(),
      50,
      fn(_) { process.send(visited, Nil) },
      fn(_) { panic as "Failed begin must not exchange" },
    )
    |> should.equal(Error("Claude OAuth enrollment unavailable"))
    process.receive(visited, 0) |> should.be_error
    { storage.read_runtime(store, key) == before } |> should.be_true
    case ticket {
      Some(ticket) -> runtime_store.cancel_enrollment(ticket) |> should.be_ok
      None -> Nil
    }
  })
}
