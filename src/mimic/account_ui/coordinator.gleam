/// The operator session and one bounded enrollment workflow are serialized here.
/// Provider I/O is cancellable asynchronous work; only this actor can commit.
/// The runtime store remains authoritative, and the gateway owns refresh.
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import mimic/account_ui/enrollment
import mimic/account_ui/enrollment_adapters as adapters
import mimic/account_ui/primitives as os
import mimic/auth/crypto
import mimic/auth/runtime as credential
import mimic/auth/runtime_store as records
import mimic/auth/storage.{type Store}
import mimic/gateway/config.{type Account}
import mimic/providers/contracts.{type AuthMaterial}
import mimic/providers/kimi/oauth

pub type Limits {
  Limits(bootstrap_ms: Int, session_ms: Int, attempt_ms: Int, tick_ms: Int)
}

pub fn default_limits() -> Limits {
  Limits(300_000, 1_800_000, oauth.max_poll_ms, 250)
}

pub opaque type Coordinator {
  Coordinator(subject: process.Subject(Message), pid: process.Pid)
}

pub type Reply {
  Reply(status: Int, body: json.Json, session_cookie: Option(String))
}

/// Session/CSRF are UI capabilities, not upstream tokens or device identity.
pub type Authorization {
  Authorization(session: String, csrf: String)
}

type Session {
  Session(token: String, csrf: String, deadline: Int)
}

type Bootstrap {
  Bootstrap(token: String, deadline: Int)
}

type Attempt {
  Attempt(
    id: Int,
    account: String,
    ticket: records.Enrollment,
    guard: process.Pid,
    monitor: process.Monitor,
    deadline: Int,
    prompt: Option(enrollment.Prompt),
  )
}

type State {
  State(
    subject: process.Subject(Message),
    store: Store,
    accounts: List(Account),
    device_id: String,
    transports: adapters.Transports,
    bootstrap_name: String,
    bootstrap: Option(Bootstrap),
    session: Option(Session),
    limits: Limits,
    clock: fn() -> Int,
    failures: Int,
    block_until: Int,
    unauth_window: Int,
    unauth_count: Int,
    sequence: Int,
    active: Option(Attempt),
    last_account: String,
    phase: String,
  )
}

type Message {
  Admit(auth: Authorization, reply: process.Subject(Reply))
  Exchange(code: String, reply: process.Subject(Reply))
  Status(auth: Authorization, reply: process.Subject(Reply))
  Login(auth: Authorization, account: String, reply: process.Subject(Reply))
  Cancel(auth: Authorization, account: String, reply: process.Subject(Reply))
  Logout(auth: Authorization, reply: process.Subject(Reply))
  Prompt(id: Int, prompt: Option(enrollment.Prompt), deadline: Int)
  Finished(id: Int, outcome: Result(AuthMaterial, String))
  Down(process.Down)
  Tick
  Stop(reply: process.Subject(Result(Nil, String)))
}

pub fn start(
  store: Store,
  accounts: List(Account),
  device_id: String,
  send: oauth.Send,
  bootstrap_name: String,
  bootstrap_token: String,
  limits: Limits,
) -> Result(Coordinator, String) {
  start_with_clock(
    store,
    accounts,
    device_id,
    send,
    bootstrap_name,
    bootstrap_token,
    limits,
    os.monotonic_ms,
  )
}

/// Internal deterministic test seam. Production uses monotonic milliseconds;
/// no HTTP caller can supply a timestamp or clock.
pub fn start_with_clock(
  store: Store,
  accounts: List(Account),
  device_id: String,
  send: oauth.Send,
  bootstrap_name: String,
  bootstrap_token: String,
  limits: Limits,
  clock: fn() -> Int,
) -> Result(Coordinator, String) {
  start_with_transports_clock(
    store,
    accounts,
    device_id,
    adapters.with_kimi(adapters.production_transports(), send),
    bootstrap_name,
    bootstrap_token,
    limits,
    clock,
  )
}

/// Provider transport injection is synthetic-only; the CLI uses approved
/// production transports. S5 and session rules are identical for all adapters.
pub fn start_with_transports_clock(
  store: Store,
  accounts: List(Account),
  device_id: String,
  transports: adapters.Transports,
  bootstrap_name: String,
  bootstrap_token: String,
  limits: Limits,
  clock: fn() -> Int,
) -> Result(Coordinator, String) {
  case
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = process.send_after(subject, limits.tick_ms, Tick)
      let now = clock()
      let state =
        State(
          subject,
          store,
          accounts,
          device_id,
          transports,
          bootstrap_name,
          Some(Bootstrap(bootstrap_token, now + limits.bootstrap_ms)),
          None,
          limits,
          clock,
          0,
          now,
          now,
          0,
          0,
          None,
          "",
          "idle",
        )
      actor.initialised(state)
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(Down),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> {
      process.unlink(started.pid)
      Ok(Coordinator(started.data, started.pid))
    }
    Error(_) -> Error("operator coordinator unavailable")
  }
}

pub fn pid(coordinator: Coordinator) -> process.Pid {
  coordinator.pid
}

fn call(
  coordinator: Coordinator,
  message: fn(process.Subject(Reply)) -> Message,
) -> Reply {
  let reply = process.new_subject()
  let monitor = process.monitor(coordinator.pid)
  process.send(coordinator.subject, message(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      rejected(503, "operator service unavailable")
    })
    |> process.selector_receive(12_000)
  process.demonitor_process(monitor)
  result.unwrap(answer, rejected(503, "operator service unavailable"))
}

/// Every request lacking a current session+CSRF shares a 20/second budget.
pub fn admit(coordinator: Coordinator, auth: Authorization) -> Bool {
  call(coordinator, Admit(auth, _)).status == 204
}

pub fn exchange(coordinator: Coordinator, code: String) -> Reply {
  call(coordinator, Exchange(code, _))
}

pub fn status(coordinator: Coordinator, auth: Authorization) -> Reply {
  call(coordinator, Status(auth, _))
}

pub fn login(
  coordinator: Coordinator,
  auth: Authorization,
  account: String,
) -> Reply {
  call(coordinator, Login(auth, account, _))
}

pub fn cancel(
  coordinator: Coordinator,
  auth: Authorization,
  account: String,
) -> Reply {
  call(coordinator, Cancel(auth, account, _))
}

pub fn logout(coordinator: Coordinator, auth: Authorization) -> Reply {
  call(coordinator, Logout(auth, _))
}

pub fn stop(coordinator: Coordinator) -> Result(Nil, String) {
  let reply = process.new_subject()
  let monitor = process.monitor(coordinator.pid)
  process.send(coordinator.subject, Stop(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) { Ok(Nil) })
    |> process.selector_receive(12_000)
  process.demonitor_process(monitor)
  result.unwrap(answer, Error("operator shutdown unconfirmed"))
}

fn rejected(status: Int, message: String) -> Reply {
  Reply(status, json.object([#("error", json.string(message))]), None)
}

fn accepted(body: json.Json) -> Reply {
  Reply(200, body, None)
}

fn authorized(state: State, auth: Authorization) -> Bool {
  case state.session {
    Some(session) ->
      state.clock() < session.deadline
      && os.equal(auth.session, session.token)
      && os.equal(auth.csrf, session.csrf)
    None -> False
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let state = expire(state)
  case message {
    Admit(auth, reply) -> {
      let now = state.clock()
      let state = case now - state.unauth_window >= 1000 {
        True -> State(..state, unauth_window: now, unauth_count: 0)
        False -> state
      }
      case authorized(state, auth) {
        True -> {
          process.send(reply, Reply(204, json.null(), None))
          actor.continue(state)
        }
        False -> {
          let allowed = state.unauth_count < 20
          process.send(reply, case allowed {
            True -> Reply(204, json.null(), None)
            False -> rejected(429, "unauthenticated request rate limited")
          })
          actor.continue(
            State(..state, unauth_count: int.min(21, state.unauth_count + 1)),
          )
        }
      }
    }
    Exchange(code, reply) -> {
      let #(state, response) = bootstrap(state, code)
      process.send(reply, response)
      actor.continue(state)
    }
    Status(auth, reply) ->
      with_auth(state, auth, reply, fn(state) { #(state, view(state)) })
    Login(auth, account, reply) ->
      with_auth(state, auth, reply, fn(state) { begin(state, account, auth) })
    Cancel(auth, account, reply) ->
      with_auth(state, auth, reply, fn(state) {
        case state.active {
          Some(attempt) if attempt.account == account -> {
            let #(state, cancelled) = cancel_active(state, "cancelled")
            #(state, case cancelled {
              Ok(_) -> view(state)
              Error(_) ->
                rejected(
                  409,
                  "cancellation unconfirmed; inspect credential status",
                )
            })
          }
          _ -> #(state, rejected(409, "no active login for this account"))
        }
      })
    Logout(auth, reply) ->
      with_auth(state, auth, reply, fn(state) {
        let #(state, cancelled) = cancel_active(state, "cancelled")
        let state = State(..state, session: None)
        #(state, case cancelled {
          Ok(_) -> accepted(json.object([#("signed_out", json.bool(True))]))
          Error(_) -> rejected(409, "signed out; cancellation unconfirmed")
        })
      })
    Prompt(id, prompt, deadline) -> {
      let active = case state.active {
        Some(attempt) if attempt.id == id ->
          Some(
            Attempt(
              ..attempt,
              prompt: prompt,
              deadline: int.min(attempt.deadline, deadline),
            ),
          )
        _ -> state.active
      }
      let phase = case active {
        Some(attempt) if attempt.id == id ->
          case prompt {
            Some(_) -> "waiting"
            None -> "exchanging"
          }
        _ -> state.phase
      }
      actor.continue(State(..state, active:, phase:))
    }
    Finished(id, outcome) -> actor.continue(complete(state, id, outcome))
    Down(down) -> {
      case state.active {
        Some(attempt) if attempt.monitor == down.monitor -> {
          let #(state, _) = cancel_active(state, "failed")
          actor.continue(state)
        }
        _ -> actor.continue(state)
      }
    }
    Tick -> {
      let _ = process.send_after(state.subject, state.limits.tick_ms, Tick)
      actor.continue(state)
    }
    Stop(reply) -> {
      let #(state, cancelled) = cancel_active(state, "cancelled")
      let cleared = clear_bootstrap(state)
      process.send(reply, case cancelled, cleared {
        Ok(_), Ok(_) -> Ok(Nil)
        _, _ -> Error("operator shutdown cleanup unconfirmed")
      })
      actor.stop()
    }
  }
}

fn with_auth(
  state: State,
  auth: Authorization,
  reply: process.Subject(Reply),
  action: fn(State) -> #(State, Reply),
) -> actor.Next(State, Message) {
  case authorized(state, auth) {
    True -> {
      let #(state, response) = action(state)
      process.send(reply, response)
      actor.continue(state)
    }
    False -> {
      process.send(reply, rejected(401, "operator session required or expired"))
      actor.continue(state)
    }
  }
}

fn bootstrap(state: State, code: String) -> #(State, Reply) {
  let now = state.clock()
  case state.bootstrap {
    Some(bootstrap) if now < bootstrap.deadline && state.failures < 8 -> {
      case now >= state.block_until && os.equal(code, bootstrap.token) {
        True -> {
          case clear_bootstrap(state) {
            Error(_) -> #(
              State(..state, bootstrap: None),
              rejected(503, "bootstrap cleanup unconfirmed; restart required"),
            )
            Ok(_) -> {
              let session =
                Session(
                  crypto.random_url_token(),
                  crypto.random_url_token(),
                  state.clock() + state.limits.session_ms,
                )
              #(
                State(..state, bootstrap: None, session: Some(session)),
                Reply(
                  200,
                  json.object([
                    #("csrf", json.string(session.csrf)),
                    #(
                      "session_expires_in_ms",
                      json.int(state.limits.session_ms),
                    ),
                  ]),
                  Some(session.token),
                ),
              )
            }
          }
        }
        False -> #(
          State(..state, failures: state.failures + 1, block_until: now + 1000),
          rejected(429, "bootstrap rejected or rate limited"),
        )
      }
    }
    _ -> #(state, rejected(401, "bootstrap unavailable; restart required"))
  }
}

fn clear_bootstrap(state: State) -> Result(Nil, String) {
  case state.bootstrap {
    None -> Ok(Nil)
    Some(bootstrap) ->
      os.remove_private(
        state.store.directory,
        state.bootstrap_name,
        bootstrap.token,
      )
  }
}

fn expire(state: State) -> State {
  let now = state.clock()
  let state = case state.bootstrap {
    Some(bootstrap) if now >= bootstrap.deadline -> {
      let _ = clear_bootstrap(state)
      State(..state, bootstrap: None)
    }
    _ -> state
  }
  let state = case state.session {
    Some(session) if now >= session.deadline -> {
      let #(state, _) = cancel_active(state, "expired")
      State(..state, session: None)
    }
    _ -> state
  }
  case state.active {
    Some(attempt) if now >= attempt.deadline -> {
      let #(state, _) = cancel_active(state, "expired")
      state
    }
    _ -> state
  }
}

fn begin(
  state: State,
  account_id: String,
  auth: Authorization,
) -> #(State, Reply) {
  case state.active {
    Some(_) -> #(state, rejected(409, "another account login is active"))
    None ->
      case list.find(state.accounts, fn(a) { a.id == account_id }) {
        Error(_) -> #(
          state,
          rejected(404, "configured supported OAuth account required"),
        )
        Ok(account) -> {
          case adapters.select(account, state.device_id, state.transports) {
            Ok(adapter) -> {
              let key =
                credential.key(account.provider, account.auth_mode, account.id)
              // No spawn or provider call until the S5 slot reservation succeeds.
              case records.begin_enrollment(state.store, key) {
                Error(_) -> #(
                  state,
                  rejected(409, "credential slot unavailable"),
                )
                Ok(ticket) -> {
                  // Filesystem begin may block. Recheck the same session at the
                  // network admission point, not only before reserving the slot.
                  case authorized(state, auth) {
                    False -> {
                      let cancelled = records.cancel_enrollment(ticket)
                      let state =
                        State(
                          ..state,
                          last_account: account.id,
                          phase: case cancelled {
                            Ok(_) -> "expired"
                            Error(_) -> "cancellation_unconfirmed"
                          },
                        )
                      #(
                        state,
                        rejected(
                          401,
                          "operator session expired before enrollment",
                        ),
                      )
                    }
                    True -> {
                      let id = state.sequence + 1
                      let deadline = state.clock() + state.limits.attempt_ms
                      let owner = process.self()
                      let guard =
                        process.spawn_unlinked(fn() {
                          guard_worker(
                            owner,
                            state.subject,
                            id,
                            ticket,
                            adapter,
                            deadline,
                            state.clock,
                          )
                        })
                      let attempt =
                        Attempt(
                          id,
                          account.id,
                          ticket,
                          guard,
                          process.monitor(guard),
                          deadline,
                          None,
                        )
                      let state =
                        State(
                          ..state,
                          active: Some(attempt),
                          sequence: id,
                          last_account: account.id,
                          phase: "starting",
                        )
                      #(state, Reply(202, view(state).body, None))
                    }
                  }
                }
              }
            }
            Error(_) -> #(
              state,
              rejected(404, "configured supported OAuth account required"),
            )
          }
        }
      }
  }
}

fn cancel_active(state: State, phase: String) -> #(State, Result(Nil, String)) {
  case state.active {
    None -> #(state, Ok(Nil))
    Some(attempt) -> {
      // Winning cancellation changes the exact store generation BEFORE the
      // network process is killed. No late message can fall back to save().
      let cancelled = records.cancel_enrollment(attempt.ticket)
      finish_worker(attempt)
      #(
        State(..state, active: None, phase: case cancelled {
          Ok(_) -> phase
          Error(_) -> "cancellation_unconfirmed"
        }),
        cancelled,
      )
    }
  }
}

fn finish_worker(attempt: Attempt) -> Nil {
  process.demonitor_process(attempt.monitor)
  process.kill(attempt.guard)
}

fn complete(
  state: State,
  id: Int,
  outcome: Result(AuthMaterial, String),
) -> State {
  case state.active {
    Some(attempt) if attempt.id == id -> {
      case outcome {
        Ok(material) -> {
          let committed = records.commit_enrollment(attempt.ticket, material)
          case committed {
            Ok(_) -> {
              finish_worker(attempt)
              State(..state, active: None, phase: "stored")
            }
            Error(_) -> {
              let #(state, _) = cancel_active(state, "installation_unconfirmed")
              // A CAS error can mean an admin winner OR an unknown mutation
              // outcome. Do not claim rollback or retry an unconditional save.
              State(..state, phase: "installation_unconfirmed")
            }
          }
        }
        Error(phase) -> {
          let #(state, _) = cancel_active(state, phase)
          state
        }
      }
    }
    _ -> state
  }
}

fn view(state: State) -> Reply {
  accepted(
    json.object([
      #(
        "accounts",
        json.array(state.accounts, fn(account) {
          let metadata =
            records.metadata(
              state.store,
              credential.key(account.provider, account.auth_mode, account.id),
            )
          let phase = case account.id == state.last_account {
            True -> state.phase
            False -> "idle"
          }
          let prompt = case state.active {
            Some(attempt) if attempt.account == account.id -> attempt.prompt
            _ -> None
          }
          let fields = [
            #("id", json.string(account.id)),
            #("provider", json.string(account.provider)),
            #("login", json.string(phase)),
            #(
              "credential",
              json.string(case metadata {
                Ok(value) -> value.kind
                Error(_) -> "missing_or_unavailable"
              }),
            ),
          ]
          let fields = case metadata {
            Ok(records.Metadata(_, Some(expiry))) -> [
              #("expires_at_ms", json.int(expiry)),
              ..fields
            ]
            _ -> fields
          }
          let fields = case prompt {
            Some(enrollment.DeviceCode(code, uri)) -> [
              #("user_code", json.string(code)),
              #("verification_uri", json.string(uri)),
              ..fields
            ]
            Some(enrollment.BrowserLogin(url)) -> [
              #("authorization_url", json.string(url)),
              ..fields
            ]
            None -> fields
          }
          json.object(fields)
        }),
      ),
    ]),
  )
}

type GuardMessage {
  OwnerDown
  ExecutionDown
  IgnoredExit
}

fn guard_worker(
  owner: process.Pid,
  subject: process.Subject(Message),
  id: Int,
  ticket: records.Enrollment,
  adapter: enrollment.Adapter,
  deadline: Int,
  clock: fn() -> Int,
) -> Nil {
  // A monitored guard is deliberately separate from blocking socket work.
  // Linked execution dies even if the guard is killed during an HTTP request.
  process.trap_exits(True)
  let ready = process.new_subject()
  let guard = process.self()
  let execution =
    process.spawn_unlinked(fn() {
      process.link(guard)
      let kickoff = process.new_subject()
      process.send(ready, kickoff)
      case process.receive(kickoff, 1000) {
        Error(_) -> Nil
        Ok(Nil) -> {
          let outcome =
            os.protect(fn() {
              adapter.run(
                fn(prompt, deadline) {
                  process.send(subject, Prompt(id, prompt, deadline))
                },
                deadline,
                clock,
              )
            })
            |> result.unwrap(Error("failed"))
          process.send(subject, Finished(id, outcome))
          // Stay alive until the coordinator commits/cancels the exact ticket.
          process.sleep_forever()
        }
      }
    })
  let owner_monitor = process.monitor(owner)
  let execution_monitor = process.monitor(execution)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
    |> process.select_specific_monitor(execution_monitor, fn(_) {
      ExecutionDown
    })
    |> process.select_trapped_exits(fn(_) { IgnoredExit })
  case process.receive(ready, 1000) {
    Ok(kickoff) -> {
      process.send(kickoff, Nil)
      guard_loop(selector, subject, id, ticket, execution)
    }
    Error(_) -> {
      let _ = records.cancel_enrollment(ticket)
      process.kill(execution)
      process.send(subject, Finished(id, Error("failed")))
    }
  }
}

fn guard_loop(
  selector: process.Selector(GuardMessage),
  subject: process.Subject(Message),
  id: Int,
  ticket: records.Enrollment,
  execution: process.Pid,
) -> Nil {
  case process.selector_receive_forever(selector) {
    IgnoredExit -> guard_loop(selector, subject, id, ticket, execution)
    OwnerDown -> {
      let _ = records.cancel_enrollment(ticket)
      process.kill(execution)
    }
    ExecutionDown -> {
      let _ = records.cancel_enrollment(ticket)
      process.send(subject, Finished(id, Error("failed")))
    }
  }
}
