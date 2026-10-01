/// F16 synthetic request admission; no actual credential/provider/CPA access.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/models
import mimic/providers/kimi/request
import mimic/providers/kimi/transform
import mimic/providers/kimi_compat/request as generic

fn parse(source: String) -> ir.Value {
  let assert Ok(value) = ir.parse(source)
  value
}

fn document(protocol: String, model: String, streaming: Bool) -> ir.Value {
  let input = case protocol {
    "chat" -> #(
      "messages",
      parse("[{\"role\":\"user\",\"content\":\"synthetic\"}]"),
    )
    _ -> #("input", ir.String("synthetic"))
  }
  ir.Object([
    #("model", ir.String(model)),
    #("stream", ir.Boolean(streaming)),
    input,
  ])
}

fn with_tool(
  value: ir.Value,
  protocol: String,
  parameters: ir.Value,
) -> ir.Value {
  let function =
    ir.Object([
      #("name", ir.String("synthetic_lookup")),
      #("description", ir.String("synthetic")),
      #("parameters", parameters),
      #("x-vendor", parse("{\"model\":\"user model\",\"$ref\":\"opaque\"}")),
    ])
  let tool = case protocol {
    "chat" ->
      ir.Object([#("type", ir.String("function")), #("function", function)])
    _ -> transform.set(function, "type", ir.String("function"))
  }
  transform.set(value, "tools", ir.Array([tool]))
}

fn admission(protocol: String, operation: String, value: ir.Value) {
  let mode = case ir.field(value, "stream") {
    Some(ir.Boolean(True)) -> contracts.Streaming
    _ -> contracts.Buffered
  }
  let assert Ok(model) = ir.string_field(value, "model")
  let context =
    contracts.Context(
      "kimi",
      "api_key",
      "synthetic-account",
      "http://127.0.0.1:8443",
      "synthetic-session-key",
      contracts.ApiKey("synthetic-key"),
    )
  let input =
    contracts.Request(
      "kimi",
      "api_key",
      model,
      protocol,
      operation,
      mode,
      [],
      "synthetic-session",
      None,
      ir.stringify(value),
    )
  request.prepare_at("/synthetic/v1", context, input)
}

fn operation(protocol: String) -> String {
  case protocol {
    "chat" -> "chat/completions"
    _ -> "responses"
  }
}

pub fn both_route_before_after_fixtures_match_one_schema_rule_test() {
  let parameters =
    parse(
      "{\"$defs\":{\"leaf\":{\"type\":\"string\",\"minLength\":1}},\"definitions\":{\"obj\":{\"properties\":{\"q\":{\"$ref\":\"#/$defs/leaf\",\"description\":\"synthetic override\"}}}},\"$ref\":\"#/definitions/obj\",\"required\":[\"q\"],\"additionalProperties\":false,\"default\":{\"$ref\":\"literal\",\"model\":\"user value\"},\"x-vendor\":{\"properties\":{\"$ref\":\"opaque\"}}}",
    )
  let expected =
    parse(
      "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\",\"minLength\":1,\"description\":\"synthetic override\"}},\"required\":[\"q\"],\"additionalProperties\":false,\"default\":{\"$ref\":\"literal\",\"model\":\"user value\"},\"x-vendor\":{\"properties\":{\"$ref\":\"opaque\"}}}",
    )
  list.each(["chat", "responses"], fn(protocol) {
    list.each([False, True], fn(streaming) {
      let before =
        with_tool(
          document(protocol, "kimi-k2.8", streaming),
          protocol,
          parameters,
        )
      let assert Ok(plan) = admission(protocol, operation(protocol), before)
      let assert Ok(after) = ir.parse(plan.body)
      let assert Some(ir.Array([tool])) = ir.field(after, "tools")
      let function = case protocol {
        "chat" -> {
          let assert Some(function) = ir.field(tool, "function")
          function
        }
        _ -> tool
      }
      ir.field(function, "parameters") |> should.equal(Some(expected))
      ir.field(function, "x-vendor")
      |> should.equal(
        Some(parse("{\"model\":\"user model\",\"$ref\":\"opaque\"}")),
      )
      ir.field(after, "model")
      |> should.equal(Some(ir.String("kimi-for-coding")))
      ir.field(after, "stream") |> should.equal(Some(ir.Boolean(streaming)))
      plan.target |> should.equal("/synthetic/v1/" <> operation(protocol))
    })
  })
}

pub fn both_route_invalid_refs_fail_as_not_sent_test() {
  list.each(["chat", "responses"], fn(protocol) {
    list.each(
      [
        "{\"$ref\":\"https://synthetic.invalid/schema\"}",
        "{\"$ref\":\"#/$defs/missing\"}",
        "{\"$defs\":{\"x\":{\"$ref\":\"#/$defs/x\"}},\"$ref\":\"#/$defs/x\"}",
        "{\"$ref\":\"#/default\",\"default\":{\"type\":\"object\"}}",
      ],
      fn(source) {
        let value =
          with_tool(
            document(protocol, "kimi-k2.8", False),
            protocol,
            parse(source),
          )
        admission(protocol, operation(protocol), value)
        |> should.equal(
          Error(contracts.Failure(
            contracts.Unsupported,
            contracts.NotSent,
            None,
          )),
        )
      },
    )
  })
}

pub fn aggregate_normalized_request_is_bounded_before_send_test() {
  let parameters =
    ir.Object([
      #(
        "$defs",
        ir.Object([
          #(
            "leaf",
            ir.Object([
              #("type", ir.String("string")),
              #("description", ir.String(string.repeat("s", 4096))),
            ]),
          ),
        ]),
      ),
      #(
        "properties",
        ir.Object(
          list.repeat(Nil, 50)
          |> list.index_map(fn(_, index) {
            #("p" <> int.to_string(index), parse("{\"$ref\":\"#/$defs/leaf\"}"))
          }),
        ),
      ),
    ])
  list.each(["chat", "responses"], fn(protocol) {
    let value =
      with_tool(document(protocol, "kimi-k2.8", False), protocol, parameters)
    let assert Some(ir.Array([tool])) = ir.field(value, "tools")
    // Each schema fits its own ceiling; their combined normalized request does not.
    admission(
      protocol,
      operation(protocol),
      transform.set(value, "tools", ir.Array(list.repeat(tool, 6))),
    )
    |> should.equal(
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
    )
  })
}

pub fn accepted_temperature_and_loss_errors_apply_to_both_routes_test() {
  list.each(["chat", "responses"], fn(protocol) {
    let value = document(protocol, "kimi-k2.8", False)
    admission(protocol, operation(protocol), value) |> should.be_ok
    admission(
      protocol,
      operation(protocol),
      transform.set(value, "temperature", ir.Integer(1)),
    )
    |> should.be_ok
    list.each(
      [ir.Decimal(0.2), ir.Decimal(0.6), ir.String("1"), ir.Null],
      fn(temp) {
        admission(
          protocol,
          operation(protocol),
          transform.set(value, "temperature", temp),
        )
        |> should.equal(
          Error(contracts.Failure(
            contracts.Unsupported,
            contracts.NotSent,
            None,
          )),
        )
      },
    )
  })
  let chat =
    document("chat", "kimi-k2.8", False)
    |> transform.set("thinking", parse("{\"type\":\"disabled\",\"keep\":true}"))
    |> transform.set("temperature", ir.Decimal(0.6))
  let assert Ok(plan) = admission("chat", "chat/completions", chat)
  let assert Ok(value) = ir.parse(plan.body)
  ir.field(value, "thinking") |> should.equal(ir.field(chat, "thinking"))
  let response =
    document("responses", "kimi-k2.8", False)
    |> transform.set(
      "reasoning",
      parse("{\"effort\":\"none\",\"summary\":\"auto\",\"x-vendor\":true}"),
    )
    |> transform.set("temperature", ir.Integer(1))
  let assert Ok(plan) = admission("responses", "responses", response)
  let assert Ok(value) = ir.parse(plan.body)
  ir.field(value, "reasoning") |> should.equal(ir.field(response, "reasoning"))
  admission(
    "responses",
    "responses",
    transform.set(response, "temperature", ir.Decimal(0.6)),
  )
  |> should.be_error
}

pub fn registered_model_efforts_preserve_dialect_controls_test() {
  list.each(models.reference_ids(), fn(model) {
    list.each(["chat", "responses"], fn(protocol) {
      let base = document(protocol, model, False)
      let assert Ok(plan) = admission(protocol, operation(protocol), base)
      let assert Ok(value) = ir.parse(plan.body)
      ir.field(value, "model")
      |> should.equal(option.map(models.upstream_id(model), ir.String))
      list.each(models.thinking_levels(model), fn(level) {
        let control = case protocol {
          "chat" -> #("reasoning_effort", ir.String(level))
          _ -> #("reasoning", ir.Object([#("effort", ir.String(level))]))
        }
        let assert Ok(plan) =
          admission(
            protocol,
            operation(protocol),
            transform.set(base, control.0, control.1),
          )
        let assert Ok(value) = ir.parse(plan.body)
        case protocol {
          "chat" -> {
            ir.field(value, "reasoning_effort") |> should.equal(None)
            let assert Some(thinking) = ir.field(value, "thinking")
            let kind = case level {
              "none" -> "disabled"
              _ -> "enabled"
            }
            ir.field(thinking, "type") |> should.equal(Some(ir.String(kind)))
          }
          _ -> ir.field(value, "reasoning") |> should.equal(Some(control.1))
        }
      })
    })
  })
}

pub fn no_effort_clamp_budget_guess_or_alias_catalog_invention_test() {
  list.each(["chat", "responses"], fn(protocol) {
    list.each(
      ["kimi-k2", "kimi-k2.7-code", "kimi-k2.7-code-highspeed"],
      fn(model) {
        let control = case protocol {
          "chat" -> #("reasoning_effort", ir.String("none"))
          _ -> #("reasoning", parse("{\"effort\":\"none\"}"))
        }
        admission(
          protocol,
          operation(protocol),
          transform.set(document(protocol, model, False), control.0, control.1),
        )
        |> should.be_error
      },
    )
    list.each(
      [
        "KIMI-K2.8",
        "kimi-k2.8[1m]",
        "kimi-k2.8(1024)",
        "kimi-k2.8-preview",
        "synthetic-model",
      ],
      fn(model) {
        admission(
          protocol,
          operation(protocol),
          document(protocol, model, False),
        )
        |> should.be_error
      },
    )
  })
  list.each(
    [
      "{\"type\":\"enabled\",\"budget_tokens\":1024}",
      "{\"type\":\"enabled\",\"effort\":\"medium\"}",
      "{\"type\":\"adaptive\"}",
    ],
    fn(control) {
      admission(
        "chat",
        "chat/completions",
        transform.set(
          document("chat", "kimi-k2.8", False),
          "thinking",
          parse(control),
        ),
      )
      |> should.be_error
    },
  )
}

pub fn chat_history_text_arguments_vendor_values_are_never_rewritten_test() {
  let value =
    parse(
      "{\"model\":\"kimi-k2.8\",\"messages\":[{\"role\":\"assistant\",\"content\":\"  \"},{\"role\":\"assistant\",\"reasoning_content\":\"synthetic raw reasoning\",\"tool_calls\":[{\"id\":\"explicit-call\",\"type\":\"function\",\"function\":{\"name\":\"synthetic_lookup\",\"arguments\":\"{ \\\"$ref\\\": \\\"file:///synthetic\\\", \\\"model\\\":\\\"kimi-k2.8\\\", \\\"type\\\":\\\"input_audio\\\" }\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"explicit-call\",\"content\":\"{\\\"$ref\\\":\\\"opaque\\\",\\\"thinking\\\":\\\"literal\\\"}\"}],\"x-vendor\":{\"thinking\":{\"type\":\"disabled\"},\"temperature\":0.2,\"conversation\":\"opaque\"}}",
    )
  let assert Ok(plan) = admission("chat", "chat/completions", value)
  let assert Ok(after) = ir.parse(plan.body)
  ir.field(after, "messages") |> should.equal(ir.field(value, "messages"))
  ir.field(after, "x-vendor") |> should.equal(ir.field(value, "x-vendor"))
}

pub fn reasoning_and_id_repair_are_errors_not_fabrication_test() {
  list.each(
    [
      "[{\"role\":\"assistant\",\"content\":\"synthetic not reasoning\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}]",
      "[{\"role\":\"assistant\",\"reasoning_content\":\"synthetic previous\"},{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}]",
      "[{\"role\":\"assistant\",\"reasoning_content\":\"synthetic\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"call_id\":\"a\",\"content\":\"synthetic\"}]",
      "[{\"role\":\"assistant\",\"reasoning_content\":\"synthetic\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"content\":\"synthetic\"}]",
      "[{\"role\":\"assistant\",\"reasoning_content\":\"synthetic\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}},{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]}]",
    ],
    fn(messages) {
      admission(
        "chat",
        "chat/completions",
        transform.set(
          document("chat", "kimi-k2.8", False),
          "messages",
          parse(messages),
        ),
      )
      |> should.be_error
    },
  )
  let value =
    document("chat", "kimi-k2.8", False)
    |> transform.set("thinking", parse("{\"type\":\"disabled\"}"))
    |> transform.set(
      "messages",
      parse(
        "[{\"role\":\"assistant\",\"tool_calls\":[{\"id\":\"a\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"{}\"}}]},{\"role\":\"tool\",\"tool_call_id\":\"a\",\"content\":\"synthetic\"}]",
      ),
    )
  let assert Ok(plan) = admission("chat", "chat/completions", value)
  let assert Ok(after) = ir.parse(plan.body)
  ir.field(after, "messages") |> should.equal(ir.field(value, "messages"))
}

pub fn native_responses_reasoning_and_raw_history_survive_schema_normalization_test() {
  let value =
    parse(
      "{\"model\":\"kimi-k2.8\",\"input\":[{\"type\":\"reasoning\",\"id\":\"reason_synthetic\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"  synthetic 思考🌍  \"}],\"encrypted_content\":\"synthetic opaque\",\"x-vendor\":{\"model\":\"user\"}},{\"type\":\"function_call\",\"id\":\"item_synthetic\",\"call_id\":\"explicit-call\",\"name\":\"synthetic_lookup\",\"arguments\":\"{ \\\"$ref\\\":\\\"opaque\\\" }\"},{\"type\":\"function_call_output\",\"call_id\":\"explicit-call\",\"output\":\"{\\\"model\\\":\\\"user\\\"}\"}],\"reasoning\":{\"effort\":\"max\",\"summary\":\"auto\"}}",
    )
  let value =
    with_tool(
      value,
      "responses",
      parse("{\"$ref\":\"#/$defs/x\",\"$defs\":{\"x\":{\"type\":\"object\"}}}"),
    )
  let assert Ok(plan) = admission("responses", "responses", value)
  let assert Ok(after) = ir.parse(plan.body)
  ir.field(after, "input") |> should.equal(ir.field(value, "input"))
  ir.field(after, "reasoning") |> should.equal(ir.field(value, "reasoning"))
}

pub fn unsupported_media_at_protocol_positions_is_not_sent_test() {
  list.each(
    ["input_audio", "video", "file", "synthetic_future_media"],
    fn(kind) {
      let part =
        ir.Object([
          #("type", ir.String(kind)),
          #("data", ir.String("synthetic")),
        ])
      list.each(["chat", "responses"], fn(protocol) {
        let message =
          ir.Object([
            #("role", ir.String("user")),
            #("content", ir.Array([part])),
          ])
        let field = case protocol {
          "chat" -> "messages"
          _ -> "input"
        }
        let assert Error(failure) =
          admission(
            protocol,
            operation(protocol),
            transform.set(
              document(protocol, "kimi-k2.8", False),
              field,
              ir.Array([message]),
            ),
          )
        // The shared Responses decoder can reject a malformed/unknown block
        // before provider policy does. Both boundaries must guarantee NotSent.
        failure.delivery |> should.equal(contracts.NotSent)
        list.contains(
          [contracts.Unsupported, contracts.InvalidConfiguration],
          failure.reason,
        )
        |> should.be_true
      })
    },
  )
}

pub fn compact_and_opaque_continuation_remain_denied_test() {
  list.each(["chat", "responses"], fn(protocol) {
    list.each(["previous_response_id", "conversation"], fn(key) {
      admission(
        protocol,
        operation(protocol),
        transform.set(
          document(protocol, "kimi-k2.8", False),
          key,
          ir.String("opaque-synthetic-handle"),
        ),
      )
      |> should.be_error
    })
  })
  list.each([False, True], fn(streaming) {
    admission(
      "responses",
      "responses/compact",
      document("responses", "kimi-k2.8", streaming),
    )
    |> should.equal(
      Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None)),
    )
  })
}

pub fn generic_raw_semantics_are_not_native_normalization_test() {
  let body =
    " { \"model\":\"synthetic-generic\", \"messages\":[{\"role\":\"user\",\"content\":\"synthetic\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"parameters\":{\"$ref\":\"#/$defs/x\",\"$defs\":{\"x\":{\"type\":\"object\"}}}}}],\"reasoning_effort\":\"medium\",\"temperature\":0.2 } "
  let context =
    contracts.Context(
      "openai-compatible-kimi",
      "api_key",
      "synthetic-generic",
      "http://127.0.0.1:8443",
      "synthetic-session",
      contracts.ApiKey("synthetic-generic-key"),
    )
  let input =
    contracts.Request(
      "openai-compatible-kimi",
      "api_key",
      "synthetic-generic",
      "chat",
      "chat/completions",
      contracts.Buffered,
      [],
      "synthetic-session",
      None,
      body,
    )
  let assert Ok(plan) = generic.prepare_at("/v1", context, input)
  plan.body |> should.equal(body)
}
