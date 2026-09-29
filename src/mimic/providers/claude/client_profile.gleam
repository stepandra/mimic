/// Approved software metadata, not a detector or a fingerprint generator.
/// The runtime/operator must authorize these per tenant, account and origin.
/// Credentials, device, session and request IDs are never taken from this list.
import gleam/list
import gleam/result
import gleam/string
import mimic/providers/contracts
import mimic/types.{type Header}

pub opaque type Approved {
  NoProfile
  Approved(
    account: String,
    auth_mode: String,
    origin: String,
    session_key: String,
    headers: List(Header),
  )
}

pub fn none() -> Approved {
  NoProfile
}

/// Approval is the caller's responsibility. Validation cannot establish trust.
/// Bind to the selected runtime context without retaining credential values.
pub fn from_operator(
  context: contracts.Context,
  headers: List(Header),
) -> Result(Approved, String) {
  use _ <- result.try(
    case
      context.provider == "claude"
      && context.account != ""
      && context.session_key != ""
    {
      True -> Ok(Nil)
      False -> Error("Invalid Claude profile scope")
    },
  )
  use _ <- result.try(
    list.try_map(headers, fn(header) {
      case allowed(header.name) && safe(header.value) {
        True -> Ok(Nil)
        False -> Error("Unsupported Claude approved client header")
      }
    }),
  )
  let names =
    headers
    |> list.map(fn(header) { string.lowercase(header.name) })
    |> list.filter(fn(name) { name != "anthropic-beta" })
  case list.length(names) == list.length(list.unique(names)) {
    True ->
      Ok(Approved(
        context.account,
        context.auth_mode,
        context.origin,
        context.session_key,
        headers,
      ))
    False -> Error("Duplicate Claude client identity header")
  }
}

pub fn for_context(
  profile: Approved,
  context: contracts.Context,
) -> Result(List(Header), String) {
  case profile {
    NoProfile -> Ok([])
    Approved(account, auth_mode, origin, session, headers) ->
      case
        context.provider == "claude"
        && context.account == account
        && context.auth_mode == auth_mode
        && context.origin == origin
        && context.session_key == session
      {
        True -> Ok(headers)
        False -> Error("Claude approved profile scope mismatch")
      }
  }
}

pub fn allowed(name: String) -> Bool {
  list.contains(
    [
      "user-agent", "x-app", "anthropic-beta",
      "anthropic-dangerous-direct-browser-access", "x-stainless-lang",
      "x-stainless-package-version", "x-stainless-os", "x-stainless-arch",
      "x-stainless-runtime", "x-stainless-runtime-version",
      "x-stainless-retry-count", "x-stainless-timeout", "x-stainless-async",
      "x-claude-code-agent-id", "x-claude-code-parent-agent-id",
      "x-claude-remote-container-id", "x-claude-remote-session-id",
      "x-client-app", "x-anthropic-additional-protection",
      "x-claude-code-request-class", "x-claude-code-agent-type",
      "x-claude-code-prev-tool-durations", "x-claude-code-compaction",
      "x-claude-code-context-compacted",
    ],
    string.lowercase(name),
  )
}

fn safe(value: String) -> Bool {
  safe_bytes(<<value:utf8>>)
}

fn safe_bytes(value: BitArray) -> Bool {
  case value {
    <<byte, _:bits>> if byte < 32 || byte == 127 -> False
    <<_, rest:bits>> -> safe_bytes(rest)
    _ -> True
  }
}
