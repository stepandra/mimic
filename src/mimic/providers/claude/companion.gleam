/// Opt-in OAuth control-plane observations. No storage, telemetry, retries,
/// device generation, entitlements, Axios UA or transport impersonation.
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/ir
import mimic/providers/claude/identity
import mimic/providers/claude/json_guard
import mimic/providers/claude/oauth
import mimic/providers/contracts
import mimic/replay
import mimic/types.{type Header, Capture, Header, Transport}

/// Constructible only from two explicit endpoints plus affirmative approval.
pub opaque type Approved {
  Approved(profile: Endpoint, roles: Endpoint)
}

type Endpoint {
  Endpoint(url: String, origin: String, authority: String, path: String)
}

pub type Request {
  Request(url: String, headers: List(Header))
}

/// Both fields are private, ephemeral data, never diagnostics. Roles remain the
/// original guarded JSON bytes, with no entitlement interpretation/persistence.
pub type Observations {
  Observations(profile: Option(oauth.Identity), roles_json: Option(String))
}

/// Device identity is operator-observed only; account/org may be filled by
/// token/profile. Construction validates even before enrollment/I/O begins.
pub opaque type Operator {
  Operator(device_id: String, identity: oauth.Identity)
}

pub fn approve(
  profile_url: String,
  roles_url: String,
  approved: Bool,
) -> Result(Approved, String) {
  use _ <- result.try(case approved {
    True -> Ok(Nil)
    False -> Error("Claude companion activity not approved")
  })
  use profile <- result.try(endpoint(profile_url))
  use roles <- result.try(endpoint(roles_url))
  Ok(Approved(profile, roles))
}

fn endpoint(url: String) -> Result(Endpoint, String) {
  let invalid = "Invalid Claude companion endpoint"
  use parsed <- result.try(uri.parse(url) |> result.replace_error(invalid))
  use host <- result.try(case parsed.host {
    Some(host) if host != "" -> Ok(host)
    _ -> Error(invalid)
  })
  use _ <- result.try(
    case
      oauth.valid_private_string(url)
      && string.byte_size(url) <= 4096
      && parsed.userinfo == None
      && parsed.query == None
      && parsed.fragment == None
      && string.starts_with(parsed.path, "/")
      && parsed.path != "/"
      && !string.contains(url, "\\")
      && !string.contains(url, " ")
      && !string.contains(url, "%")
      && !string.contains(host, ":")
      && {
        parsed.scheme == Some("https")
        || parsed.scheme == Some("http")
        && { host == "127.0.0.1" || host == "localhost" }
      }
      && case parsed.port {
        None -> True
        Some(port) -> port > 0 && port < 65_536
      }
    {
      True -> Ok(Nil)
      False -> Error(invalid)
    },
  )
  let authority =
    host
    <> case parsed.port {
      None -> ""
      Some(port) -> ":" <> int.to_string(port)
    }
  let origin =
    case parsed.scheme {
      Some("https") -> "https://"
      _ -> "http://"
    }
    <> authority
  use _ <- result.try(case url == origin <> parsed.path {
    True -> Ok(Nil)
    False -> Error(invalid)
  })
  Ok(Endpoint(url, origin, authority, parsed.path))
}

pub fn operator(value: ir.Value) -> Result(Operator, String) {
  let invalid = "Invalid Claude operator identity"
  // Preserve duplicate-key validation even for callers supplying a Value
  // directly rather than entering through the root's raw JSON gate.
  use value <- result.try(
    json_guard.parse(ir.stringify(value)) |> result.replace_error(invalid),
  )
  use device <- result.try(
    ir.string_field(value, "device_id") |> result.replace_error(invalid),
  )
  use account <- result.try(
    ir.optional_string(value, "account_uuid") |> result.replace_error(invalid),
  )
  use org <- result.try(
    ir.optional_string(value, "organization_uuid")
    |> result.replace_error(invalid),
  )
  use _ <- result.try(
    case
      string.length(device) == 64
      && list.all(string.to_graphemes(device), fn(c) {
        string.contains("0123456789abcdef", c)
      })
      && list.all([account, org], fn(value) {
        case value {
          None -> True
          Some(value) -> oauth.valid_private_string(value)
        }
      })
    {
      True -> Ok(Nil)
      False -> Error(invalid)
    },
  )
  Ok(Operator(device, oauth.Identity(account, org)))
}

pub fn parse_profile(
  response: oauth.TokenResponse,
) -> Result(oauth.Identity, String) {
  let parsed = {
    use _ <- result.try(success(response.status))
    use body <- result.try(oauth.response_json(response))
    use _ <- result.try(
      ir.as_object(body) |> result.replace_error(oauth.InvalidResponse),
    )
    use observed <- result.try(oauth.observed_identity(body))
    case observed.account_uuid, ir.field(body, "error") {
      Some(_), None -> Ok(observed)
      _, _ -> Error(oauth.InvalidResponse)
    }
  }
  parsed |> result.replace_error("Claude profile unavailable")
}

pub fn parse_roles(response: oauth.TokenResponse) -> Result(String, String) {
  let parsed = {
    use _ <- result.try(success(response.status))
    use _ <- result.try(oauth.response_json(response))
    Ok(response.body)
  }
  parsed |> result.replace_error("Claude roles unavailable")
}

fn success(status: Int) {
  case status >= 200 && status < 300 {
    True -> Ok(Nil)
    False -> Error(oauth.Unavailable)
  }
}

/// Profile then roles, once each, even when profile fails. Only validated
/// successes become observations; arbitrary transport errors are discarded.
pub fn inspect(
  approved: Approved,
  access_token: String,
  send: fn(Request) -> Result(oauth.TokenResponse, String),
) -> Result(Observations, String) {
  use _ <- result.try(case oauth.valid_private_string(access_token) {
    True -> Ok(Nil)
    False -> Error("Invalid Claude companion credential")
  })
  let profile =
    send(plan(approved.profile, access_token))
    |> result.try(parse_profile)
    |> result.map(Some)
    |> result.unwrap(None)
  let roles =
    send(plan(approved.roles, access_token))
    |> result.try(parse_roles)
    |> result.map(Some)
    |> result.unwrap(None)
  Ok(Observations(profile, roles))
}

fn plan(endpoint: Endpoint, token: String) -> Request {
  Request(endpoint.url, [
    Header("Accept", "application/json"),
    Header("Content-Type", "application/json"),
    Header("Authorization", "Bearer " <> token),
    Header("Cache-Control", "no-cache"),
    Header("Accept-Encoding", "identity"),
  ])
}

/// Reuse the shared direct HTTP/1.1 replay transport. It verifies TLS, rejects
/// unsupported framing/encoding and never follows redirects or retries.
/// The in-memory Capture is never recorded; credentials stay transport-private.
pub fn send(request: Request) -> Result(oauth.TokenResponse, String) {
  let sent = {
    use endpoint <- result.try(endpoint(request.url))
    let capture =
      Capture(
        "claude-companion",
        "unmeasured",
        endpoint.origin,
        "oauth-companion",
        "GET",
        endpoint.path,
        "HTTP/1.1",
        [
          Header("Host", endpoint.authority),
          Header("Connection", "close"),
          ..request.headers
        ],
        "",
        Transport("http/1.1", None),
      )
    replay.send(endpoint.origin, capture)
  }
  sent
  |> result.map(fn(response) {
    oauth.TokenResponse(response.status, response.headers, response.body)
  })
  |> result.replace_error("Claude companion transport unavailable")
}

/// Source identity precedence fills gaps only: conflict is fatal, not advisory.
/// Roles never participate. Only minimal validated identity metadata is stored.
pub fn reconcile(
  operator: Operator,
  tokens: oauth.Tokens,
  profile: Option(oauth.Identity),
) -> Result(contracts.AuthMaterial, String) {
  let observations = case profile {
    None -> [operator.identity, tokens.identity]
    Some(profile) -> [operator.identity, tokens.identity, profile]
  }
  use observed <- result.try(
    oauth.reconcile_identity(observations)
    |> result.replace_error("Claude OAuth identity mismatch"),
  )
  use account <- result.try(case observed.account_uuid {
    None -> Error("Claude OAuth account identity required")
    Some(value) -> Ok(value)
  })
  use _ <- result.try(
    identity.validate(identity.Account(operator.device_id, account))
    |> result.replace_error("Invalid Claude operator identity"),
  )
  let metadata = [
    #("device_id", operator.device_id),
    #("account_uuid", account),
  ]
  let metadata = case observed.organization_uuid {
    None -> metadata
    Some(org) -> list.append(metadata, [#("organization_uuid", org)])
  }
  Ok(contracts.OAuth(contracts.OAuthData(tokens.credential, metadata)))
}
