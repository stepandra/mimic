/// Native Kimi coding HTTP request planner. Runtime owns the selected account,
/// approved origin, refresh, HTTP transport, retries, and response codec.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/dialect/responses
import mimic/egress
import mimic/ir
import mimic/providers/contracts
import mimic/providers/kimi/messages
import mimic/providers/kimi/models
import mimic/providers/kimi/transform
import mimic/providers/transport
import mimic/types.{type Capture, type Header, Capture, Header, Transport}

pub fn http(ca_file: Option(String)) -> contracts.Adapter(egress.Stream) {
  transport.http(prepare, rejection, ca_file)
}

/// Resolve the base path from the account selected by runtime, not from a
/// gateway-wide/default account. The lookup must be operator-owned.
pub fn http_at(
  base_path: fn(contracts.Context) -> Result(String, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream) {
  transport.http(
    fn(context, request) {
      use path <- result.try(base_path(context))
      prepare_at(path, context, request)
    },
    rejection,
    ca_file,
  )
}

pub fn prepare(
  context: contracts.Context,
  request: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  prepare_at("/coding", context, request)
}

/// A path-only prefix, e.g. `/coding` (CPA native default), `""` (direct /v1),
/// or a configured operator-owned prefix. Never allow a second authority or
/// query/fragment; runtime's Context.origin remains the sole destination.
pub fn prepare_at(
  base_path: String,
  context: contracts.Context,
  request: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  use _ <- result.try(validate_base_path(base_path))
  use _ <- result.try(
    case
      context.provider == "kimi"
      && request.provider == "kimi"
      && context.auth_mode == request.auth_mode
      && context.account != ""
      && context.session_key != ""
      && request.session != ""
    {
      True -> Ok(Nil)
      False -> invalid()
    },
  )
  use host <- result.try(origin_host(context.origin))
  use token <- result.try(case context.auth_mode, context.credential {
    "api_key", contracts.ApiKey(token) -> valid_token(token)
    "oauth", contracts.OAuth(data) -> {
      use _ <- result.try(oauth_domain_matches(data, context.origin))
      valid_token(data.credential.access_token)
    }
    _, _ -> invalid()
  })
  use model <- result.try(
    models.upstream_id(request.model)
    |> option_to_result(contracts.Failure(
      contracts.Unsupported,
      contracts.NotSent,
      None,
    )),
  )
  use _ <- result.try(
    case
      list.any(request.required, fn(capability) {
        capability != contracts.Buffer
        && capability != contracts.Stream
        && capability != contracts.Tools
        && capability != contracts.Images
      })
      || request.pinned_account != None
    {
      True -> unsupported()
      False -> Ok(Nil)
    },
  )
  use body <- result.try(case request.protocol, request.operation {
    "responses", "responses" -> responses_body(request, model)
    "chat", "chat/completions" -> chat_body(request, model)
    "anthropic", "messages" ->
      case request.mode {
        contracts.Buffered ->
          messages.prepare(request.body, request.model, False)
          |> result.map_error(fn(_) {
            contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
          })
        contracts.Streaming -> unsupported()
      }
    _, _ -> unsupported()
  })
  let base_path = case string.ends_with(base_path, "/v1") {
    True -> string.drop_end(base_path, 3)
    False -> base_path
  }
  let target = case request.protocol {
    "responses" -> base_path <> "/v1/responses"
    "anthropic" -> base_path <> "/v1/messages?beta=true"
    _ -> base_path <> "/v1/chat/completions"
  }
  let accept = case request.mode {
    contracts.Buffered -> "application/json"
    contracts.Streaming -> "text/event-stream"
  }
  use device_headers <- result.try(case context.credential {
    contracts.OAuth(data) ->
      case
        list.filter(data.private_metadata, fn(pair) { pair.0 == "device_id" })
      {
        [#(_, device)] -> {
          use device <- result.try(valid_token(device))
          Ok([Header("X-Msh-Device-Id", device)])
        }
        _ -> invalid()
      }
    _ -> Ok([])
  })
  Ok(Capture(
    "mimic-kimi",
    "native-http",
    context.origin,
    request.operation,
    "POST",
    target,
    "HTTP/1.1",
    [
      Header("Host", host),
      Header("Authorization", "Bearer " <> token),
      Header("Content-Type", "application/json"),
      Header("Accept", accept),
      Header("Accept-Encoding", "identity"),
      Header("Content-Length", int.to_string(string.byte_size(body))),
      ..list.append(device_headers, case request.protocol {
        "anthropic" -> [Header("anthropic-version", "2023-06-01")]
        _ -> []
      })
    ],
    body,
    Transport("http/1.1", None),
  ))
}

fn validate_base_path(path: String) -> Result(Nil, contracts.Failure) {
  case
    { path == "" || string.starts_with(path, "/") }
    && !string.ends_with(path, "/")
    && !string.contains(path, "//")
    && !string.contains(path, "..")
    && !string.contains(path, "\\")
    && !string.contains(path, "?")
    && !string.contains(path, "#")
    && !string.contains(path, "%")
    && !string.contains(path, " ")
    && !string.contains(path, "\r")
    && !string.contains(path, "\n")
    && !string.contains(path, "\u{0000}")
  {
    True -> Ok(Nil)
    False -> invalid()
  }
}

fn responses_body(
  request: contracts.Request,
  model: String,
) -> Result(String, contracts.Failure) {
  use decoded <- result.try(
    responses.decode_request(request.body) |> as_invalid(),
  )
  use _ <- result.try(
    case
      decoded.model == request.model
      && decoded.stream == { request.mode == contracts.Streaming }
      && decoded.previous_response_id == None
    {
      True -> Ok(Nil)
      False -> invalid()
    },
  )
  let _ = model
  transform.request(
    request.body,
    request.model,
    "responses",
    request.mode == contracts.Streaming,
  )
  |> result.map_error(fn(_) {
    contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  })
}

fn chat_body(
  request: contracts.Request,
  model: String,
) -> Result(String, contracts.Failure) {
  use value <- result.try(ir.parse(request.body) |> as_invalid())
  use _ <- result.try(ir.as_object(value) |> as_invalid())
  use named <- result.try(ir.string_field(value, "model") |> as_invalid())
  use messages <- result.try(
    ir.required(value, "messages")
    |> result.try(ir.as_array)
    |> as_invalid(),
  )
  use stream <- result.try(
    ir.optional_bool(value, "stream", False) |> as_invalid(),
  )
  use _ <- result.try(
    case
      named == request.model
      && stream == { request.mode == contracts.Streaming }
      && messages != []
    {
      True -> Ok(Nil)
      False -> invalid()
    },
  )
  let _ = model
  transform.request(
    request.body,
    request.model,
    "chat",
    request.mode == contracts.Streaming,
  )
  |> result.map_error(fn(_) {
    contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  })
}

fn origin_host(origin: String) -> Result(String, contracts.Failure) {
  case uri.parse(origin) {
    Ok(uri.Uri(scheme, None, Some(host), port, path, None, None))
      if { path == "" || path == "/" }
      && {
        scheme == Some("https")
        || {
          scheme == Some("http")
          && {
            host == "127.0.0.1"
            || host == "localhost"
            || host == "[::1]"
            || host == "::1"
          }
        }
      }
    -> {
      let authority = case port {
        Some(p) if p > 0 && p <= 65_535 -> host <> ":" <> int.to_string(p)
        None -> host
        _ -> ""
      }
      case
        authority != ""
        && !string.contains(origin, "\\")
        && !string.contains(origin, "\r")
        && !string.contains(origin, "\n")
        && !string.contains(origin, " ")
      {
        True -> Ok(authority)
        False -> invalid()
      }
    }
    _ -> invalid()
  }
}

fn valid_token(token: String) -> Result(String, contracts.Failure) {
  case
    string.trim(token) != ""
    && !string.contains(token, "\r")
    && !string.contains(token, "\n")
    && !string.contains(token, "\u{0000}")
  {
    True -> Ok(token)
    False ->
      Error(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.NotSent,
        None,
      ))
  }
}

fn oauth_domain_matches(
  data: contracts.OAuthData,
  origin: String,
) -> Result(Nil, contracts.Failure) {
  use parsed <- result.try(uri.parse(origin) |> as_invalid())
  let host = parsed.host
  let domains =
    list.filter(data.private_metadata, fn(pair) { pair.0 == "domain" })
  case domains {
    [#(_, "kimi.ai")] if host != Some("api.kimi.com") -> Ok(Nil)
    [#(_, "kimi.com")] if host != Some("api.kimi.ai") -> Ok(Nil)
    _ -> invalid()
  }
}

/// Status alone cannot prove a quota request was not executed. No 429 replay.
pub fn rejection(
  status: Int,
  _headers: List(Header),
) -> Option(contracts.Failure) {
  case status {
    401 ->
      Some(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.Rejected,
        None,
      ))
    429 -> Some(contracts.Failure(contracts.Quota, contracts.Uncertain, None))
    _ -> None
  }
}

fn option_to_result(value: Option(a), error: e) -> Result(a, e) {
  case value {
    Some(value) -> Ok(value)
    None -> Error(error)
  }
}

fn as_invalid(value: Result(a, b)) -> Result(a, contracts.Failure) {
  result.map_error(value, fn(_) {
    contracts.Failure(contracts.InvalidConfiguration, contracts.NotSent, None)
  })
}

fn invalid() -> Result(a, contracts.Failure) {
  Error(contracts.Failure(
    contracts.InvalidConfiguration,
    contracts.NotSent,
    None,
  ))
}

fn unsupported() -> Result(a, contracts.Failure) {
  Error(contracts.Failure(contracts.Unsupported, contracts.NotSent, None))
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["help"] ->
      Ok(
        "kimi: native coding HTTP API key/OAuth; explicit account registration and approved endpoints required",
      )
    _ -> Error("Unsupported Kimi CLI command")
  }
}
