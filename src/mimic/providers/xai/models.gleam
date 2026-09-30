import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/xai/endpoint

/// Reference metadata, NOT proof of availability for an account/endpoint.
/// Limits and reasoning levels are from the pinned CPA registry.
pub type Model {
  Model(
    id: String,
    context_tokens: Int,
    max_output_tokens: Int,
    reasoning_levels: List(String),
    upstream_image_input: Bool,
    build_only: Bool,
    isolated_conversation: Bool,
  )
}

pub fn reference_models() -> List(Model) {
  [
    Model(
      "grok-4.7",
      500_000,
      500_000,
      ["low", "medium", "high", "xhigh"],
      True,
      False,
      False,
    ),
    Model(
      "grok-4.7-build-fast",
      500_000,
      500_000,
      ["low", "medium", "high", "xhigh"],
      True,
      True,
      False,
    ),
    Model(
      "grok-4.6",
      500_000,
      65_536,
      ["low", "medium", "high", "xhigh"],
      True,
      False,
      False,
    ),
    Model("grok-build-0.1", 256_000, 256_000, [], True, True, False),
    Model(
      "grok-4.5",
      500_000,
      65_536,
      ["low", "medium", "high"],
      True,
      False,
      False,
    ),
    Model(
      "grok-4.3",
      1_000_000,
      65_536,
      ["none", "low", "medium", "high"],
      True,
      False,
      False,
    ),
    Model("grok-4.20-0309-reasoning", 2_000_000, 65_536, [], True, False, False),
    Model(
      "grok-4.20-0309-non-reasoning",
      2_000_000,
      65_536,
      [],
      True,
      False,
      False,
    ),
    Model(
      "grok-4.20-multi-agent-0309",
      2_000_000,
      65_536,
      ["low", "medium", "high"],
      True,
      False,
      False,
    ),
    Model(
      "grok-3-mini",
      131_072,
      32_768,
      ["low", "medium", "high"],
      False,
      False,
      False,
    ),
    Model(
      "grok-3-mini-fast",
      131_072,
      32_768,
      ["low", "medium", "high"],
      False,
      False,
      False,
    ),
    Model("grok-composer-2.5-fast", 200_000, 32_768, [], False, False, True),
  ]
}

pub fn lookup(id: String) -> Option(Model) {
  case list.find(reference_models(), fn(model) { model.id == id }) {
    Ok(model) -> Some(model)
    Error(_) -> None
  }
}

pub fn validate(
  id: String,
  config: endpoint.Config,
  reasoning_effort: Option(String),
  conversation: String,
) -> Result(Model, String) {
  case lookup(id) {
    None -> Error("Unknown xAI model; explicit model registration required")
    Some(model) if model.build_only && config.using_api ->
      Error("Grok Build model requires CLI proxy mode")
    Some(model) if model.isolated_conversation && conversation == "" ->
      Error("Grok composer requires an isolated conversation")
    Some(model) ->
      case reasoning_effort {
        None -> Ok(model)
        Some(effort) ->
          case list.contains(model.reasoning_levels, effort) {
            True -> Ok(model)
            False -> Error("Unsupported xAI model reasoning effort")
          }
      }
  }
}

pub fn requires_conversation(id: String) -> Bool {
  string.starts_with(string.lowercase(id), "grok-composer-")
}

/// Reference metadata is not account entitlement. The operator still lists
/// enabled models on each runtime account; only native HTTP is advertised.
pub fn registration(id: String) -> Result(registry.Model, String) {
  registration_for(id, endpoint.defaults(endpoint.ApiKey))
  |> result.map(fn(model) {
    // Existing root route uses the legacy raw prepare hook. Only the native
    // adapter factory + registration_for may advertise reversible tools.
    registry.Model(..model, capabilities: [contracts.Buffer, contracts.Stream])
  })
}

/// Explicit operator mode/transport enablement, not an entitlement claim.
/// Continuation capability is connection-scoped WS only; HTTP still rejects it.
pub fn registration_for(
  id: String,
  config: endpoint.Config,
) -> Result(registry.Model, String) {
  case lookup(id) {
    Some(model) if !model.isolated_conversation -> {
      case model.build_only && config.using_api {
        True -> Error("Grok Build model requires CLI proxy mode")
        False ->
          Ok(
            registry.Model(
              "xai",
              id,
              [
                case config.mode {
                  endpoint.ApiKey -> "api_key"
                  endpoint.DeviceOAuth -> "oauth"
                },
              ],
              ["responses"],
              case config.websockets {
                True -> [
                  "responses",
                  "responses/compact",
                  "responses/websocket",
                ]
                False -> ["responses", "responses/compact"]
              },
              case config.websockets {
                True -> [
                  contracts.Buffer,
                  contracts.Stream,
                  contracts.Tools,
                  contracts.WebSocket,
                  contracts.Continuation,
                ]
                False -> [contracts.Buffer, contracts.Stream, contracts.Tools]
              },
            ),
          )
      }
    }
    _ -> Error("xAI model is unavailable for the native adapter")
  }
}
