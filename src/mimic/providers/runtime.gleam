import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import mimic/auth/runtime as credentials
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
  Stream(subject: process.Subject(GuardMessage), pid: process.Pid)
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
    open: fn(contracts.Context, Request) -> Result(contracts.Opened(h), Failure),
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
  SendFor(process.Pid, Request, process.Subject(Result(Nil, Failure)))
  CancelFor(process.Pid, process.Subject(Result(Nil, Failure)))
  Adopt(process.Pid, process.Subject(Result(Nil, Failure)))
  Pulled(Result(Read, Failure))
  Sent(Result(Nil, Failure))
  Closed(Result(Nil, Failure))
  CancelTimeout
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
      actor.initialised(State(store, guard, bound, pool, ledger, dict.new()))
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
          b.account.provider == request.provider
          && b.account.auth_mode == request.auth_mode
          && list.contains(b.account.models, request.model)
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
  open_driver(
    runtime,
    Driver(
      adapter.open,
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
  )
}

pub fn open_session(
  runtime: Runtime,
  adapter: contracts.SessionAdapter(h),
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
      adapter.open,
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
) -> Result(Response, Failure) {
  use _ <- result.try(registry.resolve(runtime.registry, request))
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
              guard_execution(owner, runtime.pid, execution, subject, ready)
            })
          process.link(guard)
          let assert Ok(guard_subject) = process.receive(ready, 5000)
          let selector = process.new_selector() |> process.select(subject)
          case attempt(runtime, adapter, request, []) {
            Error(error) -> process.send(reply, Error(error))
            Ok(#(lease, opened, material)) -> {
              process.send(
                reply,
                Ok(Response(
                  opened.status,
                  opened.headers,
                  lease.bound.account.id,
                  Stream(guard_subject, guard),
                )),
              )
              stream_loop(
                runtime,
                adapter,
                lease,
                opened.handle,
                selector,
                Request(..request, body: ""),
                material,
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
  let answer = process.selector_receive(selector, 60_000)
  process.demonitor_process(monitor)
  case answer {
    Ok(value) -> value
    Error(_) -> {
      process.kill(pid)
      Error(Failure(Unavailable, Uncertain, None))
    }
  }
}

fn guard_execution(
  owner: process.Pid,
  runtime: process.Pid,
  execution: process.Pid,
  execution_subject: process.Subject(StreamMessage),
  ready: process.Subject(process.Subject(GuardMessage)),
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
    ),
    selector,
  )
}

fn guard_loop(
  state: GuardState,
  selector: process.Selector(GuardMessage),
) -> Nil {
  case process.selector_receive_forever(selector) {
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

fn attempt(
  runtime: Runtime,
  adapter: Driver(h),
  request: Request,
  excluded: List(String),
) -> Result(#(Lease, contracts.Opened(h), contracts.AuthMaterial), Failure) {
  use lease <- result.try(ask(
    runtime.subject,
    runtime.pid,
    fn(reply) { Acquire(request, excluded, process.self(), reply) },
    5000,
  ))
  let account = lease.bound.account
  let outcome = {
    use material <- result.try(credentials.acquire(lease.bound.worker))
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
      request,
    )
    |> result.map(fn(opened) { #(opened, material) })
  }
  let outcome = case outcome {
    Error(error) -> Error(error)
    Ok(#(opened, material)) -> {
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
          5000,
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
            None -> Ok(#(opened, material))
          }
      }
    }
  }
  case outcome {
    Ok(#(opened, material)) -> Ok(#(lease, opened, material))
    Error(error) -> {
      let _ = release_lease(runtime, lease)
      case retryable(error) && request.pinned_account == None {
        True -> {
          case
            attempt(runtime, adapter, request, [lease.bound.key, ..excluded])
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
  material: contracts.AuthMaterial,
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
            material,
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
        use current <- result.try(credentials.acquire(lease.bound.worker))
        use _ <- result.try(case current == material {
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
            material,
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

fn read(stream: Stream) -> Result(Read, Failure) {
  let answer =
    ask(
      stream.subject,
      stream.pid,
      fn(reply) { PullFor(process.self(), reply) },
      10_000,
    )
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

@external(erlang, "mimic_provider_runtime_ffi", "claim_store")
fn claim_store(directory: String) -> Result(process.Pid, String)

@external(erlang, "mimic_provider_runtime_ffi", "release_store")
fn release_store(guard: process.Pid) -> Nil

@external(erlang, "mimic_provider_runtime_ffi", "protect")
fn protect(callback: fn() -> value) -> Result(value, Nil)
