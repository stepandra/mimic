/// Actual synthetic provider/runtime/socket regressions. No root-route, CPA,
/// captured/live upstream or native-client acceptance is claimed by this suite.
import codex_ws_lite_fixture as fixture
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ingress/keys
import mimic/ir
import mimic/protocol/responses/frames
import mimic/providers/codex/lite
import mimic/providers/codex/models
import mimic/providers/codex/request
import mimic/providers/codex/response
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/providers/codex_websocket
import mimic/providers/codex_websocket/errors
import mimic/providers/codex_websocket/fence
import mimic/providers/contracts
import mimic/providers/runtime
import mimic/providers/ws_transport
import mimic/recorder/tls

type Cleanup

@external(erlang, "mimic_f13_codex_ws_test_ffi", "diagnostic_start")
fn diagnostic_start() -> Nil

@external(erlang, "mimic_f13_codex_ws_test_ffi", "prepare_cleanup")
fn prepare_cleanup(
  connection: ws_transport.Connection,
  owner: process.Pid,
  helpers: List(process.Pid),
  endpoints: #(Int, Int),
) -> Result(Cleanup, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "await_prepared")
fn await_prepared(cleanup: Cleanup, timeout: Int) -> Result(Int, String)

type RootNotice {
  QueuedTick
  NativeTerminal(codex_websocket.Terminal)
}

@external(erlang, "mimic_f13_codex_ws_test_ffi", "saturate")
fn saturate(connection: ws_transport.Connection) -> Result(Int, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "now_ms")
fn now_ms() -> Int

@external(erlang, "mimic_f13_codex_ws_test_ffi", "blocked_helpers")
fn blocked_helpers(
  owner: process.Pid,
) -> Result(#(process.Pid, process.Pid), String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "await_cleanup")
fn await_cleanup(
  connection: ws_transport.Connection,
  guardian: process.Pid,
  sender: process.Pid,
  timeout: Int,
) -> Result(Int, String)

@external(erlang, "mimic_f13_codex_ws_test_ffi", "no_write_helpers")
fn no_write_helpers(owner: process.Pid) -> Bool

@external(erlang, "mimic_f13_codex_ws_test_ffi", "await_physical_close")
fn await_physical_close(
  connection: ws_transport.Connection,
  timeout: Int,
) -> Result(Int, String)

fn adapter(
  store: storage.Store,
  header: Bool,
  ca: Option(String),
) -> contracts.SessionAdapter(codex_websocket.Handle) {
  codex_websocket.native_adapter(
    "tenant",
    models.pinned(),
    "synthetic-f13/1",
    ca,
    header,
    store,
    fn() { True },
  )
}

fn message(session: runtime.Session, attempts: Int) -> String {
  let assert Ok(polled) = runtime.session_poll(session)
  case polled {
    Some(text) -> text
    None if attempts > 0 -> message(session, attempts - 1)
    _ -> panic as "synthetic F13 message not delivered"
  }
}

fn cleanup(engine: runtime.Runtime) {
  runtime.active_leases(engine) |> should.equal(Ok(0))
  runtime.stop(engine) |> should.be_ok
}

fn observed(mock: fixture.Mock) -> String {
  let assert Ok(value) = process.receive(mock.requests, 1000)
  value
}

fn no_extra(mock: fixture.Mock) {
  process.receive(mock.requests, 30) |> should.equal(Error(Nil))
}

pub fn f13_actual_socket_source_fixture_is_transparent_without_cursor_test() {
  list.each([False, True], fn(header) {
    let mock =
      fixture.peer(False, "", "", [
        fixture.turn([fixture.metadata, fixture.done, fixture.completed]),
      ])
    let store = fixture.store()
    let engine = fixture.runtime(store, mock, False)
    let req = fixture.request(fixture.create(None, !header))
    let assert Ok(opened) =
      runtime.open_session(engine, adapter(store, header, None), req)
    runtime.session_account(opened) |> should.equal("selected")
    let head = observed(mock)
    string.contains(head, "GET /backend-api/codex/responses HTTP/1.1")
    |> should.be_true
    string.contains(head, "Authorization: Bearer synthetic-f13-access")
    |> should.be_true
    string.contains(head, "Chatgpt-Account-Id: synthetic-f13-provider-account")
    |> should.be_true
    string.contains(head, "X-OpenAI-Internal-Codex-Responses-Lite: true")
    |> should.equal(header)
    string.contains(head, "session_id:") |> should.be_false
    runtime.session_send(opened, req) |> should.be_ok
    let assert Ok(sent) = ir.parse(observed(mock))
    ir.field(sent, "parallel_tool_calls")
    |> should.equal(Some(ir.Boolean(False)))
    ir.field(sent, "instructions") |> should.equal(None)
    ir.field(sent, "stream") |> should.equal(None)
    ir.field(sent, "client_metadata")
    |> should.equal(case header {
      True -> None
      False -> Some(ir.Object([#(lite.metadata_key, ir.Boolean(True))]))
    })
    message(opened, 100) |> should.equal(fixture.metadata)
    message(opened, 100) |> should.equal(fixture.done)
    message(opened, 100) |> should.equal(fixture.completed)
    runtime.session_send(
      opened,
      fixture.request(fixture.create(Some("resp_1"), !header)),
    )
    |> should.be_error
    process.receive(mock.closed, 1000) |> should.be_ok
    no_extra(mock)
    cleanup(engine)
    fixture.stop(mock)
  })
}

pub fn f13_actual_same_socket_continuation_and_reset_test() {
  let events = [fixture.created, fixture.done, fixture.completed]
  let mock = fixture.peer(False, "", "", list.repeat(fixture.turn(events), 3))
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  list.each([None, Some("resp_1"), None], fn(previous) {
    runtime.session_send(
      opened,
      fixture.request(fixture.create(previous, True)),
    )
    |> should.be_ok
    let assert Ok(sent) = ir.parse(observed(mock))
    ir.field(sent, "previous_response_id")
    |> should.equal(case previous {
      None -> None
      Some(id) -> Some(ir.String(id))
    })
    ir.field(sent, "input") |> should.equal(Some(ir.Array([])))
    list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  })
  runtime.session_cancel(opened)
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_actual_wss_uses_peer_verification_and_same_socket_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(fixture.ca_directory())
  let events = [fixture.created, fixture.done, fixture.completed]
  let mock = fixture.peer(True, cert, key, list.repeat(fixture.turn(events), 2))
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, True)
  let req = fixture.request(fixture.create(None, False))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, True, Some(cert)), req)
  let _ = observed(mock)
  list.each([None, Some("resp_1")], fn(previous) {
    runtime.session_send(
      opened,
      fixture.request(fixture.create(previous, False)),
    )
    |> should.be_ok
    let _ = observed(mock)
    list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  })
  runtime.session_cancel(opened)
  process.receive(mock.closed, 1000) |> should.be_ok
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_catalog_is_authority_and_default_adapter_stays_strict_test() {
  let mock = fixture.peer(False, "", "", [])
  let store = fixture.store()
  let context = fixture.context(mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(body) = ir.parse(req.body)
  let body =
    ir.Object([#("model", ir.String("gpt-5.5")), ..ir.extras(body, ["model"])])
  adapter(store, False, None).open(
    context,
    contracts.Request(..req, model: "gpt-5.5", body: ir.stringify(body)),
  )
  |> should.equal(
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
  )
  codex_websocket.adapter("tenant", models.pinned(), "synthetic-f13/1", None).open(
    context,
    req,
  )
  |> should.be_error
  no_extra(mock)
  fixture.stop(mock)
}

pub fn f13_catalog_flag_does_not_force_unmarked_requests_sparse_test() {
  let strict_created =
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}"
  let strict_completed =
    "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}"
  let events = [strict_created, strict_completed]
  let mock = fixture.peer(False, "", "", list.repeat(fixture.turn(events), 2))
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, False))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  list.each([None, Some("resp_1")], fn(previous) {
    runtime.session_send(
      opened,
      fixture.request(fixture.create(previous, False)),
    )
    |> should.be_ok
    let _ = observed(mock)
    list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  })
  runtime.session_send(opened, fixture.request(fixture.create(None, True)))
  |> should.be_error
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_actual_custom_tool_pairing_and_encrypted_reasoning_are_preserved_test() {
  let reasoning =
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[],\"encrypted_content\":\"synthetic-opaque\"}}"
  let custom =
    "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":\"ct_1\",\"type\":\"custom_tool_call\",\"call_id\":\"call_1\",\"name\":\"shell.exec\",\"input\":\"synthetic command\"}}"
  let first = [fixture.created, reasoning, custom, fixture.completed]
  let second = [fixture.created, fixture.done, fixture.completed]
  let mock =
    fixture.peer(False, "", "", [fixture.turn(first), fixture.turn(second)])
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  runtime.session_send(opened, req) |> should.be_ok
  let _ = observed(mock)
  list.each(first, fn(event) { message(opened, 100) |> should.equal(event) })
  let assert Ok(next) = ir.parse(fixture.create(Some("resp_1"), True))
  let output =
    ir.Object([
      #("type", ir.String("custom_tool_call_output")),
      #("call_id", ir.String("call_1")),
      #("output", ir.String("synthetic result")),
    ])
  let next =
    ir.stringify(
      ir.Object([#("input", ir.Array([output])), ..ir.extras(next, ["input"])]),
    )
  runtime.session_send(opened, fixture.request(next)) |> should.be_ok
  let assert Ok(outbound) = ir.parse(observed(mock))
  // ir.parse represents objects through dict.to_list; compare all JSON values
  // and array ordering using the same representation on the expected side.
  let assert Ok(expected) = ir.parse(ir.stringify(ir.Array([output])))
  ir.field(outbound, "input") |> should.equal(Some(expected))
  list.each(second, fn(event) { message(opened, 100) |> should.equal(event) })
  runtime.session_cancel(opened)
  process.receive(mock.closed, 1000) |> should.be_ok
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_sparse_gaps_and_unsuccessful_never_authorize_next_create_test() {
  let idless = string.replace(fixture.done, "\"id\":\"msg_1\",", "")
  let open =
    string.replace(
      fixture.done,
      "response.output_item.done",
      "response.output_item.added",
    )
  let unknown =
    "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"future_1\",\"type\":\"future_native\",\"payload\":\"synthetic\"}}"
  list.each(
    [
      [fixture.created, fixture.completed],
      [fixture.created, idless, fixture.completed],
      [fixture.created, open, fixture.completed],
      [fixture.created, unknown, fixture.completed],
      [
        fixture.created,
        string.replace(fixture.completed, "completed", "failed"),
      ],
      [
        fixture.created,
        string.replace(fixture.completed, "completed", "incomplete"),
      ],
      [
        fixture.created,
        string.replace(fixture.completed, "completed", "cancelled"),
      ],
    ],
    fn(events) {
      let mock = fixture.peer(False, "", "", [fixture.turn(events)])
      let store = fixture.store()
      let engine = fixture.runtime(store, mock, False)
      let req = fixture.request(fixture.create(None, True))
      let assert Ok(opened) =
        runtime.open_session(engine, adapter(store, False, None), req)
      let _ = observed(mock)
      runtime.session_send(opened, req) |> should.be_ok
      let _ = observed(mock)
      list.each(events, fn(event) {
        message(opened, 100) |> should.equal(event)
      })
      runtime.session_send(
        opened,
        fixture.request(fixture.create(Some("resp_1"), True)),
      )
      |> should.be_error
      process.receive(mock.closed, 1000) |> should.be_ok
      no_extra(mock)
      cleanup(engine)
      fixture.stop(mock)
    },
  )
}

pub fn f13_valid_prefix_malformed_data_and_no_reconnect_replay_test() {
  list.each(
    [
      "{broken}",
      "{\"type\":\"response.accepted\"}",
      string.replace(fixture.completed, "resp_1", "other"),
    ],
    fn(bad) {
      let mock =
        fixture.peer(False, "", "", [
          fixture.turn([fixture.created, fixture.done, bad]),
        ])
      let store = fixture.store()
      let engine = fixture.runtime(store, mock, False)
      let req = fixture.request(fixture.create(None, True))
      let assert Ok(opened) =
        runtime.open_session(engine, adapter(store, False, None), req)
      let _ = observed(mock)
      runtime.session_send(opened, req) |> should.be_ok
      let _ = observed(mock)
      message(opened, 100) |> should.equal(fixture.created)
      message(opened, 100) |> should.equal(fixture.done)
      let assert Error(failure) = poll_error(opened, 100)
      failure.delivery |> should.equal(contracts.Started)
      runtime.session_send(opened, req) |> should.be_error
      process.receive(mock.closed, 1000) |> should.be_ok
      no_extra(mock)
      cleanup(engine)
      fixture.stop(mock)
    },
  )
}

fn poll_error(opened: runtime.Session, attempts: Int) {
  case runtime.session_poll(opened) {
    Error(failure) -> Error(failure)
    Ok(None) if attempts > 0 -> poll_error(opened, attempts - 1)
    _ -> panic as "synthetic F13 failure was not observed"
  }
}

pub fn f13_queued_corruption_after_terminal_blocks_next_turn_before_send_test() {
  let events = [fixture.created, fixture.done, fixture.completed]
  let mock =
    fixture.peer(False, "", "", [
      fixture.turn(list.append(events, ["{broken}"])),
    ])
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  runtime.session_send(opened, req) |> should.be_ok
  let _ = observed(mock)
  list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  runtime.session_send(
    opened,
    fixture.request(fixture.create(Some("resp_1"), True)),
  )
  |> should.be_error
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_mode_change_and_unsupported_controls_are_fail_closed_test() {
  list.each(
    [
      fixture.create(None, False),
      string.replace(
        fixture.create(None, True),
        "response.create",
        "response.steer",
      ),
      string.replace(
        fixture.create(None, True),
        "response.create",
        "response.append",
      ),
      string.replace(
        fixture.create(None, True),
        "response.create",
        "response.cancel",
      ),
    ],
    fn(next) {
      let events = [fixture.created, fixture.done, fixture.completed]
      let mock = fixture.peer(False, "", "", [fixture.turn(events)])
      let store = fixture.store()
      let engine = fixture.runtime(store, mock, False)
      let req = fixture.request(fixture.create(None, True))
      let assert Ok(opened) =
        runtime.open_session(engine, adapter(store, False, None), req)
      let _ = observed(mock)
      runtime.session_send(opened, req) |> should.be_ok
      let _ = observed(mock)
      list.each(events, fn(event) {
        message(opened, 100) |> should.equal(event)
      })
      runtime.session_send(opened, fixture.request(next)) |> should.be_error
      process.receive(mock.closed, 1000) |> should.be_ok
      no_extra(mock)
      cleanup(engine)
      fixture.stop(mock)
    },
  )
}

pub fn f13_selected_record_replacement_delete_and_gate_clear_active_state_test() {
  list.each(["same-token", "delete", "deferred", "expiry"], fn(mutation) {
    let gate = process.new_subject()
    let mock =
      fixture.peer(False, "", "", [
        fixture.gated([fixture.created, fixture.done], gate, [
          fixture.completed,
        ]),
      ])
    let store = fixture.store()
    let engine = fixture.runtime(store, mock, False)
    let req = fixture.request(fixture.create(None, True))
    let assert Ok(opened) =
      runtime.open_session(engine, adapter(store, False, None), req)
    let _ = observed(mock)
    runtime.session_send(opened, req) |> should.be_ok
    let _ = observed(mock)
    message(opened, 100) |> should.equal(fixture.created)
    message(opened, 100) |> should.equal(fixture.done)
    let assert Ok(release) = process.receive(gate, 1000)
    let assert Ok(record) = runtime_store.load_record(store, fixture.key())
    case mutation {
      "same-token" ->
        runtime_store.save(store, fixture.key(), fixture.material())
        |> should.be_ok
      "delete" -> runtime_store.delete(store, fixture.key()) |> should.be_ok
      "deferred" -> {
        runtime_store.transition(
          store,
          fixture.key(),
          record,
          fixture.material(),
          runtime_store.Deferred(9_000_000_000_000),
        )
        |> should.be_ok
        Nil
      }
      _ -> {
        let assert contracts.OAuth(data) = fixture.material()
        let material =
          contracts.OAuth(
            contracts.OAuthData(
              ..data,
              credential: auth.Credential(..data.credential, expires_at_ms: 1),
            ),
          )
        runtime_store.save(store, fixture.key(), material) |> should.be_ok
      }
    }
    process.send(release, Nil)
    runtime.session_poll(opened)
    |> should.equal(
      Error(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.Started,
        None,
      )),
    )
    runtime.session_send(
      opened,
      fixture.request(fixture.create(Some("resp_1"), True)),
    )
    |> should.be_error
    process.receive(mock.closed, 1000) |> should.be_ok
    no_extra(mock)
    cleanup(engine)
    fixture.stop(mock)
  })
}

pub fn f13_selected_record_fence_rejects_mismatch_nonready_and_load_error_test() {
  let mock = fixture.peer(False, "", "", [])
  let context = fixture.context(mock, False)
  list.each(
    ["mismatch", "nonready", "delete", "expiry", "refreshing"],
    fn(mode) {
      let store = fixture.store()
      let assert contracts.OAuth(data) = fixture.material()
      let expired =
        contracts.OAuth(
          contracts.OAuthData(
            ..data,
            credential: auth.Credential(..data.credential, expires_at_ms: 1),
          ),
        )
      case mode {
        "mismatch" -> {
          let assert contracts.OAuth(data) = fixture.material()
          runtime_store.save(
            store,
            fixture.key(),
            contracts.OAuth(
              contracts.OAuthData(
                ..data,
                credential: auth.Credential(
                  ..data.credential,
                  access_token: "synthetic-other",
                ),
              ),
            ),
          )
          |> should.be_ok
        }
        "nonready" -> {
          let assert Ok(record) =
            runtime_store.load_record(store, fixture.key())
          runtime_store.transition(
            store,
            fixture.key(),
            record,
            fixture.material(),
            runtime_store.NeedsReauthorization,
          )
          |> should.be_ok
          Nil
        }
        "delete" -> runtime_store.delete(store, fixture.key()) |> should.be_ok
        "expiry" -> {
          runtime_store.save(store, fixture.key(), expired) |> should.be_ok
        }
        _ ->
          storage.write_runtime(
            store,
            fixture.key(),
            "{\"version\":2,\"kind\":\"refreshing\"}",
          )
          |> should.be_ok
      }
      let selected = case mode {
        "expiry" -> contracts.Context(..context, credential: expired)
        _ -> context
      }
      fence.bind(store, selected, fn() { True })
      |> should.equal(
        Error(contracts.Failure(
          contracts.CredentialUnavailable,
          contracts.NotSent,
          None,
        )),
      )
    },
  )
  no_extra(mock)
  fixture.stop(mock)
}

pub fn f13_after_poll_authorization_check_suppresses_terminal_test() {
  // The callback queue changes authorization at the *post-poll* check. Two
  // successful checks precede the physical poll; the third denies it.
  let mock =
    fixture.peer(False, "", "", [
      fixture.turn([fixture.created, fixture.done, fixture.completed]),
    ])
  let store = fixture.store()
  let checks = process.new_subject()
  let authorized = fn() {
    case process.receive(checks, 0) {
      Ok(value) -> value
      Error(_) -> True
    }
  }
  let selected =
    codex_websocket.native_adapter(
      "tenant",
      models.pinned(),
      "synthetic-f13/1",
      None,
      True,
      store,
      authorized,
    )
  let req = fixture.request(fixture.create(None, False))
  let assert Ok(opened) = selected.open(fixture.context(mock, False), req)
  let _ = observed(mock)
  let assert Ok(handle) = selected.send(opened.handle, req)
  let _ = observed(mock)
  let handle = direct_message(selected, handle, fixture.created, 100)
  let handle = direct_message(selected, handle, fixture.done, 100)
  process.send(checks, True)
  process.send(checks, True)
  process.send(checks, False)
  selected.receive(handle)
  |> should.equal(
    Error(contracts.Failure(contracts.Cancelled, contracts.Started, None)),
  )
  selected.send(handle, fixture.request(fixture.create(Some("resp_1"), False)))
  |> should.be_error
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  fixture.stop(mock)
}

pub fn f13_after_physical_poll_same_token_replacement_or_delete_suppresses_terminal_test() {
  list.each(["same-token", "delete"], fn(mutation) {
    let mock =
      fixture.peer(False, "", "", [
        fixture.turn([fixture.created, fixture.done, fixture.completed]),
      ])
    let store = fixture.store()
    let checks = process.new_subject()
    let authorized = fn() {
      case process.receive(checks, 0) {
        Ok(True) -> {
          case mutation {
            "same-token" ->
              runtime_store.save(store, fixture.key(), fixture.material())
              |> should.be_ok
            _ -> runtime_store.delete(store, fixture.key()) |> should.be_ok
          }
          True
        }
        _ -> True
      }
    }
    let selected =
      codex_websocket.native_adapter(
        "tenant",
        models.pinned(),
        "synthetic-f13/1",
        None,
        True,
        store,
        authorized,
      )
    let req = fixture.request(fixture.create(None, False))
    let assert Ok(opened) = selected.open(fixture.context(mock, False), req)
    let _ = observed(mock)
    let assert Ok(handle) = selected.send(opened.handle, req)
    let _ = observed(mock)
    let handle = direct_message(selected, handle, fixture.created, 100)
    let handle = direct_message(selected, handle, fixture.done, 100)
    process.send(checks, False)
    process.send(checks, False)
    process.send(checks, True)
    selected.receive(handle)
    |> should.equal(
      Error(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.Started,
        None,
      )),
    )
    selected.send(
      handle,
      fixture.request(fixture.create(Some("resp_1"), False)),
    )
    |> should.be_error
    process.receive(mock.closed, 1000) |> should.be_ok
    no_extra(mock)
    fixture.stop(mock)
  })
}

pub fn f13_wss_untrusted_ca_fails_without_inference_or_insecure_fallback_test() {
  let assert Ok(#(cert, key)) = tls.generate_ca(fixture.ca_directory())
  let mock = fixture.peer(True, cert, key, [])
  let store = fixture.store()
  let req = fixture.request(fixture.create(None, True))
  let assert Error(failure) =
    adapter(store, False, None).open(fixture.context(mock, True), req)
  failure.delivery |> should.equal(contracts.Uncertain)
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  fixture.stop(mock)
}

fn direct_message(
  selected: contracts.SessionAdapter(codex_websocket.Handle),
  handle: codex_websocket.Handle,
  expected: String,
  attempts: Int,
) {
  let assert Ok(#(message, next)) = selected.receive(handle)
  case message {
    Some(message) -> {
      message |> should.equal(expected)
      next
    }
    None if attempts > 0 ->
      direct_message(selected, next, expected, attempts - 1)
    _ -> panic as "synthetic direct message was not delivered"
  }
}

pub fn f13_cancellation_closes_upstream_and_cannot_reuse_handle_test() {
  let mock = fixture.peer(False, "", "", [fixture.turn([fixture.metadata])])
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  runtime.session_send(opened, req) |> should.be_ok
  let _ = observed(mock)
  message(opened, 100) |> should.equal(fixture.metadata)
  runtime.session_cancel(opened)
  runtime.session_send(opened, req) |> should.be_error
  process.receive(mock.closed, 1000) |> should.be_ok
  no_extra(mock)
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_additive_preparation_keeps_http_policy_and_marker_layer_test() {
  let context =
    request.Context(
      session.Scope("tenant", "credential", "account", fixture.model, "session"),
      "synthetic",
      "synthetic/1",
      Some("physical-1"),
    )
  let assert Ok(body) =
    ir.parse(
      "{\"model\":\"gpt-5.6-sol\",\"input\":[],\"client_metadata\":{\"ws_request_header_x_openai_internal_codex_responses_lite\":true}}",
    )
  request.prepare(
    body,
    context,
    routes.Route(routes.Responses, routes.Websocket, True),
    None,
    ["low"],
  )
  |> should.be_error
  let assert Ok(http) =
    request.prepare(
      body,
      context,
      routes.Route(routes.Responses, routes.Http, True),
      None,
      ["low"],
    )
  http.response_mode |> should.equal(request.StrictResponses)
  response.http_policy(
    request.Prepared(..http, response_mode: request.NativeLiteResponses),
  )
  |> should.not_equal(codex_websocket.policy(request.NativeLiteResponses))
  let assert Ok(ws) =
    request.prepare_websocket(
      body,
      context,
      None,
      ["low"],
      request.NativeLiteResponses,
      False,
    )
  lite.header_enabled(ws.headers) |> should.equal(Ok(False))
  ir.field(ws.body, "parallel_tool_calls")
  |> should.equal(Some(ir.Boolean(False)))
  let assert Ok(ws) =
    request.prepare_websocket(
      body,
      context,
      None,
      ["low"],
      request.NativeLiteResponses,
      True,
    )
  lite.header_enabled(ws.headers) |> should.equal(Ok(True))
}

pub fn f13_partial_fragmented_large_queued_data_blocks_cursor_and_reset_test() {
  let events = [fixture.created, fixture.done, fixture.completed]
  let stale =
    bit_array.from_string(
      "{\"type\":\"response.created\",\"response\":{\"id\":\"stale\"}}",
    )
  let fragment = <<1, { bit_array.byte_size(stale) }:8, stale:bits>>
  let assert Ok(full) =
    frames.encode_text(
      frames.Server,
      bit_array.to_string(stale) |> should.be_ok,
      None,
    )
  let assert <<partial:bits-size(24), remaining:bits>> = full
  let large =
    "{\"type\":\"response.created\",\"response\":{\"id\":\"stale\",\"future\":\""
    <> string.repeat("x", 20_000)
    <> "\"}}"
  let assert Ok(large) = frames.encode_text(frames.Server, large, None)
  let assert Ok(pong) = frames.encode_pong(frames.Server, <<>>, None)
  let flood = bit_array.concat(list.repeat(pong, 129))
  list.each(
    [
      #(fragment, <<128, 0>>),
      #(<<129>>, <<>>),
      #(partial, remaining),
      #(large, <<>>),
      #(flood, <<>>),
    ],
    fn(tail) {
      list.each([None, Some("resp_1")], fn(previous) {
        let queued = process.new_subject()
        let mock =
          fixture.peer(False, "", "", [
            fixture.raw_turn(events, tail.0, queued, tail.1),
          ])
        let store = fixture.store()
        let engine = fixture.runtime(store, mock, False)
        let req = fixture.request(fixture.create(None, True))
        let assert Ok(opened) =
          runtime.open_session(engine, adapter(store, False, None), req)
        let _ = observed(mock)
        runtime.session_send(opened, req) |> should.be_ok
        let _ = observed(mock)
        list.each(events, fn(event) {
          message(opened, 100) |> should.equal(event)
        })
        let assert Ok(release) = process.receive(queued, 1000)
        runtime.session_send(
          opened,
          fixture.request(fixture.create(previous, True)),
        )
        |> should.be_error
        process.send(release, Nil)
        process.receive(mock.closed, 1000) |> should.be_ok
        no_extra(mock)
        cleanup(engine)
        fixture.stop(mock)
      })
    },
  )
}

pub fn f13_idle_admission_preserves_legal_ping_pong_and_same_socket_test() {
  let events = [fixture.created, fixture.done, fixture.completed]
  let assert Ok(ping) = frames.encode_ping(frames.Server, <<"f13">>, None)
  let assert Ok(pong) = frames.encode_pong(frames.Server, <<"idle">>, None)
  let queued = process.new_subject()
  let mock =
    fixture.peer(False, "", "", [
      fixture.raw_turn(events, <<ping:bits, pong:bits>>, queued, <<>>),
      fixture.turn(events),
    ])
  let store = fixture.store()
  let engine = fixture.runtime(store, mock, False)
  let req = fixture.request(fixture.create(None, True))
  let assert Ok(opened) =
    runtime.open_session(engine, adapter(store, False, None), req)
  let _ = observed(mock)
  runtime.session_send(opened, req) |> should.be_ok
  let _ = observed(mock)
  list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  let assert Ok(release) = process.receive(queued, 1000)
  process.send(release, Nil)
  runtime.session_send(
    opened,
    fixture.request(fixture.create(Some("resp_1"), True)),
  )
  |> should.be_ok
  let _ = observed(mock)
  list.each(events, fn(event) { message(opened, 100) |> should.equal(event) })
  runtime.session_cancel(opened)
  process.receive(mock.closed, 1000) |> should.be_ok
  cleanup(engine)
  fixture.stop(mock)
}

pub fn f13_callback_absent_generic_error_is_suppressed_and_fault_is_terminal_test() {
  let fault =
    "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic invalid input\",\"param\":\"input\"},\"future\":{\"ok\":true}}"
  let suppressed =
    "{\"type\":\"error\",\"status\":503,\"error\":{\"type\":\"server_error\",\"message\":\"synthetic-private-diagnostic\"}}"
  let key_echo =
    "{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"synthetic invalid input\",\"x-synthetic-f13-access\":\"diagnostic\"}}"
  let escaped_key_echo =
    "{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"synthetic invalid input\",\"synthetic-f13-acc\\u0065ss\":\"diagnostic\"}}"
  list.each(
    [
      #(fault, True),
      #(suppressed, False),
      #(key_echo, False),
      #(escaped_key_echo, False),
    ],
    fn(vector) {
      let mock =
        fixture.peer(False, "", "", [fixture.turn([fixture.created, vector.0])])
      let store = fixture.store()
      let engine = fixture.runtime(store, mock, False)
      let req = fixture.request(fixture.create(None, True))
      let assert Ok(opened) =
        runtime.open_session(engine, adapter(store, False, None), req)
      let _ = observed(mock)
      runtime.session_send(opened, req) |> should.be_ok
      let _ = observed(mock)
      message(opened, 100) |> should.equal(fixture.created)
      case vector.1 {
        True -> message(opened, 100) |> should.equal(fault)
        False -> {
          runtime.session_poll(opened) |> should.be_error
          Nil
        }
      }
      // Fresh reset is forbidden, not just use of the prior cursor.
      runtime.session_send(opened, req) |> should.be_error
      process.receive(mock.closed, 1000) |> should.be_ok
      no_extra(mock)
      cleanup(engine)
      fixture.stop(mock)
    },
  )
}

pub fn f13_compatibility_strict_errors_suppress_or_deliver_once_and_close_test() {
  let created =
    "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"object\":\"response\",\"status\":\"in_progress\",\"output\":[]}}"
  let fault =
    "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic invalid input\"}}"
  let suppressed =
    "{\"type\":\"error\",\"status\":503,\"error\":{\"type\":\"server_error\",\"message\":\"synthetic-private-diagnostic\"}}"
  list.each(
    [
      #(fault, True, False),
      #(suppressed, False, False),
      #(fault, True, True),
      #(suppressed, False, True),
    ],
    fn(vector) {
      let mock =
        fixture.peer(False, "", "", [fixture.turn([created, vector.0])])
      let store = fixture.store()
      let engine = fixture.runtime_for_model(store, mock, False, "gpt-5.5")
      let original = fixture.request(fixture.create(None, False))
      let assert Ok(body) = ir.parse(original.body)
      let req =
        contracts.Request(
          ..original,
          model: "gpt-5.5",
          body: ir.stringify(
            ir.Object([
              #("model", ir.String("gpt-5.5")),
              ..ir.extras(body, ["model"])
            ]),
          ),
        )
      let terminals = process.new_subject()
      let selected = case vector.2 {
        True ->
          codex_websocket.adapter_notifying(
            "tenant",
            models.pinned(),
            "synthetic-f13/1",
            None,
            fn(terminal) { process.send(terminals, terminal) },
          )
        False ->
          codex_websocket.adapter(
            "tenant",
            models.pinned(),
            "synthetic-f13/1",
            None,
          )
      }
      let assert Ok(opened) = runtime.open_session(engine, selected, req)
      let _ = observed(mock)
      runtime.session_send(opened, req) |> should.be_ok
      let _ = observed(mock)
      message(opened, 100) |> should.equal(created)
      case vector.2 {
        True -> {
          runtime.session_poll(opened) |> should.equal(Ok(None))
          let assert Ok(terminal) = process.receive(terminals, 0)
          codex_websocket.terminal_action(terminal)
          |> should.equal(
            Ok(case vector.1 {
              True -> errors.RequestFault(fault)
              False -> errors.Suppressed
            }),
          )
          process.receive(terminals, 0) |> should.equal(Error(Nil))
        }
        False ->
          case vector.1 {
            True -> message(opened, 100) |> should.equal(fault)
            False -> {
              runtime.session_poll(opened) |> should.be_error
              Nil
            }
          }
      }
      runtime.session_send(opened, req) |> should.be_error
      process.receive(mock.closed, 1000) |> should.be_ok
      no_extra(mock)
      cleanup(engine)
      fixture.stop(mock)
    },
  )
}

pub fn f13_notification_closed_before_queued_tick_reset_and_publication_fenced_test() {
  let fault =
    "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic invalid input\"}}"
  list.each(["unchanged", "same-token", "client-revoke"], fn(mutation) {
    let mock =
      fixture.peer(False, "", "", [fixture.turn([fixture.created, fault])])
    let store = fixture.store()
    keys.create(store.directory, "f13-client", "synthetic-f13-client")
    |> should.be_ok
    let notices = process.new_subject()
    let terminals = process.new_subject()
    let selected =
      codex_websocket.native_adapter_notifying(
        "tenant",
        models.pinned(),
        "synthetic-f13/1",
        None,
        False,
        store,
        fn() {
          keys.verify(store.directory, "synthetic-f13-client") == Ok(True)
        },
        fn(terminal) { process.send(terminals, terminal) },
      )
    let engine = fixture.runtime(store, mock, False)
    let req = fixture.request(fixture.create(None, True))
    let assert Ok(opened) = runtime.open_session(engine, selected, req)
    let _ = observed(mock)
    runtime.session_send(opened, req) |> should.be_ok
    let _ = observed(mock)
    message(opened, 100) |> should.equal(fixture.created)
    // Deliberately queue a root tick before notification. Safety must not
    // depend on assumed ordering from different senders.
    process.send(notices, QueuedTick)
    runtime.session_poll(opened) |> should.equal(Ok(None))
    process.new_selector()
    |> process.select(notices)
    |> process.select_map(terminals, NativeTerminal)
    |> process.selector_receive(1000)
    |> should.equal(Ok(QueuedTick))
    runtime.session_send(opened, req) |> should.be_error
    // The dedicated terminal receive preempts even after a queued Tick's
    // blocking runtime step failed; it never waits for a callback/root ack.
    let assert Ok(terminal) = process.receive(terminals, 0)
    process.receive(terminals, 0) |> should.equal(Error(Nil))
    case mutation {
      "unchanged" ->
        codex_websocket.terminal_action(terminal)
        |> should.equal(Ok(errors.RequestFault(fault)))
      "same-token" -> {
        runtime_store.save(store, fixture.key(), fixture.material())
        |> should.be_ok
        codex_websocket.terminal_action(terminal) |> should.be_error
        Nil
      }
      _ -> {
        keys.revoke(store.directory, "f13-client") |> should.be_ok
        codex_websocket.terminal_action(terminal) |> should.be_error
        Nil
      }
    }
    process.receive(mock.closed, 1000) |> should.be_ok
    no_extra(mock)
    cleanup(engine)
    fixture.stop(mock)
  })
}

pub fn f13_source_error_classifier_and_stricter_secret_boundary_test() {
  list.each(
    [
      #(
        "{\"type\":\"error\",\"status\":503,\"error\":{\"type\":\"server_error\",\"message\":\"synthetic-private-diagnostic\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":429,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic quota\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":402,\"error\":{\"code\":\"invalid_prompt\",\"message\":\"synthetic payment\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":401,\"error\":{\"type\":\"authentication_error\",\"code\":\"invalid_request_error\",\"message\":\"synthetic auth\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"code\":\"model_not_found\",\"message\":\"synthetic missing\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":503,\"terminal_auth\":true,\"error\":{\"type\":\"server_error\",\"message\":\"synthetic diagnostic\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"echo synthetic-f13-access\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"bad request\",\"synthetic-f13-access\":\"diagnostic\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"bad request\",\"x-synthetic-f13-acc\\u0065ss-y\":\"diagnostic\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"bad request\"},\"future\":[{\"x-synthetic-f13-refresh\":\"diagnostic\"}]}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic\",\"refresh_token\":\"synthetic-f13-refresh\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":[],\"message\":\"synthetic\"}}",
        False,
      ),
      #(
        "{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"synthetic invalid input\"}}",
        True,
      ),
      #(
        "{\"type\":\"error\",\"status_code\":409,\"error\":{\"message\":\"synthetic conflict\"}}",
        True,
      ),
      #(
        "{\"type\":\"error\",\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"synthetic context\"}}",
        True,
      ),
      #(
        "{\"type\":\"error\",\"status\":404,\"error\":{\"message\":\"Item with id synthetic not found: items are not persisted when `store` is set to false\"}}",
        True,
      ),
    ],
    fn(vector) {
      let assert Ok(document) = ir.parse(vector.0)
      errors.classify(document, vector.0, False, [
        "synthetic-f13-access",
        "synthetic-f13-refresh",
      ])
      |> should.equal(case vector.1 {
        True -> errors.RequestFault(vector.0)
        False -> errors.Suppressed
      })
    },
  )
  let replay =
    "{\"type\":\"error\",\"status\":429,\"error\":{\"message\":\"synthetic quota\"}}"
  let assert Ok(document) = ir.parse(replay)
  errors.classify(document, replay, True, [])
  |> should.equal(errors.TransportClose(1012, "upstream requires HTTP replay"))
  let big =
    "{\"type\":\"error\",\"status\":413,\"error\":{\"code\":\"message_too_big\",\"message\":\""
    <> string.repeat("界", 60)
    <> "\"}}"
  let assert Ok(document) = ir.parse(big)
  errors.classify(document, big, False, [])
  |> should.equal(errors.TransportClose(1009, string.repeat("界", 41)))
}

fn transport_message(
  connection: ws_transport.Connection,
  attempts: Int,
) -> ws_transport.Connection {
  let assert Ok(#(next, text)) = ws_transport.poll(connection)
  case text {
    Some("pressure-ready") -> next
    None if attempts > 0 -> transport_message(next, attempts - 1)
    _ -> panic as "synthetic pressure-ready not delivered"
  }
}

fn pressure_connection(
  peer: fixture.Pressure,
  secure: Bool,
  cert: String,
) -> ws_transport.Connection {
  let origin =
    case secure {
      True -> "https://127.0.0.1:"
      False -> "http://127.0.0.1:"
    }
    <> int.to_string(peer.port)
  let assert Ok(connection) =
    ws_transport.open(
      origin,
      origin,
      "/synthetic-pressure",
      [],
      ws_transport.Config(
        case secure {
          True -> Some(cert)
          False -> None
        },
        5000,
        20,
        1_048_576,
        1_048_576,
      ),
    )
  transport_message(connection, 100)
}

fn peer_terminated(
  peer: fixture.Pressure,
  release: process.Subject(Nil),
  case_label: String,
) {
  process.send(release, Nil)
  let #(elapsed, kind) = case process.receive(peer.eof, 1200) {
    Ok(Ok(value)) -> value
    Ok(Error(category)) -> {
      let message = case_label <> ": " <> category
      panic as message
    }
    Error(_) -> {
      let message = case_label <> ": peer receive deadline"
      panic as message
    }
  }
  { elapsed <= 1000 } |> should.be_true
  list.contains(["eof", "reset"], kind) |> should.be_true
  fixture.stop_pressure(peer)
}

pub fn f13_actual_blocked_pong_and_abort_have_bounded_tcp_tls_termination_test() {
  list.each([False, True], fn(secure) {
    let assert Ok(#(cert, key)) = tls.generate_ca(fixture.ca_directory())
    list.each(["pong", "partial"], fn(kind) {
      let tail = case kind {
        "pong" -> {
          let assert Ok(ping) =
            frames.encode_ping(frames.Server, <<"pressure">>, None)
          ping
        }
        _ -> <<0x81>>
      }
      let peer = fixture.pressure_peer(secure, cert, key, tail)
      let connection = pressure_connection(peer, secure, cert)
      let assert Ok(release) = process.receive(peer.ready, 1000)
      let assert Ok(pending) = saturate(connection)
      { pending >= 65_536 } |> should.be_true
      let started = now_ms()
      let assert Error(reason) = ws_transport.ensure_idle(connection)
      let elapsed = now_ms() - started
      case kind {
        "pong" -> {
          string.contains(reason, "write") |> should.be_true
          { elapsed >= 20 && elapsed <= 400 } |> should.be_true
        }
        _ -> {
          string.contains(reason, "incomplete") |> should.be_true
          { elapsed <= 150 } |> should.be_true
        }
      }
      // The sender is stopped and the physical handle is positively closed.
      ws_transport.send(connection, "late-create") |> should.be_error
      peer_terminated(
        peer,
        release,
        kind
          <> case secure {
          True -> "-TLS"
          False -> "-TCP"
        },
      )
    })
  })
}

pub fn f13_actual_owner_death_stops_blocked_sender_and_success_leaves_no_helpers_test() {
  diagnostic_start()
  list.each([False, True], fn(secure) {
    let assert Ok(#(cert, key)) = tls.generate_ca(fixture.ca_directory())
    list.each([False, True], fn(blocked) {
      let tail = case blocked {
        True -> {
          let assert Ok(ping) =
            frames.encode_ping(frames.Server, <<"owner-death">>, None)
          ping
        }
        False -> <<>>
      }
      let peer = fixture.pressure_peer(secure, cert, key, tail)
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          diagnostic_start()
          let connection = pressure_connection(peer, secure, cert)
          case blocked {
            True -> {
              let assert Ok(pending) = saturate(connection)
              { pending >= 65_536 } |> should.be_true
            }
            False ->
              ws_transport.send(connection, "synthetic-committed-send")
              |> should.be_ok
          }
          let start = process.new_subject()
          process.send(ready, #(connection, start))
          process.receive(start, 1000) |> should.be_ok
          case blocked {
            True -> {
              let _ = ws_transport.ensure_idle(connection)
              Nil
            }
            False -> {
              let _ = process.receive(start, 5000)
              Nil
            }
          }
        })
      let assert Ok(#(connection, start)) = process.receive(ready, 1000)
      let assert Ok(release) = process.receive(peer.ready, 1000)
      let assert Ok(endpoints) = process.receive(peer.endpoints, 1000)
      case blocked {
        True -> {
          process.send(start, Nil)
          let assert Ok(#(guardian, sender)) = blocked_helpers(owner)
          let assert Ok(cleanup) =
            prepare_cleanup(connection, owner, [guardian, sender], endpoints)
          let started = now_ms()
          process.kill(owner)
          await_prepared(cleanup, 100) |> should.be_ok
          { now_ms() - started <= 150 } |> should.be_true
        }
        False -> {
          no_write_helpers(owner) |> should.be_true
          let assert Ok(cleanup) =
            prepare_cleanup(connection, owner, [], endpoints)
          process.kill(owner)
          // Existing socket-owner behavior after success, not a persistent
          // guardian or a claimed whole-connection 100 ms lifetime guarantee.
          await_prepared(cleanup, 1000) |> should.be_ok
          Nil
        }
      }
      peer_terminated(
        peer,
        release,
        case blocked {
          True -> "blocked-owner"
          False -> "successful-owner"
        }
          <> case secure {
          True -> "-TLS"
          False -> "-TCP"
        },
      )
    })
  })
}
