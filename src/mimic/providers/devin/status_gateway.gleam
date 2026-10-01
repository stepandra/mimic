/// F28 private unary status. Scope is operator configuration; credentials,
/// leases, socket ownership and HTTP framing remain shared runtime concerns.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth/runtime as credentials
import mimic/egress
import mimic/fleet
import mimic/providers/contracts as c
import mimic/providers/devin/identity
import mimic/providers/devin/status
import mimic/providers/devin/status_observation as observation
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/transport
import mimic/types.{type Header, Header}

pub const max_duration_ms = 30_000

pub opaque type Scope {
  Scope(account: String, origin: String, model: String)
}

pub opaque type Client {
  Client(account: String, stream: runtime.Stream, deadline_ms: Int)
}

/// Preserve HTTP codes without reflecting any provider reason/body/header.
pub type Failure {
  RuntimeFailure(c.Failure)
  HttpFailure(status: Int)
  InvalidObservation
  DeadlineExceeded
}

/// One configured model ID is only the shared model-indexed registry's lease
/// eligibility key. It is never serialized in the unary status request.
pub fn scope(account: runtime.Account) -> Result(Scope, String) {
  use _ <- result.try(
    case
      account.provider == "devin"
      && account.auth_mode == "session_token"
      && account.auth_policy == credentials.StaticSession
      && account.egress == fleet.LocalLoopback
      && account.id != ""
      && string.byte_size(account.id) <= 256
      && !string.contains(account.id, "\r")
      && !string.contains(account.id, "\n")
      && !string.contains(account.id, "\u{0000}")
    {
      True -> Ok(Nil)
      False -> Error("Configured Devin permanent-session account required")
    },
  )
  use model <- result.try(
    list.first(account.models)
    |> result.replace_error("Configured Devin model eligibility required"),
  )
  use _ <- result.try(case model != "" {
    True -> Ok(Nil)
    False -> Error("Configured Devin model eligibility required")
  })
  use parsed <- result.try(
    uri.parse(account.origin)
    |> result.replace_error("Invalid Devin status origin"),
  )
  use _ <- result.try(case parsed {
    uri.Uri(
      scheme: Some("http"),
      host: Some("127.0.0.1"),
      path: "",
      userinfo: None,
      query: None,
      fragment: None,
      port: port,
    ) ->
      case port {
        None -> Ok(Nil)
        Some(port) if port > 0 && port < 65_536 -> Ok(Nil)
        _ -> Error("Invalid Devin status origin")
      }
    _ -> Error("Devin status requires configured numeric loopback HTTP")
  })
  Ok(Scope(account.id, account.origin, model))
}

/// PRIVATE operator registry only; never put this row in public /v1/models.
pub fn registration(scope: Scope) -> registry.Model {
  registry.Model(
    "devin",
    scope.model,
    ["session_token"],
    ["devin-status"],
    ["status"],
    [c.Buffer],
  )
}

pub fn request(scope: Scope) -> c.Request {
  c.Request(
    "devin",
    "session_token",
    scope.model,
    "devin-status",
    "status",
    c.Buffered,
    [c.Buffer],
    identity.uuid(),
    Some(scope.account),
    "",
  )
}

pub fn open(engine: runtime.Runtime, scope: Scope) -> Result(Client, Failure) {
  open_with_budget(engine, scope, max_duration_ms)
}

/// Trusted internal API for shorter operator budgets/tests, never an origin
/// override. The request-wide clock is created before shared acquisition.
pub fn open_with_budget(
  engine: runtime.Runtime,
  scope: Scope,
  budget_ms: Int,
) -> Result(Client, Failure) {
  use _ <- result.try(case budget_ms > 0 && budget_ms <= max_duration_ms {
    True -> Ok(Nil)
    False ->
      Error(RuntimeFailure(c.Failure(c.InvalidConfiguration, c.NotSent, None)))
  })
  let deadline = monotonic_ms() + budget_ms
  use response <- result.try(
    runtime.open_until(engine, adapter(scope), request(scope), deadline)
    |> result.map_error(fn(error) { classify(error, deadline) }),
  )
  case response.status {
    200 -> Ok(Client(scope.account, response.stream, deadline))
    code -> {
      runtime.cancel(response.stream)
      Error(HttpFailure(code))
    }
  }
}

/// Fully complete HTTP framing before publishing ONE numeric observation.
/// The shared guard interrupts blocked reads at the SAME absolute deadline.
pub fn finish(
  client: Client,
  observe: fn(observation.Observation) -> Nil,
) -> Result(observation.Observation, Failure) {
  use body <- result.try(read_all(client, [], 0))
  let decoded =
    status.decode(body, now_ms()) |> result.replace_error(InvalidObservation)
  use _ <- result.try(case monotonic_ms() >= client.deadline_ms {
    True -> Error(DeadlineExceeded)
    False -> Ok(Nil)
  })
  use value <- result.try(decoded)
  let value = observation.from_status(client.account, value)
  observe(value)
  Ok(value)
}

fn read_all(
  client: Client,
  reversed: List(BitArray),
  size: Int,
) -> Result(BitArray, Failure) {
  use chunk <- result.try(
    runtime.next_until(client.stream, client.deadline_ms)
    |> result.map_error(fn(error) { classify(error, client.deadline_ms) }),
  )
  case chunk {
    None -> Ok(bit_array.concat(list.reverse(reversed)))
    Some(bytes) -> {
      let size = size + bit_array.byte_size(bytes)
      case size > status.max_response_bytes {
        True -> {
          cancel(client)
          Error(InvalidObservation)
        }
        False -> read_all(client, [bytes, ..reversed], size)
      }
    }
  }
}

pub fn fetch(
  engine: runtime.Runtime,
  scope: Scope,
  observe: fn(observation.Observation) -> Nil,
) -> Result(observation.Observation, Failure) {
  use client <- result.try(open(engine, scope))
  finish(client, observe)
}

pub fn cancel(client: Client) -> Nil {
  runtime.cancel(client.stream)
}

pub fn adopt(client: Client) -> Result(Nil, Failure) {
  runtime.adopt(client.stream)
  |> result.map_error(fn(error) { classify(error, client.deadline_ms) })
}

fn classify(error: c.Failure, deadline_ms: Int) -> Failure {
  case monotonic_ms() >= deadline_ms {
    True -> DeadlineExceeded
    False -> RuntimeFailure(error)
  }
}

/// Trusted internal adapter; caller must authenticate before runtime use.
/// No fallback, redirects, credential writes or separate sockets are added.
pub fn adapter(scope: Scope) -> c.Adapter(egress.Stream) {
  let base =
    transport.binary_http(
      fn(context, request) { prepare(scope, context, request) },
      fn(_, _) { None },
      None,
    )
  c.Adapter(..base, open: fn(context, request) {
    use opened <- result.try(base.open(context, request))
    case bounded_head(opened.headers) {
      False -> {
        base.cancel(opened.handle)
        Error(c.Failure(c.InvalidResponse, c.Uncertain, None))
      }
      True ->
        // Shared quota observation gets only canonical numeric Retry-After
        // on 429, never arbitrary provider-private header values.
        Ok(c.Opened(
          opened.status,
          case opened.status {
            429 -> safe_retry_header(opened.headers)
            _ -> []
          },
          opened.handle,
        ))
    }
  })
}

fn prepare(
  scope: Scope,
  context: c.Context,
  request: c.Request,
) -> Result(c.HttpRequest, c.Failure) {
  use _ <- result.try(
    case
      context.provider == "devin"
      && context.auth_mode == "session_token"
      && context.account == scope.account
      && context.origin == scope.origin
      && context.session_key != ""
      && request.provider == "devin"
      && request.auth_mode == "session_token"
      && request.model == scope.model
      && request.protocol == "devin-status"
      && request.operation == "status"
      && request.mode == c.Buffered
      && request.required == [c.Buffer]
      && request.pinned_account == Some(scope.account)
      && request.session != ""
      && request.body == ""
    {
      True -> Ok(Nil)
      False -> Error(c.Failure(c.InvalidConfiguration, c.NotSent, None))
    },
  )
  use token <- result.try(case context.credential {
    c.SessionToken(token, _) -> Ok(token)
    _ -> Error(c.Failure(c.CredentialUnavailable, c.NotSent, None))
  })
  // Permanent material is used exactly as stored; status never prefixes,
  // refreshes, replaces or enriches the grant.
  status.request(
    context.origin,
    token,
    identity.hex(identity.random_bytes(366)),
    identity.os_name(),
  )
  |> result.replace_error(c.Failure(c.InvalidConfiguration, c.NotSent, None))
}

fn bounded_head(headers: List(Header)) -> Bool {
  case header_values(headers, "content-length") {
    [] -> True
    [raw] ->
      case int.parse(raw) {
        Ok(size) -> size >= 0 && size <= status.max_response_bytes
        _ -> False
      }
    _ -> False
  }
}

fn safe_retry_header(headers: List(Header)) -> List(Header) {
  case header_values(headers, "retry-after") {
    [raw] ->
      case int.parse(raw) {
        Ok(seconds) if seconds >= 0 && seconds <= 86_400 ->
          case raw == int.to_string(seconds) {
            True -> [Header("Retry-After", raw)]
            False -> []
          }
        _ -> []
      }
    _ -> []
  }
}

fn header_values(headers: List(Header), name: String) -> List(String) {
  headers
  |> list.filter(fn(header) { string.lowercase(header.name) == name })
  |> list.map(fn(header) { header.value })
}

pub fn message(failure: Failure) -> String {
  case failure {
    HttpFailure(code) -> "Devin status HTTP " <> int.to_string(code)
    InvalidObservation -> "Invalid Devin status observation"
    DeadlineExceeded -> "Devin status deadline exceeded"
    RuntimeFailure(c.Failure(c.CredentialUnavailable, _, _)) ->
      "Devin status credential unavailable"
    RuntimeFailure(c.Failure(c.NoAccount, _, _)) ->
      "Devin status account unavailable"
    RuntimeFailure(c.Failure(c.Cancelled, _, _)) -> "Devin status cancelled"
    RuntimeFailure(c.Failure(c.InvalidResponse, _, _)) ->
      "Invalid Devin status response"
    RuntimeFailure(_) -> "Devin status unavailable"
  }
}

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
fn now_ms() -> Int
