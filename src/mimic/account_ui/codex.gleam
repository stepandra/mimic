/// F06: pinned Codex PKCE policy, ephemeral loopback callback, one exchange.
/// Verifier, callback code and tokens remain in the cancellable private worker.
/// Persistence belongs exclusively to the account UI coordinator's S5 ticket.
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/account_ui/enrollment
import mimic/account_ui/primitives as os
import mimic/gateway/refresh
import mimic/providers/codex/adapter as provider
import mimic/providers/codex/oauth
import mimic/providers/contracts.{type RefreshFailure, OAuth}
import mimic/types.{type WireResponse}
import mist
import mist/internal/http as mist_http

pub type Send =
  fn(oauth.TokenRequest) -> Result(WireResponse, RefreshFailure)

type Redirect {
  Redirect(port: Int, authority: String, path: String)
}

/// Private callback capability; never serialized or retained as history.
type Callback {
  Callback(query: String, connection: process.Pid, reply: process.Subject(Int))
}

type StopReason {
  Shutdown
}

type StopReturn

@external(erlang, "gen_server", "stop")
fn stop_supervisor(
  pid: process.Pid,
  reason: StopReason,
  timeout_ms: Int,
) -> StopReturn

fn stop_listener(pid: process.Pid) -> Result(Nil, String) {
  // An exit(normal) from a non-parent is ignored by an OTP supervisor.
  // Use its actual bounded shutdown protocol, without logging private state.
  let monitor = process.monitor(pid)
  let _ = os.protect(fn() { stop_supervisor(pid, Shutdown, 5000) })
  let joined =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  joined |> result.replace_error("callback_cleanup_unconfirmed")
}

pub fn validate(config: oauth.Config, ui_port: Int) -> Result(Nil, String) {
  use _ <- result.try(
    oauth.refresh_request(config, "synthetic-validation")
    |> result.replace_error("invalid configured Codex OAuth endpoints"),
  )
  use _ <- result.try(refresh.validate(config.token_url))
  use redirect <- result.try(redirect(config))
  case
    redirect.port != ui_port
    && string.byte_size(config.authorize_url) <= 2048
    && string.byte_size(config.token_url) <= 2048
  {
    True -> Ok(Nil)
    False -> Error("Codex callback requires a distinct explicit loopback port")
  }
}

fn redirect(config: oauth.Config) -> Result(Redirect, String) {
  use parsed <- result.try(
    uri.parse(config.redirect_uri)
    |> result.replace_error("invalid Codex redirect"),
  )
  case parsed.scheme, parsed.host, parsed.port {
    Some("http"), Some(host), Some(port)
      if { host == "localhost" || host == "127.0.0.1" }
      && port > 0
      && port < 65_536
    ->
      case
        parsed.userinfo == None
        && parsed.query == None
        && parsed.fragment == None
        && string.starts_with(parsed.path, "/")
        && parsed.path != "/"
        && string.byte_size(parsed.path) <= 128
        && !string.contains(parsed.path, "%")
        && !string.contains(parsed.path, "\\")
      {
        True ->
          Ok(Redirect(port, host <> ":" <> int.to_string(port), parsed.path))
        False -> Error("invalid Codex callback path")
      }
    _, _, _ ->
      Error("Codex redirect requires explicit loopback HTTP port and path")
  }
}

pub fn adapter(config: oauth.Config, send: Send) -> enrollment.Adapter {
  enrollment.Adapter(fn(emit, deadline, clock) {
    use redirect <- result.try(
      redirect(config) |> result.replace_error("failed"),
    )
    let started_ms = clock()
    let deadline = int.min(deadline, started_ms + 300_000)
    use login <- result.try(
      oauth.begin_login(config, os.epoch_ms()) |> result.replace_error("failed"),
    )
    use plan <- result.try(await_callback(
      config,
      login,
      redirect,
      emit,
      deadline,
      clock,
    ))
    use _ <- result.try(before_deadline(deadline, clock))
    // Exactly one token exchange, no retry on an unknown delivery outcome.
    use response <- result.try(send(plan) |> result.replace_error("failed"))
    use _ <- result.try(before_deadline(deadline, clock))
    oauth.decode_tokens(response.status, response.body, None, os.epoch_ms())
    |> result.map(fn(tokens) { OAuth(provider.material(tokens)) })
    |> result.replace_error("failed")
  })
}

fn before_deadline(
  deadline: Int,
  clock: enrollment.Clock,
) -> Result(Nil, String) {
  case clock() < deadline {
    True -> Ok(Nil)
    False -> Error("expired")
  }
}

fn remaining(deadline: Int, clock: enrollment.Clock) -> Int {
  int.max(0, deadline - clock())
}

fn singleton(req: Request(a), name: String) -> Result(String, Nil) {
  case list.filter(req.headers, fn(pair) { pair.0 == name }) {
    [#(_, value)] -> Ok(value)
    _ -> Error(Nil)
  }
}

fn callback_query(
  req: Request(mist.Connection),
  redirect: Redirect,
) -> Result(String, Nil) {
  use query <- result.try(case req.query {
    Some(query) ->
      case string.byte_size(query) <= 4096 {
        True -> Ok(query)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  })
  use _ <- result.try(
    case
      req.method == Get
      && req.path == redirect.path
      && singleton(req, "host") == Ok(redirect.authority)
      && list.length(req.headers) <= 32
      && list.all(req.headers, fn(pair) {
        string.byte_size(pair.0) <= 64 && string.byte_size(pair.1) <= 4096
      })
      && !list.any(req.headers, fn(pair) { pair.0 == "transfer-encoding" })
      && case
        list.filter(req.headers, fn(pair) { pair.0 == "content-length" })
      {
        [] | [#(_, "0")] -> True
        _ -> False
      }
      && case req.body.body {
        mist_http.Initial(_) -> True
        _ -> False
      }
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  // Policy performs state/code singleton checks. Bound all decoded fields too.
  use fields <- result.try(uri.parse_query(query) |> result.replace_error(Nil))
  case
    list.length(fields) <= 6
    && list.all(fields, fn(pair) {
      list.contains(
        ["state", "code", "scope", "error", "error_description", "error_uri"],
        pair.0,
      )
      && string.byte_size(pair.1) <= 2048
      && !string.contains(pair.1, "\r")
      && !string.contains(pair.1, "\n")
      && !string.contains(pair.1, "\u{0000}")
    })
  {
    True -> Ok(query)
    False -> Error(Nil)
  }
}

fn reply(status: Int) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("connection", "close")
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_header("cache-control", "no-store, max-age=0")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; frame-ancestors 'none'",
  )
  |> response.set_body(
    mist.Bytes(
      bytes_tree.from_string(case status {
        200 ->
          "Callback consumed. Return to the MIMIC account page for installation status."
        _ ->
          "Callback rejected or no longer active. Return to the MIMIC account page."
      }),
    ),
  )
}

fn await_callback(
  config: oauth.Config,
  login: oauth.Login,
  redirect: Redirect,
  emit: enrollment.Emit,
  deadline: Int,
  clock: enrollment.Clock,
) -> Result(oauth.TokenRequest, String) {
  let callback = process.new_subject()
  let ready = process.new_subject()
  let owner = process.self()
  let builder =
    mist.new(fn(req) {
      case callback_query(req, redirect) {
        Error(_) -> reply(400)
        Ok(query) -> {
          let answer = process.new_subject()
          process.send(callback, Callback(query, process.self(), answer))
          // Worker consumes only the first admitted callback, even on mismatch.
          // Concurrent/replayed callbacks cannot exchange or install a second grant.
          reply(process.receive(answer, 1000) |> result.unwrap(410))
        }
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(redirect.port)
    |> mist.after_start(fn(actual, _, _) { process.send(ready, actual) })
  use server <- result.try(
    mist.start(builder) |> result.replace_error("failed"),
  )
  // Transfer the initially linked listener to an acknowledged lifecycle
  // monitor before exposing the URL. Cancellation can then stop Mist normally
  // instead of producing worker/supervisor crash reports.
  let watched = process.new_subject()
  let cleanup =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(owner)
      let listener = process.monitor(server.pid)
      process.send(watched, Nil)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.select_specific_monitor(listener, fn(_) { Nil })
        |> process.selector_receive_forever
      let _ = stop_listener(server.pid)
      Nil
    })
  let watching = process.receive(watched, 1000)
  case watching {
    Ok(_) -> process.unlink(server.pid)
    Error(_) -> Nil
  }
  let outcome = {
    use _ <- result.try(watching |> result.replace_error("failed"))
    use actual <- result.try(
      process.receive(ready, int.min(5000, remaining(deadline, clock)))
      |> result.replace_error("failed"),
    )
    use _ <- result.try(case actual == redirect.port {
      True -> before_deadline(deadline, clock)
      False -> Error("failed")
    })
    emit(
      Some(enrollment.BrowserLogin(oauth.authorization_url(login))),
      deadline,
    )
    use incoming <- result.try(
      process.receive(callback, remaining(deadline, clock))
      |> result.replace_error("expired"),
    )
    emit(None, deadline)
    let plan =
      oauth.exchange_request(config, login, incoming.query, os.epoch_ms())
      |> result.replace_error("callback_rejected")
    process.send(incoming.reply, case plan {
      Ok(_) -> 200
      Error(_) -> 400
    })
    // As in the existing auth callback, Connection: close makes the handler's
    // termination the response-attempt boundary rather than a guessed sleep.
    let monitor = process.monitor(incoming.connection)
    let _ =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive(int.min(1000, remaining(deadline, clock)))
    process.demonitor_process(monitor)
    use _ <- result.try(before_deadline(deadline, clock))
    plan
  }
  process.unlink(server.pid)
  let stopped = stop_listener(server.pid)
  case stopped {
    Ok(_) -> process.kill(cleanup)
    // Retain the owner monitor on an unknown shutdown outcome. Do not
    // exchange a token while claiming an unjoined listener has disappeared.
    Error(_) -> Nil
  }
  use _ <- result.try(stopped)
  outcome
}
