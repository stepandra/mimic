/// Executable local policy scenario. Uses synthetic mock endpoint functions,
/// never an HTTP client. Native documents and SSE use the shared codec.
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/errors
import mimic/providers/codex/fixtures
import mimic/providers/codex/models
import mimic/providers/codex/oauth
import mimic/providers/codex/request
import mimic/providers/codex/response
import mimic/providers/codex/routes
import mimic/providers/codex/session

pub fn main() {
  case cli([]) {
    Ok(report) -> io.println(report)
    Error(error) -> panic as error
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    [] | ["synthetic"] -> run()
    _ -> Error("usage: codex scenario [synthetic]")
  }
}

pub fn run() -> Result(String, String) {
  let config =
    oauth.Config(
      "http://127.0.0.1:1455/authorize",
      "http://127.0.0.1:1455/token",
      "http://localhost:1455/auth/callback",
    )
  use login <- result.try(oauth.begin_login(config, 1000))
  use authorize <- result.try(
    uri.parse(oauth.authorization_url(login))
    |> result.map_error(fn(_) { "synthetic login URL" }),
  )
  use query <- result.try(case authorize.query {
    Some(query) -> Ok(query)
    None -> Error("missing synthetic login query")
  })
  use query <- result.try(
    uri.parse_query(query)
    |> result.map_error(fn(_) { "synthetic login query" }),
  )
  use state <- result.try(
    list.key_find(query, "state")
    |> result.map_error(fn(_) { "synthetic login state" }),
  )
  use exchange <- result.try(oauth.exchange_request(
    config,
    login,
    uri.query_to_string([
      #("code", "synthetic-code"),
      #("state", state),
    ]),
    1001,
  ))
  use token_body <- result.try(mock_tokens(exchange))
  use tokens <- result.try(
    oauth.decode_tokens(200, token_body, None, 1001)
    |> result.map_error(fn(_) { "synthetic token decode failed" }),
  )
  use refresh <- result.try(oauth.refresh_request(
    config,
    tokens.credential.refresh_token,
  ))
  use refreshed_body <- result.try(mock_tokens(refresh))
  use rotated <- result.try(
    oauth.decode_tokens(200, refreshed_body, Some(tokens), 2000)
    |> result.map_error(fn(_) { "synthetic refresh failed" }),
  )
  let context =
    request.Context(
      session.Scope(
        "synthetic-client-key-id",
        "synthetic-internal-account",
        rotated.account_id,
        "gpt-5.5",
        "synthetic-session",
      ),
      rotated.credential.access_token,
      "mimic-synthetic-codex/1",
      Some("synthetic-socket-generation"),
    )
  use model <- result.try(models.lookup(models.pinned(), "gpt-5.5"))
  use route <- result.try(routes.resolve(
    "POST",
    "/backend-api/codex/responses",
    False,
    False,
  ))
  use body <- result.try(ir.parse(fixtures.request))
  use prepared <- result.try(request.prepare(
    body,
    context,
    route,
    None,
    model.reasoning_efforts,
  ))
  use terminal_body <- result.try(mock_backend(prepared))
  use terminal <- result.try(responses.decode_response(terminal_body))
  use collector <- result.try(response.new(prepared))
  use streamed <- result.try(response.feed(
    collector,
    bit_array.from_string(fixtures.sse()),
  ))
  use completed <- result.try(response.finish(streamed.0))
  use _ <- result.try(check(
    completed.response == terminal,
    "synthetic buffered/SSE disagreement",
  ))
  let receipt = completed.continuation
  use next <- result.try(ir.parse(fixtures.continuation))
  use followup <- result.try(request.prepare(
    next,
    context,
    route,
    Some(receipt),
    model.reasoning_efforts,
  ))
  use _ <- result.try(check(
    ir.field(followup.body, "previous_response_id") == None
      && followup.pending_calls == [],
    "synthetic HTTP replay failed",
  ))
  let ws =
    request.prepare(
      next,
      context,
      routes.Route(routes.Responses, routes.Websocket, True),
      Some(receipt),
      model.reasoning_efforts,
    )
  use _ <- result.try(check(
    result.is_error(ws),
    "HTTP receipt incorrectly accepted as a WS continuation",
  ))
  use compact <- result.try(request.prepare(
    followup.body,
    context,
    routes.Route(routes.Compact, routes.Http, True),
    None,
    model.reasoning_efforts,
  ))
  use compact_body <- result.try(mock_backend(compact))
  use _ <- result.try(responses.decode_compact_response(compact_body))
  let quota =
    errors.classify(
      429,
      [],
      "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_in_seconds\":10}}",
      2000,
    )
  use _ <- result.try(check(
    !errors.permits_retry(quota, True, False),
    "synthetic retry guard failed",
  ))
  Ok(
    "SYNTHETIC Codex policy/shared-codec scenario passed: PKCE, rotated refresh, native preparation, HTTP/SSE terminal and usage preservation, tool/reasoning replay, HTTP-to-WS receipt rejection, compact, quota retry guard. No sockets, live calls, measured usage, WS transport or assembled-ingress claim.",
  )
}

fn mock_tokens(plan: oauth.TokenRequest) -> Result(String, String) {
  use form <- result.try(
    uri.parse_query(plan.body)
    |> result.map_error(fn(_) { "synthetic form invalid" }),
  )
  case list.key_find(form, "grant_type") {
    Ok("authorization_code") -> Ok(fixtures.tokens())
    Ok("refresh_token") ->
      Ok(
        "{\"access_token\":\"synthetic-rotated-access\",\"refresh_token\":\"synthetic-rotated-refresh\",\"expires_in\":3600}",
      )
    _ -> Error("unexpected synthetic token grant")
  }
}

fn mock_backend(plan: request.Prepared) -> Result(String, String) {
  use _ <- result.try(check(
    ir.field(plan.body, "store") == Some(ir.Boolean(False)),
    "synthetic backend requires store=false",
  ))
  case plan.target {
    "/backend-api/codex/responses" -> Ok(fixtures.completed)
    "/backend-api/codex/responses/compact" -> Ok(fixtures.compact)
    _ -> Error("unexpected synthetic backend target")
  }
}

fn check(condition: Bool, error: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(error)
  }
}
