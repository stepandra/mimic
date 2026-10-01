/// Explicit, exclusive operation-origin authority for one configured account.
/// Bindings are secret-free and share the runtime's existing credential worker.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/fleet
import mimic/ir
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/xai/endpoint
import mimic/providers/xai/models

pub opaque type Binding {
  Binding(
    account: String,
    auth_mode: String,
    protocol: String,
    operation: String,
    origin: String,
    config: endpoint.Config,
    egress: fleet.Egress,
  )
}

/// Full base is explicit and canonical /v1. Never fill missing origins or
/// silently rewrite a default API base into the CLI proxy.
pub fn new(
  account: String,
  auth_mode: String,
  protocol: String,
  operation: String,
  base: String,
  using_api: Bool,
) -> Result(Binding, String) {
  use mode <- result.try(case auth_mode {
    "oauth" -> Ok(endpoint.DeviceOAuth)
    "api_key" -> Ok(endpoint.ApiKey)
    _ -> Error("unsupported xAI authentication mode")
  })
  use url <- result.try(uri.parse(base) |> safe)
  use policy <- result.try(case url.scheme, url.host {
    Some("http"), Some("127.0.0.1") -> Ok(endpoint.LocalMock)
    Some("https"), Some(host) ->
      case string.contains(host, ":") {
        False -> Ok(endpoint.VerifiedTls)
        True -> Error("xAI operation IPv6 transport is unsupported")
      }
    _, _ -> Error("unsupported configured xAI operation transport")
  })
  use _ <- result.try(endpoint.validate_base(base, policy))
  let host = case url.host {
    Some(host) -> string.lowercase(host)
    None -> ""
  }
  use _ <- result.try(
    case
      account != ""
      && string.byte_size(account) <= 256
      && !string.contains(account, "\u{0000}")
      && protocol == "responses"
      && {
        operation == "responses"
        || operation == "responses/compact"
        || operation == "responses/websocket"
      }
      && { operation == "responses" || using_api }
      && url.path == "/v1"
      && url.host == Some(host)
      && uri.to_string(url) == base
      && { using_api || base != endpoint.api_base }
      && { !using_api || host != "cli-chat-proxy.grok.com" }
    {
      True -> Ok(Nil)
      False -> Error("unsupported or implicit configured xAI operation")
    },
  )
  let config =
    endpoint.Config(
      mode,
      using_api,
      operation == "responses/websocket",
      Some(base),
      Some(base),
      case operation {
        "responses/websocket" -> Some(base)
        _ -> None
      },
      policy,
    )
  let op = case operation {
    "responses/compact" -> endpoint.Compact
    "responses/websocket" -> endpoint.WebSocket
    _ -> endpoint.Responses
  }
  use plan <- result.try(endpoint.select(config, op))
  let expected = case op {
    endpoint.WebSocket -> {
      let websocket_base =
        base
        |> string.replace("https://", "wss://")
        |> string.replace("http://", "ws://")
      websocket_base <> "/responses"
    }
    _ -> base <> "/" <> operation
  }
  use _ <- result.try(case plan.url == expected {
    True -> Ok(Nil)
    False -> Error("xAI operation cannot change its explicit base")
  })
  let origin =
    uri.to_string(uri.Uri(..url, path: "", query: None, fragment: None))
  let egress = case policy {
    endpoint.LocalMock -> fleet.LocalLoopback
    endpoint.VerifiedTls -> fleet.OperatorHttps
  }
  Ok(Binding(account, auth_mode, protocol, operation, origin, config, egress))
}

pub fn decode(
  account: String,
  auth_mode: String,
  raw: ir.Value,
) -> Result(List(Binding), String) {
  use values <- result.try(ir.as_array(raw) |> safe)
  use bindings <- result.try(
    list.try_map(values, fn(raw) {
      use fields <- result.try(ir.as_object(raw) |> safe)
      use _ <- result.try(
        case
          list.sort(list.map(fields, fn(field) { field.0 }), string.compare)
          == ["base", "operation", "protocol", "using_api"]
        {
          True -> Ok(Nil)
          False ->
            Error(
              "xAI operation requires exactly protocol/operation/base/using_api",
            )
        },
      )
      use protocol <- result.try(ir.string_field(raw, "protocol") |> safe)
      use operation <- result.try(ir.string_field(raw, "operation") |> safe)
      use base <- result.try(ir.string_field(raw, "base") |> safe)
      use api <- result.try(
        ir.required(raw, "using_api") |> result.try(ir.as_bool) |> safe,
      )
      new(account, auth_mode, protocol, operation, base, api)
    }),
  )
  use _ <- result.try(validate_account(account, auth_mode, bindings))
  Ok(bindings)
}

/// Root config and UI admission use this same ownership/exclusivity rule.
pub fn validate_account(
  account: String,
  auth_mode: String,
  bindings: List(Binding),
) -> Result(Nil, String) {
  let keys = list.map(bindings, fn(b) { #(b.protocol, b.operation) })
  case
    { auth_mode == "api_key" || auth_mode == "oauth" }
    && { auth_mode != "oauth" || !list.is_empty(bindings) }
    && list.length(keys) == list.length(list.unique(keys))
    && list.all(bindings, fn(b) {
      b.account == account && b.auth_mode == auth_mode
    })
  {
    True -> Ok(Nil)
    False ->
      Error("xAI operations require unique bindings owned by this account")
  }
}

pub fn runtime_bindings(
  bindings: List(Binding),
) -> List(runtime.EndpointBinding) {
  list.map(bindings, fn(b) {
    runtime.EndpointBinding(
      "xai",
      b.auth_mode,
      b.account,
      b.protocol,
      b.operation,
      b.origin,
      b.egress,
    )
  })
}

/// Registration belongs to the same model/mode/operation policy as selection.
/// A model needs at least one qualifying configured binding, not entitlement
/// inferred from a generic OAuth default. Root may union results across accounts.
pub fn registration(
  account: String,
  auth_mode: String,
  bindings: List(Binding),
  model: String,
) -> Result(registry.Model, String) {
  use _ <- result.try(validate_account(account, auth_mode, bindings))
  case bindings {
    // validate_account admits an empty list only for the legacy API-key path.
    [] -> models.registration_for(model, endpoint.defaults(endpoint.ApiKey))
    _ -> {
      let admitted =
        list.filter_map(bindings, fn(binding) {
          use registered <- result.try(models.registration_for(
            model,
            binding.config,
          ))
          case list.contains(registered.operations, binding.operation) {
            True -> Ok(binding.operation)
            False -> Error("model does not support this xAI operation")
          }
        })
      case admitted {
        [] -> Error("xAI model has no source-supported configured operation")
        _ ->
          Ok(registry.Model(
            "xai",
            model,
            [auth_mode],
            ["responses"],
            list.unique(admitted),
            capabilities(admitted),
          ))
      }
    }
  }
}

/// Called AFTER actual account/operation selection. No request origin, metadata
/// endpoint or account.origin fallback can authorize a new destination.
pub fn select(
  bindings: List(Binding),
  context: contracts.Context,
  request: contracts.Request,
) -> Result(endpoint.Config, String) {
  use _ <- result.try(validate_account(
    context.account,
    context.auth_mode,
    bindings,
  ))
  use binding <- result.try(
    list.find(bindings, fn(b) {
      context.provider == "xai"
      && request.provider == "xai"
      && context.auth_mode == request.auth_mode
      && b.account == context.account
      && b.auth_mode == context.auth_mode
      && b.protocol == request.protocol
      && b.operation == request.operation
      && b.origin == context.origin
      && {
        request.pinned_account == None
        || request.pinned_account == Some(b.account)
      }
    })
    |> result.replace_error(
      "xAI operation has no approved selected account origin",
    ),
  )
  Ok(binding.config)
}

/// A root-owned aggregate of already startup-validated account bindings. Select
/// the authoritative runtime account/auth partition, preserving every binding
/// inside it, then apply the unchanged per-account exclusivity/origin policy.
/// No request field, metadata endpoint or first configured account is authority.
pub fn select_configured(
  bindings: List(Binding),
  context: contracts.Context,
  request: contracts.Request,
) -> Result(endpoint.Config, String) {
  let selected =
    list.filter(bindings, fn(binding) {
      binding.account == context.account
      && binding.auth_mode == context.auth_mode
    })
  select(selected, context, request)
}

fn capabilities(admitted: List(String)) -> List(contracts.Capability) {
  let buffered = case
    list.contains(admitted, "responses")
    || list.contains(admitted, "responses/compact")
  {
    True -> [contracts.Buffer]
    False -> []
  }
  let streaming = case
    list.contains(admitted, "responses")
    || list.contains(admitted, "responses/websocket")
  {
    True -> [contracts.Stream, contracts.Tools]
    False -> []
  }
  let websocket = case list.contains(admitted, "responses/websocket") {
    True -> [contracts.WebSocket, contracts.Continuation]
    False -> []
  }
  list.append(buffered, list.append(streaming, websocket))
}

fn safe(value: Result(a, e)) -> Result(a, String) {
  value |> result.replace_error("invalid configured xAI operation")
}
