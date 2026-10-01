/// Fail-closed HTTP boundary. Browser/API input never supplies an endpoint,
/// device identity or provider credential. The actor rechecks session authority
/// at the action, not in an earlier check/use step.
import gleam/bit_array
import gleam/bytes_tree
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/account_ui/coordinator.{
  type Authorization, type Coordinator, Authorization,
}
import mimic/account_ui/page
import mimic/ir
import mimic/ir/json_guard
import mimic/providers/kimi/json_guard as strict_json
import mist

const body_limit = 1024

pub fn cookie_name(port: Int) -> String {
  "mimic_operator_" <> int.to_string(port)
}

fn singleton(req: Request(a), name: String) -> Result(String, Nil) {
  case list.filter(req.headers, fn(pair) { pair.0 == name }) {
    [#(_, value)] -> Ok(value)
    _ -> Error(Nil)
  }
}

fn optional_origin(req: Request(a), port: Int) -> Bool {
  case list.filter(req.headers, fn(pair) { pair.0 == "origin" }) {
    [] -> True
    [#(_, value)] -> value == origin(port)
    _ -> False
  }
}

fn origin(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

fn boundary(req: Request(a), port: Int) -> Bool {
  singleton(req, "host") == Ok("127.0.0.1:" <> int.to_string(port))
  && req.host == "127.0.0.1"
  && req.query == None
  && string.byte_size(req.path) <= 64
  && list.length(req.headers) <= 32
  && list.all(req.headers, fn(pair) {
    string.byte_size(pair.0) <= 64 && string.byte_size(pair.1) <= 4096
  })
  && optional_origin(req, port)
  && case singleton(req, "sec-fetch-site") {
    Ok("cross-site") | Ok("same-site") -> False
    _ -> True
  }
}

fn length(req: Request(a)) -> Result(Int, Nil) {
  case list.any(req.headers, fn(h) { h.0 == "transfer-encoding" }) {
    True -> Error(Nil)
    False ->
      case singleton(req, "content-length") {
        Ok(raw) ->
          case int.parse(raw) {
            Ok(size) if size >= 0 && size <= body_limit ->
              case int.to_string(size) == raw {
                True -> Ok(size)
                False -> Error(Nil)
              }
            _ -> Error(Nil)
          }
        Error(_) -> Ok(0)
      }
  }
}

pub fn handle(
  req: Request(mist.Connection),
  coordinator: Coordinator,
  port: Int,
) -> Response(mist.ResponseData) {
  let empty_body = length(req) == Ok(0)
  let admitted = coordinator.admit(coordinator, authorization(req, port))
  let response = case admitted, boundary(req, port) {
    False, _ -> error(429, "unauthenticated request rate limited")
    _, False -> error(403, "operator boundary rejected")
    True, True ->
      case req.method, req.path {
        Get, "/" if empty_body ->
          reply(200, page.html, "text/html; charset=utf-8")
        Get, "/panel.js" if empty_body ->
          reply(200, page.javascript, "text/javascript; charset=utf-8")
        Get, "/panel.css" if empty_body ->
          reply(200, page.css, "text/css; charset=utf-8")
        Post, path -> {
          case
            list.contains(
              [
                "/api/session",
                "/api/status",
                "/api/login",
                "/api/cancel",
                "/api/logout",
              ],
              path,
            )
          {
            False -> error(404, "not found")
            True ->
              case
                singleton(req, "origin") == Ok(origin(port))
                && singleton(req, "x-mimic-ui") == Ok("1")
                && singleton(req, "content-type") == Ok("application/json")
              {
                False -> error(403, "same-origin JSON request required")
                True ->
                  case length(req) {
                    Ok(size) if size > 0 -> {
                      case mist.read_body(req, max_body_limit: body_limit) {
                        Error(_) -> error(413, "bounded request body required")
                        Ok(req) -> api(req, coordinator, port)
                      }
                    }
                    _ ->
                      error(
                        413,
                        "bounded content-length required; chunked input unsupported",
                      )
                  }
              }
          }
        }
        _, _ -> error(404, "not found")
      }
  }
  response
  |> response.map(bytes_tree.from_string)
  |> response.map(mist.Bytes)
}

fn authorization(req: Request(a), port: Int) -> Authorization {
  let session = case singleton(req, "cookie") {
    Ok(_) ->
      case
        list.filter(request.get_cookies(req), fn(pair) {
          pair.0 == cookie_name(port)
        })
      {
        [#(_, value)] -> token(value)
        _ -> ""
      }
    _ -> ""
  }
  let csrf = case singleton(req, "x-csrf-token") {
    Ok(value) -> token(value)
    _ -> ""
  }
  Authorization(session, csrf)
}

fn token(value: String) -> String {
  case string.byte_size(value) == 43 {
    True -> value
    False -> ""
  }
}

fn parse(body: BitArray) -> Result(ir.Value, String) {
  use text <- result.try(
    bit_array.to_string(body) |> result.replace_error("invalid UTF-8 JSON"),
  )
  use _ <- result.try(json_guard.validate(text, body_limit, 4, 16))
  strict_json.parse(text)
}

fn api(
  req: Request(BitArray),
  coordinator: Coordinator,
  port: Int,
) -> Response(String) {
  case parse(req.body) {
    Error(_) -> error(400, "invalid bounded JSON")
    Ok(value) -> {
      let auth = authorization(req, port)
      let outcome = case req.path, value {
        "/api/session", ir.Object([#("code", ir.String(code))]) ->
          case string.byte_size(code) == 43 {
            True -> Ok(coordinator.exchange(coordinator, code))
            False -> Error(Nil)
          }
        "/api/status", ir.Object([]) ->
          Ok(coordinator.status(coordinator, auth))
        "/api/logout", ir.Object([]) ->
          Ok(coordinator.logout(coordinator, auth))
        "/api/login", ir.Object([#("account", ir.String(account))])
        | "/api/cancel", ir.Object([#("account", ir.String(account))])
        ->
          case
            string.byte_size(account) > 0 && string.byte_size(account) <= 256
          {
            False -> Error(Nil)
            True ->
              case req.path {
                "/api/login" ->
                  Ok(coordinator.login(coordinator, auth, account))
                _ -> Ok(coordinator.cancel(coordinator, auth, account))
              }
          }
        _, _ -> Error(Nil)
      }
      case outcome {
        Error(_) -> error(400, "invalid operator action")
        Ok(value) -> {
          let response =
            reply(value.status, json.to_string(value.body), "application/json")
          case value.session_cookie {
            Some(token) ->
              response.set_header(
                response,
                "set-cookie",
                cookie_name(port)
                  <> "="
                  <> token
                  <> "; HttpOnly; SameSite=Strict; Path=/; Max-Age=1800",
              )
            None ->
              case req.path == "/api/logout" {
                True ->
                  response.set_header(
                    response,
                    "set-cookie",
                    cookie_name(port)
                      <> "=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0",
                  )
                False -> response
              }
          }
        }
      }
    }
  }
}

fn error(status: Int, message: String) -> Response(String) {
  reply(
    status,
    json.to_string(json.object([#("error", json.string(message))])),
    "application/json",
  )
}

fn reply(status: Int, body: String, content_type: String) -> Response(String) {
  response.new(status)
  |> response.set_body(body)
  |> response.set_header("content-type", content_type)
  |> response.set_header("cache-control", "no-store, max-age=0")
  |> response.set_header("pragma", "no-cache")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("x-frame-options", "DENY")
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'",
  )
  |> response.set_header("connection", "close")
}
