import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/auth
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/status
import mimic/providers/devin/status_observation as observation
import mimic/providers/devin/tokens
import mimic/types.{Header}

fn quota(fields: List(pb.Field)) -> BitArray {
  pb.encode([pb.message(1, [pb.message(13, fields)])])
}

pub fn f28_exact_basic_session_auth_unframed_proto_request_test() {
  let token = "devin-session-token$synthetic-jwt"
  let fingerprint = string.repeat("a", 732)
  let assert Ok(plan) =
    status.request("http://127.0.0.1:9876", token, fingerprint, "darwin")
  plan.method |> should.equal("POST")
  plan.target |> should.equal(status.get_user_status_path)
  plan.protocol |> should.equal(c.Http1)
  plan.media |> should.equal(c.Proto)
  plan.headers
  |> should.equal([
    Header("Host", "127.0.0.1:9876"),
    Header("Authorization", "Basic " <> token <> "-" <> token),
    Header("Connect-Protocol-Version", "1"),
    Header("Content-Type", "application/proto"),
    Header("Accept", "*/*"),
    Header("Content-Length", int.to_string(bit_array.byte_size(plan.body))),
  ])
  // Exact fields/order/values, no five-byte Connect frame.
  plan.body
  |> should.equal(
    pb.encode([
      pb.message(1, [
        pb.text(1, "chisel"),
        pb.text(2, "3000.10.21"),
        pb.text(3, token),
        pb.text(4, "en"),
        pb.text(5, "darwin"),
        pb.text(7, "3000.10.21"),
        pb.text(12, "chisel"),
        pb.text(31, fingerprint),
      ]),
    ]),
  )
}

pub fn f28_absent_quota_zero_quota_and_zero_reset_are_distinct_test() {
  let assert Ok(value) =
    status.decode(
      quota([
        pb.Varint(14, 0),
        pb.Varint(17, 0),
        pb.message(2, [pb.Varint(1, 0)]),
        pb.message(3, []),
      ]),
      1234,
    )
  value.daily_remaining_percent |> should.equal(Some(0))
  value.weekly_remaining_percent |> should.equal(None)
  value.daily_reset_seconds |> should.equal(None)
  value.weekly_reset_seconds |> should.equal(None)
  value.plan_start_seconds |> should.equal(None)
  value.plan_end_seconds |> should.equal(None)
  value.observed_at_ms |> should.equal(1234)
  let assert Ok(json) =
    ir.parse(observation.to_json(observation.from_status("selected", value)))
  ir.field(json, "daily_remaining_percent")
  |> should.equal(Some(ir.Integer(0)))
  ir.field(json, "weekly_remaining_percent") |> should.equal(Some(ir.Null))
}

pub fn f28_reset_values_are_exact_signed_int64_unix_seconds_test() {
  let assert Ok(value) =
    status.decode(
      quota([
        pb.Varint(17, 1),
        pb.Varint(18, 9_223_372_036_854_775_807),
        pb.message(2, [pb.Varint(1, 1_789_200_000), pb.Varint(2, 1)]),
      ]),
      9_999_999,
    )
  value.daily_reset_seconds |> should.equal(Some(1))
  value.weekly_reset_seconds |> should.equal(Some(9_223_372_036_854_775_807))
  value.plan_start_seconds |> should.equal(Some(1_789_200_000))
  list.each([17, 18], fn(tag) {
    list.each([9_223_372_036_854_775_808, 18_446_744_073_709_551_615], fn(n) {
      status.decode(quota([pb.Varint(tag, n)]), 1) |> should.be_error
    })
  })
  list.each([2, 3], fn(tag) {
    status.decode(
      quota([pb.message(tag, [pb.Varint(1, 18_446_744_073_709_551_615)])]),
      1,
    )
    |> should.be_error
  })
}

pub fn f28_invalid_percentages_duplicate_and_wrong_wire_fields_reject_test() {
  list.each([14, 15], fn(tag) {
    list.each([101, 18_446_744_073_709_551_615], fn(n) {
      status.decode(quota([pb.Varint(tag, n)]), 1) |> should.be_error
    })
  })
  list.each(
    [
      [pb.Varint(14, 1), pb.Varint(14, 2)],
      [pb.text(15, "synthetic")],
      [pb.message(2, [pb.Varint(1, 1), pb.Varint(1, 2)])],
      [pb.Varint(1, 1)],
    ],
    fn(fields) { status.decode(quota(fields), 1) |> should.be_error },
  )
  status.decode(pb.encode([pb.message(1, []), pb.message(1, [])]), 1)
  |> should.be_error
}

pub fn f28_unknown_extensions_are_skipped_private_text_is_not_projected_test() {
  let secret = "synthetic-reflected-credential"
  let assert Ok(value) =
    status.decode(
      pb.encode([
        pb.Varint(90, 123),
        pb.message(1, [
          pb.text(3, secret),
          pb.text(7, secret),
          pb.Fixed32(91, <<1, 2, 3, 4>>),
          pb.Fixed64(92, <<1, 2, 3, 4, 5, 6, 7, 8>>),
          pb.message(13, [
            pb.text(90, secret),
            pb.Varint(14, 7),
            pb.Varint(17, 123),
            pb.message(1, [
              pb.text(2, secret),
              pb.message(33, [pb.text(4, secret), pb.text(8, secret)]),
            ]),
          ]),
        ]),
      ]),
      10,
    )
  let output = observation.to_json(observation.from_status("selected", value))
  !string.contains(output, secret) |> should.be_true
  { string.byte_size(output) < 2048 } |> should.be_true
  value.daily_remaining_percent |> should.equal(Some(7))
  value.daily_reset_seconds |> should.equal(Some(123))
}

pub fn f28_invalid_body_and_request_inputs_are_safe_test() {
  list.each([<<>>, <<10, 20, 1>>, <<10, 3, 26, 1, 255>>], fn(bytes) {
    status.decode(bytes, 1) |> should.be_error
  })
  status.decode(quota([]), -1) |> should.be_error
  list.each(
    ["", "has spaces", "has\ttab", "has\rreturn", "has\nline", "nul\u{0000}"],
    fn(token) {
      status.request(
        "http://127.0.0.1:1234",
        token,
        string.repeat("a", 732),
        "linux",
      )
      |> should.equal(Error("Invalid Devin status request inputs"))
    },
  )
  // Byte count, not a character count.
  status.request(
    "http://127.0.0.1:1234",
    string.repeat("é", 8193),
    string.repeat("a", 732),
    "linux",
  )
  |> should.be_error
  list.each([0, 65_536], fn(port) {
    let origin = case port {
      0 -> "http://127.0.0.1:0"
      _ -> "http://127.0.0.1:65536"
    }
    status.request(origin, "synthetic", string.repeat("a", 732), "linux")
    |> should.equal(Error("Invalid Devin status origin"))
  })
}

pub fn f28_token_estimate_has_explicit_heuristic_labels_test() {
  auth.estimated_tokens("ééé") |> should.equal(1)
  tokens.estimate("abc") |> should.equal(tokens.Estimate(0, 3))
  let assert Ok(value) = ir.parse(observation.estimated_tokens("ééé"))
  ir.field(value, "estimated_input_tokens") |> should.equal(Some(ir.Integer(1)))
  ir.field(value, "payload_bytes") |> should.equal(Some(ir.Integer(6)))
  ir.field(value, "estimate") |> should.equal(Some(ir.Boolean(True)))
  ir.field(value, "exact") |> should.equal(Some(ir.Boolean(False)))
  ir.field(value, "method")
  |> should.equal(Some(ir.String("payload_utf8_bytes_div_4")))
  ir.field(value, "input_tokens") |> should.equal(None)
  tokens.exact_native_count("synthetic") |> should.be_error
}
