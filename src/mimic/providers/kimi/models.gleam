import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import mimic/providers/contracts
import mimic/providers/registry

/// Reference IDs from CPA's pinned models.json, not account entitlements.
pub fn reference_ids() -> List(String) {
  [
    "kimi-k2",
    "kimi-k2-thinking",
    "kimi-k2.5",
    "kimi-k2.6",
    "kimi-k2.7-code",
    "kimi-k2.7-code-highspeed",
    "kimi-k2.8",
    "kimi-k2.8-code",
    "kimi-k3",
    "kimi-k3-256k",
  ]
}

/// CPA's executor remaps Code aliases before generic prefix stripping.
/// Only the statically registered IDs are accepted; no guessed model names.
pub fn upstream_id(id: String) -> Option(String) {
  case list.contains(reference_ids(), id) {
    False -> None
    True -> {
      let normalized = case id {
        "kimi-k2.7-code" | "kimi-k2.8" | "kimi-k2.8-code" -> "kimi-for-coding"
        "kimi-k2.7-code-highspeed" -> "kimi-for-coding-highspeed"
        _ -> string.drop_start(id, 5)
      }
      Some(normalized)
    }
  }
}

/// Source-backed controls, not measured model availability. Reject unsupported
/// levels instead of CPA's clamping, which would silently change client intent.
pub fn thinking_levels(id: String) -> List(String) {
  case id {
    "kimi-k2" -> []
    "kimi-k2-thinking" | "kimi-k2.5" | "kimi-k2.6" -> ["none", "low", "high"]
    "kimi-k2.7-code" | "kimi-k2.7-code-highspeed" -> ["low", "high"]
    "kimi-k2.8" | "kimi-k2.8-code" | "kimi-k3" | "kimi-k3-256k" -> [
      "none",
      "low",
      "high",
      "max",
    ]
    _ -> []
  }
}

pub fn supports_images(id: String) -> Bool {
  list.contains(reference_ids(), id)
  && id != "kimi-k2"
  && id != "kimi-k2-thinking"
}

/// Only native protocols are registered. No continuation, compact or audio.
pub fn registration(id: String) -> Result(registry.Model, String) {
  case upstream_id(id) {
    None -> Error("Unknown Kimi model; explicit registration required")
    Some(_) ->
      Ok(
        registry.Model(
          "kimi",
          id,
          ["api_key", "oauth"],
          ["responses", "chat", "anthropic"],
          ["responses", "chat/completions", "messages"],
          case supports_images(id) {
            True -> [
              contracts.Buffer,
              contracts.Stream,
              contracts.Tools,
              contracts.Images,
            ]
            False -> [contracts.Buffer, contracts.Stream, contracts.Tools]
          },
        ),
      )
  }
}
