import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/ir
import mimic/providers/xai/endpoint
import mimic/providers/xai/request
import mimic/providers/xai/tools

fn value(source) {
  let assert Ok(value) = ir.parse(source)
  value
}

fn config() {
  endpoint.defaults(endpoint.ApiKey)
}

pub fn namespace_roundtrip_and_alias_test() {
  let body =
    value(
      "{\"model\":\"grok-4.7\",\"input\":[{\"type\":\"function_call\",\"name\":\"run\",\"namespace\":\"shell\",\"arguments\":\"{}\",\"call_id\":\"c1\"}],\"tools\":[{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"function\",\"name\":\"run\",\"parameters\":{\"type\":\"object\"}}]},{\"type\":\"function\",\"name\":\"web_search\"},{\"type\":\"function\",\"name\":\"clientfn_web_search\"}],\"tool_choice\":{\"type\":\"function\",\"name\":\"run\",\"namespace\":\"shell\"}}",
    )
  let assert Ok(prepared) =
    request.prepare(config(), endpoint.Responses, body, "session")
  prepared.tool_refs
  |> should.equal([
    tools.Ref("shell__run", "run", "shell"),
    tools.Ref("clientfn_web_search_1", "web_search", ""),
    tools.Ref("clientfn_web_search", "clientfn_web_search", ""),
  ])
  let assert Ok(choice) = ir.required(prepared.body, "tool_choice")
  ir.string_field(choice, "name") |> should.equal(Ok("shell__run"))
  ir.string_field(choice, "type") |> should.equal(Ok("function"))
  ir.field(choice, "namespace") |> should.equal(None)
  let event =
    value(
      "{\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"function_call\",\"name\":\"shell__run\",\"arguments\":\"{\\\"name\\\":\\\"shell__run\\\"}\"},{\"type\":\"function_call\",\"name\":\"clientfn_web_search_1\"}],\"usage\":{\"input_tokens\":9,\"output_tokens\":7,\"output_tokens_details\":{\"reasoning_tokens\":4}}}}",
    )
  let restored = request.restore_event(event, prepared.tool_refs)
  let assert Ok(response) = ir.required(restored, "response")
  let assert Ok(ir.Array([first, second])) = ir.required(response, "output")
  ir.string_field(first, "name") |> should.equal(Ok("run"))
  ir.string_field(first, "namespace") |> should.equal(Ok("shell"))
  ir.string_field(first, "arguments")
  |> should.equal(Ok("{\"name\":\"shell__run\"}"))
  ir.string_field(second, "name") |> should.equal(Ok("web_search"))
  let assert Ok(original) = ir.required(event, "response")
  ir.field(response, "usage") |> should.equal(ir.field(original, "usage"))
  request.restore_event(event, []) |> should.equal(event)
}

pub fn collisions_and_unsupported_tools_fail_closed_test() {
  tools.prepare([
    value("{\"type\":\"function\",\"name\":\"shell__run\"}"),
    value(
      "{\"type\":\"namespace\",\"name\":\"shell\",\"tools\":[{\"type\":\"function\",\"name\":\"run\"}]}",
    ),
  ])
  |> should.be_error
  list.each(["image_generation", "tool_search", "custom"], fn(kind) {
    tools.prepare([ir.Object([#("type", ir.String(kind))])])
    |> should.be_error
  })
}

pub fn native_server_tools_and_client_alias_remain_distinct_test() {
  let server =
    value("{\"type\":\"web_search\",\"allowed_domains\":[\"example.invalid\"]}")
  let x_search =
    value("{\"type\":\"x_search\",\"allowed_x_handles\":[\"synthetic\"]}")
  let assert Ok(#(declared, refs)) =
    tools.prepare([
      server,
      x_search,
      value(
        "{\"type\":\"function\",\"name\":\"web_search\",\"parameters\":{\"type\":\"object\"}}",
      ),
    ])
  list.take(declared, 2) |> should.equal([server, x_search])
  refs |> should.equal([tools.Ref("clientfn_web_search", "web_search", "")])
  tools.wire_call(value("{\"name\":\"web_search\",\"namespace\":1}"), refs)
  |> should.be_error
  let event =
    value(
      "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"web_search_call\",\"id\":\"synthetic\",\"status\":\"completed\"}}",
    )
  request.restore_event(event, refs) |> should.equal(event)
  let body =
    value(
      "{\"model\":\"grok-4.7\",\"input\":[],\"tools\":[{\"type\":\"web_search\"}],\"tool_choice\":{\"type\":\"web_search\"}}",
    )
  let assert Ok(prepared) =
    request.prepare(config(), endpoint.Responses, body, "")
  ir.field(prepared.body, "tool_choice")
  |> should.equal(ir.field(body, "tool_choice"))
  request.prepare(
    config(),
    endpoint.Responses,
    tools.set(body, "tools", ir.Array([])),
    "",
  )
  |> should.be_error
}

pub fn http_compact_ws_request_controls_test() {
  let body =
    value(
      "{\"model\":\"grok-4.7\",\"input\":\"hello\",\"instructions\":\"keep\",\"previous_response_id\":\"resp_old\",\"stream\":false,\"background\":true,\"tools\":[{\"type\":\"function\",\"name\":\"run\"}],\"tool_choice\":\"auto\",\"temperature\":0.2,\"max_output_tokens\":200,\"reasoning\":{\"effort\":\"high\"},\"vendor_extension\":{\"keep\":true}}",
    )
  let assert Ok(http) = request.prepare(config(), endpoint.Responses, body, "")
  ir.field(http.body, "stream") |> should.equal(Some(ir.Boolean(True)))
  ir.field(http.body, "previous_response_id") |> should.equal(None)
  let assert Ok(compact) = request.prepare(config(), endpoint.Compact, body, "")
  list.each(
    ["stream", "tools", "tool_choice", "temperature", "max_output_tokens"],
    fn(key) { ir.field(compact.body, key) |> should.equal(None) },
  )
  ir.field(compact.body, "previous_response_id")
  |> should.equal(Some(ir.String("resp_old")))
  let assert Ok(ws) = request.prepare(config(), endpoint.WebSocket, body, "")
  ir.field(ws.body, "type") |> should.equal(Some(ir.String("response.create")))
  ir.field(ws.body, "store") |> should.equal(Some(ir.Boolean(True)))
  list.each(["stream", "background", "instructions"], fn(key) {
    ir.field(ws.body, key) |> should.equal(None)
  })
  list.each([http, compact, ws], fn(prepared) {
    ir.field(prepared.body, "reasoning")
    |> should.equal(ir.field(body, "reasoning"))
    ir.field(prepared.body, "vendor_extension")
    |> should.equal(ir.field(body, "vendor_extension"))
  })
}

pub fn compaction_trigger_is_explicit_test() {
  let body =
    value(
      "{\"model\":\"grok-4.7\",\"input\":[{\"type\":\"compaction_trigger\"}]}",
    )
  request.prepare(config(), endpoint.Responses, body, "") |> should.be_error
  let assert Ok(compact) = request.prepare(config(), endpoint.Compact, body, "")
  ir.field(compact.body, "input") |> should.equal(Some(ir.Array([])))
}

pub fn media_is_explicitly_unsupported_test() {
  let body =
    value(
      "{\"model\":\"grok-4.7\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\"https://example.invalid/image.png\"}]}]}",
    )
  request.prepare(config(), endpoint.Responses, body, "")
  |> should.equal(Error("xAI media input is not enabled in this adapter"))
}
