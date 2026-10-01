/// F27 root seam using the explicit catalog and actual F23/F24/F25 routes.
/// Responses projection adds no count/compact/WS/continuation entitlements.
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response, Response}
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import mimic/egress
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/catalog
import mimic/providers/devin/chat
import mimic/providers/devin/chat_gateway
import mimic/providers/devin/client
import mimic/providers/devin/configuration
import mimic/providers/devin/messages_gateway
import mimic/providers/devin/messages_stream
import mimic/providers/devin/responses_gateway
import mimic/providers/devin/responses_stream
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mist

pub fn registration(
  configured: configuration.Configured,
  id: String,
) -> Result(registry.Model, String) {
  use selected <- result.try(configuration.lookup(configured, id))
  use current <- result.try(
    messages_gateway.configured_combined_registration(id, [selected.model]),
  )
  use responses <- result.try(
    responses_gateway.configured_registration(id, [selected.model]),
  )
  use _ <- result.try(case current.capabilities == responses.capabilities {
    True -> Ok(Nil)
    False -> Error("asymmetric Devin Responses capabilities")
  })
  Ok(
    registry.Model(
      ..current,
      protocols: list.append(current.protocols, responses.protocols),
    ),
  )
}

/// Metadata is derived from the exact admitted row. A catalog is neither live
/// discovery nor evidence of upstream support, account entitlement or latency.
pub fn listing(
  configured: configuration.Configured,
  admitted: registry.Model,
) -> Result(ir.Value, String) {
  use expected <- result.try(registration(configured, admitted.id))
  use selected <- result.try(configuration.lookup(configured, admitted.id))
  use _ <- result.try(case admitted == expected {
    True -> Ok(Nil)
    False -> Error("unsupported admitted Devin metadata")
  })
  Ok(
    ir.Object([
      #("id", ir.String(admitted.id)),
      #("object", ir.String("model")),
      #("owned_by", ir.String("devin")),
      #(
        "devin",
        ir.Object([
          #("canonical_id", ir.String(selected.canonical_id)),
          #("native_uid", ir.String(selected.model.uid)),
          #("max_tokens", ir.Integer(selected.model.max_tokens)),
          #(
            "images",
            ir.Boolean(list.contains(admitted.capabilities, c.Images)),
          ),
          #(
            "metadata_source",
            ir.String(
              catalog.metadata_source(configuration.catalog(configured)),
            ),
          ),
          #("protocols", strings(admitted.protocols)),
          #("operations", strings(admitted.operations)),
          #(
            "capabilities",
            strings(list.map(admitted.capabilities, capability_name)),
          ),
          #("live_discovery", ir.Boolean(False)),
        ]),
      ),
    ]),
  )
}

/// Unknown/unenabled IDs, auth, protocol, capability and body mismatches fail
/// here, before even querying runtime or acquiring its credential worker.
pub fn validate(
  configured: configuration.Configured,
  request: c.Request,
) -> Result(Nil, c.Failure) {
  use row <- result.try(
    registration(configured, request.model)
    |> result.replace_error(unsupported()),
  )
  use gate <- result.try(registry.new([row]))
  use _ <- result.try(registry.resolve(gate, request))
  let maps = catalog.mappings(configuration.catalog(configured))
  case request.protocol {
    "openai-chat" -> bridge.validate_chat(request, maps)
    "anthropic-messages" -> messages_gateway.validate(request, maps)
    "openai-responses" -> responses_gateway.validate(request, maps)
    _ -> Error("unsupported Devin protocol")
  }
  |> result.replace_error(unsupported())
}

/// Uses only the actual Context account/origin's model mapping. Existing F22
/// binary HTTP transport and bridge numeric-loopback authority guard are reused.
pub fn adapter(
  configured: configuration.Configured,
  ca: Option(String),
) -> c.Adapter(egress.Stream) {
  transport.binary_http(
    fn(context, request) {
      use maps <- result.try(
        configuration.selected(configured, context, request)
        |> result.replace_error(c.Failure(
          c.InvalidConfiguration,
          c.NotSent,
          None,
        )),
      )
      bridge.prepare_configured(context, request, maps)
    },
    bridge.rejection,
    ca,
  )
}

pub fn execute(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
) -> Result(String, c.Failure) {
  use _ <- result.try(validate(configured, request))
  use _ <- result.try(case request.mode {
    c.Buffered -> Ok(Nil)
    _ -> Error(unsupported())
  })
  case request.protocol {
    "openai-chat" ->
      bridge.execute_with_adapter(engine, request, adapter(configured, ca))
    "anthropic-messages" ->
      messages_gateway.execute_with_adapter(
        engine,
        request,
        catalog.mappings(configuration.catalog(configured)),
        adapter(configured, ca),
      )
    "openai-responses" ->
      responses_gateway.execute_with_adapter(
        engine,
        request,
        catalog.mappings(configuration.catalog(configured)),
        adapter(configured, ca),
      )
    _ -> Error(unsupported())
  }
}

pub fn open_chat(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
) -> Result(#(String, client.Client(chat.State)), c.Failure) {
  use _ <- result.try(validate(configured, request))
  chat_gateway.open_with_adapter(
    engine,
    request,
    catalog.mappings(configuration.catalog(configured)),
    adapter(configured, ca),
  )
}

pub fn open_messages(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
) -> Result(#(String, client.Client(messages_stream.State)), c.Failure) {
  use _ <- result.try(validate(configured, request))
  use _ <- result.try(case request.protocol {
    "anthropic-messages" -> Ok(Nil)
    _ -> Error(unsupported())
  })
  messages_gateway.open_with_adapter(
    engine,
    request,
    catalog.mappings(configuration.catalog(configured)),
    adapter(configured, ca),
  )
}

pub fn open_responses(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
) -> Result(#(String, client.Client(responses_stream.State)), c.Failure) {
  open_responses_until(
    engine,
    ca,
    request,
    configured,
    responses_gateway.new_deadline(),
  )
}

pub fn open_responses_until(
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
  deadline: Int,
) -> Result(#(String, client.Client(responses_stream.State)), c.Failure) {
  use _ <- result.try(validate(configured, request))
  use _ <- result.try(case request.protocol {
    "openai-responses" -> Ok(Nil)
    _ -> Error(unsupported())
  })
  responses_gateway.open_with_adapter_until(
    engine,
    request,
    catalog.mappings(configuration.catalog(configured)),
    adapter(configured, ca),
    deadline,
  )
}

pub fn serve(
  incoming: Request(mist.Connection),
  engine: runtime.Runtime,
  ca: Option(String),
  request: c.Request,
  configured: configuration.Configured,
) -> Response(mist.ResponseData) {
  case request.protocol {
    "openai-chat" ->
      case open_chat(engine, ca, request, configured) {
        Ok(#(_, opened)) -> chat_gateway.send(incoming, opened)
        Error(error) -> rejection(error)
      }
    "anthropic-messages" ->
      case open_messages(engine, ca, request, configured) {
        Ok(#(_, opened)) -> messages_gateway.send(incoming, opened)
        Error(error) -> rejection(error)
      }
    "openai-responses" -> {
      let deadline = responses_gateway.new_deadline()
      case open_responses_until(engine, ca, request, configured, deadline) {
        Ok(#(_, opened)) -> responses_gateway.send(incoming, opened, deadline)
        Error(error) -> rejection(error)
      }
    }
    _ -> rejection(unsupported())
  }
}

fn rejection(error: c.Failure) -> Response(mist.ResponseData) {
  Response(
    case error.reason {
      c.Unsupported -> 422
      _ -> 503
    },
    [#("content-type", "application/json")],
    mist.Bytes(bytes_tree.from_string("{\"error\":\"provider unavailable\"}")),
  )
}

fn unsupported() -> c.Failure {
  c.Failure(c.Unsupported, c.NotSent, None)
}

fn strings(values: List(String)) -> ir.Value {
  ir.Array(list.map(values, ir.String))
}

fn capability_name(capability: c.Capability) -> String {
  case capability {
    c.Buffer -> "buffer"
    c.Stream -> "stream"
    c.Tools -> "tools"
    c.Images -> "images"
    _ -> "unsupported"
  }
}
