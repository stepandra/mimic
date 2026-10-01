// MIMIC chunk lifecycle: socket events must not wait behind upstream pulls.
// The coordinator owns receives; one linked executor owns init and callbacks.
import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import glisten/socket/options
import glisten/transport
import mist/internal/http.{type Connection}
import mist/internal/next.{type Next, AbnormalStop, Continue, NormalStop}

pub const max_pending_messages = 32

pub const max_retained_tail_bytes = 65_536

pub type Message(message) {
  Ready
  User(message)
  Continued
  Finished
  Aborted(String)
  ExecutorDown
  RequestOwnerDown
  SocketData(BitArray)
  SocketClosed
  SocketFailed
}

type Work(message) {
  Run(message)
}

type State(message) {
  State(
    executor: Pid,
    work: Subject(Work(message)),
    executor_monitor: process.Monitor,
    request_monitor: Option(process.Monitor),
    ready: Bool,
    in_flight: Bool,
    pending: List(message),
    pending_count: Int,
    retained_tail: BytesTree,
    retained_tail_bytes: Int,
  )
}

/// Synchronous executor init keeps runtime adoption ahead of request-owner exit.
/// Its application subject is a send-only capability owned by the coordinator.
pub fn start(
  connection: Connection,
  request_owner: Pid,
  init: fn(Subject(message)) -> state,
  loop: fn(state, message) -> Next(state, message),
  final_chunk: fn() -> Result(Nil, Nil),
  ready: Subject(Subject(Message(message))),
) -> Result(actor.Started(Pid), actor.StartError) {
  actor.new_with_initialiser(1000, fn(control) {
    let user = process.new_subject()
    let request_monitor = process.monitor(request_owner)
    use executor <- result.try(
      start_executor(user, control, init, loop, final_chunk)
      |> result.replace_error("Failed to initialise chunk executor"),
    )
    let executor_monitor = process.monitor(executor.pid)
    let selector =
      socket_selector(connection)
      |> process.select(control)
      |> process.select_map(user, User)
      |> process.select_specific_monitor(executor_monitor, fn(_) {
        ExecutorDown
      })
      |> process.select_specific_monitor(request_monitor, fn(_) {
        RequestOwnerDown
      })
    State(
      executor.pid,
      executor.data,
      executor_monitor,
      Some(request_monitor),
      False,
      False,
      [],
      0,
      bytes_tree.new(),
      0,
    )
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(control)
    |> Ok
  })
  |> actor.on_message(fn(state, message) { handle(state, message, connection) })
  |> actor.start
  |> result.map(fn(started) {
    process.send(ready, started.data)
    actor.Started(started.pid, started.pid)
  })
}

fn start_executor(
  user: Subject(message),
  control: Subject(Message(message)),
  init: fn(Subject(message)) -> state,
  loop: fn(state, message) -> Next(state, message),
  final_chunk: fn() -> Result(Nil, Nil),
) -> Result(actor.Started(Subject(Work(message))), actor.StartError) {
  actor.new_with_initialiser(1000, fn(work) {
    init(user)
    |> actor.initialised
    |> actor.returning(work)
    |> Ok
  })
  |> actor.on_message(fn(state, work) {
    let Run(message) = work
    case loop(state, message) {
      Continue(state, _) -> {
        process.send(control, Continued)
        actor.continue(state)
      }
      NormalStop -> {
        // A final send can block too. It stays on the interruptible executor,
        // never on the socket-event coordinator.
        case final_chunk() {
          Ok(_) -> process.send(control, Finished)
          Error(_) ->
            process.send(control, Aborted("Failed to send final chunk"))
        }
        actor.stop()
      }
      AbnormalStop(reason) -> {
        process.send(control, Aborted(reason))
        actor.stop()
      }
    }
  })
  |> actor.start
}

fn socket_selector(
  connection: Connection,
) -> process.Selector(Message(message)) {
  // Like the existing glisten/WS selectors, this process owns exactly one
  // downstream socket. Only that transport's OS messages are selected here.
  let #(data, closed, error) = case connection.transport {
    transport.Tcp -> #("tcp", "tcp_closed", "tcp_error")
    transport.Ssl -> #("ssl", "ssl_closed", "ssl_error")
  }
  process.new_selector()
  |> process.select_record(atom.create(data), 2, fn(record) {
    {
      use bytes <- decode.field(2, decode.bit_array)
      decode.success(SocketData(bytes))
    }
    |> decode.run(record, _)
    |> result.unwrap(SocketFailed)
  })
  |> process.select_record(atom.create(closed), 1, fn(_) { SocketClosed })
  |> process.select_record(atom.create(error), 2, fn(_) { SocketFailed })
}

fn handle(
  state: State(message),
  message: Message(message),
  connection: Connection,
) -> actor.Next(State(message), Message(message)) {
  case message {
    Ready if state.ready -> actor.continue(state)
    Ready ->
      case arm(connection) {
        Error(_) -> abort(state, connection, "Failed to observe chunk socket")
        Ok(_) -> {
          case state.request_monitor {
            Some(monitor) -> process.demonitor_process(monitor)
            None -> Nil
          }
          dispatch(State(..state, ready: True, request_monitor: None))
          |> actor.continue
        }
      }
    User(message) ->
      case state.pending_count >= max_pending_messages {
        True -> abort(state, connection, "Chunk message queue limit exceeded")
        False ->
          State(
            ..state,
            pending: list.append(state.pending, [message]),
            pending_count: state.pending_count + 1,
          )
          |> dispatch
          |> actor.continue
      }
    Continued ->
      State(..state, in_flight: False)
      |> dispatch
      |> actor.continue
    Finished -> finish(state, connection, None)
    Aborted(reason) -> abort(state, connection, reason)
    ExecutorDown -> abort(state, connection, "Chunk executor terminated")
    RequestOwnerDown ->
      case state.request_monitor {
        Some(_) -> abort(state, connection, "Chunk handoff owner terminated")
        None -> actor.continue(state)
      }
    SocketClosed | SocketFailed ->
      // Transport termination is not a successful upstream EOF. In particular
      // active TCP's default FIN/SHUT_WR behavior is not a read-abandonment test.
      abort(state, connection, "Chunk downstream transport terminated")
    SocketData(data) -> {
      let size = state.retained_tail_bytes + bit_array.byte_size(data)
      case size > max_retained_tail_bytes {
        True ->
          abort(state, connection, "Chunk post-request tail limit exceeded")
        False ->
          case arm(connection) {
            Error(_) ->
              abort(state, connection, "Failed to observe chunk socket")
            Ok(_) ->
              State(
                ..state,
                retained_tail: bytes_tree.append(state.retained_tail, data),
                retained_tail_bytes: size,
              )
              |> actor.continue
          }
      }
    }
  }
}

fn arm(connection: Connection) -> Result(Nil, Nil) {
  transport.set_opts(connection.transport, connection.socket, [
    options.ActiveMode(options.Once),
  ])
  |> result.replace_error(Nil)
}

fn dispatch(state: State(message)) -> State(message) {
  case state.ready, state.in_flight, state.pending {
    True, False, [message, ..rest] -> {
      process.send(state.work, Run(message))
      State(
        ..state,
        in_flight: True,
        pending: rest,
        pending_count: state.pending_count - 1,
      )
    }
    _, _, _ -> state
  }
}

fn abort(
  state: State(message),
  connection: Connection,
  reason: String,
) -> actor.Next(State(message), Message(message)) {
  finish(state, connection, Some(reason))
}

fn finish(
  state: State(message),
  connection: Connection,
  reason: Option(String),
) -> actor.Next(State(message), Message(message)) {
  // Never wait for a callback that may be blocked inside runtime.next or send.
  // Unlink before killing so cleanup cannot kill the coordinator mid-operation.
  process.unlink(state.executor)
  process.kill(state.executor)
  process.demonitor_process(state.executor_monitor)
  case state.request_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  let _ = transport.close(connection.transport, connection.socket)
  case reason {
    None -> actor.stop()
    Some(reason) -> actor.stop_abnormal(reason)
  }
}
