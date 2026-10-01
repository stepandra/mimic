/// Actual bounded execution using ONLY synthetic injectable/loopback fixtures.
/// This does not launch CPA, native clients, F02/Docker or any paid service.
import argv
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import live_test
import mimic/live
import mimic/live/admission
import mimic/live/budget
import mimic/live/http
import mimic/live/identity
import mimic/live/policy
import mimic/live/runner
import mimic/live/synthetic
import simplifile

fn one_cost(approval: policy.Approval, binding, request) -> policy.Approval {
  let plan = live_test.plan(approval, binding, request)
  policy.Approval(
    ..approval,
    limits: policy.Limits(
      ..approval.limits,
      cost_nano_usd: policy.cost_ceiling(plan),
    ),
  )
}

pub fn reservation_precedes_send_and_concurrent_callers_cannot_overspend_test() {
  let #(approval, binding, request) = live_test.fixture()
  let approval = one_cost(approval, binding, request)
  let entered = process.new_subject()
  let finished = process.new_subject()
  let transport =
    synthetic.transport(
      Some(runner.Usage(1, 1)),
      fn(plan) {
        let release = process.new_subject()
        process.send(entered, #(plan, release))
        let _ = process.receive(release, 1000)
        Nil
      },
      fn() { Nil },
    )
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(index) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          finished,
          runner.execute(running, "caller-" <> int.to_string(index), request),
        )
      })
  })
  let assert Ok(#(plan, release)) = process.receive(entered, 1000)
  let assert Ok(snapshot) = runner.snapshot(running)
  snapshot.requests_reserved |> should.equal(1)
  snapshot.cost_reserved_nano_usd |> should.equal(policy.cost_ceiling(plan))
  // Worker is blocked before its synthetic write finishes; reservation already
  // exists. Lower observed usage later does not release ANY allowance.
  process.send(release, Nil)
  let outcomes =
    list.map([1, 2, 3, 4, 5, 6, 7, 8], fn(_) {
      let assert Ok(outcome) = process.receive(finished, 1500)
      outcome
    })
  list.count(outcomes, result.is_ok) |> should.equal(1)
  list.count(outcomes, result.is_error) |> should.equal(7)
  process.receive(entered, 0) |> should.equal(Error(Nil))
  let assert Ok(final) = runner.close(running)
  final.cost_reserved_nano_usd |> should.equal(snapshot.cost_reserved_nano_usd)
}

pub fn failures_before_and_after_send_keep_full_reservation_test() {
  let #(approval, binding, request) = live_test.fixture()
  let approval = one_cost(approval, binding, request)
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let called = process.new_subject()
  let before =
    runner.Transport(
      fn(_, _) { Error("synthetic_connect_failure") },
      fn(connection: Int, _, _) {
        process.send(called, Nil)
        Ok(connection)
      },
      fn(_: Int, _, _) { Ok(runner.End(None)) },
      fn(_) { Nil },
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, before)
  let assert Ok(outcome) = runner.execute(running, "pre-send", request)
  outcome.delivery |> should.equal(runner.NotSent)
  outcome.reason |> should.equal(runner.ConnectFailed)
  runner.execute(running, "different-id", request)
  |> should.equal(Error("live_budget_exhausted"))
  process.receive(called, 0) |> should.equal(Error(Nil))
  let assert Ok(final) = runner.close(running)
  final.requests_reserved |> should.equal(1)

  let after =
    runner.Transport(
      fn(_, _) { Ok(0) },
      fn(_connection, _, _) {
        process.send(called, Nil)
        Error("synthetic_partial_write_unknown")
      },
      fn(_: Int, _, _) { Ok(runner.End(None)) },
      fn(_) { Nil },
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, after)
  let assert Ok(outcome) = runner.execute(running, "post-send", request)
  outcome.delivery |> should.equal(runner.Uncertain)
  outcome.reason |> should.equal(runner.WriteFailed)
  let assert Ok(Nil) = process.receive(called, 1000)
  runner.execute(running, "post-send", request) |> should.be_error
  runner.execute(running, "explicit-retry", request)
  |> should.equal(Error("live_budget_exhausted"))
  process.receive(called, 0) |> should.equal(Error(Nil))
  let assert Ok(final2) = runner.close(running)
  final2.cost_reserved_nano_usd |> should.equal(final.cost_reserved_nano_usd)
}

pub fn cancellation_and_timeout_never_refund_or_replay_test() {
  let #(approval, binding, request) = live_test.fixture()
  let approval = one_cost(approval, binding, request)
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let entered = process.new_subject()
  let transport =
    synthetic.transport(
      None,
      fn(_) {
        process.send(entered, process.self())
        process.sleep_forever()
      },
      fn() { Nil },
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let attempt = runner.submit(running, "cancelled-send", request)
  let assert Ok(worker) = process.receive(entered, 1000)
  let monitor = process.monitor(worker)
  runner.cancel(running, "cancelled-send") |> should.equal(Ok(Nil))
  let assert Ok(outcome) = runner.await(attempt)
  outcome.delivery |> should.equal(runner.Uncertain)
  outcome.reason |> should.equal(runner.Cancelled)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  down |> should.equal(Ok(Nil))
  runner.execute(running, "cancellation-is-not-a-refund", request)
  |> should.equal(Error("live_budget_exhausted"))
  let assert Ok(cancelled) = runner.close(running)

  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(..approval.limits, duration_ms: 500, request_ms: 50),
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let started = runner.now_ms()
  let assert Ok(outcome) = runner.execute(running, "timeout-send", request)
  outcome.reason |> should.equal(runner.TimedOut)
  outcome.delivery |> should.equal(runner.Uncertain)
  { runner.now_ms() - started < 1000 } |> should.be_true
  runner.execute(running, "timeout-is-not-a-refund", request)
  |> should.equal(Error("live_budget_exhausted"))
  let assert Ok(timed) = runner.close(running)
  timed.cost_reserved_nano_usd |> should.equal(cancelled.cost_reserved_nano_usd)
}

pub fn unknown_usage_cost_and_invalid_admission_never_create_allowance_test() {
  let #(approval, binding, request) = live_test.fixture()
  let approval = one_cost(approval, binding, request)
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let called = process.new_subject()
  let transport =
    synthetic.transport(None, fn(_) { process.send(called, Nil) }, fn() { Nil })
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let assert Ok(outcome) = runner.execute(running, "unknown-usage", request)
  outcome.reason |> should.equal(runner.Completed)
  outcome.usage |> should.equal(None)
  outcome.observed_cost_nano_usd |> should.equal(None)
  runner.execute(running, "no-usage-does-not-mean-free", request)
  |> should.equal(Error("live_budget_exhausted"))
  let assert Ok(Nil) = process.receive(called, 1000)
  process.receive(called, 0) |> should.equal(Error(Nil))
  let _ = runner.close(running)

  let unpriced = policy.Approval(..approval, price: None)
  let assert Ok(running) = runner.start(allowed, unpriced, binding, transport)
  runner.execute(running, "unknown-price", request)
  |> should.equal(Error("live_unknown_pricing"))
  runner.execute(
    running,
    "wrong-route",
    policy.Request(..request, path: "/redirect"),
  )
  |> should.be_error
  let assert Ok(snapshot) = runner.snapshot(running)
  snapshot.requests_reserved |> should.equal(0)
  process.receive(called, 0) |> should.equal(Error(Nil))
  let _ = runner.close(running)
}

pub fn response_chunk_and_known_usage_limits_close_or_cancel_test() {
  let #(approval, binding, request) = live_test.fixture()
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let cancelled = process.new_subject()
  let transport =
    synthetic.transport(Some(runner.Usage(1, 33)), fn(_) { Nil }, fn() {
      process.send(cancelled, Nil)
    })
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let assert Ok(outcome) =
    runner.execute(running, "above-output-ceiling", request)
  outcome.reason |> should.equal(runner.UsageLimit)
  runner.execute(running, "after-usage-violation", request)
  |> should.equal(Error("live_run_closed"))
  let assert Ok(snapshot) = runner.snapshot(running)
  snapshot.lifecycle |> should.equal(budget.Closed("usage_ceiling_violated"))
  let assert Ok(Nil) = process.receive(cancelled, 1000)
  let _ = runner.close(running)

  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(..approval.limits, response_bytes: 3),
    )
  let transport =
    synthetic.transport(None, fn(_) { Nil }, fn() {
      process.send(cancelled, Nil)
    })
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let assert Ok(outcome) =
    runner.execute(running, "oversized-response", request)
  outcome.reason |> should.equal(runner.ResponseLimit)
  let assert Ok(Nil) = process.receive(cancelled, 1000)
  let _ = runner.close(running)

  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(
        ..approval.limits,
        response_bytes: 4096,
        stream_chunks: 1,
      ),
    )
  let endless =
    runner.Transport(
      fn(_, _) { Ok(0) },
      fn(connection, _, _) { Ok(connection) },
      fn(connection, _, _) {
        case connection {
          0 -> Ok(runner.Head(200, 1))
          _ -> Ok(runner.Data(<<65>>, 1))
        }
      },
      fn(_) { Nil },
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, endless)
  let assert Ok(outcome) = runner.execute(running, "endless-chunks", request)
  outcome.reason |> should.equal(runner.ResponseLimit)
  let _ = runner.close(running)
}

pub fn owner_death_closes_execution_and_abandoned_run_is_bounded_test() {
  let #(approval, binding, request) = live_test.fixture()
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let entered = process.new_subject()
  let transport =
    synthetic.transport(
      None,
      fn(_) {
        process.send(entered, process.self())
        process.sleep_forever()
      },
      fn() { Nil },
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let _ = runner.submit(running, "owner-dies", request)
  let assert Ok(worker) = process.receive(entered, 1000)
  let monitor = process.monitor(worker)
  process.kill(runner.pid(running))
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1000)
  |> should.equal(Ok(Nil))

  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(..approval.limits, duration_ms: 20, request_ms: 10),
    )
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let monitor = process.monitor(runner.pid(running))
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(1500)
  |> should.equal(Ok(Nil))
}

// Trusted synthetic code exercising the production runner's pull seam.
// The concrete HTTP tests below exercise the unchanged shared SSE parser.
fn scripted_transport(
  frames: List(runner.Frame(Int)),
  pulled: process.Subject(Int),
  cancelled: process.Subject(Nil),
) -> runner.Transport(Int) {
  runner.Transport(
    fn(_, _) { Ok(0) },
    fn(connection, _, _) { Ok(connection) },
    fn(connection, _, _) {
      process.send(pulled, connection)
      list.drop(frames, connection)
      |> list.first
      |> result.replace_error("synthetic_script_exhausted")
    },
    fn(_) { process.send(cancelled, Nil) },
  )
}

fn assert_run_closed(
  running: runner.Runner,
  request: policy.Request,
  lifecycle: String,
  reserved_cost: Int,
) {
  runner.execute(running, "after-usage-rejection", request)
  |> should.equal(Error("live_run_closed"))
  let assert Ok(snapshot) = runner.snapshot(running)
  snapshot.lifecycle |> should.equal(budget.Closed(lifecycle))
  snapshot.requests_reserved |> should.equal(1)
  snapshot.cost_reserved_nano_usd |> should.equal(reserved_cost)
  let assert Ok(final) = runner.close(running)
  final.cost_reserved_nano_usd |> should.equal(reserved_cost)
}

pub fn ordered_usage_breach_stops_before_any_later_pull_test() {
  let #(approval, binding, request) = live_test.fixture()
  let pulled = process.new_subject()
  let cancelled = process.new_subject()
  let transport =
    scripted_transport(
      [
        runner.Head(200, 1),
        runner.Data(bit_array.from_string("raw-usage"), 2),
        runner.ObservedUsage(runner.Usage(1, 33), 3),
        runner.ObservedUsage(runner.Usage(1, 2), 4),
        runner.End(None),
      ],
      pulled,
      cancelled,
    )
  let assert Ok(allowed) = admission.synthetic(approval.endpoint)
  let assert Ok(running) = runner.start(allowed, approval, binding, transport)
  let assert Ok(outcome) =
    runner.execute(running, "early-usage-breach", request)
  outcome.reason |> should.equal(runner.UsageLimit)
  outcome.usage |> should.equal(Some(runner.Usage(1, 33)))
  outcome.response_bytes |> should.equal(9)
  outcome.observed_cost_nano_usd |> should.equal(None)
  list.each([0, 1, 2], fn(index) {
    process.receive(pulled, 1000) |> should.equal(Ok(index))
  })
  process.receive(pulled, 0) |> should.equal(Error(Nil))
  process.receive(cancelled, 1000) |> should.equal(Ok(Nil))
  assert_run_closed(
    running,
    request,
    "usage_ceiling_violated",
    policy.cost_ceiling(live_test.plan(approval, binding, request)),
  )
}

pub fn cumulative_usage_and_terminal_snapshots_cannot_decrease_test() {
  let #(approval, binding, request) = live_test.fixture()
  let prior = runner.Usage(2, 3)
  list.each(
    [
      #(runner.End(None), runner.Completed),
      #(runner.End(Some(prior)), runner.Completed),
      #(runner.End(Some(runner.Usage(1, 3))), runner.UsageNonMonotonic),
      #(runner.End(Some(runner.Usage(2, 2))), runner.UsageNonMonotonic),
      #(runner.ObservedUsage(runner.Usage(1, 3), 4), runner.UsageNonMonotonic),
      #(runner.ObservedUsage(runner.Usage(2, 2), 4), runner.UsageNonMonotonic),
      #(runner.ObservedUsage(runner.Usage(-1, 3), 4), runner.UsageInvalid),
      #(runner.ObservedUsage(runner.Usage(2, -1), 4), runner.UsageInvalid),
    ],
    fn(test_case) {
      let #(terminal, expected) = test_case
      let pulled = process.new_subject()
      let cancelled = process.new_subject()
      let transport =
        scripted_transport(
          [
            runner.Head(200, 1),
            runner.Data(<<65>>, 2),
            runner.ObservedUsage(prior, 3),
            terminal,
            runner.End(None),
          ],
          pulled,
          cancelled,
        )
      let assert Ok(allowed) = admission.synthetic(approval.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, transport)
      let assert Ok(outcome) =
        runner.execute(running, "cumulative-usage", request)
      outcome.reason |> should.equal(expected)
      outcome.usage |> should.equal(Some(prior))
      list.each([0, 1, 2, 3], fn(index) {
        process.receive(pulled, 1000) |> should.equal(Ok(index))
      })
      process.receive(pulled, 0) |> should.equal(Error(Nil))
      process.receive(cancelled, 1000) |> should.equal(Ok(Nil))
      case expected {
        runner.Completed -> {
          outcome.observed_cost_nano_usd
          |> should.equal(
            Some(policy.usage_cost(
              live_test.plan(approval, binding, request),
              prior.input_tokens,
              prior.output_tokens,
            )),
          )
          let _ = runner.close(running)
          Nil
        }
        _ ->
          assert_run_closed(
            running,
            request,
            "usage_contract_violated",
            policy.cost_ceiling(live_test.plan(approval, binding, request)),
          )
      }
    },
  )
}

pub fn usage_observation_cap_includes_terminal_snapshot_test() {
  let #(approval, binding, request) = live_test.fixture()
  list.each(
    [
      #(1024, None, runner.Completed),
      #(1025, None, runner.ResponseLimit),
      #(1023, Some(runner.Usage(1, 1)), runner.Completed),
      #(1024, Some(runner.Usage(1, 1)), runner.ResponseLimit),
    ],
    fn(test_case) {
      let #(observations, terminal, expected) = test_case
      let transport =
        runner.Transport(
          fn(_, _) { Ok(0) },
          fn(connection, _, _) { Ok(connection) },
          fn(connection, _, _) {
            case connection {
              0 -> Ok(runner.Head(200, 1))
              index if index <= observations ->
                Ok(runner.ObservedUsage(runner.Usage(1, 1), index + 1))
              _ -> Ok(runner.End(terminal))
            }
          },
          fn(_) { Nil },
        )
      let assert Ok(allowed) = admission.synthetic(approval.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, transport)
      let assert Ok(outcome) =
        runner.execute(running, "bounded-observations", request)
      outcome.reason |> should.equal(expected)
      outcome.usage |> should.equal(Some(runner.Usage(1, 1)))
      let assert Ok(final) = runner.close(running)
      final.requests_reserved |> should.equal(1)
      final.cost_reserved_nano_usd
      |> should.equal(
        policy.cost_ceiling(live_test.plan(approval, binding, request)),
      )
    },
  )
}

type Listener

type Socket

@external(erlang, "mimic_live_test_ffi", "listen_loopback")
fn listen_loopback() -> Result(#(Listener, Int), String)

@external(erlang, "mimic_live_test_ffi", "accept")
fn accept(listener: Listener, timeout: Int) -> Result(Socket, String)

@external(erlang, "mimic_live_test_ffi", "close_listener")
fn close_listener(listener: Listener) -> Nil

@external(erlang, "mimic_egress_ffi", "line")
fn line(socket: Socket, timeout: Int) -> Result(String, String)

@external(erlang, "mimic_egress_ffi", "bytes")
fn bytes(socket: Socket, length: Int, timeout: Int) -> Result(BitArray, String)

@external(erlang, "mimic_egress_ffi", "write")
fn write(socket: Socket, raw: String, timeout: Int) -> Result(Nil, String)

@external(erlang, "mimic_egress_ffi", "close")
fn close_socket(socket: Socket) -> Nil

type PeerRead {
  PeerClosed
  PeerReset
  PeerTimeout
  PeerData(BitArray)
  PeerError
}

type ClosureEvidence {
  PeerObserved(PeerRead)
  ServerDisconnected
}

@external(erlang, "mimic_live_test_ffi", "peer_read")
fn peer_read(socket: Socket, timeout: Int) -> PeerRead

@external(erlang, "mimic_egress_ffi", "connect")
fn connect_socket(
  host: String,
  port: Int,
  tls: Bool,
  timeout: Int,
) -> Result(Socket, String)

type FixtureMode {
  Reply(raw: String)
  Drop
  Hang
}

type Fixture {
  Fixture(
    listener: Listener,
    worker: process.Pid,
    endpoint: String,
    mode: FixtureMode,
    received: process.Subject(Result(String, String)),
    closed: process.Subject(ClosureEvidence),
    replayed: process.Subject(Bool),
  )
}

fn open_fixture(mode: FixtureMode) -> Fixture {
  let assert Ok(#(listener, port)) = listen_loopback()
  let received = process.new_subject()
  let closed = process.new_subject()
  let replayed = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      case accept(listener, 1000) {
        Error(error) -> process.send(received, Error(error))
        Ok(socket) -> {
          process.send(received, read_request(socket))
          case mode {
            Reply(raw) -> {
              let _ = write(socket, raw, 500)
              // Observe the remote close/reset BEFORE local fixture cleanup.
              process.send(closed, PeerObserved(peer_read(socket, 500)))
            }
            Hang -> process.send(closed, PeerObserved(peer_read(socket, 500)))
            Drop -> {
              close_socket(socket)
              // This fault is a server-side disconnect, not client-close proof.
              process.send(closed, ServerDisconnected)
            }
          }
          close_socket(socket)
          case accept(listener, 50) {
            Ok(extra) -> {
              close_socket(extra)
              process.send(replayed, True)
            }
            Error(_) -> process.send(replayed, False)
          }
        }
      }
    })
  Fixture(
    listener,
    worker,
    "http://127.0.0.1:" <> int.to_string(port),
    mode,
    received,
    closed,
    replayed,
  )
}

fn read_request(socket: Socket) -> Result(String, String) {
  use first <- result.try(line(socket, 1000))
  read_request_headers(socket, first, 0, 0)
}

fn read_request_headers(
  socket: Socket,
  raw: String,
  length: Int,
  count: Int,
) -> Result(String, String) {
  case count > 32 || string.byte_size(raw) > 8192 {
    True -> Error("synthetic_request_limit")
    False -> {
      use next <- result.try(line(socket, 1000))
      case next {
        "\r\n" -> {
          use body <- result.try(bytes(socket, length, 1000))
          use body <- result.try(
            bit_array.to_string(body)
            |> result.replace_error("synthetic_request_binary"),
          )
          Ok(raw <> "\r\n" <> body)
        }
        _ -> {
          let length = case string.split_once(next, "Content-Length: ") {
            Ok(#("", value)) ->
              int.parse(string.trim(value)) |> result.unwrap(-1)
            _ -> length
          }
          case length >= 0 && length <= 16_384 {
            True -> read_request_headers(socket, raw <> next, length, count + 1)
            False -> Error("synthetic_request_length")
          }
        }
      }
    }
  }
}

fn socket_setup(
  fixture: Fixture,
  streaming: Bool,
) -> #(policy.Approval, identity.Binding, policy.Request) {
  let assert Ok(contract) =
    simplifile.read("docs/parity/final-v1/contract.json")
  let assert Ok(setup) =
    synthetic.setup(
      contract,
      case streaming {
        True -> "codex-sse.final-v1"
        False -> "claude-messages.final-v1"
      },
      fixture.endpoint,
      streaming,
    )
  setup
}

fn peer_is_closed(observed: PeerRead) -> Bool {
  case observed {
    PeerClosed | PeerReset -> True
    PeerTimeout | PeerData(_) | PeerError -> False
  }
}

fn finish_fixture(fixture: Fixture) {
  let assert Ok(observed) = process.receive(fixture.closed, 1000)
  case fixture.mode {
    Drop -> observed |> should.equal(ServerDisconnected)
    _ ->
      case observed {
        PeerObserved(peer) -> peer_is_closed(peer) |> should.be_true
        _ -> panic as "server disconnect is not client-close evidence"
      }
  }
  let assert Ok(False) = process.receive(fixture.replayed, 1000)
  close_listener(fixture.listener)
  process.kill(fixture.worker)
}

pub fn open_peer_timeout_is_not_socket_close_evidence_test() {
  let assert Ok(#(listener, port)) = listen_loopback()
  let observed = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = accept(listener, 1000)
      let legacy_probe = bytes(socket, 1, 500)
      process.send(observed, #(legacy_probe, peer_read(socket, 500)))
      close_socket(socket)
    })
  // The peer stays open through both real 500ms probes. The old error-only
  // oracle says "closed"; the corrected OS-tag oracle must say "not closed".
  let assert Ok(client) = connect_socket("127.0.0.1", port, False, 1000)
  let assert Ok(#(legacy_probe, current_probe)) =
    process.receive(observed, 1500)
  result.is_error(legacy_probe) |> should.be_true
  current_probe |> should.equal(PeerTimeout)
  peer_is_closed(current_probe) |> should.be_false
  close_socket(client)
  close_listener(listener)
  process.kill(worker)
}

pub fn actual_loopback_buffered_and_sse_execution_test() {
  let body = "{\"usage\":{\"input_tokens\":1,\"output_tokens\":2}}"
  let fixture =
    open_fixture(Reply(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
      <> int.to_string(string.byte_size(body))
      <> "\r\n\r\n"
      <> body,
    ))
  let #(approval, binding, request) = socket_setup(fixture, False)
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let assert Ok(outcome) = runner.execute(running, "buffered-loopback", request)
  outcome.reason |> should.equal(runner.Completed)
  outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
  let assert Ok(Ok(raw)) = process.receive(fixture.received, 1000)
  string.starts_with(raw, "POST /v1/messages HTTP/1.1\r\n") |> should.be_true
  string.contains(raw, "Accept-Encoding: identity\r\n") |> should.be_true
  string.contains(raw, "Connection: close\r\n") |> should.be_true
  string.ends_with(raw, request.body) |> should.be_true
  let _ = runner.close(running)
  finish_fixture(fixture)

  let data = "data: " <> body <> "\n\ndata: [DONE]\n\n"
  let fixture =
    open_fixture(Reply(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      <> int.to_base16(string.byte_size(data))
      <> "\r\n"
      <> data
      <> "\r\n0\r\n\r\n",
    ))
  let #(approval, binding, request) = socket_setup(fixture, True)
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let assert Ok(outcome) = runner.execute(running, "stream-loopback", request)
  outcome.reason |> should.equal(runner.Completed)
  outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
  let assert Ok(Ok(raw)) = process.receive(fixture.received, 1000)
  string.contains(raw, "Accept: text/event-stream\r\n") |> should.be_true
  let _ = runner.close(running)
  finish_fixture(fixture)
}

fn usage_event(input: Int, output: Int) -> String {
  "data:"
  <> json.to_string(
    json.object([
      #(
        "usage",
        json.object([
          #("input_tokens", json.int(input)),
          #("output_tokens", json.int(output)),
        ]),
      ),
    ]),
  )
  <> "\n\n"
}

fn sse_response(chunks: List(String), terminal: String) -> String {
  "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
  <> string.join(
    list.map(chunks, fn(data) {
      int.to_base16(string.byte_size(data)) <> "\r\n" <> data <> "\r\n"
    }),
    "",
  )
  <> terminal
}

pub fn actual_loopback_coalesced_high_low_and_truncated_tail_are_sticky_test() {
  let high = usage_event(1, 33)
  let low = usage_event(1, 2)
  list.each(
    [
      #(high <> low, True),
      #(high <> "event: usage\ndata:{\"usage\":", True),
      #(high, False),
    ],
    fn(test_case) {
      let #(data, ended) = test_case
      let raw = case ended {
        True -> sse_response([data], "0\r\n\r\n")
        // No chunk separator, zero chunk or SSE terminal will ever arrive.
        // Usage must be checked before any of those later socket pulls.
        False ->
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
          <> int.to_base16(string.byte_size(data))
          <> "\r\n"
          <> data
      }
      let fixture = open_fixture(Reply(raw))
      let #(approval, binding, request) = socket_setup(fixture, True)
      let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, http.transport())
      let assert Ok(outcome) =
        runner.execute(running, "sticky-high-usage", request)
      outcome.delivery |> should.equal(runner.Sent)
      outcome.reason |> should.equal(runner.UsageLimit)
      outcome.usage |> should.equal(Some(runner.Usage(1, 33)))
      outcome.response_bytes |> should.equal(string.byte_size(data))
      assert_run_closed(
        running,
        request,
        "usage_ceiling_violated",
        policy.cost_ceiling(live_test.plan(approval, binding, request)),
      )
      let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
      finish_fixture(fixture)
    },
  )
}

pub fn actual_loopback_event_prefix_multiline_and_split_utf8_usage_test() {
  let prefix = ":synthetic comment\r\nevent: usage\r\ndata:{\"text\":\""
  // Place the first byte of € at byte 4095 so HTTP's real 4096-byte pulls
  // split the codepoint. The shared byte parser must preserve it unchanged.
  let data =
    prefix
    <> string.repeat("a", 4095 - string.byte_size(prefix))
    <> "€🙂\",\r\ndata:\"usage\":{\"input_tokens\":1,\r\ndata:\"output_tokens\":2}}\r\n\r\n"
  let fixture = open_fixture(Reply(sse_response([data], "0\r\n\r\n")))
  let #(approval, binding, request) = socket_setup(fixture, True)
  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(
        ..approval.limits,
        response_bytes: string.byte_size(data),
        stream_chunks: 2,
      ),
    )
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let assert Ok(outcome) =
    runner.execute(running, "multiline-utf8-usage", request)
  outcome.reason |> should.equal(runner.Completed)
  outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
  outcome.response_bytes |> should.equal(string.byte_size(data))
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  let _ = runner.close(running)
  finish_fixture(fixture)
}

pub fn actual_loopback_unknown_usage_does_not_erase_known_counts_test() {
  let data =
    usage_event(1, 2)
    <> "event: unknown\ndata:{\"text\":\"synthetic\"}\n\n"
    <> "data:{\"usage\":null}\n\ndata:[DONE]\n\n"
  let fixture = open_fixture(Reply(sse_response([data], "0\r\n\r\n")))
  let #(approval, binding, request) = socket_setup(fixture, True)
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let assert Ok(outcome) =
    runner.execute(running, "unknown-after-known", request)
  outcome.reason |> should.equal(runner.Completed)
  outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
  outcome.response_bytes |> should.equal(string.byte_size(data))
  outcome.observed_cost_nano_usd
  |> should.equal(
    Some(policy.usage_cost(live_test.plan(approval, binding, request), 1, 2)),
  )
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  let _ = runner.close(running)
  finish_fixture(fixture)
}

pub fn actual_loopback_decreasing_and_unsupported_usage_close_test() {
  let known = usage_event(2, 3)
  list.each(
    [
      #(usage_event(1, 3), runner.UsageNonMonotonic),
      #(usage_event(2, 2), runner.UsageNonMonotonic),
      #("data:{\"usage\":{\"input_tokens\":1}}\n\n", runner.UsageInvalid),
      #("data:{\"usage\":{\"output_tokens\":2}}\n\n", runner.UsageInvalid),
      #(
        "data:{\"usage\":{\"input_tokens_delta\":1,\"output_tokens_delta\":2}}\n\n",
        runner.UsageInvalid,
      ),
      #(
        "data:{\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"delta\":true}}\n\n",
        runner.UsageInvalid,
      ),
      #(
        "data:{\"usage\":{\"input_tokens\":null,\"output_tokens\":2}}\n\n",
        runner.UsageInvalid,
      ),
      #(
        "data:{\"usage\":{\"input_tokens\":\"1\",\"output_tokens\":2}}\n\n",
        runner.UsageInvalid,
      ),
      #("data:{\"usage\":[]}\n\n", runner.UsageInvalid),
      #("data:{\"usage\":false}\n\n", runner.UsageInvalid),
      #(usage_event(-1, 3), runner.UsageInvalid),
      #(usage_event(2, -1), runner.UsageInvalid),
    ],
    fn(test_case) {
      let #(bad, expected) = test_case
      let fixture =
        open_fixture(Reply(sse_response([known <> bad], "0\r\n\r\n")))
      let #(approval, binding, request) = socket_setup(fixture, True)
      let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, http.transport())
      let assert Ok(outcome) =
        runner.execute(running, "unsupported-usage", request)
      outcome.reason |> should.equal(expected)
      outcome.usage |> should.equal(Some(runner.Usage(2, 3)))
      outcome.observed_cost_nano_usd |> should.equal(None)
      assert_run_closed(
        running,
        request,
        "usage_contract_violated",
        policy.cost_ceiling(live_test.plan(approval, binding, request)),
      )
      let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
      finish_fixture(fixture)
    },
  )
}

pub fn actual_loopback_usage_bytes_are_metered_before_observations_test() {
  let first = usage_event(1, 2)
  let second = "data:{\"usage\":null}\n\n"
  list.each([0, 1], fn(shortfall) {
    let fixture =
      open_fixture(Reply(sse_response([first, second], "0\r\n\r\n")))
    let #(approval, binding, request) = socket_setup(fixture, True)
    let approval =
      policy.Approval(
        ..approval,
        limits: policy.Limits(
          ..approval.limits,
          response_bytes: string.byte_size(first <> second) - shortfall,
        ),
      )
    let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
    let assert Ok(running) =
      runner.start(allowed, approval, binding, http.transport())
    let assert Ok(outcome) =
      runner.execute(running, "usage-byte-accounting", request)
    outcome.reason
    |> should.equal(case shortfall {
      0 -> runner.Completed
      _ -> runner.ReadFailed
    })
    outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
    outcome.response_bytes
    |> should.equal(case shortfall {
      0 -> string.byte_size(first <> second)
      _ -> string.byte_size(first)
    })
    let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
    let _ = runner.close(running)
    finish_fixture(fixture)
  })
}

pub fn actual_loopback_truncated_sse_retains_prior_usage_test() {
  list.each(
    ["event: usage\ndata:{\"usage\":", "data:{\"usage\":\n\n"],
    fn(tail) {
      let data = usage_event(1, 2) <> tail
      let fixture = open_fixture(Reply(sse_response([data], "0\r\n\r\n")))
      let #(approval, binding, request) = socket_setup(fixture, True)
      let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, http.transport())
      let assert Ok(outcome) =
        runner.execute(running, "truncated-known-usage", request)
      outcome.reason |> should.equal(runner.ReadFailed)
      outcome.usage |> should.equal(Some(runner.Usage(1, 2)))
      outcome.response_bytes |> should.equal(string.byte_size(data))
      let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
      let _ = runner.close(running)
      finish_fixture(fixture)
    },
  )
}

pub fn actual_loopback_after_send_failure_and_timeout_no_replay_test() {
  let fixture = open_fixture(Drop)
  let #(approval, binding, request) = socket_setup(fixture, False)
  let approval = one_cost(approval, binding, request)
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let assert Ok(outcome) =
    runner.execute(running, "disconnected-after-send", request)
  outcome.delivery |> should.equal(runner.Sent)
  outcome.reason |> should.equal(runner.ReadFailed)
  runner.execute(running, "not-a-free-retry", request)
  |> should.equal(Error("live_budget_exhausted"))
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  let _ = runner.close(running)
  finish_fixture(fixture)

  let fixture = open_fixture(Hang)
  let #(approval, binding, request) = socket_setup(fixture, False)
  let approval = one_cost(approval, binding, request)
  let approval =
    policy.Approval(
      ..approval,
      limits: policy.Limits(
        ..approval.limits,
        duration_ms: 500,
        request_ms: 150,
      ),
    )
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let started = runner.now_ms()
  let assert Ok(outcome) = runner.execute(running, "deadline-hang", request)
  list.contains([runner.TimedOut, runner.ReadFailed], outcome.reason)
  |> should.be_true
  { runner.now_ms() - started < 1000 } |> should.be_true
  runner.execute(running, "timeout-not-a-free-retry", request)
  |> should.equal(Error("live_budget_exhausted"))
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  let _ = runner.close(running)
  finish_fixture(fixture)
}

pub fn actual_loopback_operator_cancel_closes_socket_without_refund_test() {
  let fixture = open_fixture(Hang)
  let #(approval, binding, request) = socket_setup(fixture, False)
  let approval = one_cost(approval, binding, request)
  let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
  let assert Ok(running) =
    runner.start(allowed, approval, binding, http.transport())
  let attempt = runner.submit(running, "operator-cancel", request)
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  runner.cancel(running, "operator-cancel") |> should.equal(Ok(Nil))
  let assert Ok(outcome) = runner.await(attempt)
  outcome.reason |> should.equal(runner.Cancelled)
  outcome.delivery |> should.equal(runner.Uncertain)
  runner.execute(running, "cancel-is-not-free", request)
  |> should.equal(Error("live_budget_exhausted"))
  let _ = runner.close(running)
  finish_fixture(fixture)
}

pub fn actual_loopback_redirect_encoding_and_response_limits_fail_explicitly_test() {
  list.each(
    [
      "HTTP/1.1 302 Redirect\r\nLocation: http://outside.invalid/\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 65537\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
    ],
    fn(raw) {
      let fixture = open_fixture(Reply(raw))
      let #(approval, binding, request) = socket_setup(fixture, False)
      let assert Ok(allowed) = admission.synthetic(fixture.endpoint)
      let assert Ok(running) =
        runner.start(allowed, approval, binding, http.transport())
      let assert Ok(outcome) =
        runner.execute(running, "rejected-response", request)
      outcome.reason |> should.equal(runner.ReadFailed)
      let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
      let _ = runner.close(running)
      finish_fixture(fixture)
    },
  )
}

type FixtureFile

@external(erlang, "mimic_live_test_ffi", "write_private")
fn write_private(path: String, text: String) -> Result(FixtureFile, String)

@external(erlang, "mimic_live_test_ffi", "remove_fixture")
fn remove_fixture(file: FixtureFile) -> Result(Nil, String)

/// Explicit scratch dir is passed by the validation caller, never discovered
/// from HOME/environment/store. Only created fixture inode tokens are deleted.
pub fn actual_cli_private_input(directory: String) {
  let fixture =
    open_fixture(Reply(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}",
    ))
  let #(approval, binding, request) = socket_setup(fixture, False)
  let approval = one_cost(approval, binding, request)
  let approval_path = directory <> "/f04-approval.json"
  let body_path = directory <> "/f04-body.json"
  let assert Ok(approval_file) =
    write_private(
      approval_path,
      synthetic.approval_json(approval, binding, [
        "first",
        "explicit-retry",
        "first",
      ]),
    )
  let assert Ok(body_file) = write_private(body_path, request.body)
  let report =
    live.cli([
      "synthetic",
      approval_path,
      "docs/parity/final-v1/contract.json",
      body_path,
    ])
  // Clean up only the fixture files even if the CLI returned an error.
  remove_fixture(approval_file) |> should.equal(Ok(Nil))
  remove_fixture(body_file) |> should.equal(Ok(Nil))
  let assert Ok(report) = report
  json.parse(report, decode.at(["requests_reserved"], decode.int))
  |> should.equal(Ok(1))
  json.parse(report, decode.at(["cost_reserved_nano_usd"], decode.int))
  |> should.equal(
    Ok(policy.cost_ceiling(live_test.plan(approval, binding, request))),
  )
  string.contains(report, "live_budget_exhausted") |> should.be_true
  string.contains(report, "live_expired_or_duplicate_attempt") |> should.be_true
  string.contains(report, "\"running_identity\":\"unverified\"")
  |> should.be_true
  string.contains(report, "\"live\":\"not_run\"") |> should.be_true
  string.contains(
    report,
    "\"reason\":\"transport_completed_not_a_parity_pass\"",
  )
  |> should.be_true
  io.println("F04 synthetic CLI report: " <> report)
  let assert Ok(Ok(_)) = process.receive(fixture.received, 1000)
  finish_fixture(fixture)
}

/// Narrow validation main: only this synthetic harness, no unrelated workflows.
pub fn main() {
  let assert [directory] = argv.load().arguments
  reservation_precedes_send_and_concurrent_callers_cannot_overspend_test()
  failures_before_and_after_send_keep_full_reservation_test()
  cancellation_and_timeout_never_refund_or_replay_test()
  let _ = unknown_usage_cost_and_invalid_admission_never_create_allowance_test()
  let _ = response_chunk_and_known_usage_limits_close_or_cancel_test()
  owner_death_closes_execution_and_abandoned_run_is_bounded_test()
  ordered_usage_breach_stops_before_any_later_pull_test()
  cumulative_usage_and_terminal_snapshots_cannot_decrease_test()
  usage_observation_cap_includes_terminal_snapshot_test()
  actual_loopback_buffered_and_sse_execution_test()
  actual_loopback_coalesced_high_low_and_truncated_tail_are_sticky_test()
  actual_loopback_event_prefix_multiline_and_split_utf8_usage_test()
  actual_loopback_unknown_usage_does_not_erase_known_counts_test()
  actual_loopback_decreasing_and_unsupported_usage_close_test()
  actual_loopback_usage_bytes_are_metered_before_observations_test()
  actual_loopback_truncated_sse_retains_prior_usage_test()
  actual_loopback_after_send_failure_and_timeout_no_replay_test()
  actual_loopback_operator_cancel_closes_socket_without_refund_test()
  actual_loopback_redirect_encoding_and_response_limits_fail_explicitly_test()
  open_peer_timeout_is_not_socket_close_evidence_test()
  actual_cli_private_input(directory)
  io.println(
    "F04 synthetic execution checks completed; live/native admission remains blocked.",
  )
}
