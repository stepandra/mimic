/// Caller-owned native JSON profile. This does not synthesize a CLI fingerprint.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/ir
import mimic/providers/claude/cache
import mimic/providers/claude/client_profile
import mimic/providers/claude/identity as account_identity
import mimic/providers/claude/policy
import mimic/types.{type Capture, type Header, Capture, Header, Transport}

pub type Credential {
  ApiKey(String)
  OAuth(String)
}

pub type Operation {
  Messages(streaming: Bool)
  CountTokens
}

/// Runtime-generated request ID is fresh per request; session ID is stable
/// within the selected credential/session. Never hash a credential into either.
pub type Identity {
  Identity(
    session_id: String,
    request_id: String,
    account: Option(account_identity.Account),
  )
}

const oauth_beta = "oauth-2025-04-20"

const code_beta = "claude-code-20250219"

const ttl_beta = "extended-cache-ttl-2025-04-11"

const effort_beta = "effort-2025-11-24"

const display_beta = "thinking-display-updates-2026-08-18"

const redact_beta = "redact-thinking-2026-02-12"

pub fn prepare(
  origin: String,
  credential: Credential,
  operation: Operation,
  caller_headers: List(Header),
  identity: Option(Identity),
  source: String,
) -> Result(Capture, String) {
  prepare_with_policy(
    origin,
    credential,
    operation,
    caller_headers,
    identity,
    source,
    policy.native(),
  )
}

/// `selected` and client headers must be approved by the integration owner.
/// This function does not authenticate or detect a native client.
pub fn prepare_with_policy(
  origin: String,
  credential: Credential,
  operation: Operation,
  caller_headers: List(Header),
  identity: Option(Identity),
  source: String,
  selected: policy.Policy,
) -> Result(Capture, String) {
  use host <- result.try(origin_host(origin))
  let token = case credential {
    ApiKey(token) | OAuth(token) -> token
  }
  use _ <- result.try(case safe_value(token) && string.trim(token) != "" {
    True -> Ok(Nil)
    False -> Error("Invalid Claude credential")
  })
  use _ <- result.try(
    case
      list.all(caller_headers, fn(h) {
        safe_name(h.name) && safe_value(h.value)
      })
    {
      True -> Ok(Nil)
      False -> Error("Invalid Claude header")
    },
  )
  use body <- result.try(ir.parse(source))
  use _ <- result.try(ir.as_object(body))
  use model <- result.try(ir.string_field(body, "model"))
  use messages <- result.try(
    ir.required(body, "messages") |> result.try(ir.as_array),
  )
  use _ <- result.try(case model != "" && !list.is_empty(messages) {
    True -> Ok(Nil)
    False -> Error("Claude model and messages must not be empty")
  })
  use body_betas <- result.try(case ir.field(body, "betas") {
    None -> Ok([])
    Some(value) ->
      ir.as_array(value)
      |> result.try(fn(items) { list.try_map(items, ir.as_string) })
  })
  use _ <- result.try(case list.all(body_betas, safe_value) {
    True -> Ok(Nil)
    False -> Error("Invalid Claude body beta")
  })
  use body <- result.try(operation_body(remove(body, "betas"), operation))
  use body <- result.try(policy.normalize(body, selected))
  use body <- result.try(case selected.input, operation {
    policy.TranslatedMessages, Messages(_) ->
      cache.ensure_translated(body, credential_is_oauth(credential), selected)
    _, _ -> Ok(body)
  })
  use body <- result.try(case credential, identity {
    OAuth(_), Some(Identity(session, _, Some(account))) -> {
      use _ <- result.try(account_identity.validate(account))
      case operation {
        CountTokens -> Ok(body)
        Messages(_) -> account_identity.apply(body, account, session)
      }
    }
    OAuth(_), _ -> Error("Missing Claude OAuth credential identity")
    ApiKey(_), _ -> Ok(body)
  })
  use cache <- result.try(cache.validate(body))
  use _ <- result.try(
    case selected.turn == policy.Helper && cache.has_one_hour {
      True -> Error("Claude helper profile does not support 1h cache")
      False -> Ok(Nil)
    },
  )
  let betas =
    list.filter(caller_headers, fn(h) {
      string.lowercase(h.name) == "anthropic-beta"
    })
    |> list.flat_map(fn(h) { string.split(h.value, ",") })
    |> list.append(body_betas)
    |> list.map(string.trim)
    |> list.filter(fn(b) { b != "" })
    |> list.unique
  let betas =
    beta_profile(
      betas,
      credential,
      operation,
      body,
      cache.has_one_hour,
      selected,
    )
  use identity_headers <- result.try(case identity {
    None -> Ok([])
    Some(Identity(session, request, _)) ->
      case
        session != ""
        && request != ""
        && safe_value(session)
        && safe_value(request)
      {
        True ->
          Ok([
            Header("X-Claude-Code-Session-Id", session),
            Header("x-client-request-id", request),
          ])
        False -> Error("Invalid Claude request identity")
      }
  })
  // Byte-preserve a native request when no semantic rewrite was needed.
  let encoded = case ir.parse(source) == Ok(body) {
    True -> source
    False -> ir.stringify(body)
  }
  let auth = case credential {
    ApiKey(key) -> Header("x-api-key", key)
    OAuth(token) -> Header("Authorization", "Bearer " <> token)
  }
  let accept = case operation {
    Messages(True) -> "text/event-stream"
    _ -> "application/json"
  }
  let headers = [
    Header("Host", host),
    auth,
    Header("Content-Type", "application/json"),
    Header("Accept", accept),
    Header("Accept-Encoding", "identity"),
    Header("anthropic-version", "2023-06-01"),
  ]
  let headers = case betas {
    [] -> headers
    _ ->
      list.append(headers, [Header("anthropic-beta", string.join(betas, ","))])
  }
  let headers =
    headers
    |> list.append(list.filter(caller_headers, allowed_caller_header))
    |> list.append(identity_headers)
    |> list.append([
      Header("Content-Length", int.to_string(string.byte_size(encoded))),
    ])
  let #(target, kind) = case operation {
    Messages(_) -> #("/v1/messages?beta=true", "messages")
    CountTokens -> #("/v1/messages/count_tokens?beta=true", "count_tokens")
  }
  Ok(Capture(
    "claude",
    "caller-owned",
    origin,
    kind,
    "POST",
    target,
    "HTTP/1.1",
    headers,
    encoded,
    Transport("http/1.1", None),
  ))
}

fn operation_body(
  body: ir.Value,
  operation: Operation,
) -> Result(ir.Value, String) {
  case operation {
    Messages(streaming) ->
      case ir.field(body, "stream") {
        None if !streaming -> Ok(body)
        None -> Ok(set(body, "stream", ir.Boolean(True)))
        Some(ir.Boolean(value)) if value == streaming -> Ok(body)
        _ -> Error("Claude stream body and transport mode disagree")
      }
    CountTokens ->
      case ir.field(body, "stream") {
        Some(ir.Boolean(True)) -> Error("Claude count_tokens cannot stream")
        Some(ir.Boolean(False)) | None ->
          Ok(
            ir.Object(
              ir.extras(body, [
                "stream", "max_tokens", "metadata", "context_management",
                "diagnostics",
              ]),
            ),
          )
        _ -> Error("Invalid Claude count_tokens stream field")
      }
  }
}

fn credential_is_oauth(credential: Credential) -> Bool {
  case credential {
    OAuth(_) -> True
    ApiKey(_) -> False
  }
}

fn beta_profile(
  requested: List(String),
  credential: Credential,
  operation: Operation,
  body: ir.Value,
  one_hour: Bool,
  selected: policy.Policy,
) -> List(String) {
  let base = case operation, selected.input, requested {
    CountTokens, policy.TranslatedMessages, _ | CountTokens, _, [] ->
      list.append(
        [
          code_beta, "interleaved-thinking-2025-05-14",
          "context-management-2025-06-27", "token-counting-2024-11-01",
        ],
        list.filter(requested, fn(beta) { !managed_beta(beta) }),
      )
    _, _, _ -> requested
  }
  let base = case credential {
    ApiKey(_) -> without(base, oauth_beta)
    OAuth(_) ->
      case list.contains(base, oauth_beta), base {
        True, _ -> base
        False, [first, ..rest] if first == code_beta -> [
          first,
          oauth_beta,
          ..rest
        ]
        False, _ -> [oauth_beta, ..base]
      }
  }
  let base = case operation {
    CountTokens ->
      append_beta(without(base, ttl_beta), "token-counting-2024-11-01")
    Messages(_) if one_hour -> append_beta(base, ttl_beta)
    _ -> base
  }
  let thinking = nested_string(body, "thinking", "type")
  let forced =
    list.contains(["any", "tool"], nested_string(body, "tool_choice", "type"))
  let model =
    ir.string_field(body, "model") |> result.unwrap("") |> policy.model
  let base = case
    thinking == "disabled"
    || forced
    || model == policy.Haiku
    || selected.turn == policy.Helper
  {
    True -> without(base, effort_beta)
    False -> base
  }
  let base = case
    thinking == "disabled" || forced || selected.turn == policy.Helper
  {
    True -> without(base, display_beta)
    False -> base
  }
  let base = case nested_string(body, "thinking", "display") {
    "" -> base
    _ -> without(base, redact_beta)
  }
  let base = case selected.turn, one_hour, operation {
    policy.Helper, _, _ | policy.Subagent, False, _ | _, _, CountTokens ->
      without(base, ttl_beta)
    _, _, _ -> base
  }
  let base = case operation, ir.string_field(body, "speed") {
    Messages(_), Ok("fast") -> append_beta(base, "fast-mode-2026-02-01")
    _, _ -> base
  }
  let advisor = "advisor-tool-2026-03-01"
  let tools = case ir.field(body, "tools") {
    Some(ir.Array(tools)) -> tools
    _ -> []
  }
  let needs_advisor =
    list.contains(requested, advisor)
    || list.any(tools, fn(tool) {
      ir.string_field(tool, "type")
      |> result.unwrap("")
      |> string.starts_with("advisor_")
    })
  case needs_advisor {
    True -> insert_advisor(without(base, advisor), advisor)
    False -> base
  }
}

/// CPA withClaudeAdvisorToolBeta: known trailer boundaries only. Unknown
/// betas retain order, and a correctly ordered helper profile stays unchanged.
fn insert_advisor(betas: List(String), advisor: String) -> List(String) {
  case betas {
    [] -> [advisor]
    [first, ..rest] ->
      case
        list.contains(
          [
            "advanced-tool-use-2025-11-20", effort_beta,
            "server-side-fallback-2026-06-01", "fallback-credit-2026-06-01",
            "structured-outputs-2025-12-15", "fast-mode-2026-02-01",
            "afk-mode-2026-01-31", ttl_beta, "cache-diagnosis-2026-04-07",
          ],
          first,
        )
      {
        True -> [advisor, ..betas]
        False -> [first, ..insert_advisor(rest, advisor)]
      }
  }
}

/// Managed names from CPA's pinned claudeManagedBetaSet, not an allowlist:
/// unknown betas remain caller-owned and keep their relative order.
pub fn managed_beta(beta: String) -> Bool {
  list.contains(
    [
      code_beta, oauth_beta, ttl_beta, effort_beta, display_beta, redact_beta,
      "token-counting-2024-11-01", "fast-mode-2026-02-01",
      "context-1m-2025-08-07", "mid-conversation-system-2026-04-07",
      "per-turn-control-2026-07-01", "timing-2026-09-09",
      "mid-conversation-tool-changes-2026-07-01", "inline-tools-2026-09-15",
      "mid-conversation-system-clear-at-2026-08-21",
      "dangerous-tool-use-2026-09-03", "advisor-tool-2026-03-01",
      "advanced-tool-use-2025-11-20", "server-side-fallback-2026-06-01",
      "fallback-credit-2026-06-01", "structured-outputs-2025-12-15",
      "thinking-binding-controls-2026-08-01", "thinking-resumption-2026-07-17",
      "prompt-caching-evict-2026-05-12", "cache-diagnosis-2026-04-07",
      "afk-mode-2026-01-31", "interleaved-thinking-2025-05-14",
      "thinking-token-count-2026-05-13", "context-management-2025-06-27",
      "prompt-caching-scope-2026-01-05",
    ],
    beta,
  )
}

fn append_beta(betas: List(String), beta: String) -> List(String) {
  case list.contains(betas, beta) {
    True -> betas
    False -> list.append(betas, [beta])
  }
}

fn without(betas: List(String), beta: String) -> List(String) {
  list.filter(betas, fn(value) { value != beta })
}

fn nested_string(value: ir.Value, key: String, nested: String) -> String {
  ir.required(value, key)
  |> result.try(fn(value) { ir.string_field(value, nested) })
  |> result.unwrap("")
}

fn remove(body: ir.Value, key: String) -> ir.Value {
  ir.Object(ir.extras(body, [key]))
}

fn set(body: ir.Value, key: String, value: ir.Value) -> ir.Value {
  ir.Object(list.append(ir.extras(body, [key]), [#(key, value)]))
}

fn safe_value(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn safe_name(name: String) -> Bool {
  let allowed =
    string.to_graphemes("abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
  name != ""
  && list.all(string.to_graphemes(string.lowercase(name)), fn(char) {
    list.contains(allowed, char)
  })
}

fn allowed_caller_header(header: Header) -> Bool {
  let name = string.lowercase(header.name)
  name != "anthropic-beta" && client_profile.allowed(name)
}

/// No URL path, query, userinfo, fragment or insecure non-loopback origin.
fn origin_host(origin: String) -> Result(String, String) {
  case uri.parse(origin) {
    Ok(uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      port: port,
      path: path,
      userinfo: None,
      query: None,
      fragment: None,
    ))
      if path == "" || path == "/"
    -> {
      let allowed =
        scheme == "https"
        || {
          scheme == "http"
          && list.contains(["127.0.0.1", "localhost", "::1"], host)
        }
      case allowed && safe_value(host) && host != "" {
        False -> Error("Claude origin must use HTTPS or loopback HTTP")
        True -> {
          let host = case string.contains(host, ":") {
            True -> "[" <> host <> "]"
            False -> host
          }
          case port {
            Some(port) if port > 0 && port <= 65_535 ->
              Ok(host <> ":" <> int.to_string(port))
            None -> Ok(host)
            _ -> Error("Invalid Claude origin port")
          }
        }
      }
    }
    _ -> Error("Claude requires a plain approved origin")
  }
}
