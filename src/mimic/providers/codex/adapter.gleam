/// Thin bridge to the separately owned provider runtime v1. No transport,
/// scheduler, fleet, or credential-store implementation lives here.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth/crypto
import mimic/egress
import mimic/ir
import mimic/providers/codex/errors
import mimic/providers/codex/json_guard
import mimic/providers/codex/lite
import mimic/providers/codex/models
import mimic/providers/codex/oauth
import mimic/providers/codex/request as codex_request
import mimic/providers/codex/routes
import mimic/providers/codex/session
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/transport
import mimic/types.{
  type Capture, type Header, type WireResponse, Capture, Header, Transport,
}

pub type Config {
  Config(
    tenant: String,
    user_agent: String,
    native: Bool,
    catalog: models.Catalog,
    continuation: Option(session.Continuation),
  )
}

pub fn http(
  config: Config,
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream) {
  http_planned(config, ca_file, fn(_, _) { Nil })
}

/// Gateway hook: retain plans privately per attempt, then select ONLY the plan
/// whose account equals runtime.Response.account. Never log this callback data.
pub fn http_planned(
  config: Config,
  ca_file: Option(String),
  remember: fn(String, codex_request.Prepared) -> Nil,
) -> contracts.Adapter(egress.Stream) {
  transport.http(
    fn(context, request) {
      use prepared <- result.try(prepare_native(config, context, request))
      use capture <- result.try(capture(context, request, prepared))
      remember(context.account, prepared)
      Ok(capture)
    },
    rejection,
    ca_file,
  )
}

pub fn prepare(
  config: Config,
  context: contracts.Context,
  req: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  use prepared <- result.try(prepare_native(config, context, req))
  capture(context, req, prepared)
}

/// Runtime-side composition hook after account selection. Keep the returned
/// secret-bearing plan ephemeral; its identity binds the HTTP response collector.
pub fn prepare_native(
  config: Config,
  context: contracts.Context,
  req: contracts.Request,
) -> Result(codex_request.Prepared, contracts.Failure) {
  use _ <- result.try(
    case
      context.provider == "codex"
      && req.provider == "codex"
      && context.auth_mode == "oauth"
      && req.auth_mode == "oauth"
      && req.protocol == "responses"
      && !list.contains(req.required, contracts.WebSocket)
      && context.origin != ""
      && context.session_key != ""
    {
      True -> Ok(Nil)
      False -> Error(unsupported())
    },
  )
  use operation <- result.try(case req.operation, req.mode {
    "responses", _ -> Ok(routes.Responses)
    "responses/lite", _ -> Ok(routes.Lite)
    "responses/compact", contracts.Buffered -> Ok(routes.Compact)
    _, _ -> Error(unsupported())
  })
  use data <- result.try(case context.credential {
    contracts.OAuth(data) -> Ok(data)
    _ ->
      Error(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.NotSent,
        None,
      ))
  })
  use account <- result.try(
    provider_account(data) |> result.map_error(fn(_) { unsupported() }),
  )
  use model <- result.try(
    models.lookup(config.catalog, req.model)
    |> result.map_error(fn(_) { unsupported() }),
  )
  use body <- result.try(
    json_guard.parse(req.body) |> result.map_error(fn(_) { unsupported() }),
  )
  use marked_lite <- result.try(
    lite.enabled(body) |> result.map_error(fn(_) { unsupported() }),
  )
  use _ <- result.try(
    lite.validate_modalities(body, model.input_modalities)
    |> result.map_error(fn(_) { unsupported() }),
  )
  use _ <- result.try(case ir.field(body, "previous_response_id") {
    None | Some(ir.Null) -> Ok(Nil)
    _ ->
      case req.pinned_account == Some(context.account) {
        True -> Ok(Nil)
        False -> Error(unsupported())
      }
  })
  let scope =
    session.Scope(
      config.tenant,
      context.account,
      account,
      req.model,
      // HTTP origin/mode remain separate from native WS identity. Authoritative
      // credential Revision is enforced by codex/http's shared-cache scope.
      crypto.pkce_challenge(
        "mimic:codex:http:v1:"
        <> ir.stringify(
          ir.Array([
            ir.String(context.origin),
            ir.String(context.session_key),
            ir.Boolean(marked_lite || operation == routes.Lite),
          ]),
        ),
      ),
    )
  codex_request.prepare(
    body,
    codex_request.Context(
      scope,
      data.credential.access_token,
      config.user_agent,
      None,
    ),
    routes.Route(operation, routes.Http, config.native),
    config.continuation,
    model.reasoning_efforts,
  )
  |> result.map_error(fn(_) { unsupported() })
}

pub fn capture(
  context: contracts.Context,
  req: contracts.Request,
  prepared: codex_request.Prepared,
) -> Result(Capture, contracts.Failure) {
  use origin <- result.try(
    uri.parse(context.origin) |> result.map_error(fn(_) { unsupported() }),
  )
  use host <- result.try(case origin.host {
    Some(host) -> Ok(host)
    None -> Error(unsupported())
  })
  let host = case string.contains(host, ":") && !string.starts_with(host, "[") {
    True -> "[" <> host <> "]"
    False -> host
  }
  let authority =
    host
    <> case origin.port {
      Some(port) -> ":" <> int.to_string(port)
      None -> ""
    }
  let body = ir.stringify(prepared.body)
  Ok(Capture(
    client: "codex",
    version: "unmeasured",
    endpoint: context.origin,
    request_kind: req.operation,
    method: "POST",
    target: prepared.target,
    http_version: "HTTP/1.1",
    headers: [
      Header("Host", authority),
      Header("Content-Length", int.to_string(string.byte_size(body))),
      Header("Connection", "close"),
      ..prepared.headers
    ],
    body: body,
    transport: Transport("http/1.1", None),
  ))
}

/// Buffered runtime calls return the upstream SSE bytes for /responses;
/// coordinator MUST use the common codec to assemble the client JSON result.
/// /responses/compact returns JSON, never regular Responses streaming.
pub fn registration(model: models.Model) -> Result(registry.Model, String) {
  let images = case list.contains(model.input_modalities, "image") {
    True -> [contracts.Images]
    False -> []
  }
  Ok(
    registry.Model(
      "codex",
      model.slug,
      ["oauth"],
      ["responses"],
      ["responses", "responses/compact", "responses/lite"],
      [
        contracts.Buffer,
        contracts.Stream,
        contracts.Tools,
        contracts.Continuation,
        ..images
      ],
    ),
  )
}

pub fn material(tokens: oauth.Tokens) -> contracts.OAuthData {
  contracts.OAuthData(tokens.credential, [
    #("chatgpt_account_id", tokens.account_id),
  ])
}

/// Transport injection is deliberate. Runtime owns TLS/origin approval/timeouts,
/// secret handling and token persistence, not this refresh callback.
/// With runtime v4, send may return RefreshRetryable ONLY with affirmative
/// no-send/non-execution proof. Generic timeouts must be RefreshUnavailable.
pub fn refresh(
  config: oauth.Config,
  send: fn(oauth.TokenRequest) -> Result(WireResponse, contracts.RefreshFailure),
) -> contracts.Refresh {
  contracts.Refresh(fn(old, now_ms) {
    use account <- result.try(
      provider_account(old)
      |> result.map_error(fn(_) { contracts.InvalidGrant }),
    )
    use plan <- result.try(
      oauth.refresh_request(config, old.credential.refresh_token)
      |> result.map_error(fn(_) { contracts.RefreshUnsupported }),
    )
    use response <- result.try(send(plan))
    case refresh_rate_limit(response, now_ms) {
      Some(failure) -> Error(failure)
      None ->
        oauth.decode_tokens(
          response.status,
          response.body,
          Some(oauth.Tokens(old.credential, account)),
          now_ms,
        )
        |> result.map(material)
        |> result.map_error(fn(failure) {
          case failure {
            oauth.InvalidGrant -> contracts.InvalidGrant
            oauth.Unavailable -> contracts.RefreshUnavailable
            // A malformed success can hide rotation; retain the v4 recovery fence.
            oauth.InvalidResponse -> contracts.RefreshUnavailable
          }
        })
    }
  })
}

/// Recognized structured rejection, never merely a 429 status or rate-looking
/// HTTP 200. Synthetic contract coverage is not live OAuth acceptance evidence.
fn refresh_rate_limit(
  response: WireResponse,
  now_ms: Int,
) -> Option(contracts.RefreshFailure) {
  let recognized = case json_guard.parse(response.body) {
    Ok(root) ->
      case ir.field(root, "error") {
        Some(error) -> {
          let unambiguous = case
            ir.field(error, "code"),
            ir.field(error, "type")
          {
            Some(ir.String("rate_limit_exceeded")), None
            | Some(ir.String("rate_limit_exceeded")),
              Some(ir.String("rate_limit_error"))
            | None, Some(ir.String("rate_limit_error"))
            -> True
            _, _ -> False
          }
          unambiguous
          && list.all(
            [
              "access_token",
              "refresh_token",
              "id_token",
              "token_type",
              "expires_in",
            ],
            fn(field) { ir.field(root, field) == None },
          )
        }
        None -> False
      }
    Error(_) -> False
  }
  case response.status == 429 && recognized {
    False -> None
    True -> {
      let headers =
        list.filter(response.headers, fn(header) {
          string.lowercase(header.name) == "retry-after"
        })
      case headers {
        [] -> Some(contracts.RefreshRateLimited(0))
        [_] ->
          case
            errors.classify(429, response.headers, "", now_ms).retry_after_ms
          {
            Some(delay) -> Some(contracts.RefreshRateLimited(delay))
            None -> Some(contracts.RefreshUnavailable)
          }
        _ -> Some(contracts.RefreshUnavailable)
      }
    }
  }
}

fn provider_account(data: contracts.OAuthData) -> Result(String, String) {
  case
    list.filter(data.private_metadata, fn(pair) {
      pair.0 == "chatgpt_account_id"
    })
  {
    [#(_, account)] ->
      case oauth.safe_header(account) {
        True -> Ok(account)
        False -> Error("invalid private Codex account hint")
      }
    _ -> Error("missing or duplicate private Codex account hint")
  }
}

/// Header-only hook cannot inspect a response body before the runtime commits
/// output. Other categories remain terminal to this HTTP adapter.
pub fn rejection(
  status: Int,
  headers: List(Header),
) -> Option(contracts.Failure) {
  case status {
    401 ->
      Some(contracts.Failure(
        contracts.CredentialUnavailable,
        contracts.Rejected,
        None,
      ))
    429 -> {
      let classification = errors.classify(status, headers, "", now_ms())
      Some(contracts.Failure(
        contracts.Quota,
        contracts.Rejected,
        classification.retry_after_ms,
      ))
    }
    _ -> None
  }
}

fn unsupported() -> contracts.Failure {
  contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
}

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
