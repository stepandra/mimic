import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/providers/claude/companion
import mimic/providers/claude/oauth
import mimic/replay
import mimic/types.{type WireResponse, Capture, Header, Transport}

@external(erlang, "mimic_replay_test_ffi", "start_response")
fn start_response(response: String) -> Int

@external(erlang, "mimic_replay_test_ffi", "received")
fn received() -> String

fn wire(prefix: String) -> Result(WireResponse, String) {
  wire_media(prefix <> "application/json")
}

fn wire_media(media: String) -> Result(WireResponse, String) {
  let body = "{\"account\":{\"uuid\":\"synthetic-account\"}}"
  let port =
    start_response(
      "HTTP/1.1 200 OK\r\nContent-Type:"
      <> media
      <> "\r\nContent-Length: "
      <> int.to_string(string.byte_size(body))
      <> "\r\nConnection: close\r\n\r\n"
      <> body,
    )
  let endpoint = "http://127.0.0.1:" <> int.to_string(port)
  let capture =
    Capture(
      "synthetic",
      "1",
      endpoint,
      "main",
      "GET",
      "/profile",
      "HTTP/1.1",
      [Header("Host", "127.0.0.1:" <> int.to_string(port))],
      "",
      Transport("http/1.1", None),
    )
  let response = replay.send(endpoint, capture)
  let _ = received()
  response
}

fn rejected(prefix: String) {
  case wire(prefix) {
    Error(_) -> Nil
    Ok(response) -> {
      let token =
        oauth.TokenResponse(response.status, response.headers, response.body)
      oauth.response_json(token) |> should.be_error
      companion.parse_profile(token) |> should.be_error
      companion.parse_roles(token) |> should.be_error
      Nil
    }
  }
}

pub fn raw_vertical_tab_cannot_become_valid_media_test() {
  rejected("\u{000B}")
}

pub fn raw_unicode_pattern_whitespace_cannot_become_valid_media_test() {
  rejected("\u{200E}")
}

pub fn raw_nbsp_is_not_http_whitespace_test() {
  rejected("\u{00A0}")
}

pub fn actual_http_ows_stays_accepted_test() {
  list.each(["", " ", "\t", " \t "], fn(prefix) {
    let assert Ok(response) = wire(prefix)
    let token =
      oauth.TokenResponse(response.status, response.headers, response.body)
    oauth.response_json(token) |> should.be_ok
    companion.parse_profile(token) |> should.be_ok
    companion.parse_roles(token) |> should.be_ok
  })
}

pub fn actual_trailing_and_parameter_ows_stays_accepted_test() {
  list.each(
    [
      "application/json\t",
      "application/json;\tcharset=utf-8",
      "\tapplication/problem+json \t; \tcharset=utf-8\t ",
    ],
    fn(media) {
      let assert Ok(response) = wire_media(media)
      let token =
        oauth.TokenResponse(response.status, response.headers, response.body)
      oauth.response_json(token) |> should.be_ok
      companion.parse_profile(token) |> should.be_ok
      companion.parse_roles(token) |> should.be_ok
    },
  )
}

pub fn actual_in_token_ows_is_not_normalized_test() {
  list.each(
    [
      "application/\tjson",
      "application/problem\t+json",
      "application/json;charset=\tutf-8",
    ],
    fn(media) {
      let assert Ok(response) = wire_media(media)
      let token =
        oauth.TokenResponse(response.status, response.headers, response.body)
      oauth.response_json(token) |> should.be_error
      companion.parse_profile(token) |> should.be_error
      companion.parse_roles(token) |> should.be_error
    },
  )
}
