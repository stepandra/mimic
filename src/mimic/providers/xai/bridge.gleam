import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/dialect/responses
import mimic/ir
import mimic/providers/contracts as runtime
import mimic/providers/xai/endpoint
import mimic/providers/xai/http_continuation
import mimic/providers/xai/json_guard
import mimic/providers/xai/oauth
import mimic/providers/xai/request as xai_request
import mimic/providers/xai/tools
import mimic/types

pub type Prepared {
  Prepared(capture: types.Capture, tool_refs: List(tools.Ref))
}

/// Exact runtime transport.http prepare hook. Caller must use the shared
/// Responses decoder/event wrapper, not forward transformed tool names raw.
pub fn prepare(
  config: endpoint.Config,
  context: runtime.Context,
  req: runtime.Request,
) -> Result(types.Capture, runtime.Failure) {
  use plan <- result.try(prepare_plan(config, context, req))
  // Legacy raw transport callers cannot restore client names. The native
  // adapter uses prepare_plan and keeps refs on its selected response handle.
  case plan.tool_refs {
    [] -> Ok(plan.capture)
    _ -> Error(runtime.Failure(runtime.Unsupported, runtime.NotSent, None))
  }
}

pub fn prepare_plan(
  config: endpoint.Config,
  context: runtime.Context,
  req: runtime.Request,
) -> Result(Prepared, runtime.Failure) {
  let mode = case config.mode {
    endpoint.ApiKey -> "api_key"
    endpoint.DeviceOAuth -> "oauth"
  }
  use _ <- result.try(
    case
      context.provider == "xai"
      && req.provider == "xai"
      && context.auth_mode == mode
      && req.auth_mode == mode
      && context.session_key != ""
      && req.session != ""
    {
      True -> Ok(Nil)
      False -> invalid()
    },
  )
  use operation <- result.try(case req.protocol, req.operation {
    "responses", "responses" -> Ok(endpoint.Responses)
    "responses", "responses/compact" if req.mode == runtime.Buffered ->
      Ok(endpoint.Compact)
    _, _ -> Error(runtime.Failure(runtime.Unsupported, runtime.NotSent, None))
  })
  use _ <- result.try(
    case
      list.any(req.required, fn(capability) {
        capability != runtime.Buffer
        && capability != runtime.Stream
        && capability != runtime.Tools
      })
    {
      True -> Error(runtime.Failure(runtime.Unsupported, runtime.NotSent, None))
      False -> Ok(Nil)
    },
  )
  use plan <- result.try(endpoint.select(config, operation) |> sanitized)
  use url <- result.try(uri.parse(plan.url) |> sanitized)
  // Runtime account origins are exact scheme://authority, without base paths.
  let origin =
    uri.to_string(uri.Uri(..url, path: "", query: None, fragment: None))
  use _ <- result.try(case origin == context.origin {
    True -> Ok(Nil)
    False -> invalid()
  })
  use token <- result.try(case config.mode, context.credential {
    endpoint.ApiKey, runtime.ApiKey(token) -> valid_token(token)
    endpoint.DeviceOAuth, runtime.OAuth(data) ->
      valid_token(data.credential.access_token)
    _, _ -> invalid()
  })
  use document <- result.try(json_guard.parse(req.body) |> sanitized)
  use _ <- result.try(ir.as_object(document) |> sanitized)
  use _ <- result.try(
    http_continuation.validate(document)
    |> result.replace_error(runtime.Failure(
      runtime.Unsupported,
      runtime.NotSent,
      None,
    )),
  )
  use decoded <- result.try(case operation {
    endpoint.Compact -> responses.decode_compact_request(req.body) |> sanitized
    _ -> responses.decode_request(req.body) |> sanitized
  })
  use _ <- result.try(
    case
      decoded.model == req.model
      && decoded.stream == { req.mode == runtime.Streaming }
    {
      True -> Ok(Nil)
      False -> invalid()
    },
  )
  // HTTP state is explicitly unsupported, not dropped or recovered from a WS
  // receipt. Stateless history must be fully paired within this request.
  use _ <- result.try(responses.pair_input(decoded, []) |> sanitized)
  use _ <- result.try(case operation {
    endpoint.Compact ->
      case
        list.any(
          [
            "tools",
            "tool_choice",
            "max_output_tokens",
            "temperature",
            "top_p",
            "top_k",
          ],
          fn(key) { ir.field(decoded.document, key) != None },
        )
      {
        True ->
          Error(runtime.Failure(runtime.Unsupported, runtime.NotSent, None))
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    case
      ir.field(decoded.document, "prompt_cache_retention") == None
      && ir.field(decoded.document, "safety_identifier") == None
      && ir.field(decoded.document, "stream_options") == None
      && ir.field(decoded.document, "stop") == None
    {
      True -> Ok(Nil)
      False ->
        Error(runtime.Failure(runtime.Unsupported, runtime.NotSent, None))
    },
  )
  use prepared <- result.try(
    xai_request.prepare(
      config,
      operation,
      decoded.document,
      context.session_key,
    )
    |> sanitized,
  )
  use headers <- result.try(
    endpoint.headers(plan, context.session_key) |> sanitized,
  )
  let host =
    uri.to_string(
      uri.Uri(..url, scheme: None, path: "", query: None, fragment: None),
    )
  let host = string.drop_start(host, 2)
  let body = ir.stringify(prepared.body)
  let capture =
    types.Capture(
      client: "mimic-xai",
      version: "1",
      endpoint: origin,
      request_kind: req.operation,
      method: "POST",
      target: url.path,
      http_version: "HTTP/1.1",
      headers: list.append(
        [
          types.Header("Host", host),
          types.Header("Authorization", "Bearer " <> token),
          types.Header(
            "Content-Length",
            int.to_string(bit_array.byte_size(bit_array.from_string(body))),
          ),
        ],
        headers,
      ),
      body: body,
      transport: types.Transport("http/1.1", None),
    )
  Ok(Prepared(capture, prepared.tool_refs))
}

fn invalid() {
  Error(runtime.Failure(runtime.InvalidConfiguration, runtime.NotSent, None))
}

fn sanitized(value) {
  value
  |> result.map_error(fn(_) {
    runtime.Failure(runtime.InvalidConfiguration, runtime.NotSent, None)
  })
}

fn valid_token(token) {
  case
    string.trim(token) == ""
    || string.contains(token, "\r")
    || string.contains(token, "\n")
    || string.contains(token, "\u{0000}")
  {
    True -> invalid()
    False -> Ok(token)
  }
}

/// Return to runtime_store.save before account activation. No identity is
/// inferred from unverified JWT claims; only the approved refresh endpoint is
/// persisted as private metadata.
pub fn oauth_material(
  config: oauth.Config,
  discovery: oauth.Discovery,
  credential: auth.Credential,
) -> Result(runtime.AuthMaterial, String) {
  use _ <- result.try(oauth.validate_endpoint(
    discovery.token_endpoint,
    config.policy,
  ))
  Ok(
    runtime.OAuth(
      runtime.OAuthData(credential, [
        #("token_endpoint", discovery.token_endpoint),
      ]),
    ),
  )
}

pub fn refresher(config: oauth.Config, send: oauth.Send) -> runtime.Refresh {
  runtime.Refresh(fn(data, now_ms) {
    let endpoints =
      list.filter(data.private_metadata, fn(pair) { pair.0 == "token_endpoint" })
    case endpoints {
      [#(_, token_endpoint)] ->
        case
          oauth.refresh_outcome(
            config,
            token_endpoint,
            data.credential,
            send,
            now_ms,
          )
        {
          Ok(credential) ->
            Ok(runtime.OAuthData(..data, credential: credential))
          Error(oauth.InvalidGrant) -> Error(runtime.InvalidGrant)
          Error(oauth.RateLimited(delay)) ->
            Error(runtime.RefreshRateLimited(delay))
          Error(oauth.Unavailable) -> Error(runtime.RefreshUnavailable)
        }
      _ -> Error(runtime.RefreshUnavailable)
    }
  })
}

/// Gateway registration uses the one runtime refresh worker and durable fence.
/// API keys remain StaticKey; enrollment persists oauth_material before activation.
pub fn oauth_policy(
  config: oauth.Config,
  send: oauth.Send,
) -> credentials.Policy {
  credentials.Refreshable(refresher(config, send))
}

/// A bare 429 does not prove the request was not executed. Observe cooldown
/// but prohibit automatic replay. A bare 401 is not affirmative execution proof.
pub fn rejection(
  status: Int,
  _headers: List(types.Header),
) -> Option(runtime.Failure) {
  case status {
    429 -> Some(runtime.Failure(runtime.Quota, runtime.Uncertain, None))
    401 ->
      Some(runtime.Failure(
        runtime.CredentialUnavailable,
        runtime.Uncertain,
        None,
      ))
    _ -> None
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["help"] ->
      Ok(
        "xai: explicit API-key or Grok Build device OAuth; native HTTP/SSE and opt-in WS adapters; operator/runtime registration required; no browser-account or media support",
      )
    _ -> Error("Unsupported xAI CLI command")
  }
}
