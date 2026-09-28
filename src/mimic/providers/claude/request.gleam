/// Caller-owned native JSON profile. This does not synthesize a CLI fingerprint.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/ir
import mimic/providers/claude/cache
import mimic/providers/claude/identity as account_identity
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
  let body = compatibility(body)
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
    beta_profile(betas, credential, operation, body, cache.has_one_hour)
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

fn compatibility(body: ir.Value) -> ir.Value {
  let choice = nested_string(body, "tool_choice", "type")
  let body = case choice {
    "any" | "tool" -> {
      let body = remove(body, "thinking")
      case ir.field(body, "output_config") {
        Some(ir.Object(fields)) ->
          case list.filter(fields, fn(f) { f.0 != "effort" }) {
            [] -> remove(body, "output_config")
            fields -> set(body, "output_config", ir.Object(fields))
          }
        _ -> body
      }
    }
    _ -> body
  }
  let thinking = nested_string(body, "thinking", "type")
  case thinking {
    "enabled" | "adaptive" | "auto" -> {
      let body = remove(body, "top_k")
      let body = case ir.field(body, "temperature") {
        None | Some(ir.Integer(1)) | Some(ir.Decimal(1.0)) -> body
        _ -> remove(body, "temperature")
      }
      case ir.field(body, "top_p") {
        Some(ir.Decimal(value)) if value <. 0.95 -> remove(body, "top_p")
        Some(ir.Integer(value)) if value < 1 -> remove(body, "top_p")
        _ -> body
      }
    }
    _ ->
      case ir.field(body, "temperature") {
        None -> body
        Some(_) -> remove(body, "top_p")
      }
  }
}

fn beta_profile(
  requested: List(String),
  credential: Credential,
  operation: Operation,
  body: ir.Value,
  one_hour: Bool,
) -> List(String) {
  let base = case operation, requested {
    CountTokens, [] -> [
      code_beta, "interleaved-thinking-2025-05-14",
      "context-management-2025-06-27", "token-counting-2024-11-01",
    ]
    _, _ -> requested
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
    ir.string_field(body, "model") |> result.unwrap("") |> string.lowercase
  let base = case
    thinking == "disabled" || forced || string.contains(model, "haiku")
  {
    True -> without(base, effort_beta)
    False -> base
  }
  let base = case thinking == "disabled" || forced {
    True -> without(base, display_beta)
    False -> base
  }
  let base = case nested_string(body, "thinking", "display") {
    "" -> base
    _ -> without(base, redact_beta)
  }
  case ir.string_field(body, "speed") {
    Ok("fast") -> append_beta(base, "fast-mode-2026-02-01")
    _ -> base
  }
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
  name == "user-agent"
  || name == "x-app"
  || string.starts_with(name, "x-stainless-")
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
