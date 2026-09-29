import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/providers/contracts as c
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/status
import mimic/types.{Header}

pub fn synthetic_status_request_contains_secret_binary_plan_test() {
  let fingerprint = string.repeat("a", 732)
  let assert Ok(plan) =
    status.request(
      "http://127.0.0.1:9191",
      "devin-session-token$synthetic",
      fingerprint,
      "linux",
    )
  plan.method |> should.equal("POST")
  plan.target |> should.equal(status.get_user_status_path)
  plan.protocol |> should.equal(c.Http1)
  plan.media |> should.equal(c.Proto)
  plan.headers
  |> should.equal([
    Header("Host", "127.0.0.1:9191"),
    Header(
      "Authorization",
      "Basic devin-session-token$synthetic-devin-session-token$synthetic",
    ),
    Header("Connect-Protocol-Version", "1"),
    Header("Content-Type", "application/proto"),
    Header("Accept", "*/*"),
    Header("Content-Length", int.to_string(bit_array.byte_size(plan.body))),
  ])
  let assert Ok([pb.Bytes(1, metadata)]) = pb.decode(plan.body)
  pb.decode(metadata)
  |> should.equal(
    Ok([
      pb.text(1, "chisel"),
      pb.text(2, "3000.10.21"),
      pb.text(3, "devin-session-token$synthetic"),
      pb.text(4, "en"),
      pb.text(5, "linux"),
      pb.text(7, "3000.10.21"),
      pb.text(12, "chisel"),
      pb.text(31, fingerprint),
    ]),
  )
}

pub fn synthetic_status_nested_decode_test() {
  let wire =
    pb.encode([
      pb.message(1, [
        pb.text(3, "synthetic-user"),
        pb.text(5, "synthetic-team"),
        pb.text(7, "synthetic@example.invalid"),
        pb.text(36, "synthetic-id"),
        pb.message(13, [
          pb.message(1, [
            pb.text(2, "Synthetic Pro"),
            pb.message(33, [
              pb.text(4, "synthetic-org"),
              pb.text(8, "Synthetic Organization"),
            ]),
          ]),
          pb.message(2, [pb.Varint(1, 1_789_000_000)]),
          pb.message(3, [pb.Varint(1, 1_789_100_000)]),
          pb.Varint(14, 100),
          pb.Varint(15, 50),
          pb.Varint(17, 1_789_200_000),
          pb.Varint(18, 1_789_300_000),
        ]),
      ]),
    ])
  status.decode(wire, 1234)
  |> should.equal(
    Ok(status.Observation(
      1234,
      "synthetic-user",
      "synthetic-id",
      "synthetic-team",
      "synthetic@example.invalid",
      "synthetic-org",
      "Synthetic Organization",
      "Synthetic Pro",
      Some(100),
      Some(50),
      Some(1_789_200_000),
      Some(1_789_300_000),
      Some(1_789_000_000),
      Some(1_789_100_000),
    )),
  )
}

pub fn synthetic_missing_quota_is_not_zero_test() {
  let body = pb.encode([pb.message(1, [pb.text(3, "synthetic")])])
  let assert Ok(observation) = status.decode(body, 500)
  observation.daily_remaining_percent |> should.equal(None)
  observation.weekly_remaining_percent |> should.equal(None)
  observation.daily_reset_seconds |> should.equal(None)
}

pub fn synthetic_bounded_fail_closed_secret_safe_errors_test() {
  status.request(
    "https://user:secret@server.codeium.com",
    "synthetic",
    string.repeat("a", 732),
    "linux",
  )
  |> should.equal(Error("Invalid Devin status origin"))
  status.request(
    "http://127.0.0.1:9191",
    "synthetic\r\nAuthorization: secret",
    string.repeat("a", 732),
    "linux",
  )
  |> should.equal(Error("Invalid Devin status request inputs"))
  status.request(
    "http://127.0.0.1:9191",
    "synthetic",
    string.repeat("g", 732),
    "linux",
  )
  |> should.equal(Error("Invalid Devin status request inputs"))
  status.decode(bit_array.from_string(string.repeat("x", 4_194_305)), 1)
  |> should.equal(Error("Invalid Devin status observation"))
  status.decode(pb.encode([pb.message(1, [])]), 1)
  |> should.equal(Error("Invalid Devin status protobuf"))
  status.decode(pb.encode([pb.message(1, [pb.Bytes(13, <<10, 20>>)])]), 1)
  |> should.equal(Error("Invalid Devin status protobuf"))
  status.decode(
    pb.encode([
      pb.message(1, [
        pb.Varint(13, 1),
      ]),
    ]),
    1,
  )
  |> should.equal(Error("Invalid Devin status protobuf"))
}
