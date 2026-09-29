/// Private, read-only Devin status/quota observation. No refresh, persistence,
/// credential mutation, transport, or public management projection lives here.
/// The entire request plan, including its binary body, is SECRET.
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/providers/contracts as c
import mimic/providers/devin/protobuf as pb
import mimic/types.{Header}

pub const get_user_status_path = "/exa.seat_management_pb.SeatManagementService/GetUserStatus"

pub type Observation {
  Observation(
    observed_at_ms: Int,
    user_name: String,
    user_id: String,
    team_id: String,
    email: String,
    org_id: String,
    org_name: String,
    plan: String,
    daily_remaining_percent: Option(Int),
    weekly_remaining_percent: Option(Int),
    daily_reset_seconds: Option(Int),
    weekly_reset_seconds: Option(Int),
    plan_start_seconds: Option(Int),
    plan_end_seconds: Option(Int),
  )
}

/// Pure protobuf serialization, matching CPA's f1 metadata fields. Fingerprint
/// is supplied by the private caller rather than derived from the session token.
pub fn request(
  approved_origin: String,
  session_token: String,
  fingerprint: String,
  os_name: String,
) -> Result(c.HttpRequest, String) {
  use _ <- result.try(valid_origin(approved_origin))
  use _ <- result.try(
    case
      session_token != ""
      && string.length(session_token) <= 16_384
      && !string.contains(session_token, "\r")
      && !string.contains(session_token, "\n")
      && !string.contains(session_token, "\t")
      && !string.contains(session_token, " ")
      && !string.contains(session_token, "\u{0000}")
      && string.length(fingerprint) == 732
      && ascii_hex(bit_array.from_string(fingerprint))
      && os_name != ""
      && string.length(os_name) <= 32
      && ascii_os(bit_array.from_string(os_name))
    {
      True -> Ok(Nil)
      False -> Error("Invalid Devin status request inputs")
    },
  )
  let body =
    pb.encode([
      pb.message(1, [
        pb.text(1, "chisel"),
        pb.text(2, "3000.10.21"),
        pb.text(3, session_token),
        pb.text(4, "en"),
        pb.text(5, os_name),
        pb.text(7, "3000.10.21"),
        pb.text(12, "chisel"),
        pb.text(31, fingerprint),
      ]),
    ])
  let assert Ok(parsed) = uri.parse(approved_origin)
  let host = case parsed.host {
    Some(host) -> host
    None -> ""
  }
  let authority =
    host
    <> case parsed.port {
      None -> ""
      Some(port) -> ":" <> int.to_string(port)
    }
  Ok(c.HttpRequest(
    endpoint: approved_origin,
    method: "POST",
    target: get_user_status_path,
    headers: [
      Header("Host", authority),
      Header("Authorization", "Basic " <> session_token <> "-" <> session_token),
      Header("Connect-Protocol-Version", "1"),
      Header("Content-Type", "application/proto"),
      Header("Accept", "*/*"),
      Header("Content-Length", int.to_string(bit_array.byte_size(body))),
    ],
    body: body,
    protocol: c.Http1,
    media: c.Proto,
  ))
}

/// Pass only a successful HTTP 200 protobuf body. Never include upstream
/// response bytes, headers, or errors in public diagnostics. No wire evidence
/// is implied by decoding synthetic fixtures.
pub fn decode(
  body: BitArray,
  observed_at_ms: Int,
) -> Result(Observation, String) {
  use _ <- result.try(
    case
      observed_at_ms >= 0
      && bit_array.byte_size(body) > 0
      && bit_array.byte_size(body) <= 4_194_304
    {
      True -> Ok(Nil)
      False -> Error("Invalid Devin status observation")
    },
  )
  use root <- result.try(fields(body))
  use nested <- result.try(required_message(root, 1))
  use user <- result.try(fields(nested))
  use _ <- result.try(
    case
      list.any(user, fn(field) {
        list.contains([3, 5, 7, 13, 36], field_tag(field))
      })
    {
      True -> Ok(Nil)
      False -> Error("Invalid Devin status protobuf")
    },
  )
  let empty =
    Observation(
      observed_at_ms,
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      None,
      None,
      None,
      None,
      None,
      None,
    )
  use user_name <- result.try(optional_text(user, 3))
  use team_id <- result.try(optional_text(user, 5))
  use email <- result.try(optional_text(user, 7))
  use user_id <- result.try(optional_text(user, 36))
  use plan_bytes <- result.try(optional_message(user, 13))
  let base =
    Observation(
      ..empty,
      user_name: user_name,
      team_id: team_id,
      email: email,
      user_id: user_id,
    )
  case plan_bytes {
    None -> Ok(base)
    Some(bytes) -> decode_plan(bytes, base)
  }
}

fn decode_plan(
  body: BitArray,
  base: Observation,
) -> Result(Observation, String) {
  use fields <- result.try(fields(body))
  use info <- result.try(optional_message(fields, 1))
  use daily <- result.try(optional_int(fields, 14))
  use weekly <- result.try(optional_int(fields, 15))
  use daily_reset <- result.try(optional_int(fields, 17))
  use weekly_reset <- result.try(optional_int(fields, 18))
  use start <- result.try(optional_message(fields, 2))
  use end <- result.try(optional_message(fields, 3))
  use start_seconds <- result.try(seconds(start))
  use end_seconds <- result.try(seconds(end))
  let base =
    Observation(
      ..base,
      daily_remaining_percent: daily,
      weekly_remaining_percent: weekly,
      daily_reset_seconds: positive(daily_reset),
      weekly_reset_seconds: positive(weekly_reset),
      plan_start_seconds: start_seconds,
      plan_end_seconds: end_seconds,
    )
  case info {
    None -> Ok(base)
    Some(bytes) -> decode_info(bytes, base)
  }
}

fn decode_info(
  body: BitArray,
  base: Observation,
) -> Result(Observation, String) {
  use info_fields <- result.try(fields(body))
  use name <- result.try(optional_text(info_fields, 2))
  use org <- result.try(optional_message(info_fields, 33))
  let base = Observation(..base, plan: name)
  case org {
    None -> Ok(base)
    Some(bytes) -> {
      use org_fields <- result.try(fields(bytes))
      use id <- result.try(optional_text(org_fields, 4))
      use name <- result.try(optional_text(org_fields, 8))
      Ok(Observation(..base, org_id: id, org_name: name))
    }
  }
}

fn seconds(message: Option(BitArray)) -> Result(Option(Int), String) {
  case message {
    None -> Ok(None)
    Some(bytes) -> {
      use fields <- result.try(fields(bytes))
      use value <- result.try(optional_int(fields, 1))
      Ok(positive(value))
    }
  }
}

fn positive(value: Option(Int)) -> Option(Int) {
  case value {
    Some(n) if n > 0 -> Some(n)
    _ -> None
  }
}

fn fields(bytes: BitArray) -> Result(List(pb.Field), String) {
  pb.decode(bytes) |> result.replace_error("Invalid Devin status protobuf")
}

fn required_message(
  fields: List(pb.Field),
  tag: Int,
) -> Result(BitArray, String) {
  case optional_message(fields, tag) {
    Ok(Some(bytes)) -> Ok(bytes)
    _ -> Error("Invalid Devin status protobuf")
  }
}

fn optional_message(
  fields: List(pb.Field),
  tag: Int,
) -> Result(Option(BitArray), String) {
  case list.filter(fields, fn(field) { field_tag(field) == tag }) {
    [] -> Ok(None)
    [pb.Bytes(_, bytes)] -> Ok(Some(bytes))
    _ -> Error("Invalid Devin status protobuf")
  }
}

fn optional_text(fields: List(pb.Field), tag: Int) -> Result(String, String) {
  use value <- result.try(optional_message(fields, tag))
  case value {
    None -> Ok("")
    Some(bytes) ->
      bit_array.to_string(bytes)
      |> result.replace_error("Invalid Devin status protobuf")
  }
}

fn optional_int(
  fields: List(pb.Field),
  tag: Int,
) -> Result(Option(Int), String) {
  case list.filter(fields, fn(field) { field_tag(field) == tag }) {
    [] -> Ok(None)
    [pb.Varint(_, value)] -> Ok(Some(value))
    _ -> Error("Invalid Devin status protobuf")
  }
}

fn field_tag(field: pb.Field) -> Int {
  case field {
    pb.Varint(tag, _)
    | pb.Bytes(tag, _)
    | pb.Fixed32(tag, _)
    | pb.Fixed64(tag, _) -> tag
  }
}

fn ascii_hex(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>>
      if { byte >= 48 && byte <= 57 } || { byte >= 97 && byte <= 102 }
    -> ascii_hex(rest)
    _ -> False
  }
}

fn ascii_os(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>>
      if { byte >= 97 && byte <= 122 } || { byte >= 48 && byte <= 57 }
    -> ascii_os(rest)
    _ -> False
  }
}

fn valid_origin(origin: String) -> Result(Nil, String) {
  use parsed <- result.try(
    uri.parse(origin) |> result.replace_error("Invalid Devin status origin"),
  )
  case parsed {
    uri.Uri(
      scheme: Some("https"),
      host: Some(host),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    )
      if host != ""
    -> Ok(Nil)
    uri.Uri(
      scheme: Some("http"),
      host: Some("127.0.0.1"),
      userinfo: None,
      path: "",
      query: None,
      fragment: None,
      ..,
    ) -> Ok(Nil)
    _ -> Error("Invalid Devin status origin")
  }
}
