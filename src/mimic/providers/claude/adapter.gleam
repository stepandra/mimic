/// Claude protocol bridge; the shared runtime alone owns credentials and leases.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/auth
import mimic/auth/crypto
import mimic/auth/runtime_store
import mimic/ir
import mimic/providers/claude/client_profile
import mimic/providers/claude/identity
import mimic/providers/claude/json_guard
import mimic/providers/claude/oauth
import mimic/providers/claude/policy
import mimic/providers/claude/request
import mimic/providers/contracts
import mimic/types.{type Capture, type Header}

pub fn prepare(
  context: contracts.Context,
  req: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  prepare_with_policy(context, req, policy.native(), client_profile.none())
}

/// Bind this closure to the shared runtime's existing Prepare callback.
/// Policy/profile must come from trusted routing, not incoming auth/UA headers.
pub fn prepare_with_policy(
  context: contracts.Context,
  req: contracts.Request,
  selected: policy.Policy,
  profile: client_profile.Approved,
) -> Result(Capture, contracts.Failure) {
  let prepared = {
    use _ <- result.try(
      case
        context.provider == "claude"
        && req.provider == "claude"
        && req.auth_mode == context.auth_mode
      {
        True -> Ok(Nil)
        False -> Error("Claude runtime context mismatch")
      },
    )
    use body <- result.try(json_guard.parse_native(req.body, 8_388_608))
    use model <- result.try(ir.string_field(body, "model"))
    use _ <- result.try(case model == req.model {
      True -> Ok(Nil)
      False -> Error("Claude selected model and body disagree")
    })
    use approved_headers <- result.try(client_profile.for_context(
      profile,
      context,
    ))
    use material <- result.try(case context.credential, context.auth_mode {
      contracts.ApiKey(token), "api_key" -> Ok(#(request.ApiKey(token), None))
      contracts.OAuth(data), "oauth" -> {
        use account <- result.try(account_identity(data.private_metadata))
        Ok(#(request.OAuth(data.credential.access_token), Some(account)))
      }
      _, _ -> Error("unsupported Claude credential")
    })
    use operation <- result.try(case req.operation, req.mode {
      "messages", contracts.Streaming -> Ok(request.Messages(True))
      "messages", contracts.Buffered -> Ok(request.Messages(False))
      "messages/count_tokens", contracts.Buffered -> Ok(request.CountTokens)
      _, _ -> Error("unsupported Claude operation")
    })
    request.prepare_with_policy(
      context.origin,
      material.0,
      operation,
      approved_headers,
      Some(request.Identity(
        context.session_key,
        crypto.random_url_token(),
        material.1,
      )),
      req.body,
      selected,
    )
  }
  prepared
  |> result.map_error(fn(_) {
    contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  })
}

pub fn account_identity(
  metadata: List(#(String, String)),
) -> Result(identity.Account, String) {
  use device <- result.try(
    list.key_find(metadata, "device_id")
    |> result.replace_error("missing Claude device identity"),
  )
  use account <- result.try(
    list.key_find(metadata, "account_uuid")
    |> result.replace_error("missing Claude account identity"),
  )
  let account = identity.Account(device, account)
  use _ <- result.try(identity.validate(account))
  Ok(account)
}

/// Private import never infers expiry/account/device identity from a token.
pub fn import_oauth(body: ir.Value) -> Result(contracts.AuthMaterial, String) {
  use access <- result.try(ir.string_field(body, "access_token"))
  use refresh <- result.try(ir.string_field(body, "refresh_token"))
  use expires <- result.try(
    ir.required(body, "expires_at_ms") |> result.try(ir.as_int),
  )
  use device <- result.try(ir.string_field(body, "device_id"))
  use account <- result.try(ir.string_field(body, "account_uuid"))
  use organization <- result.try(ir.optional_string(body, "organization_uuid"))
  let metadata =
    [#("device_id", device), #("account_uuid", account)]
    |> put("organization_uuid", organization)
  use _ <- result.try(account_identity(metadata))
  case
    access != ""
    && refresh != ""
    && expires > 0
    && runtime_store.valid_timestamp(expires)
  {
    True ->
      Ok(
        contracts.OAuth(contracts.OAuthData(
          auth.Credential(access, refresh, expires),
          metadata,
        )),
      )
    False -> Error("invalid Claude grant")
  }
}

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
    429 ->
      Some(contracts.Failure(
        contracts.Quota,
        contracts.Rejected,
        Some(oauth.retry_after(headers)),
      ))
    _ -> None
  }
}

/// Preserve all private metadata and v4 uncertainty semantics. Parsing raw JSON
/// (including escaped duplicate keys) precedes any retry-safe classification.
pub fn refresher(
  config: auth.Config,
  send: fn(oauth.TokenRequest) -> Result(oauth.TokenResponse, String),
) -> contracts.Refresh {
  contracts.Refresh(fn(data, now) {
    let previous =
      oauth.Tokens(
        data.credential,
        oauth.Identity(
          field(data.private_metadata, "account_uuid"),
          field(data.private_metadata, "organization_uuid"),
        ),
      )
    oauth.refresh(config, previous, now, send)
    |> result.map(fn(tokens) {
      contracts.OAuthData(
        tokens.credential,
        data.private_metadata
          |> put("account_uuid", tokens.identity.account_uuid)
          |> put("organization_uuid", tokens.identity.organization_uuid),
      )
    })
    |> result.map_error(fn(failure) {
      case failure {
        oauth.RateLimited(ms) -> contracts.RefreshRateLimited(ms)
        oauth.InvalidGrant | oauth.IdentityChanged -> contracts.InvalidGrant
        oauth.Unavailable | oauth.InvalidResponse ->
          contracts.RefreshUnavailable
        oauth.InvalidCallback -> contracts.RefreshUnsupported
      }
    })
  })
}

fn field(metadata: List(#(String, String)), key: String) -> Option(String) {
  list.key_find(metadata, key) |> result.map(Some) |> result.unwrap(None)
}

fn put(
  metadata: List(#(String, String)),
  key: String,
  value: Option(String),
) -> List(#(String, String)) {
  case value {
    None -> metadata
    Some(value) -> [
      #(key, value),
      ..list.filter(metadata, fn(item) { item.0 != key })
    ]
  }
}
