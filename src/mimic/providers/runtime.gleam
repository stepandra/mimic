import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/uri
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store.{type Revision}
import mimic/auth/storage.{type Store}
import mimic/fleet
import mimic/providers/contracts.{
  type Adapter, type Failure, type Request, Buffered, Cancelled, Context,
  CredentialUnavailable, Failure, InvalidConfiguration, InvalidResponse,
  NoAccount, NotSent, Persistence, Quota, ReauthorizationRequired, Rejected,
  Request, Started, Unavailable, Uncertain,
}
import mimic/providers/registry.{type Registry}
import mimic/quota
import mimic/types.{type Header, WireResponse}

pub type Account {
  Account(
    provider: String,
    auth_mode: String,
    id: String,
    origin: String,
    egress: fleet.Egress,
    max_in_flight: Int,
    models: List(String),
    auth_policy: credentials.Policy,
  )
}

/// Operator configuration, never constructed from an inbound request origin.
/// An account with bindings uses an exclusive protocol/operation allowlist.
/// All bindings share its existing credential worker, quota and concurrency pool.
pub type EndpointBinding {
  EndpointBinding(
    provider: String,
    auth_mode: String,
    account: String,
    protocol: String,
    operation: String,
    origin: String,
    egress: fleet.Egress,
  )
}

pub opaque type Runtime {
  Runtime(
    subject: process.Subject(Message),
    pid: process.Pid,
    registry: Registry,
  )
}

type Bound {
  Bound(account: Account, key: String, worker: credentials.Worker)
}

type Lease {
  Lease(selection: fleet.Selection, bound: Bound)
}

type State {
  State(
    store: Store,
    guard: process.Pid,
    accounts: List(Bound),
    bindings: List(EndpointBinding),
    fleet: fleet.State,
    ledger: quota.Ledger,
    monitors: Dict(Int, #(Lease, process.Monitor, process.Pid)),
  )
}

type Message {
  Acquire(
    Request,
    List(String),
    process.Pid,
    process.Subject(Result(Lease, Failure)),
  )
  Release(Lease, process.Subject(Result(Nil, Failure)))
  ReleaseOwner(process.Pid, process.Subject(Result(Nil, Failure)))
  Observe(
    Lease,
    Int,
    List(Header),
    Option(Int),
    process.Subject(Result(Nil, Failure)),
  )
  Down(process.Down)
  Snapshot(process.Subject(Result(Int, Failure)))
  Stop(process.Subject(Result(Nil, Failure)))
}

pub opaque type Stream {
  Stream(
    subject: process.Subject(GuardMessage),
    pid: process.Pid,
    execution: process.Pid,
    runtime: Runtime,
    deadline_ms: Option(Int),
  )
}

/// No pooling: this capability owns one connection, lease and credential
/// generation. A replacement connection requires a new session and receipt.
pub opaque type Session {
  Session(stream: Stream, account: String)
}

type Read {
  Chunk(BitArray)
  Idle
  End
}

type Driver(h) {
  Driver(
    open: fn(contracts.Context, Revision, Request) ->
      Result(contracts.Opened(h), Failure),
    next: fn(h) -> Result(#(Read, h), Failure),
    send: Option(fn(h, Request) -> Result(h, Failure)),
    cancel: fn(h) -> Nil,
    rejection: fn(Int, List(Header)) -> Option(Failure),
  )
}

type StreamMessage {
  Pull(process.Subject(Result(Read, Failure)))
  Send(Request, process.Subject(Result(Nil, Failure)))
  Cancel(process.Subject(Result(Nil, Failure)))
}

type GuardMessage {
  PullFor(process.Pid, process.Subject(Result(Read, Failure)))
  PullUntilFor(process.Pid, Int, process.Subject(Result(Read, Failure)))
  ExpireFor(process.Pid, process.Subject(Result(Nil, Failure)))
  SendFor(process.Pid, Request, process.Subject(Result(Nil, Failure)))
  CancelFor(process.Pid, process.Subject(Result(Nil, Failure)))
  Adopt(process.Pid, process.Subject(Result(Nil, Failure)))
  Pulled(Result(Read, Failure))
  Sent(Result(Nil, Failure))
  Closed(Result(Nil, Failure))
  CancelTimeout
  DeadlineReached
  GuardDown(process.Down)
}

type GuardState {
  GuardState(
    owner: process.Pid,
    owner_monitor: process.Monitor,
    execution: process.Pid,
    execution_monitor: process.Monitor,
    runtime_monitor: process.Monitor,
    subject: process.Subject(GuardMessage),
    execution_subject: process.Subject(StreamMessage),
    pull_reply: process.Subject(Result(Read, Failure)),
    send_reply: process.Subject(Result(Nil, Failure)),
    cancel_reply: process.Subject(Result(Nil, Failure)),
    pending: Option(process.Subject(Result(Read, Failure))),
    sending: Option(process.Subject(Result(Nil, Failure))),
    cancelling: Option(process.Subject(Result(Nil, Failure))),
    revoked: List(process.Pid),
    deadline_ms: Option(Int),
  )
}

pub type Response {
  Response(status: Int, headers: List(Header), account: String, stream: Stream)
}

pub type BufferedResponse {
  BufferedResponse(
    status: Int,
    headers: List(Header),
    account: String,
    body: BitArray,
  )
}

/// One runtime per private store. Atomic mkdir rejects aliases and other VMs.
/// A hard VM crash requires explicit operator recovery of the ownership guard.
pub fn start(
  store: Store,
  registry: Registry,
  accounts: List(Account),
) -> Result(Runtime, Failure) {
  start_with_bindings(store, registry, accounts, [])
}

pub fn start_with_bindings(
  store: Store,
  registry: Registry,
  accounts: List(Account),
  bindings: List(EndpointBinding),
) -> Result(Runtime, Failure) {
  use _ <- result.try(
    validate_bindings(registry, accounts, bindings)
    |> result.replace_error(Failure(InvalidConfiguration, NotSent, None)),
  )
  use pool <- result.try(
    fleet.new(
      list.map(accounts, fn(a) {
        fleet.Profile(
          credentials.key(a.provider, a.auth_mode, a.id),
          a.origin,
          a.egress,
          a.max_in_flight,
        )
      }),
    )
    |> result.replace_error(Failure(InvalidConfiguration, NotSent, None)),
  )
  use _ <- result.try(
    case
      list.all(accounts, fn(a) {
        a.provider != ""
        && a.auth_mode != ""
        && a.id != ""
        && a.models != []
        && list.all(a.models, fn(model) {
          list.any(registry.models(registry), fn(m) {
            m.provider == a.provider
            && m.id == model
            && list.contains(m.auth_modes, a.auth_mode)
          })
        })
      })
    {
      True -> Ok(Nil)
      False -> Error(Failure(InvalidConfiguration, NotSent, None))
    },
  )
  let initialiser = fn(subject) {
    use guard <- result.try(claim_store(store.directory))
    use ledger <- result.try(quota.load_or_empty(store))
    use bound <- result.try(start_accounts(store, accounts, []))
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(Down)
    Ok(
      actor.initialised(State(
        store,
        guard,
        bound,
        bindings,
        pool,
        ledger,
        dict.new(),
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject),
    )
  }
  case
    actor.new_with_initialiser(5000, initialiser)
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> Ok(Runtime(started.data, started.pid, registry))
    Error(_) -> Error(Failure(InvalidConfiguration, NotSent, None))
  }
}

fn validate_bindings(
  registry: Registry,
  accounts: List(Account),
  bindings: List(EndpointBinding),
) -> Result(Nil, String) {
  let keys =
    list.map(bindings, fn(b) {
      #(b.provider, b.auth_mode, b.account, b.protocol, b.operation)
    })
  use _ <- result.try(case list.length(list.unique(keys)) == list.length(keys) {
    True -> Ok(Nil)
    False -> Error("duplicate endpoint binding")
  })
  list.try_each(bindings, fn(b) {
    use account <- result.try(
      list.find(accounts, fn(a) {
        a.provider == b.provider
        && a.auth_mode == b.auth_mode
        && a.id == b.account
      })
      |> result.replace_error("unknown endpoint binding account"),
    )
    use _ <- result.try(
      case
        list.any(registry.models(registry), fn(m) {
          m.provider == b.provider
          && list.contains(account.models, m.id)
          && list.contains(m.auth_modes, b.auth_mode)
          && list.contains(m.protocols, b.protocol)
          && list.contains(m.operations, b.operation)
        })
      {
        True -> Ok(Nil)
        False -> Error("endpoint binding is not a registered operation")
      },
    )
    use _ <- result.try(
      fleet.validate(fleet.Profile(
        account.id,
        b.origin,
        b.egress,
        account.max_in_flight,
      )),
    )
    case uri.parse(b.origin) {
      Ok(uri.Uri(
        userinfo: None,
        query: None,
        fragment: None,
        path: path,
        port: port,
        ..,
      ))
        if path == "" || path == "/"
      ->
        case port {
          None -> Ok(Nil)
          Some(port) if port > 0 && port < 65_536 -> Ok(Nil)
          _ -> Error("invalid endpoint binding port")
        }
      _ ->
        Error("endpoint binding must be an origin without path or credentials")
    }
  })
}

fn endpoint(
  bindings: List(EndpointBinding),
  account: Account,
  request: Request,
) -> Result(Account, String) {
  let bindings =
    list.filter(bindings, fn(b) {
      b.provider == account.provider
      && b.auth_mode == account.auth_mode
      && b.account == account.id
    })
  case bindings {
    [] -> Ok(account)
    _ ->
      list.find(bindings, fn(b) {
        b.protocol == request.protocol && b.operation == request.operation
      })
      |> result.map(fn(b) {
        Account(..account, origin: b.origin, egress: b.egress)
      })
      |> result.replace_error("operation has no approved endpoint")
  }
}

fn start_accounts(
  store: Store,
  accounts: List(Account),
  ready: List(Bound),
) -> Result(List(Bound), String) {
  case accounts {
    [] -> Ok(list.reverse(ready))
    [account, ..rest] -> {
      let key = credentials.key(account.provider, account.auth_mode, account.id)
      case credentials.start(store, key, account.auth_policy) {
        Ok(worker) ->
          start_accounts(store, rest, [Bound(account, key, worker), ..ready])
        Error(_) -> {
          list.each(ready, fn(b) { credentials.stop(b.worker) })
          Error("Credential worker unavailable")
        }
      }
    }
  }
}

pub fn stop(runtime: Runtime) -> Result(Nil, Failure) {
  let monitor = process.monitor(runtime.pid)
  let answer = ask(runtime.subject, runtime.pid, Stop, 5000)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(5000)
  process.demonitor_process(monitor)
  answer
}

/// Secret-free lifecycle diagnostic for tests/management integration.
pub fn active_leases(runtime: Runtime) -> Result(Int, Failure) {
  ask(runtime.subject, runtime.pid, Snapshot, 5000)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Acquire(request, excluded, owner, reply) -> {
      let eligible =
        state.accounts
        |> list.filter(fn(b) {
          process.is_alive(owner)
          && b.account.provider == request.provider
          && b.account.auth_mode == request.auth_mode
          && list.contains(b.account.models, request.model)
          && result.is_ok(endpoint(state.bindings, b.account, request))
          && !list.contains(excluded, b.key)
          && case request.pinned_account {
            None -> True
            Some(id) -> id == b.account.id
          }
        })
        |> list.map(fn(b) { b.key })
      let session =
        json.array(
          [request.provider, request.auth_mode, request.session],
          json.string,
        )
        |> json.to_string
      case
        fleet.select_eligible(
          state.fleet,
          state.ledger,
          session,
          eligible,
          now_ms(),
        )
      {
        Error(_) -> {
          process.send(reply, Error(Failure(NoAccount, NotSent, None)))
          actor.continue(state)
        }
        Ok(#(pool, selection)) -> {
          let assert Ok(bound) =
            list.find(state.accounts, fn(b) { b.key == selection.profile.id })
          let assert Ok(account) =
            endpoint(state.bindings, bound.account, request)
          let bound = Bound(..bound, account: account)
          let lease = Lease(selection, bound)
          let monitor = process.monitor(owner)
          process.send(reply, Ok(lease))
          actor.continue(
            State(
              ..state,
              fleet: pool,
              monitors: dict.insert(state.monitors, selection.lease_id, #(
                lease,
                monitor,
                owner,
              )),
            ),
          )
        }
      }
    }
    Release(lease, reply) -> {
      let next = release(state, lease)
      process.send(reply, Ok(Nil))
      actor.continue(next)
    }
    ReleaseOwner(owner, reply) -> {
      let next =
        list.fold(dict.values(state.monitors), state, fn(state, entry) {
          case entry.2 == owner {
            True -> release(state, entry.0)
            False -> state
          }
        })
      process.send(reply, Ok(Nil))
      actor.continue(next)
    }
    Down(down) -> {
      let next =
        list.fold(dict.values(state.monitors), state, fn(state, entry) {
          case entry.1 == down.monitor {
            True -> release(state, entry.0)
            False -> state
          }
        })
      actor.continue(next)
    }
    Observe(lease, status, headers, retry, reply) -> {
      let now = now_ms()
      let ledger =
        quota.observe(
          state.ledger,
          lease.bound.key,
          WireResponse(status, headers, "", 0),
          now,
        )
      let ledger = case retry {
        Some(ms) if ms > 0 -> quota.cool_down(ledger, lease.bound.key, now + ms)
        _ -> ledger
      }
      case quota.save(state.store, ledger) {
        Ok(_) -> {
          process.send(reply, Ok(Nil))
          actor.continue(State(..state, ledger: ledger))
        }
        Error(_) -> {
          process.send(reply, Error(Failure(Persistence, Uncertain, None)))
          // Still keep the cooldown in memory; fail closed on persistence loss.
          actor.continue(State(..state, ledger: ledger))
        }
      }
    }
    Snapshot(reply) -> {
      process.send(reply, Ok(dict.size(state.monitors)))
      actor.continue(state)
    }
    Stop(reply) -> {
      list.each(dict.values(state.monitors), fn(entry) { process.kill(entry.2) })
      list.each(state.accounts, fn(b) { credentials.stop(b.worker) })
      release_store(state.guard)
      process.send(reply, Ok(Nil))
      actor.stop()
    }
  }
}

fn release(state: State, lease: Lease) -> State {
  case dict.get(state.monitors, lease.selection.lease_id) {
    Ok(#(_, monitor, _)) -> {
      process.demonitor_process(monitor)
      State(
        ..state,
        fleet: fleet.release(state.fleet, lease.selection),
        monitors: dict.delete(state.monitors, lease.selection.lease_id),
      )
    }
    Error(_) -> state
  }
}

/// Returning headers is the downstream commitment point. Even an error on the
/// first subsequent pull is Started and cannot cause transparent failover.
pub fn open(
  runtime: Runtime,
  adapter: Adapter(h),
  request: Request,
) -> Result(Response, Failure) {
  open_scoped(
    runtime,
    adapter,
    fn(context, _, request) { adapter.open(context, request) },
    request,
  )
}

/// Additive trusted-generation hook. Replaces only adapter.open; next, cancel
/// and rejection keep their ABI. The callback runs with the selected account,
/// approved origin and authoritative revision, never a token-derived digest.
/// Generation/scope must stay private; provider code owns continuation policy.
pub fn open_scoped(
  runtime: Runtime,
  adapter: Adapter(h),
  open: fn(contracts.Context, Revision, Request) ->
    Result(contracts.Opened(h), Failure),
  request: Request,
) -> Result(Response, Failure) {
  open_scoped_with_deadline(runtime, adapter, open, request, None)
}

/// Absolute monotonic deadline; a negative BEAM monotonic origin is valid.
/// One existing execution guard covers acquisition, open and idle/active reads.
/// Expiry is Cancelled/NotSent before launch, Cancelled/Uncertain after launch.
pub fn open_until(
  runtime: Runtime,
  adapter: Adapter(h),
  request: Request,
  deadline_ms: Int,
) -> Result(Response, Failure) {
  open_scoped_with_deadline(
    runtime,
    adapter,
    fn(context, _, request) { adapter.open(context, request) },
    request,
    Some(deadline_ms),
  )
}

fn open_scoped_with_deadline(
  runtime: Runtime,
  adapter: Adapter(h),
  open: fn(contracts.Context, Revision, Request) ->
    Result(contracts.Opened(h), Failure),
  request: Request,
  deadline_ms: Option(Int),
) -> Result(Response, Failure) {
  open_driver(
    runtime,
    Driver(
      open,
      fn(handle) {
        adapter.next(handle)
        |> result.map(fn(value) {
          case value {
            Some(#(bytes, next)) -> #(Chunk(bytes), next)
            None -> #(End, handle)
          }
        })
      },
      None,
      adapter.cancel,
      adapter.rejection,
    ),
    request,
    deadline_ms,
  )
}

pub fn open_session(
  runtime: Runtime,
  adapter: contracts.SessionAdapter(h),
  request: Request,
) -> Result(Session, Failure) {
  open_session_scoped(
    runtime,
    adapter,
    fn(context, _, request) { adapter.open(context, request) },
    request,
  )
}

/// Session counterpart to open_scoped: replace only the open callback and pass
/// the authoritative acquired revision unchanged. Provider code must validate
/// that revision before transport I/O; reading a newer equal-valued credential
/// is not an equivalent acquisition. Receive/send/cancel retain their ABI.
pub fn open_session_scoped(
  runtime: Runtime,
  adapter: contracts.SessionAdapter(h),
  open: fn(contracts.Context, Revision, Request) ->
    Result(contracts.Opened(h), Failure),
  request: Request,
) -> Result(Session, Failure) {
  use _ <- result.try(
    case list.contains(request.required, contracts.WebSocket) {
      True -> Ok(Nil)
      False -> Error(Failure(contracts.Unsupported, NotSent, None))
    },
  )
  use response <- result.try(open_driver(
    runtime,
    Driver(
      open,
      fn(handle) {
        adapter.receive(handle)
        |> result.map(fn(pair) {
          #(
            case pair.0 {
              None -> Idle
              Some(text) -> Chunk(bit_array.from_string(text))
            },
            pair.1,
          )
        })
      },
      Some(adapter.send),
      adapter.cancel,
      fn(_, _) { None },
    ),
    request,
    None,
  ))
  Ok(Session(response.stream, response.account))
}

pub fn session_account(session: Session) -> String {
  session.account
}

pub fn session_adopt(session: Session) -> Result(Nil, Failure) {
  adopt(session.stream)
}

pub fn session_cancel(session: Session) -> Nil {
  cancel(session.stream)
}

pub fn session_send(
  session: Session,
  request: Request,
) -> Result(Nil, Failure) {
  let answer =
    ask(
      session.stream.subject,
      session.stream.pid,
      fn(reply) { SendFor(process.self(), request, reply) },
      10_000,
    )
  case answer {
    Error(_) -> {
      cancel(session.stream)
      answer
    }
    Ok(_) -> answer
  }
}

pub fn session_poll(session: Session) -> Result(Option(String), Failure) {
  use read <- result.try(read(session.stream))
  case read {
    Idle -> Ok(None)
    Chunk(bytes) ->
      bit_array.to_string(bytes)
      |> result.map(Some)
      |> result.replace_error(Failure(InvalidResponse, Started, None))
    End -> Error(Failure(Cancelled, Started, None))
  }
}

fn open_driver(
  runtime: Runtime,
  adapter: Driver(h),
  request: Request,
  deadline_ms: Option(Int),
) -> Result(Response, Failure) {
  use _ <- result.try(check_deadline(deadline_ms, NotSent))
  use _ <- result.try(registry.resolve(runtime.registry, request))
  use _ <- result.try(check_deadline(deadline_ms, NotSent))
  let reply = process.new_subject()
  let owner = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      let _ =
        protect(fn() {
          let subject = process.new_subject()
          let ready = process.new_subject()
          let execution = process.self()
          let guard =
            process.spawn_unlinked(fn() {
              guard_execution(
                owner,
                runtime.pid,
                execution,
                subject,
                ready,
                deadline_ms,
              )
            })
          process.link(guard)
          let assert Ok(guard_subject) =
            process.receive(ready, wait_ms(deadline_ms, 5000))
          let selector = process.new_selector() |> process.select(subject)
          case attempt(runtime, adapter, request, [], deadline_ms) {
            Error(error) -> process.send(reply, Error(error))
            Ok(#(lease, opened, generation)) -> {
              process.send(
                reply,
                Ok(Response(
                  opened.status,
                  opened.headers,
                  lease.bound.account.id,
                  Stream(guard_subject, guard, execution, runtime, deadline_ms),
                )),
              )
              stream_loop(
                runtime,
                adapter,
                lease,
                opened.handle,
                selector,
                Request(..request, body: ""),
                generation,
              )
            }
          }
        })
      Nil
    })
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(Failure(Unavailable, Uncertain, None))
    })
  let answer = process.selector_receive(selector, wait_ms(deadline_ms, 60_000))
  case expired(deadline_ms) {
    True -> {
      kill_execution(runtime, pid)
      process.demonitor_process(monitor)
      Error(Failure(Cancelled, Uncertain, None))
    }
    False -> {
      process.demonitor_process(monitor)
      case answer {
        Ok(value) -> value
        Error(_) -> {
          process.kill(pid)
          Error(Failure(Unavailable, Uncertain, None))
        }
      }
    }
  }
}

fn guard_execution(
  owner: process.Pid,
  runtime: process.Pid,
  execution: process.Pid,
  execution_subject: process.Subject(StreamMessage),
  ready: process.Subject(process.Subject(GuardMessage)),
  deadline_ms: Option(Int),
) -> Nil {
  let subject = process.new_subject()
  let pull_reply = process.new_subject()
  let send_reply = process.new_subject()
  let cancel_reply = process.new_subject()
  let execution_monitor = process.monitor(execution)
  let owner_monitor = process.monitor(owner)
  let runtime_monitor = process.monitor(runtime)
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_map(pull_reply, Pulled)
    |> process.select_map(send_reply, Sent)
    |> process.select_map(cancel_reply, Closed)
    |> process.select_monitors(GuardDown)
  process.send(ready, subject)
  guard_loop(
    GuardState(
      owner,
      owner_monitor,
      execution,
      execution_monitor,
      runtime_monitor,
      subject,
      execution_subject,
      pull_reply,
      send_reply,
      cancel_reply,
      None,
      None,
      None,
      [],
      deadline_ms,
    ),
    selector,
  )
}

fn guard_loop(
  state: GuardState,
  selector: process.Selector(GuardMessage),
) -> Nil {
  let message = case state.deadline_ms {
    None -> process.selector_receive_forever(selector)
    Some(_) ->
      process.selector_receive(
        selector,
        wait_ms(state.deadline_ms, 2_147_483_647),
      )
      |> result.unwrap(DeadlineReached)
  }
  // Queued late answers never resurrect a capability after the deadline.
  case expired(state.deadline_ms) {
    True -> expire_guard(state)
    False -> handle_guard(state, selector, message)
  }
}

fn handle_guard(
  state: GuardState,
  selector: process.Selector(GuardMessage),
  message: GuardMessage,
) -> Nil {
  case message {
    Adopt(owner, reply) -> {
      case
        state.pending == None
        && state.sending == None
        && state.cancelling == None
        && !list.contains(state.revoked, owner)
        && process.is_alive(state.owner)
        && process.is_alive(state.execution)
        && process.is_alive(owner)
      {
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
        True if owner == state.owner -> {
          process.send(reply, Ok(Nil))
          guard_loop(state, selector)
        }
        True -> {
          // Establish the replacement monitor before removing the old one.
          let monitor = process.monitor(owner)
          process.demonitor_process(state.owner_monitor)
          let next =
            GuardState(..state, owner: owner, owner_monitor: monitor, revoked: [
              state.owner,
              ..state.revoked
            ])
          process.send(reply, Ok(Nil))
          guard_loop(next, selector)
        }
      }
    }
    PullFor(owner, reply) -> {
      case
        owner == state.owner
        && state.pending == None
        && state.sending == None
        && state.cancelling == None
      {
        True -> {
          process.send(state.execution_subject, Pull(state.pull_reply))
          guard_loop(GuardState(..state, pending: Some(reply)), selector)
        }
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
      }
    }
    PullUntilFor(owner, deadline_ms, reply) -> {
      case
        owner == state.owner
        && state.pending == None
        && state.sending == None
        && state.cancelling == None
      {
        True -> {
          let next =
            GuardState(
              ..state,
              deadline_ms: earliest(state.deadline_ms, Some(deadline_ms)),
              pending: Some(reply),
            )
          case expired(next.deadline_ms) {
            True -> expire_guard(next)
            False -> {
              process.send(state.execution_subject, Pull(state.pull_reply))
              guard_loop(next, selector)
            }
          }
        }
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
      }
    }
    ExpireFor(owner, reply) -> {
      case owner == state.owner {
        True -> {
          process.send(reply, Ok(Nil))
          expire_guard(state)
        }
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
      }
    }
    SendFor(owner, request, reply) -> {
      case
        owner == state.owner
        && state.pending == None
        && state.sending == None
        && state.cancelling == None
      {
        True -> {
          process.send(state.execution_subject, Send(request, state.send_reply))
          guard_loop(GuardState(..state, sending: Some(reply)), selector)
        }
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
      }
    }
    Sent(answer) -> {
      case state.sending {
        Some(reply) -> process.send(reply, answer)
        None -> Nil
      }
      guard_loop(GuardState(..state, sending: None), selector)
    }
    CancelFor(owner, reply) -> {
      case owner == state.owner && state.cancelling == None {
        True -> {
          process.send(state.execution_subject, Cancel(state.cancel_reply))
          let _ = process.send_after(state.subject, 1000, CancelTimeout)
          guard_loop(GuardState(..state, cancelling: Some(reply)), selector)
        }
        False -> {
          process.send(reply, Error(Failure(Cancelled, Started, None)))
          guard_loop(state, selector)
        }
      }
    }
    Pulled(answer) -> {
      case state.pending {
        Some(reply) -> process.send(reply, answer)
        None -> Nil
      }
      guard_loop(GuardState(..state, pending: None), selector)
    }
    Closed(answer) -> {
      case state.cancelling {
        Some(reply) -> process.send(reply, answer)
        None -> Nil
      }
      guard_loop(state, selector)
    }
    CancelTimeout -> {
      process.kill(state.execution)
      Nil
    }
    DeadlineReached -> expire_guard(state)
    GuardDown(down) -> {
      case down.monitor {
        monitor if monitor == state.execution_monitor -> Nil
        monitor
          if monitor == state.owner_monitor || monitor == state.runtime_monitor
        -> {
          process.kill(state.execution)
          Nil
        }
        _ -> guard_loop(state, selector)
      }
    }
  }
}

fn expire_guard(state: GuardState) -> Nil {
  case state.pending {
    Some(reply) -> process.send(reply, Error(Failure(Cancelled, Started, None)))
    None -> Nil
  }
  case state.sending {
    Some(reply) -> process.send(reply, Error(Failure(Cancelled, Started, None)))
    None -> Nil
  }
  case state.cancelling {
    Some(reply) -> process.send(reply, Error(Failure(Cancelled, Started, None)))
    None -> Nil
  }
  // Only this socket-owning execution dies, not a shared refresh worker.
  process.kill(state.execution)
}

fn attempt(
  runtime: Runtime,
  adapter: Driver(h),
  request: Request,
  excluded: List(String),
  deadline_ms: Option(Int),
) -> Result(#(Lease, contracts.Opened(h), Revision), Failure) {
  use _ <- result.try(check_deadline(deadline_ms, NotSent))
  use lease <- result.try(ask(
    runtime.subject,
    runtime.pid,
    fn(reply) { Acquire(request, excluded, process.self(), reply) },
    wait_ms(deadline_ms, 5000),
  ))
  let account = lease.bound.account
  let outcome = {
    use acquired <- result.try(credentials.acquire_versioned(lease.bound.worker))
    use _ <- result.try(check_deadline(deadline_ms, NotSent))
    let #(material, generation) = acquired
    let session_key =
      json.array([lease.bound.key, request.session], json.string)
      |> json.to_string
    adapter.open(
      Context(
        account.provider,
        account.auth_mode,
        account.id,
        account.origin,
        session_key,
        material,
      ),
      generation,
      request,
    )
    |> result.map(fn(opened) { #(opened, generation) })
  }
  let outcome = case outcome {
    Error(error) -> Error(error)
    Ok(#(opened, generation)) -> {
      let rejection = adapter.rejection(opened.status, opened.headers)
      let retry = case rejection {
        Some(error) -> error.retry_after_ms
        None -> None
      }
      case
        ask(
          runtime.subject,
          runtime.pid,
          fn(reply) {
            Observe(lease, opened.status, opened.headers, retry, reply)
          },
          wait_ms(deadline_ms, 5000),
        )
      {
        Error(error) -> {
          adapter.cancel(opened.handle)
          Error(error)
        }
        Ok(_) ->
          case rejection {
            Some(error) -> {
              adapter.cancel(opened.handle)
              Error(error)
            }
            None -> Ok(#(opened, generation))
          }
      }
    }
  }
  case outcome {
    Ok(#(opened, generation)) -> Ok(#(lease, opened, generation))
    Error(error) -> {
      let _ = release_lease(runtime, lease)
      case
        retryable(error)
        && request.pinned_account == None
        && !expired(deadline_ms)
      {
        True -> {
          case
            attempt(
              runtime,
              adapter,
              request,
              [lease.bound.key, ..excluded],
              deadline_ms,
            )
          {
            Ok(value) -> Ok(value)
            Error(next) -> Error(select_failure(error, next))
          }
        }
        False -> Error(error)
      }
    }
  }
}

pub fn retryable(error: Failure) -> Bool {
  { error.delivery == NotSent || error.delivery == Rejected }
  && {
    error.reason == Quota
    || error.reason == Unavailable
    || error.reason == CredentialUnavailable
    || error.reason == ReauthorizationRequired
  }
}

fn select_failure(previous: Failure, next: Failure) -> Failure {
  // Preserve a later potentially executed request, or any terminal failure.
  case next.delivery == Uncertain || next.delivery == Started {
    True -> next
    False if next.reason == NoAccount -> previous
    False ->
      case retryable(next) {
        False -> next
        True ->
          case next.reason {
            ReauthorizationRequired
              if previous.reason != ReauthorizationRequired
            -> previous
            _ ->
              case previous.retry_after_ms, next.retry_after_ms {
                Some(a), Some(b) if a < b -> previous
                Some(_), None -> previous
                _, _ -> next
              }
          }
      }
  }
}

fn release_lease(runtime: Runtime, lease: Lease) -> Result(Nil, Failure) {
  ask(runtime.subject, runtime.pid, fn(reply) { Release(lease, reply) }, 5000)
}

fn stream_loop(
  runtime: Runtime,
  adapter: Driver(h),
  lease: Lease,
  handle: h,
  selector: process.Selector(StreamMessage),
  request: Request,
  generation: Revision,
) -> Nil {
  case process.selector_receive(selector, 60_000) {
    Ok(Pull(reply)) ->
      case adapter.next(handle) {
        Ok(#(read, next)) if read != End -> {
          process.send(reply, Ok(read))
          stream_loop(
            runtime,
            adapter,
            lease,
            next,
            selector,
            request,
            generation,
          )
        }
        Ok(_) -> {
          adapter.cancel(handle)
          let _ = release_lease(runtime, lease)
          process.send(reply, Ok(End))
        }
        Error(error) -> {
          adapter.cancel(handle)
          let _ = release_lease(runtime, lease)
          process.send(reply, Error(Failure(..error, delivery: Started)))
        }
      }
    Ok(Send(next_request, reply)) -> {
      let outcome = {
        use send <- result.try(case adapter.send {
          Some(send) -> Ok(send)
          None -> Error(Failure(contracts.Unsupported, Started, None))
        })
        use _ <- result.try(case same_session(request, next_request, lease) {
          True -> Ok(Nil)
          False -> Error(Failure(InvalidConfiguration, Started, None))
        })
        use _ <- result.try(registry.resolve(runtime.registry, next_request))
        // Re-read through the durable credential worker before every turn.
        // Rotation/deletion/refresh never silently re-authenticates a socket.
        use current <- result.try(credentials.acquire_versioned(
          lease.bound.worker,
        ))
        use _ <- result.try(case current.1 == generation {
          True -> Ok(Nil)
          False -> Error(Failure(CredentialUnavailable, Started, None))
        })
        send(handle, next_request)
      }
      case outcome {
        Ok(next) -> {
          process.send(reply, Ok(Nil))
          stream_loop(
            runtime,
            adapter,
            lease,
            next,
            selector,
            request,
            generation,
          )
        }
        Error(error) -> {
          adapter.cancel(handle)
          let _ = release_lease(runtime, lease)
          process.send(reply, Error(Failure(..error, delivery: Started)))
        }
      }
    }
    Ok(Cancel(reply)) -> {
      adapter.cancel(handle)
      let _ = release_lease(runtime, lease)
      process.send(reply, Ok(Nil))
    }
    Error(_) -> {
      adapter.cancel(handle)
      let _ = release_lease(runtime, lease)
      Nil
    }
  }
}

fn same_session(original: Request, next: Request, lease: Lease) -> Bool {
  original.provider == next.provider
  && original.auth_mode == next.auth_mode
  && original.model == next.model
  && original.protocol == next.protocol
  && original.operation == next.operation
  && original.mode == next.mode
  && original.session == next.session
  && list.contains(next.required, contracts.WebSocket)
  && case next.pinned_account {
    None -> True
    Some(id) -> id == lease.bound.account.id
  }
}

pub fn next(stream: Stream) -> Result(Option(BitArray), Failure) {
  use value <- result.try(read(stream))
  case value {
    Chunk(bytes) -> Ok(Some(bytes))
    End -> Ok(None)
    Idle -> Error(Failure(InvalidResponse, Started, None))
  }
}

/// Tighten, never extend, an execution's absolute deadline. An expired
/// adopted/revoked handle cannot cancel the current owner's execution.
pub fn next_until(
  stream: Stream,
  deadline_ms: Int,
) -> Result(Option(BitArray), Failure) {
  use value <- result.try(read_with_deadline(stream, Some(deadline_ms)))
  case value {
    Chunk(bytes) -> Ok(Some(bytes))
    End -> Ok(None)
    Idle -> Error(Failure(InvalidResponse, Started, None))
  }
}

fn read(stream: Stream) -> Result(Read, Failure) {
  read_with_deadline(stream, None)
}

fn read_with_deadline(
  stream: Stream,
  requested_deadline: Option(Int),
) -> Result(Read, Failure) {
  let deadline_ms = earliest(stream.deadline_ms, requested_deadline)
  use _ <- result.try(case expired(deadline_ms) {
    True -> {
      expire_stream(stream)
      Error(Failure(Cancelled, Started, None))
    }
    False -> Ok(Nil)
  })
  let answer =
    ask(
      stream.subject,
      stream.pid,
      fn(reply) {
        case deadline_ms {
          None -> PullFor(process.self(), reply)
          Some(deadline) -> PullUntilFor(process.self(), deadline, reply)
        }
      },
      wait_ms(deadline_ms, 10_000),
    )
  case expired(deadline_ms) {
    True -> {
      expire_stream(stream)
      Error(Failure(Cancelled, Started, None))
    }
    False -> read_answer(stream, answer)
  }
}

fn read_answer(
  stream: Stream,
  answer: Result(Read, Failure),
) -> Result(Read, Failure) {
  case answer {
    Error(error) -> {
      case error.delivery {
        Uncertain -> cancel(stream)
        _ -> Nil
      }
      Error(Failure(..error, delivery: Started))
    }
    Ok(value) -> Ok(value)
  }
}

/// At most one second AFTER expiry for process death and coordinator release.
/// The socket dies with its execution. A stuck coordinator may defer bookkeeping,
/// but queued acquisitions from a dead execution cannot create a late lease.
pub const deadline_cleanup_ms = 1000

fn expire_stream(stream: Stream) -> Nil {
  let until = monotonic_ms() + deadline_cleanup_ms
  let allowed =
    ask(
      stream.subject,
      stream.pid,
      fn(reply) { ExpireFor(process.self(), reply) },
      wait_ms(Some(until), deadline_cleanup_ms),
    )
  case allowed, process.is_alive(stream.execution) {
    Ok(_), _ | _, False ->
      reap_execution(stream.runtime, stream.execution, until)
    _, True -> Nil
  }
}

fn kill_execution(runtime: Runtime, execution: process.Pid) -> Nil {
  let until = monotonic_ms() + deadline_cleanup_ms
  process.kill(execution)
  reap_execution(runtime, execution, until)
}

fn reap_execution(runtime: Runtime, execution: process.Pid, until: Int) -> Nil {
  let monitor = process.monitor(execution)
  let dead =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(wait_ms(Some(until), deadline_cleanup_ms))
  process.demonitor_process(monitor)
  case dead {
    Ok(_) -> {
      let _ =
        ask(
          runtime.subject,
          runtime.pid,
          fn(reply) { ReleaseOwner(execution, reply) },
          wait_ms(Some(until), deadline_cleanup_ms),
        )
      Nil
    }
    // Never make a still-live execution's capacity reusable.
    Error(_) -> Nil
  }
}

fn expired(deadline_ms: Option(Int)) -> Bool {
  case deadline_ms {
    None -> False
    Some(deadline) -> monotonic_ms() >= deadline
  }
}

fn check_deadline(
  deadline_ms: Option(Int),
  delivery: contracts.Delivery,
) -> Result(Nil, Failure) {
  case expired(deadline_ms) {
    True -> Error(Failure(Cancelled, delivery, None))
    False -> Ok(Nil)
  }
}

fn wait_ms(deadline_ms: Option(Int), maximum: Int) -> Int {
  case deadline_ms {
    None -> maximum
    Some(deadline) -> int.max(0, int.min(maximum, deadline - monotonic_ms()))
  }
}

fn earliest(a: Option(Int), b: Option(Int)) -> Option(Int) {
  case a, b {
    None, other | other, None -> other
    Some(a), Some(b) -> Some(int.min(a, b))
  }
}

/// Safe to call repeatedly. A blocked/crashed adapter is killed; its socket is
/// process-owned and the coordinator monitor always releases the lease.
pub fn cancel(stream: Stream) -> Nil {
  let _ =
    ask(
      stream.subject,
      stream.pid,
      fn(reply) { CancelFor(process.self(), reply) },
      1500,
    )
  Nil
}

/// The opaque handle is the transfer capability. Call synchronously from the
/// replacement process before the old owner exits (e.g. Mist chunk init).
/// After acknowledgement the old owner may no longer pull/cancel/re-adopt.
/// Transfer while a pull/cancel is pending or after owner death fails closed.
pub fn adopt(stream: Stream) -> Result(Nil, Failure) {
  ask(
    stream.subject,
    stream.pid,
    fn(reply) { Adopt(process.self(), reply) },
    1000,
  )
}

pub fn execute(
  runtime: Runtime,
  adapter: Adapter(h),
  request: Request,
) -> Result(BufferedResponse, Failure) {
  use response <- result.try(open(
    runtime,
    adapter,
    Request(..request, mode: Buffered),
  ))
  use body <- result.try(read_all(response.stream, [], 0))
  Ok(BufferedResponse(response.status, response.headers, response.account, body))
}

fn read_all(
  stream: Stream,
  reversed: List(BitArray),
  size: Int,
) -> Result(BitArray, Failure) {
  use chunk <- result.try(next(stream))
  case chunk {
    None -> Ok(bit_array.concat(list.reverse(reversed)))
    Some(bytes) -> {
      let size = size + bit_array.byte_size(bytes)
      case size > 8_388_608 {
        True -> {
          cancel(stream)
          Error(Failure(InvalidResponse, Started, None))
        }
        False -> read_all(stream, [bytes, ..reversed], size)
      }
    }
  }
}

fn ask(
  subject: process.Subject(message),
  pid: process.Pid,
  make: fn(process.Subject(Result(value, Failure))) -> message,
  timeout: Int,
) -> Result(value, Failure) {
  let reply = process.new_subject()
  let monitor = process.monitor(pid)
  let selector =
    process.new_selector()
    |> process.select_map(reply, fn(value) { value })
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(Failure(Cancelled, Uncertain, None))
    })
  process.send(subject, make(reply))
  let answer = process.selector_receive(selector, timeout)
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(Failure(Unavailable, Uncertain, None)))
}

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_provider_runtime_ffi", "claim_store")
fn claim_store(directory: String) -> Result(process.Pid, String)

@external(erlang, "mimic_provider_runtime_ffi", "release_store")
fn release_store(guard: process.Pid) -> Nil

@external(erlang, "mimic_provider_runtime_ffi", "protect")
fn protect(callback: fn() -> value) -> Result(value, Nil)
