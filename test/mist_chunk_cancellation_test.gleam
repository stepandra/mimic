/// Actual Mist + shared runtime + egress; every endpoint/content/key is synthetic.
/// No live/native-client/CPA qualification follows from this cancellation lane.
import gleam/bit_array
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import glisten/socket.{type Socket}
import glisten/transport as downstream
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/fleet
import mimic/providers/contracts as c
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/recorder/tls
import mimic/types.{Capture, Header, Transport}
import mist
import mist/internal/http
import mist_chunk_legacy_fixture as legacy

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "run")
pub fn main() -> Nil

type Fixture

type Client

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "with_fixture")
fn with_fixture(mode: String, work: fn(Fixture) -> Nil) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "port")
fn fixture_port(fixture: Fixture) -> Int

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "directory")
fn fixture_directory(fixture: Fixture) -> String

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "release")
fn release(fixture: Fixture) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "await_peer_eof")
fn peer_eof(fixture: Fixture, timeout_ms: Int) -> Bool

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "requests")
fn fixture_requests(fixture: Fixture) -> Int

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "with_cleanup")
fn with_cleanup(work: fn() -> Nil, cleanup: fn() -> Nil) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "stop_server")
fn stop_server(pid: process.Pid) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "with_client")
fn with_client(
  port: Int,
  request: String,
  tls: Bool,
  read_prefix: Bool,
  work: fn(Client) -> Nil,
) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "first")
fn first(client: Client) -> String

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "headers")
fn headers(client: Client) -> String

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "close_client")
fn close_client(client: Client) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "reset_client")
fn reset_client(client: Client) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "half_close")
fn half_close(client: Client) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "send_tail")
fn send_tail(client: Client, bytes: String) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "read_all")
fn read_all(client: Client) -> #(String, Bool)

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "configure_pressure")
fn configure_pressure(socket: Socket, client: Client) -> Result(Nil, String)

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "pressure_deadline")
fn pressure_deadline(client: Client) -> Int

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "remaining_ms")
fn remaining_ms(deadline: Int) -> Int

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "pressure_pause")
fn pressure_pause(deadline: Int) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "pressure_sample")
fn pressure_sample(
  socket: Socket,
  writer: process.Pid,
  executor: process.Pid,
  coordinator: process.Pid,
  client: Client,
  deadline: Int,
  index: Int,
) -> Bool

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "report_pressure_probe")
fn report_pressure_probe(
  socket: Socket,
  writer: process.Pid,
  executor: process.Pid,
  coordinator: process.Pid,
  client: Client,
  deadline: Int,
  index: Int,
) -> Nil

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "await")
fn await(check: fn() -> Bool, timeout_ms: Int) -> Bool

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "connection_abi")
fn connection_abi(conn: mist.Connection) -> Bool

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "socket_owner")
fn socket_owner(conn: mist.Connection, expected: process.Pid) -> Bool

@external(erlang, "mimic_mist_chunk_cancellation_test_ffi", "tail_unchanged")
fn tail_unchanged(
  conn: mist.Connection,
  expected: String,
  peek: fn() -> Bool,
) -> Bool

const prefix = "data: {\"type\":\"synthetic.metadata\"}\n\n"

const complete = "data: {\"type\":\"synthetic.metadata\"}\n\ndata: synthetic second\n\ndata: synthetic third\n\n"

const request = "POST /stream HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"

const pipeline_tail = "GET /not-dispatched HTTP/1.1\r\nHost: localhost\r\n\r\n"

const pressure_payload_bytes = 262_144

const pressure_max_writes = 8

const pressure_max_body_bytes = 2_097_152

const pressure_max_wire_bytes = 2_097_224

const pressure_chunk_overhead = 9

type Tick {
  Tick
}

type Behavior {
  Forward
  ByTick
  RepeatedCancel
  FailedWrite
  Backpressure
}

type Event {
  Callback(process.Pid)
  Pull(Int, process.Pid)
  Wrote(Int, process.Pid)
}

type Write {
  PressureReady(Socket, process.Pid, process.Subject(Int))
  WriteStarted(Int, Socket, process.Pid)
  WriteReturned(Int, process.Pid, String)
  PressureFailed(String)
}

type PendingWrite {
  PendingWrite(index: Int, socket: Socket, writer: process.Pid)
}

type Owner {
  Owner(
    executor: process.Pid,
    coordinator: process.Pid,
    messages: process.Subject(Tick),
  )
}

type StreamState {
  StreamState(
    stream: runtime.Stream,
    messages: process.Subject(Tick),
    coordinator: process.Pid,
    sequence: Int,
  )
}

type Server {
  Server(
    port: Int,
    pid: process.Pid,
    owners: process.Subject(Owner),
    events: process.Subject(Event),
    writes: process.Subject(Write),
    handled: process.Subject(String),
  )
}

fn runtime_for(fixture: Fixture) -> runtime.Runtime {
  let assert Ok(store) = storage.new(fixture_directory(fixture) <> "/state")
  let assert Ok(registry) =
    registry.new([
      registry.Model("synthetic", "model", ["key"], ["test"], ["generate"], [
        c.Buffer,
        c.Stream,
      ]),
    ])
  credentials.save_api_key(
    store,
    credentials.key("synthetic", "key", "a"),
    "synthetic-f12-cancel-credential",
  )
  |> should.be_ok
  let assert Ok(provider) =
    runtime.start(store, registry, [
      runtime.Account(
        "synthetic",
        "key",
        "a",
        "http://127.0.0.1:" <> int.to_string(fixture_port(fixture)),
        fleet.LocalLoopback,
        1,
        ["model"],
        credentials.StaticKey,
      ),
    ])
  provider
}

fn adapter() {
  transport.http(
    fn(context, request) {
      let assert c.ApiKey(key) = context.credential
      Ok(Capture(
        "synthetic",
        "1",
        context.origin,
        "test",
        "POST",
        "/generate",
        "HTTP/1.1",
        [
          Header("Host", string.replace(context.origin, "http://", "")),
          Header("Authorization", "Bearer " <> key),
          Header("Content-Type", "application/json"),
          Header(
            "Content-Length",
            int.to_string(string.byte_size(request.body)),
          ),
        ],
        request.body,
        Transport("http/1.1", None),
      ))
    },
    fn(_, _) { None },
    None,
  )
}

fn serve(
  provider: runtime.Runtime,
  behavior: Behavior,
  legacy: Bool,
  tls_files,
  inspect_tail: Bool,
) -> Server {
  let ports = process.new_subject()
  let owners = process.new_subject()
  let events = process.new_subject()
  let writes = process.new_subject()
  let handled = process.new_subject()
  let handler = fn(req: Request(mist.Connection)) {
    connection_abi(req.body) |> should.be_true
    process.send(handled, req.path)
    let assert Ok(read) = mist.read_body(req, 4096)
    read.body |> should.equal(bit_array.from_string("{}"))
    case inspect_tail {
      True ->
        tail_unchanged(req.body, pipeline_tail, fn() {
          http.request_body_completed(req.body)
        })
        |> should.be_true
      False -> Nil
    }
    let assert Ok(opened) =
      runtime.open(
        provider,
        adapter(),
        c.Request(
          "synthetic",
          "key",
          "model",
          "test",
          "generate",
          c.Streaming,
          [],
          "synthetic-cancellation-session",
          None,
          "{}",
        ),
      )
    let init = fn(messages) {
      runtime.adopt(opened.stream) |> should.equal(Ok(Nil))
      let assert Ok(coordinator) = process.subject_owner(messages)
      process.send(owners, Owner(process.self(), coordinator, messages))
      process.send(messages, Tick)
      StreamState(opened.stream, messages, coordinator, 1)
    }
    let loop = fn(state: StreamState, _: Tick, connection: mist.Connection) {
      case connection.transport, legacy {
        downstream.Tcp, False ->
          socket_owner(connection, state.coordinator) |> should.be_true
        // The retained lifecycle had no readiness gate. Do not retrofit this
        // invariant into the legacy idle/half-close control.
        _, _ -> Nil
      }
      process.send(events, Callback(process.self()))
      case behavior {
        ByTick -> tick(state, connection, events)
        _ -> pump(state.stream, connection, events, writes, behavior, 1)
      }
    }
    let initial = response.new(200)
    let initial =
      response.set_header(initial, "content-type", "text/event-stream")
    case legacy {
      True -> legacy.chunked(req, initial, init, loop)
      False -> mist.chunked(req, initial, init, loop)
    }
  }
  let builder =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
  let builder = case tls_files {
    Some(#(cert, key)) -> mist.with_tls(builder, cert, key)
    None -> builder
  }
  let assert Ok(server) = mist.start(builder)
  process.unlink(server.pid)
  let assert Ok(port) = process.receive(ports, 1000)
  Server(port, server.pid, owners, events, writes, handled)
}

fn pump(
  stream: runtime.Stream,
  connection: mist.Connection,
  events: process.Subject(Event),
  writes: process.Subject(Write),
  behavior: Behavior,
  sequence: Int,
) -> mist.ChunkNext(StreamState) {
  process.send(events, Pull(sequence, process.self()))
  case runtime.next(stream) {
    Error(_) -> {
      runtime.cancel(stream)
      mist.chunk_stop_abnormal("synthetic upstream error")
    }
    Ok(None) -> mist.chunk_stop()
    Ok(Some(bytes)) ->
      case mist.send_chunk(connection, bytes) {
        Error(_) -> {
          runtime.cancel(stream)
          mist.chunk_stop_abnormal("synthetic downstream write failure")
        }
        Ok(_) -> {
          process.send(events, Wrote(sequence, process.self()))
          case behavior {
            RepeatedCancel -> {
              runtime.cancel(stream)
              runtime.cancel(stream)
              mist.chunk_stop_abnormal("synthetic repeated cancellation")
            }
            FailedWrite -> {
              let _ = downstream.close(connection.transport, connection.socket)
              mist.send_chunk(
                connection,
                bit_array.from_string("not delivered"),
              )
              |> should.be_error
              runtime.cancel(stream)
              mist.chunk_stop_abnormal("synthetic failed send")
            }
            Backpressure -> pressure(stream, connection, writes)
            _ ->
              pump(stream, connection, events, writes, behavior, sequence + 1)
          }
        }
      }
  }
}

fn pressure(
  stream: runtime.Stream,
  connection: mist.Connection,
  writes: process.Subject(Write),
) -> mist.ChunkNext(StreamState) {
  // Construct once before the begin gate. The test must parse the prefix and
  // seal all subsequent peer reads before any pressure byte can be written.
  let bytes = bit_array.from_string(string.repeat("b", pressure_payload_bytes))
  let begin = process.new_subject()
  process.send(writes, PressureReady(connection.socket, process.self(), begin))
  // A startup cap only; authorization supplies the client's single absolute
  // prefix-time + 1000ms deadline for every write and admission sample.
  case process.receive(begin, 1000) {
    Error(_) -> pressure_failed(stream, writes, "pressure begin gate expired")
    Ok(deadline) ->
      pressure_writes(stream, connection, writes, bytes, deadline, 1, 0, 0)
  }
}

fn pressure_failed(
  stream: runtime.Stream,
  writes: process.Subject(Write),
  reason: String,
) -> mist.ChunkNext(StreamState) {
  process.send(writes, PressureFailed(reason))
  runtime.cancel(stream)
  mist.chunk_stop_abnormal(reason)
}

fn pressure_send(
  connection: mist.Connection,
  writes: process.Subject(Write),
  bytes: BitArray,
  index: Int,
) -> Result(Nil, Nil) {
  process.send(writes, WriteStarted(index, connection.socket, process.self()))
  let sent = mist.send_chunk(connection, bytes)
  let outcome = case sent {
    Ok(_) -> "ok"
    Error(_) -> "error"
  }
  // This post-call side effect keeps pressure_send/4 as an exact stack anchor.
  // Do not tail-call mist.send_chunk or move the write into a helper process.
  process.send(writes, WriteReturned(index, process.self(), outcome))
  sent
}

fn pressure_writes(
  stream: runtime.Stream,
  connection: mist.Connection,
  writes: process.Subject(Write),
  bytes: BitArray,
  deadline: Int,
  index: Int,
  body_bytes: Int,
  wire_bytes: Int,
) -> mist.ChunkNext(StreamState) {
  let size = bit_array.byte_size(bytes)
  let next_body = body_bytes + size
  let next_wire = wire_bytes + size + pressure_chunk_overhead
  let remaining = remaining_ms(deadline)
  let capped =
    index > pressure_max_writes
    || size != pressure_payload_bytes
    || next_body > pressure_max_body_bytes
    || next_wire > pressure_max_wire_bytes
    || remaining <= 0
    || remaining > 1000
  case capped {
    True -> pressure_failed(stream, writes, "pressure cap/deadline reached")
    False ->
      case pressure_send(connection, writes, bytes, index) {
        Error(_) ->
          pressure_failed(stream, writes, "pressure send returned error")
        Ok(_) ->
          pressure_writes(
            stream,
            connection,
            writes,
            bytes,
            deadline,
            index + 1,
            next_body,
            next_wire,
          )
      }
  }
}

fn pressure_event(
  message: Write,
  owner: Owner,
  pending: Option(PendingWrite),
) -> Option(PendingWrite) {
  case message {
    WriteStarted(index, socket, writer) -> {
      let valid =
        writer == owner.executor
        && index >= 1
        && index <= pressure_max_writes
        && pending == None
      valid |> should.be_true
      Some(PendingWrite(index, socket, writer))
    }
    WriteReturned(index, writer, outcome) -> {
      let assert Some(current) = pending
      let valid =
        index == current.index && writer == current.writer && outcome == "ok"
      valid |> should.be_true
      None
    }
    PressureFailed(reason) -> panic as reason
    PressureReady(_, _, _) -> panic as "repeated pressure begin gate"
  }
}

fn sample_write(
  current: PendingWrite,
  owner: Owner,
  client: Client,
  deadline: Int,
) -> Bool {
  pressure_sample(
    current.socket,
    current.writer,
    owner.executor,
    owner.coordinator,
    client,
    deadline,
    current.index,
  )
}

fn report_write(
  current: PendingWrite,
  owner: Owner,
  client: Client,
  deadline: Int,
) -> Nil {
  report_pressure_probe(
    current.socket,
    current.writer,
    owner.executor,
    owner.coordinator,
    client,
    deadline,
    current.index,
  )
}

fn await_blocked_write(
  messages: process.Subject(Write),
  owner: Owner,
  client: Client,
  deadline: Int,
  pending: Option(PendingWrite),
) -> PendingWrite {
  case remaining_ms(deadline) <= 0 {
    True -> {
      case pending {
        Some(current) -> report_write(current, owner, client, deadline)
        None -> Nil
      }
      panic as "no observable blocked send within shared pressure deadline"
    }
    False ->
      case process.receive(messages, 0) {
        Ok(message) ->
          await_blocked_write(
            messages,
            owner,
            client,
            deadline,
            pressure_event(message, owner, pending),
          )
        Error(_) ->
          case pending {
            None -> {
              pressure_pause(deadline)
              await_blocked_write(messages, owner, client, deadline, None)
            }
            Some(current) ->
              case sample_write(current, owner, client, deadline) {
                False -> {
                  pressure_pause(deadline)
                  await_blocked_write(
                    messages,
                    owner,
                    client,
                    deadline,
                    pending,
                  )
                }
                True -> {
                  // Never shorten the required separation near the deadline.
                  { remaining_ms(deadline) > 5 } |> should.be_true
                  pressure_pause(deadline)
                  // Same unmatched write must survive the 5ms separation.
                  case process.receive(messages, 0) {
                    Ok(message) ->
                      await_blocked_write(
                        messages,
                        owner,
                        client,
                        deadline,
                        pressure_event(message, owner, pending),
                      )
                    Error(_) ->
                      case sample_write(current, owner, client, deadline) {
                        True -> current
                        False ->
                          await_blocked_write(
                            messages,
                            owner,
                            client,
                            deadline,
                            pending,
                          )
                      }
                  }
                }
              }
          }
      }
  }
}

fn tick(state: StreamState, connection, events) {
  process.send(events, Pull(state.sequence, process.self()))
  case runtime.next(state.stream) {
    Error(_) -> {
      runtime.cancel(state.stream)
      mist.chunk_stop_abnormal("synthetic upstream error")
    }
    Ok(None) -> mist.chunk_stop()
    Ok(Some(bytes)) -> {
      let assert Ok(_) = mist.send_chunk(connection, bytes)
      process.send(events, Wrote(state.sequence, process.self()))
      process.send(state.messages, Tick)
      mist.chunk_continue(StreamState(..state, sequence: state.sequence + 1))
    }
  }
}

fn with_server(mode, behavior, legacy, encrypted, inspect_tail, work) {
  with_fixture(mode, fn(fixture) {
    let provider = runtime_for(fixture)
    let tls_files = case encrypted {
      True -> {
        let assert Ok(files) =
          tls.generate_ca(fixture_directory(fixture) <> "/ca")
        Some(files)
      }
      False -> None
    }
    let server = serve(provider, behavior, legacy, tls_files, inspect_tail)
    with_cleanup(fn() { work(fixture, provider, server) }, fn() {
      stop_server(server.pid)
      runtime.stop(provider) |> should.be_ok
    })
  })
}

fn owner(server: Server, legacy: Bool) -> Owner {
  let assert Ok(owner) = process.receive(server.owners, 1000)
  case legacy {
    True -> owner.executor |> should.equal(owner.coordinator)
    False -> { owner.executor == owner.coordinator } |> should.be_false
  }
  owner
}

fn pending_pull(server: Server, owner: Owner) -> Nil {
  let assert Ok(event) = process.receive(server.events, 1000)
  case event {
    Pull(2, pid) -> pid |> should.equal(owner.executor)
    Callback(pid) | Pull(_, pid) | Wrote(_, pid) -> {
      pid |> should.equal(owner.executor)
      pending_pull(server, owner)
    }
  }
}

fn dead(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  let observed =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  observed |> should.be_ok
}

fn cancelled(fixture: Fixture, provider: runtime.Runtime, owner: Owner) -> Nil {
  // Stronger than the unchanged root 5s gate: cannot pass by egress's 5s timeout.
  peer_eof(fixture, 1000) |> should.be_true
  await(fn() { runtime.active_leases(provider) == Ok(0) }, 1000)
  |> should.be_true
  dead(owner.executor)
  dead(owner.coordinator)
  fixture_requests(fixture) |> should.equal(1)
}

fn no_leak(body: String) -> Nil {
  string.contains(body, "synthetic-f12-cancel-credential") |> should.be_false
}

pub fn idle_upstream_close_cancels_before_read_timeout_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        first(client) |> should.equal(prefix)
        headers(client)
        |> string.lowercase
        |> string.contains("connection: close")
        |> should.be_true
        let owner = owner(server, False)
        pending_pull(server, owner)
        close_client(client)
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn retained_legacy_idle_control_needs_owner_death_test() {
  with_server(
    "idle",
    Forward,
    True,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        first(client) |> should.equal(prefix)
        let owner = owner(server, True)
        pending_pull(server, owner)
        close_client(client)
        peer_eof(fixture, 150) |> should.be_false
        runtime.active_leases(provider) |> should.equal(Ok(1))
        process.kill(owner.executor)
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn executor_owner_death_cancels_idle_upstream_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        process.kill(owner.executor)
        cancelled(fixture, provider, owner)
        read_all(client) |> should.equal(#(prefix, False))
      })
    },
  )
}

pub fn coordinator_death_kills_blocked_executor_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        process.kill(owner.coordinator)
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn normal_eof_preserves_prefix_order_and_one_terminal_chunk_test() {
  with_server(
    "normal",
    ByTick,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        release(fixture)
        let #(body, completed) = read_all(client)
        body |> should.equal(complete)
        completed |> should.be_true
        no_leak(body)
        cancelled(fixture, provider, owner)
        // All four callbacks (three data pulls plus EOF) use the same adopted PID.
        let events = collect_events(server.events, [])
        list.each(events, fn(event) {
          case event {
            Callback(pid) | Pull(_, pid) | Wrote(_, pid) ->
              pid |> should.equal(owner.executor)
          }
        })
        list.filter_map(events, fn(event) {
          case event {
            Wrote(sequence, _) -> Ok(sequence)
            _ -> Error(Nil)
          }
        })
        |> should.equal([2, 3])
      })
    },
  )
}

fn collect_events(events, accumulated) {
  case process.receive(events, 0) {
    Ok(event) -> collect_events(events, [event, ..accumulated])
    Error(_) -> list.reverse(accumulated)
  }
}

pub fn upstream_error_keeps_valid_prefix_without_invented_eof_test() {
  with_server(
    "error",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        release(fixture)
        read_all(client) |> should.equal(#(prefix, False))
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn repeated_owner_cancel_releases_once_and_aborts_test() {
  with_server(
    "idle",
    RepeatedCancel,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        read_all(client) |> should.equal(#(prefix, False))
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn downstream_send_failure_releases_stream_test() {
  with_server(
    "idle",
    FailedWrite,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        read_all(client) |> should.equal(#(prefix, False))
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn downstream_reset_interrupts_actual_write_backpressure_test() {
  with_server(
    "idle",
    Backpressure,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        let deadline = pressure_deadline(client)
        let assert Ok(PressureReady(socket, writer, begin)) =
          process.receive(server.writes, remaining_ms(deadline))
        writer |> should.equal(owner.executor)
        configure_pressure(socket, client) |> should.be_ok
        { remaining_ms(deadline) > 0 } |> should.be_true
        process.send(begin, deadline)
        let blocked =
          await_blocked_write(server.writes, owner, client, deadline, None)
        blocked.socket |> should.equal(socket)
        report_write(blocked, owner, client, deadline)
        // Third, final joint sample plus completion recheck, still under the
        // same deadline. No client reset is permitted on unmet prerequisites.
        sample_write(blocked, owner, client, deadline) |> should.be_true
        process.receive(server.writes, 0) |> should.equal(Error(Nil))
        { remaining_ms(deadline) > 0 } |> should.be_true
        reset_client(client)
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn pending_application_message_limit_aborts_blocked_callback_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        list.each(list.repeat(Tick, 33), fn(message) {
          process.send(owner.messages, message)
        })
        cancelled(fixture, provider, owner)
        read_all(client) |> should.equal(#(prefix, False))
      })
    },
  )
}

pub fn retained_post_request_tail_is_not_dispatched_or_body_test() {
  with_server(
    "normal",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        send_tail(client, pipeline_tail)
        release(fixture)
        read_all(client) |> should.equal(#(complete, True))
        cancelled(fixture, provider, owner)
        process.receive(server.handled, 0) |> should.equal(Ok("/stream"))
        process.receive(server.handled, 0) |> should.equal(Error(Nil))
      })
    },
  )
}

pub fn post_request_tail_limit_aborts_without_success_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        send_tail(client, string.repeat("p", 65_537))
        cancelled(fixture, provider, owner)
        read_all(client) |> should.equal(#(prefix, False))
      })
    },
  )
}

pub fn coalesced_chunked_body_tail_peek_preserves_owner_test() {
  with_server(
    "normal",
    Forward,
    False,
    False,
    True,
    fn(fixture, provider, server) {
      let request =
        "POST /stream HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"
        <> pipeline_tail
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        release(fixture)
        read_all(client) |> should.equal(#(complete, True))
        cancelled(fixture, provider, owner)
        process.receive(server.handled, 0) |> should.equal(Ok("/stream"))
        process.receive(server.handled, 0) |> should.equal(Error(Nil))
      })
    },
  )
}

pub fn active_tcp_half_close_aborts_without_hang_or_lease_leak_test() {
  with_server(
    "idle",
    Forward,
    False,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        half_close(client)
        cancelled(fixture, provider, owner)
        read_all(client) |> should.equal(#(prefix, False))
      })
    },
  )
}

pub fn retained_passive_half_close_control_can_finish_response_test() {
  with_server(
    "normal",
    Forward,
    True,
    False,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, False, True, fn(client) {
        let owner = owner(server, True)
        pending_pull(server, owner)
        half_close(client)
        peer_eof(fixture, 150) |> should.be_false
        release(fixture)
        read_all(client) |> should.equal(#(complete, True))
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn tls_nonowner_executor_send_and_normal_eof_test() {
  with_server(
    "normal",
    ByTick,
    False,
    True,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, True, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        release(fixture)
        read_all(client) |> should.equal(#(complete, True))
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn tls_idle_close_interrupts_adopted_executor_test() {
  with_server(
    "idle",
    Forward,
    False,
    True,
    False,
    fn(fixture, provider, server) {
      with_client(server.port, request, True, True, fn(client) {
        let owner = owner(server, False)
        pending_pull(server, owner)
        close_client(client)
        cancelled(fixture, provider, owner)
      })
    },
  )
}

pub fn unread_request_body_handoff_is_rejected_without_drain_test() {
  let ready = process.new_subject()
  let initialized = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(req) {
      mist.chunked(
        req,
        response.new(200),
        fn(_) { process.send(initialized, Nil) },
        fn(_, _, _) { mist.chunk_stop() },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  process.unlink(server.pid)
  let assert Ok(port) = process.receive(ready, 1000)
  with_cleanup(
    fn() {
      with_client(
        port,
        "POST /stream HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\n\r\n{}",
        False,
        False,
        fn(client) {
          headers(client) |> string.contains(" 400 ") |> should.be_true
          process.receive(initialized, 0) |> should.equal(Error(Nil))
        },
      )
    },
    fn() { stop_server(server.pid) },
  )
}
