/// F12 synthetic loopback runtime tests, not CPA/native/live execution.
/// The three source events are reused verbatim from F11's pinned fixtures.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/continuation
import mimic/protocol/responses/http as pump
import mimic/protocol/responses/sparse
import mimic/protocol/responses/stream
import mimic/providers/codex/adapter
import mimic/providers/codex/http
import mimic/providers/codex/lite
import mimic/providers/codex/models
import mimic/providers/codex/normalize
import mimic/providers/codex/request
import mimic/providers/codex/response
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/types.{Header}
import responses_sparse_test as source

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

@external(erlang, "mimic_gateway_codex_http_test_ffi", "upstream")
fn upstream(bodies: List(String)) -> #(Int, process.Pid)

@external(erlang, "mimic_gateway_codex_http_test_ffi", "observations")
fn observations(pid: process.Pid) -> List(String)

@external(erlang, "mimic_gateway_codex_http_test_ffi", "stop")
fn stop_upstream(pid: process.Pid) -> Nil

const model = "gpt-5.6-sol"

fn config(tenant: String) {
  adapter.Config(tenant, "synthetic-f12/1", True, models.pinned(), None)
}

fn req(body: String) {
  contracts.Request(
    "codex",
    "oauth",
    model,
    "responses",
    "responses/lite",
    contracts.Buffered,
    [],
    "server-authenticated-session",
    Some("a"),
    body,
  )
}

fn body() {
  "{\"model\":\"gpt-5.6-sol\",\"input\":\"synthetic first\"}"
}

fn follow() {
  "{\"model\":\"gpt-5.6-sol\",\"input\":\"synthetic next\",\"previous_response_id\":\"resp_1\"}"
}

fn material(account: String) {
  contracts.OAuth(
    contracts.OAuthData(
      auth.Credential(
        "synthetic-access-" <> account,
        "synthetic-refresh",
        9_000_000_000_000,
      ),
      [#("chatgpt_account_id", "synthetic-provider-" <> account)],
    ),
  )
}

fn context() {
  contracts.Context(
    "codex",
    "oauth",
    "a",
    "http://127.0.0.1:1",
    "trusted-runtime-session",
    material("a"),
  )
}

fn sse(events: List(String)) -> String {
  events
  |> list.map(fn(data) { "data: " <> data <> "\n\n" })
  |> string.join("")
}

fn created() {
  "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}"
}

fn native() {
  sse([source.metadata(), source.done(), source.completed()])
}

fn eligible() {
  sse([created(), source.done(), source.completed()])
}

fn with_runtime(
  bodies: List(String),
  exercise: fn(
    runtime.Runtime,
    continuation.Cache(session.Continuation),
    storage.Store,
    process.Pid,
  ) -> Nil,
) {
  let #(port, upstream_pid) = upstream(bodies)
  let assert Ok(store) = storage.new(directory())
  list.each(["a", "b"], fn(account) {
    runtime_store.save(
      store,
      credentials.key("codex", "oauth", account),
      material(account),
    )
    |> should.be_ok
  })
  let assert Ok(entry) = models.lookup(models.pinned(), model)
  let assert Ok(registered) = adapter.registration(entry)
  let assert Ok(registry) = registry.new([registered])
  let accounts =
    list.map(["a", "b"], fn(account) {
      runtime.Account(
        "codex",
        "oauth",
        account,
        "http://127.0.0.1:" <> int.to_string(port),
        fleet.LocalLoopback,
        4,
        [model],
        credentials.Refreshable(
          contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
        ),
      )
    })
  let assert Ok(provider) = runtime.start(store, registry, accounts)
  let assert Ok(cache) =
    continuation.start(continuation.Limits(32, 8_388_608, 2_097_152, 900_000))
  exercise(provider, cache, store, upstream_pid)
  runtime.active_leases(provider) |> should.equal(Ok(0))
  continuation.stop(cache) |> should.be_ok
  runtime.stop(provider) |> should.be_ok
  stop_upstream(upstream_pid)
}

pub fn lite_markers_are_route_intent_not_catalog_or_receipt_authority_test() {
  let normal = contracts.Request(..req(body()), operation: "responses")
  let assert Ok(plan) =
    adapter.prepare_native(config("tenant"), context(), normal)
  response.http_policy(plan) |> should.equal(stream.Strict)
  list.each([ir.Boolean(True), ir.String(" TRUE ")], fn(marker) {
    let assert Ok(value) = ir.parse(body())
    let value =
      normalize.put(
        value,
        "client_metadata",
        ir.Object([#(lite.metadata_key, marker)]),
      )
    let assert Ok(classified) =
      adapter.classify_http(
        contracts.Request(..normal, body: ir.stringify(value)),
        [],
      )
    classified.operation |> should.equal("responses/lite")
  })
  let assert Ok(classified) =
    adapter.classify_http(normal, [Header(lite.header, " TRUE ")])
  let assert Ok(plan) =
    adapter.prepare_native(config("tenant"), context(), classified)
  response.http_policy(plan)
  |> should.equal(stream.NativeSparse(
    sparse.HydrateCompleted,
    8_388_608,
    32_768,
  ))
  response.executor_policy(plan)
  |> should.equal(stream.NativeSparse(sparse.Transparent, 8_388_608, 32_768))
  let unqualified =
    contracts.Request(
      ..classified,
      model: "gpt-5.5",
      body: string.replace(body(), model, "gpt-5.5"),
    )
  adapter.prepare_native(config("tenant"), context(), unqualified)
  |> should.equal(
    Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
  )
  adapter.classify_http(normal, [
    Header(lite.header, "true"),
    Header(lite.header, "true"),
  ])
  |> should.be_error
  adapter.classify_http(normal, [Header(lite.header, "yes")]) |> should.be_error
  adapter.classify_http(
    contracts.Request(..normal, operation: "responses/compact"),
    [Header(lite.header, "true")],
  )
  |> should.be_error
  let assert Ok(value) = ir.parse(body())
  let assert Ok(low_level) =
    request.prepare(
      value,
      request.Context(
        session.Scope("tenant", "a", "provider-a", model, "client"),
        "synthetic",
        "synthetic/1",
        None,
      ),
      routes.Route(routes.Lite, routes.Http, True),
      None,
      ["medium"],
    )
  response.http_policy(low_level) |> should.equal(stream.Strict)
}

pub fn lite_catalog_flags_and_transport_discovery_are_exact_test() {
  let assert Ok(normal) = models.lookup(models.pinned(), "gpt-5.5")
  let assert Ok(registered) = adapter.registration(normal)
  list.contains(registered.operations, "responses/lite") |> should.be_false
  let available = models.available(models.pinned(), [model], False, True)
  let assert Some(ir.Array([visible])) = ir.field(available, "models")
  ir.field(visible, "use_responses_lite")
  |> should.equal(Some(ir.Boolean(True)))
  ir.field(visible, "prefer_websockets")
  |> should.equal(Some(ir.Boolean(False)))
  let omitted = models.available(models.pinned(), [model], False, False)
  ir.field(omitted, "models") |> should.equal(Some(ir.Array([])))
  let http_only =
    models.available_http(models.pinned(), [model, "gpt-5.5"], True)
  let assert Some(ir.Array([lite_model, strict_model])) =
    ir.field(http_only, "models")
  ir.field(lite_model, "prefer_websockets")
  |> should.equal(Some(ir.Boolean(False)))
  ir.field(strict_model, "prefer_websockets")
  |> should.equal(Some(ir.Boolean(True)))
  models.decode("{\"models\":[],\"models\":[]}", models.OperatorSupplied)
  |> should.be_error
}

pub fn lite_selected_catalog_preparation_preserves_native_tools_images_and_extensions_test() {
  let source =
    "{\"model\":\"gpt-5.6-sol\",\"input\":[{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"custom\",\"name\":\"exec\"}]}]},{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"https://example.invalid/synthetic.png\"}]}],\"parallel_tool_calls\":true,\"include\":[\"synthetic.extension\"],\"future\":{\"model\":\"user-data\"}}"
  let assert Ok(prepared) =
    adapter.prepare_native(config("tenant"), context(), req(source))
  let assert Ok(original) = ir.parse(source)
  prepared.target |> should.equal("/backend-api/codex/responses")
  ir.field(prepared.body, "input") |> should.equal(ir.field(original, "input"))
  ir.field(prepared.body, "instructions") |> should.equal(None)
  ir.field(prepared.body, "parallel_tool_calls")
  |> should.equal(Some(ir.Boolean(False)))
  ir.field(prepared.body, "include")
  |> should.equal(
    Some(
      ir.Array([
        ir.String("synthetic.extension"),
        ir.String("reasoning.encrypted_content"),
      ]),
    ),
  )
  ir.field(prepared.body, "future")
  |> should.equal(ir.field(original, "future"))
  list.contains(prepared.headers, Header(lite.header, "true"))
  |> should.be_false
  // Outbound spelling is constructed, not copied from arbitrary client headers.
  list.contains(
    prepared.headers,
    Header("X-OpenAI-Internal-Codex-Responses-Lite", "true"),
  )
  |> should.be_true
}

pub fn pinned_sparse_http_delivery_hydrates_but_missing_created_never_receipts_test() {
  with_runtime([native()], fn(provider, cache, _, peer) {
    let assert Ok(opened) =
      http.open(provider, cache, config("tenant"), None, req(body()))
    let assert Ok(delivery) = http.consume_http(opened)
    let assert Ok(text) = response.delivery_body(delivery)
    let assert Ok(document) = ir.parse(text)
    ir.field(document, "object") |> should.equal(None)
    ir.field(document, "future")
    |> should.equal(Some(ir.Object([#("ok", ir.Boolean(True))])))
    let assert Some(ir.Array([item])) = ir.field(document, "output")
    ir.field(item, "id") |> should.equal(Some(ir.String("msg_1")))
    response.delivery_completion(delivery) |> should.equal(None)
    let assert Some(report) = response.delivery_report(delivery)
    let assert sparse.Reconstructed(_) = sparse.reconstruction(report)
    sparse.authority(report)
    |> should.equal(sparse.Ineligible([sparse.MissingCreated]))
    http.open(provider, cache, config("tenant"), None, req(follow()))
    |> should.be_error
    list.length(observations(peer)) |> should.equal(1)
  })
}

pub fn lite_completed_report_is_provisional_until_actual_runtime_eof_test() {
  with_runtime([eligible()], fn(provider, cache, _, peer) {
    let assert Ok(opened) =
      http.open(provider, cache, config("tenant"), None, req(body()))
    let delivered = process.new_subject()
    let assert Ok(delivery) =
      http.forward_http(opened, fn(event) {
        process.send(delivered, stream.wire_event(event).name)
        case stream.wire_event(event).name {
          "response.completed" -> {
            // Authority on this event is still provisional. Nothing is published.
            let assert Some(report) = stream.wire_report(event)
            let assert sparse.ContinuationEligible(_) = sparse.authority(report)
            http.open(provider, cache, config("tenant"), None, req(follow()))
            |> should.be_error
            Nil
          }
          _ -> Nil
        }
        Ok(pump.Continue)
      })
    let assert Some(completion) = response.delivery_completion(delivery)
    session.replay(completion.continuation) |> should.be_ok
    list.each(
      ["response.created", "response.output_item.done", "response.completed"],
      fn(name) { process.receive(delivered, 0) |> should.equal(Ok(name)) },
    )
    list.length(observations(peer)) |> should.equal(1)
  })
}

pub fn lite_unknown_empty_idless_open_and_extension_output_never_receipt_test() {
  let cases = [
    #(sse([created(), source.completed()]), sparse.MissingOutput),
    #(
      sse([
        created(),
        string.replace(source.done(), "\"id\":\"msg_1\",", ""),
        source.completed(),
      ]),
      sparse.MissingItemIdentity,
    ),
    #(
      sse([
        created(),
        string.replace(
          source.done(),
          "response.output_item.done",
          "response.output_item.added",
        ),
        source.completed(),
      ]),
      sparse.OpenItems,
    ),
    #(
      sse([
        created(),
        "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"future_1\",\"type\":\"future_native\",\"payload\":\"synthetic-opaque\"}}",
        source.completed(),
      ]),
      sparse.UnknownExtension,
    ),
  ]
  list.each(cases, fn(case_) {
    with_runtime([case_.0], fn(provider, cache, _, peer) {
      let assert Ok(opened) =
        http.open(provider, cache, config("tenant"), None, req(body()))
      let assert Ok(delivery) = http.consume_http(opened)
      response.delivery_body(delivery) |> should.be_ok
      response.delivery_completion(delivery) |> should.equal(None)
      let assert Some(report) = response.delivery_report(delivery)
      let assert sparse.Ineligible(gaps) = sparse.authority(report)
      list.contains(gaps, case_.1) |> should.be_true
      http.open(provider, cache, config("tenant"), None, req(follow()))
      |> should.be_error
      list.length(observations(peer)) |> should.equal(1)
    })
  })
}

pub fn lite_trailing_corruption_model_and_terminal_identity_mismatch_keep_prefix_not_receipt_test() {
  list.each(["trailing", "model", "id", "truncated"], fn(fault) {
    let events = case fault {
      "trailing" -> eligible() <> "data: {bad}\n\n"
      "truncated" -> sse([created(), source.done()])
      "model" ->
        sse([
          created(),
          source.done(),
          string.replace(
            source.completed(),
            "\"id\":\"resp_1\",",
            "\"id\":\"resp_1\",\"model\":\"different\",",
          ),
        ])
      _ ->
        sse([
          created(),
          source.done(),
          string.replace(source.completed(), "resp_1", "different"),
        ])
    }
    with_runtime([events], fn(provider, cache, _, peer) {
      let assert Ok(opened) =
        http.open(provider, cache, config("tenant"), None, req(body()))
      let seen = process.new_subject()
      http.forward_http(opened, fn(event) {
        process.send(seen, stream.wire_event(event).name)
        Ok(pump.Continue)
      })
      |> should.equal(
        Error(contracts.Failure(
          contracts.InvalidResponse,
          contracts.Started,
          None,
        )),
      )
      process.receive(seen, 0) |> should.equal(Ok("response.created"))
      process.receive(seen, 0) |> should.equal(Ok("response.output_item.done"))
      case fault {
        "trailing" ->
          process.receive(seen, 0) |> should.equal(Ok("response.completed"))
        _ -> Nil
      }
      process.receive(seen, 0) |> should.be_error
      http.open(provider, cache, config("tenant"), None, req(follow()))
      |> should.be_error
      list.length(observations(peer)) |> should.equal(1)
    })
  })
}

pub fn lite_local_cancel_downstream_failure_and_remote_non_success_never_receipt_test() {
  list.each(
    ["cancel", "downstream", "failed", "incomplete", "cancelled", "error"],
    fn(mode) {
      let events = case mode {
        "failed" | "incomplete" | "cancelled" ->
          sse([created(), string.replace(source.completed(), "completed", mode)])
        "error" ->
          sse([
            created(),
            "{\"type\":\"error\",\"error\":{\"message\":\"SYNTHETIC failure\"}}",
          ])
        _ -> eligible()
      }
      with_runtime([events], fn(provider, cache, _, peer) {
        let assert Ok(opened) =
          http.open(provider, cache, config("tenant"), None, req(body()))
        let result =
          http.forward_http(opened, fn(_) {
            case mode {
              "cancel" -> Ok(pump.Cancel)
              "downstream" -> Error("synthetic closed")
              _ -> Ok(pump.Continue)
            }
          })
        case mode {
          "cancel" | "downstream" ->
            result
            |> should.equal(
              Error(contracts.Failure(
                contracts.Cancelled,
                contracts.Started,
                None,
              )),
            )
          _ -> {
            let assert Ok(delivery) = result
            response.delivery_completion(delivery) |> should.equal(None)
            case mode {
              "error" -> response.delivery_body(delivery) |> should.be_error
              _ -> response.delivery_body(delivery) |> should.be_ok
            }
            Nil
          }
        }
        http.open(provider, cache, config("tenant"), None, req(follow()))
        |> should.be_error
        list.length(observations(peer)) |> should.equal(1)
      })
    },
  )
}

pub fn lite_receipts_preserve_account_revision_operation_scope_and_restart_fences_test() {
  with_runtime(
    [eligible(), string.replace(eligible(), "resp_1", "resp_2")],
    fn(provider, cache, store, peer) {
      let assert Ok(opened) =
        http.open(provider, cache, config("tenant"), None, req(body()))
      http.consume_http(opened) |> should.be_ok
      list.each(
        [
          #(config("other-tenant"), req(follow())),
          #(
            config("tenant"),
            contracts.Request(..req(follow()), pinned_account: Some("b")),
          ),
          #(
            config("tenant"),
            contracts.Request(..req(follow()), session: "other-session"),
          ),
          #(
            config("tenant"),
            contracts.Request(..req(follow()), operation: "responses"),
          ),
          #(
            config("tenant"),
            contracts.Request(..req(follow()), operation: "responses/compact"),
          ),
        ],
        fn(case_) {
          http.open(provider, cache, case_.0, None, case_.1) |> should.be_error
        },
      )
      let assert Ok(next) =
        http.open(
          provider,
          cache,
          config("tenant"),
          None,
          contracts.Request(..req(follow()), pinned_account: None),
        )
      let assert Ok(delivery) = http.consume_http(next)
      let assert Some(completed) = response.delivery_completion(delivery)
      completed.response.id |> should.equal("resp_2")
      let observed = observations(peer)
      list.length(observed) |> should.equal(2)
      let assert Ok(last) = list.last(observed)
      string.contains(last, "synthetic first") |> should.be_true
      string.contains(last, "\"id\":\"msg_1\"") |> should.be_true
      string.contains(last, "synthetic next") |> should.be_true
      string.contains(last, "previous_response_id") |> should.be_false
      string.contains(last, "Chatgpt-Account-Id: synthetic-provider-a")
      |> should.be_true
      runtime_store.save(
        store,
        credentials.key("codex", "oauth", "a"),
        material("a"),
      )
      |> should.be_ok
      http.open(provider, cache, config("tenant"), None, req(follow()))
      |> should.be_error
      runtime_store.delete(store, credentials.key("codex", "oauth", "a"))
      |> should.be_ok
      http.open(provider, cache, config("tenant"), None, req(follow()))
      |> should.be_error
      let assert Ok(fresh) =
        continuation.start(continuation.Limits(
          32,
          8_388_608,
          2_097_152,
          900_000,
        ))
      http.open(provider, fresh, config("tenant"), None, req(follow()))
      |> should.be_error
      continuation.stop(fresh) |> should.be_ok
      list.length(observations(peer)) |> should.equal(2)
    },
  )
}

pub fn lite_response_consumer_rejects_foreign_selected_plan_test() {
  with_runtime([native()], fn(provider, _, _, _) {
    let plans = process.new_subject()
    let transport =
      adapter.http_planned(config("tenant"), None, fn(account, plan) {
        process.send(plans, #(account, plan))
      })
    let assert Ok(opened) = runtime.open(provider, transport, req(body()))
    let assert Ok(#("a", prepared)) = process.receive(plans, 1000)
    response.consume_http(
      opened,
      request.Prepared(..prepared, credential_id: "b"),
    )
    |> should.equal(
      Error(contracts.Failure(
        contracts.InvalidConfiguration,
        contracts.Started,
        None,
      )),
    )
  })
}

pub fn lite_executor_projection_preserves_exact_event_json_and_usage_test() {
  let assert Ok(prepared) =
    adapter.prepare_native(config("tenant"), context(), req(body()))
  let assert Ok(state) =
    stream.new_with_policy(response.executor_policy(prepared))
  let decoded = stream.feed_wire_partial(state, bit_array.from_string(native()))
  let assert Ok(state) = decoded.next
  stream.finish(state) |> should.equal(Ok(stream.Completed))
  list.map(decoded.events, stream.wire_data)
  |> should.equal([source.metadata(), source.done(), source.completed()])
  // Public HTTP hydration is a different projection and cannot invent usage.
  let assert Ok(public) = stream.new_with_policy(response.http_policy(prepared))
  let hydrated =
    stream.feed_wire_partial(public, bit_array.from_string(native()))
  let assert Ok(_) = hydrated.next
  let assert Ok(last) = list.last(hydrated.events)
  let assert Some(document) =
    ir.field(stream.wire_event(last).document, "response")
  let assert Ok(original) = ir.parse(source.completed())
  let assert Some(original) = ir.field(original, "response")
  ir.field(document, "usage") |> should.equal(ir.field(original, "usage"))
}

pub fn main() {
  // Focused runner; no unrelated test discovery/full gate.
  let assert Ok(_) =
    run_eunit([CodexHttpLiteTest], [Verbose, ScaleTimeouts(10)])
  Nil
}

type TestModule {
  CodexHttpLiteTest
}

type EunitOption {
  Verbose
  ScaleTimeouts(Int)
}

@external(erlang, "gleeunit_ffi", "run_eunit")
fn run_eunit(
  modules: List(TestModule),
  options: List(EunitOption),
) -> Result(Nil, Nil)
