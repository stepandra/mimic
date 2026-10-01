/// Synthetic F10 decisions and actual transport/runtime sockets.
/// No real credentials, provider calls or production-root substitutions.
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/providers/claude/adapter
import mimic/providers/claude/rejection
import mimic/providers/claude/transport
import mimic/providers/contracts
import mimic/providers/registry
import mimic/providers/runtime
import mimic/quota
import mimic/types.{Header}

pub type Fixture

@external(erlang, "mimic_claude_f10_test_ffi", "start_script")
pub fn fixture(scripts: List(List(#(Int, BitArray)))) -> Fixture

@external(erlang, "mimic_claude_f10_test_ffi", "port")
pub fn port(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "requests")
pub fn requests(fixture: Fixture) -> List(String)

@external(erlang, "mimic_claude_f10_test_ffi", "closed")
pub fn closed(fixture: Fixture) -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "stop")
pub fn stop(fixture: Fixture) -> Nil

@external(erlang, "mimic_provider_runtime_test_ffi", "capture_logs")
pub fn capture_logs(action: fn() -> a) -> #(a, List(String))

@external(erlang, "mimic_claude_f10_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_auth_ffi", "now_ms")
pub fn wall_ms() -> Int

pub const model = "claude-opus-4-6"

pub const rate_body = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limit exceeded; synthetic-f10-private\"}}"

pub const credits_body = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Usage credits are required for fast mode; synthetic-f10-private\"}}"

const now = 1_700_000_000_000

const prefix = "anthropic-ratelimit-unified-"

fn json_headers(extra) {
  [Header("Content-Type", "application/json"), ..extra]
}

fn h(suffix, value) {
  Header(prefix <> suffix, value)
}

pub fn scope_precedence_and_healthy_windows_test() {
  let cases = [
    #([], rate_body, rejection.Unknown),
    #([Header("Retry-After", "120")], rate_body, rejection.Unknown),
    #([Header("Retry-After", "120")], credits_body, rejection.RequestScoped),
    #(
      [h("5h-status", "rejected")],
      rate_body,
      rejection.SharedQuota(60_000, ["5h"]),
    ),
    #(
      [h("7d-status", "rejected")],
      credits_body,
      rejection.SharedQuota(60_000, ["7d"]),
    ),
    #(
      [h("7d-status", "rejected")],
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Fast request rejected\"}}",
      rejection.SharedQuota(60_000, ["7d"]),
    ),
    #([h("status", " ReJeCtEd ")], rate_body, rejection.SharedQuota(60_000, [])),
    #([h("status", "rejected")], credits_body, rejection.Unknown),
    #(
      [h("status", "allowed"), h("5h-status", "rejected")],
      rate_body,
      rejection.Unknown,
    ),
    #(
      [h("status", "allowed_warning"), h("7d-status", "rejected")],
      credits_body,
      rejection.Unknown,
    ),
    #(
      [h("5h-status", "allowed"), h("7d-status", "allowed_warning")],
      rate_body,
      rejection.RequestScoped,
    ),
    #(
      [
        h("status", "rejected"),
        h("5h-status", "allowed"),
        h("7d-status", "allowed"),
      ],
      rate_body,
      rejection.Unknown,
    ),
    #(
      [
        h("status", "rejected"),
        h("5h-status", "allowed_warning"),
        h("7d-status", "allowed"),
        h("7d_oi-status", "rejected"),
      ],
      rate_body,
      rejection.RequestScoped,
    ),
    #(
      [
        h("status", "rejected"),
        h("7d-status", "allowed"),
        h("5h-utilization", "0.00"),
        h("overage-status", "rejected"),
      ],
      rate_body,
      rejection.RequestScoped,
    ),
    #(
      [
        h("status", "rejected"),
        h("5h-status", "allowed"),
        h("7d-utilization", "0.999999"),
        h("representative-claim", "seven_day_overage_included"),
      ],
      rate_body,
      rejection.RequestScoped,
    ),
    #(
      [
        h("status", "rejected"),
        h("7d-status", "allowed"),
        h("overage-disabled-reason", "org_spend_cap_reached"),
      ],
      rate_body,
      rejection.Unknown,
    ),
    #(
      [
        h("status", "rejected"),
        h("5h-status", "rejected"),
        h("7d-status", "allowed_warning"),
        h("7d_oi-status", "rejected"),
      ],
      rate_body,
      rejection.SharedQuota(60_000, ["5h"]),
    ),
  ]
  list.each(cases, fn(row) {
    rejection.classify(json_headers(row.0), row.1, now) |> should.equal(row.2)
  })
  list.each(["0", "0.50", "0.999999"], fn(utilization) {
    rejection.classify(
      json_headers([
        h("status", "rejected"),
        h("7d-status", "allowed"),
        h("5h-utilization", utilization),
        h("7d_oi-status", "rejected"),
      ]),
      rate_body,
      now,
    )
    |> should.equal(rejection.RequestScoped)
  })
  // No absent/malformed utilization becomes shared-quota replay permission.
  list.each(
    ["", "-0.1", "1.0", "1.05", "NaN", "+Inf", "-Inf", "invalid"],
    fn(raw) {
      let headers = case raw {
        "" -> []
        _ -> [h("5h-utilization", raw)]
      }
      rejection.classify(
        json_headers([
          h("status", "rejected"),
          h("7d-status", "allowed"),
          h("7d_oi-status", "rejected"),
          ..headers
        ]),
        rate_body,
        now,
      )
      |> should.equal(rejection.Unknown)
    },
  )
}

pub fn malformed_duplicate_and_unknown_evidence_never_qualifies_test() {
  list.each(
    [
      "", "{malformed", "[]", "{}", "{\"error\":\"rate_limit_error\"}",
      "{\"type\":\"message\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"}}",
      "{\"error\":{\"type\":\"unknown_error\",\"message\":\"Fast request rejected\"}}",
      "{\"error\":{\"type\":\"invalid_request_error\",\"message\":\"quota\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":10}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\",\"code\":\"unknown\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"},\"content\":[]}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"},\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"ty\\u0070e\":\"rate_limit_error\",\"message\":\"quota\"}}",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\",\"messa\\u0067e\":\"quota\"}}",
      "{\"type\":\"error\",\"ty\\u0070e\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"}}",
    ],
    fn(body) {
      rejection.classify(json_headers([h("7d-status", "rejected")]), body, now)
      |> should.equal(rejection.Unknown)
    },
  )
  let critical = [
    Header("Content-Type", "application/json"),
    Header("Content-Encoding", "identity"),
    Header("Content-Length", "123"),
    Header("Transfer-Encoding", "chunked"),
    Header("Retry-After", "120"),
    h("status", "rejected"),
    h("reset", "1700000120"),
    h("5h-status", "rejected"),
    h("5h-reset", "1700000120"),
    h("5h-utilization", "1.0"),
    h("7d-status", "rejected"),
    h("7d-reset", "1700000120"),
    h("7d-utilization", "1.0"),
    h("7d_oi-status", "rejected"),
    h("7d_oi-reset", "1700000120"),
    h("7d_oi-utilization", "1.02"),
    h("overage-status", "rejected"),
    h("overage-disabled-reason", "test_reason"),
    h("representative-claim", "seven_day"),
  ]
  list.each(critical, fn(header) {
    let headers = case string.lowercase(header.name) == "content-type" {
      True -> []
      False -> json_headers([])
    }
    rejection.classify(
      [
        header,
        Header(string.lowercase(header.name), header.value),
        h("7d-status", "rejected"),
        ..headers
      ],
      rate_body,
      now,
    )
    |> should.equal(rejection.Unknown)
  })
  list.each(
    ["unknown", "rejected,allowed", "", "rejected\u{0009}", "rejécted"],
    fn(status) {
      rejection.classify(json_headers([h("7d-status", status)]), rate_body, now)
      |> should.equal(rejection.Unknown)
    },
  )
}

pub fn media_and_encoding_reuse_f08_gate_test() {
  list.each(
    [
      "application/json",
      "Application/Problem+JSON; charset=UTF-8",
      "application/vnd.synthetic+json",
    ],
    fn(media) {
      rejection.classify(
        [Header("Content-Type", media), h("7d-status", "rejected")],
        rate_body,
        now,
      )
      |> should.equal(rejection.SharedQuota(60_000, ["7d"]))
    },
  )
  list.each(
    [
      "application/json, application/problem+json",
      "application/json,application/json", "application/bad/subtype+json",
      "application/+json", "application/json; charset=utf-16",
      "application/json; charset=utf-8; charset=utf-8", "text/event-stream",
      "text/html", "application/json; x=1", "application/json\u{00a0}",
    ],
    fn(media) {
      rejection.classify(
        [Header("Content-Type", media), h("7d-status", "rejected")],
        rate_body,
        now,
      )
      |> should.equal(rejection.Unknown)
    },
  )
  rejection.classify([h("7d-status", "rejected")], rate_body, now)
  |> should.equal(rejection.Unknown)
  list.each(["gzip", "br", "identity,identity", ""], fn(encoding) {
    rejection.classify(
      json_headers([
        Header("Content-Encoding", encoding),
        h("7d-status", "rejected"),
      ]),
      rate_body,
      now,
    )
    |> should.equal(rejection.Unknown)
  })
  rejection.classify(
    json_headers([
      Header("Content-Encoding", "identity"),
      h("7d-status", "rejected"),
    ]),
    rate_body,
    now,
  )
  |> should.equal(rejection.SharedQuota(60_000, ["7d"]))
}

pub fn retry_after_units_limits_and_latest_applicable_reset_test() {
  list.each(
    [
      #("120", 120_000),
      #("120.001", 121_000),
      #("0", 60_000),
      #("1.5", 60_000),
      #("604800", rejection.max_retry_ms),
      #("Tue, 14 Nov 2023 22:15:20 GMT", 120_000),
      #("2023-11-14T22:15:20Z", 120_000),
      #("Tue, 14 Nov 2023 22:12:20 GMT", 60_000),
    ],
    fn(row) {
      rejection.classify(
        json_headers([Header("Retry-After", row.0), h("7d-status", "rejected")]),
        rate_body,
        now,
      )
      |> should.equal(rejection.SharedQuota(row.1, ["7d"]))
    },
  )
  list.each(
    [
      "-1",
      "+120",
      "1e2",
      "NaN",
      "Infinity",
      "120.0001",
      "604801",
      "9999999999999999999999999",
      "120,180",
      "not-a-date",
    ],
    fn(raw) {
      rejection.classify(
        json_headers([Header("Retry-After", raw), h("7d-status", "rejected")]),
        rate_body,
        now,
      )
      |> should.equal(rejection.Unknown)
    },
  )
  rejection.classify(
    json_headers([
      Header("Retry-After-ms", "120000"),
      h("7d-status", "rejected"),
    ]),
    rate_body,
    now,
  )
  |> should.equal(rejection.Unknown)
  list.each(
    [
      "1700000300",
      "1700000300.001",
      "2023-11-14T22:18:20Z",
      "Tue, 14 Nov 2023 22:18:20 GMT",
    ],
    fn(reset) {
      let expected = case reset {
        "1700000300.001" -> 301_000
        _ -> 300_000
      }
      rejection.classify(
        json_headers([
          Header("Retry-After", "120"),
          h("5h-status", "rejected"),
          h("5h-reset", reset),
          h("7d-status", "allowed"),
          h("7d-reset", "1700604800"),
        ]),
        rate_body,
        now,
      )
      |> should.equal(rejection.SharedQuota(expected, ["5h"]))
    },
  )
  rejection.classify(
    json_headers([
      h("5h-status", "rejected"),
      h("5h-reset", "1700000120"),
      h("7d-status", "rejected"),
      h("7d-reset", "1700000300"),
      h("reset", "1700000250"),
    ]),
    rate_body,
    now,
  )
  |> should.equal(rejection.SharedQuota(300_000, ["5h", "7d"]))
  rejection.classify(
    json_headers([
      h("5h-status", "rejected"),
      h("5h-reset", "1700000120"),
      h("7d_oi-status", "rejected"),
      h("7d_oi-reset", "1700000300"),
    ]),
    rate_body,
    now,
  )
  |> should.equal(rejection.SharedQuota(300_000, ["5h"]))
  list.each(
    ["1700604801", "1700000300000", "-1", "NaN", "not-a-date"],
    fn(reset) {
      rejection.classify(
        json_headers([h("7d-status", "rejected"), h("7d-reset", reset)]),
        rate_body,
        now,
      )
      |> should.equal(rejection.Unknown)
    },
  )
  rejection.classify(
    json_headers([h("7d-status", "rejected"), h("7d-reset", "1699999999")]),
    rate_body,
    now,
  )
  |> should.equal(rejection.SharedQuota(60_000, ["7d"]))
}

fn timing_fields() {
  [
    "Retry-After",
    prefix <> "reset",
    prefix <> "5h-reset",
    prefix <> "7d-reset",
    prefix <> "7d_oi-reset",
  ]
}

pub fn timing_dates_require_complete_valid_components_test() {
  // Source-derived synthetic admission cases, NOT execution evidence for CPA.
  list.each(
    [
      "Tue, 14 Nov 2023 22:15:20 GMTjunk",
      "Tue, 14 Nov 2023 22:15:20 GMT, 120",
      "Tuesday, 14-Nov-23 22:15:20 GMTjunk",
      "Tue Nov 14 22:15:20 2023junk",
      "2023-11-14T22:15:20Zjunk",
      "2023-11-14T22:15:20Z, 120",
      "Tue, 14 Nov 2023 22:15:20",
      "Tue, 14 Nov 2023 22:15:20 UTC",
      "Tue, 14 Nov 2023 22:15:20 +0000",
      "Xxx, 14 Nov 2023 22:15:20 GMT",
      "Tue, 14 Xxx 2023 22:15:20 GMT",
      "Tuesday, 14/Nov/23 22:15:20 GMT",
      "Tue, 00 Nov 2023 22:15:20 GMT",
      "Tue, 31 Nov 2023 22:15:20 GMT",
      "Tue, 29 Feb 2023 22:15:20 GMT",
      "Tue, 29 Feb 2100 22:15:20 GMT",
      "Tue, 14 Nov 2023 24:15:20 GMT",
      "Tue, 14 Nov 2023 22:60:20 GMT",
      "Tue, 14 Nov 2023 22:15:99 GMT",
      "Tuesday, 31-Nov-23 22:15:20 GMT",
      "Tue Nov 31 22:15:20 2023",
      "Tue Nov 14 22:15:99 2023",
      "2023-00-14T22:15:20Z",
      "2023-13-14T22:15:20Z",
      "2023-11-00T22:15:20Z",
      "2023-11-31T22:15:20Z",
      "2023-02-29T22:15:20Z",
      "2100-02-29T22:15:20Z",
      "2023-11-14T24:15:20Z",
      "2023-11-14T22:60:20Z",
      "2023-11-14T22:15:99Z",
      "2016-12-31T23:59:60Z",
      "2023-11-14T23:59:60Z",
      "Tue, 14 Nov 2023 23:59:60 GMT",
      "2023-11-14X22:15:20Z",
      "2023-11-14T22:15:20+24:00",
      "2023-11-14T22:15:20+00:60",
      "2023-11-14T22:15:20+0130",
      "2023-11-14T22:15:20+01:3",
      "2023-11-14T22:15:20",
      "2023-11-14T22:15:20.Z",
      "2023-11-14T22:15:20.1.2Z",
      "2023-11-14T22:15:20,123Z",
      "\u{000b}Tue, 14 Nov 2023 22:15:20 GMT",
      "2023-11-14T22:15:20Z\u{000d}",
      string.repeat("1", 257),
      "2023-11-14T22:15:20." <> string.repeat("0", 236) <> "Z",
    ],
    fn(raw) {
      list.each(timing_fields(), fn(name) {
        let headers =
          json_headers([Header(name, raw), h("7d-status", "rejected")])
        io.println(
          "F10 invalid timing: " <> name <> " = " <> string.inspect(raw),
        )
        rejection.classify(
          headers,
          "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"quota\"}}",
          now,
        )
        |> should.equal(rejection.Unknown)
        rejection.admissible_headers(headers) |> should.be_false
      })
    },
  )
}

pub fn timing_dates_preserve_supported_forms_and_boundaries_test() {
  list.each(
    [
      #("Tue, 14 Nov 2023 22:15:20 GMT", now, 120_000),
      #(" Tue, 14 Nov 2023 22:15:20 GMT ", now, 120_000),
      #("Tuesday, 14-Nov-23 22:15:20 GMT", now, 120_000),
      #("Tue Nov 14 22:15:20 2023", now, 120_000),
      #("Sun Nov  5 22:15:20 2023", 1_699_222_400_000, 120_000),
      #("2023-11-14T22:15:20Z", now, 120_000),
      #("2023-11-14t22:15:20z", now, 120_000),
      #("2023-11-14 22:15:20Z", now, 120_000),
      #("2023-11-14T23:45:20+01:30", now, 120_000),
      #("2023-11-14T20:45:20-01:30", now, 120_000),
      #("2023-11-14T22:15:20-00:00", now, 120_000),
      #("2023-11-14T22:15:20+00:00", now, 120_000),
      #("2023-11-14T22:15:20.1Z", now, 121_000),
      #("2023-11-14T22:15:20.001Z", now, 121_000),
      #("2023-11-14T22:15:20.0009Z", now, 121_000),
      #("2023-11-14T22:15:20.123456789012Z", now, 121_000),
      #("2023-11-14T23:45:20.123+01:30", now, 121_000),
      #("2023-11-14T22:15:20." <> string.repeat("0", 235) <> "Z", now, 120_000),
      #("Thu, 29 Feb 2024 00:00:00 GMT", 1_709_164_680_000, 120_000),
      #("2024-02-29T00:00:00Z", 1_709_164_680_000, 120_000),
      #("2000-02-29T00:00:00Z", 951_782_280_000, 120_000),
      #("2023-11-14T23:59:59Z", 1_700_006_279_000, 120_000),
      #("2016-12-31T23:59:59Z", 1_483_228_679_000, 120_000),
      #("2023-11-14T22:15:20+23:59", 1_699_913_660_000, 120_000),
      #("2023-11-14T22:15:20-23:59", 1_700_086_340_000, 120_000),
      #("1970-01-01T00:00:01Z", 0, 60_000),
      #("9999-12-31T23:59:59Z", 253_402_300_679_000, 120_000),
      #("2023-11-14T22:15:20Z", now + 200_000, 60_000),
    ],
    fn(row) {
      list.each(timing_fields(), fn(name) {
        let headers =
          json_headers([
            Header(name, row.0),
            h("5h-status", "rejected"),
            h("7d-status", "rejected"),
            h("7d_oi-status", "rejected"),
          ])
        rejection.admissible_headers(headers) |> should.be_true
        rejection.classify(headers, rate_body, row.1)
        |> should.equal(rejection.SharedQuota(row.2, ["5h", "7d"]))
      })
    },
  )
  // Epoch bounds are still checked AFTER grammar and component validity.
  list.each(["1970-01-01T00:00:00Z", "9999-12-31T23:59:59-00:01"], fn(raw) {
    rejection.classify(
      json_headers([Header("Retry-After", raw), h("7d-status", "rejected")]),
      rate_body,
      now,
    )
    |> should.equal(rejection.Unknown)
  })
}

pub fn json_byte_depth_value_and_message_budgets_test() {
  let padded =
    rate_body
    <> string.repeat(
      " ",
      rejection.max_body_bytes - string.byte_size(rate_body),
    )
  let headers = json_headers([h("7d-status", "rejected")])
  rejection.classify(headers, padded, now)
  |> should.equal(rejection.SharedQuota(60_000, ["7d"]))
  list.each(
    [
      padded <> " ",
      "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\""
        <> string.repeat("x", 16_385)
        <> "\"}}",
      string.repeat("[", 33) <> "0" <> string.repeat("]", 33),
      "[" <> string.join(list.repeat("0", 4097), ",") <> "]",
    ],
    fn(body) {
      rejection.classify(headers, body, now) |> should.equal(rejection.Unknown)
    },
  )
}

pub fn wire(status: Int, headers: String, body: String) -> BitArray {
  bit_array.from_string(
    "HTTP/1.1 "
    <> int.to_string(status)
    <> " Synthetic\r\nContent-Length: "
    <> int.to_string(string.byte_size(body))
    <> "\r\n"
    <> headers
    <> "\r\n"
    <> body,
  )
}

pub fn part(delay: Int, raw: String) -> #(Int, BitArray) {
  #(delay, bit_array.from_string(raw))
}

pub fn origin(upstream: Fixture) -> String {
  "http://127.0.0.1:" <> int.to_string(port(upstream))
}

pub fn await(predicate: fn() -> Bool, remaining: Int) {
  case predicate(), remaining {
    True, _ -> Nil
    False, 0 -> should.fail()
    False, _ -> {
      process.sleep(5)
      await(predicate, remaining - 1)
    }
  }
}

pub fn no_secrets(source: String) {
  list.each(
    [
      "synthetic-key-a", "synthetic-key-b", "synthetic-access-a",
      "synthetic-access-b", "synthetic-refresh-a", "synthetic-refresh-b",
      "synthetic-f10-private", "synthetic-f10-client-body",
      "synthetic-f10-client-key-123456789",
    ],
    fn(marker) { string.contains(source, marker) |> should.be_false },
  )
}

pub fn seed(store: storage.Store, mode: String, id: String) {
  let material = case mode {
    "oauth" ->
      contracts.OAuth(
        contracts.OAuthData(
          auth.Credential(
            "synthetic-access-" <> id,
            "synthetic-refresh-" <> id,
            9_000_000_000_000,
          ),
          [
            #("device_id", string.repeat("a", 64)),
            #("account_uuid", "synthetic-account-" <> id),
          ],
        ),
      )
    _ -> contracts.ApiKey("synthetic-key-" <> id)
  }
  runtime_store.save(store, credentials.key("claude", mode, id), material)
  |> should.be_ok
}

fn request(mode: String) -> contracts.Request {
  contracts.Request(
    "claude",
    mode,
    model,
    "messages",
    "messages",
    contracts.Buffered,
    [],
    "synthetic-f10-session",
    None,
    "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic-f10-client-body\"}],\"max_tokens\":16,\"speed\":\"fast\"}",
  )
}

pub fn closed_quota_handle_and_original_success_handle_test() {
  let upstream =
    fixture([
      [
        #(
          0,
          wire(
            429,
            "Content-Type: application/json\r\nRetry-After: 120.001\r\nanthropic-ratelimit-unified-7d-status: rejected\r\nX-Private: synthetic-f10-private\r\n",
            rate_body,
          ),
        ),
      ],
      [#(0, wire(201, "Content-Type: application/json\r\n", "{}"))],
    ])
  let provider = transport.http_classified(adapter.prepare, None)
  let context =
    contracts.Context(
      "claude",
      "api_key",
      "a",
      origin(upstream),
      "synthetic-session",
      contracts.ApiKey("synthetic-key-a"),
    )
  let assert Ok(rejected) = provider.open(context, request("api_key"))
  rejected.status |> should.equal(429)
  rejected.headers
  |> should.equal([
    Header("Retry-After", "121"),
    h("7d-status", "rejected"),
  ])
  provider.rejection(rejected.status, rejected.headers)
  |> should.equal(
    Some(contracts.Failure(contracts.Quota, contracts.Rejected, Some(121_000))),
  )
  provider.next(rejected.handle) |> should.equal(Ok(None))
  provider.cancel(rejected.handle)
  provider.cancel(rejected.handle)
  await(fn() { closed(upstream) == 1 }, 200)
  let assert Ok(success) = provider.open(context, request("api_key"))
  success.status |> should.equal(201)
  closed(upstream) |> should.equal(1)
  let assert Ok(Some(#(body, final))) = provider.next(success.handle)
  body |> should.equal(bit_array.from_string("{}"))
  provider.next(final) |> should.equal(Ok(None))
  closed(upstream) |> should.equal(1)
  provider.cancel(final)
  await(fn() { closed(upstream) == 2 }, 200)
  requests(upstream) |> list.length |> should.equal(2)
  stop(upstream)
}

fn engine(store, mode, first, second) {
  let assert Ok(models) =
    registry.new([
      registry.Model("claude", model, [mode], ["messages"], ["messages"], [
        contracts.Buffer,
        contracts.Stream,
      ]),
    ])
  let policy = case mode {
    "oauth" ->
      credentials.Refreshable(
        contracts.Refresh(fn(_, _) {
          panic as "Fresh synthetic OAuth material must not refresh"
        }),
      )
    _ -> credentials.StaticKey
  }
  let assert Ok(engine) =
    runtime.start(store, models, [
      runtime.Account(
        "claude",
        mode,
        "a",
        origin(first),
        fleet.LocalLoopback,
        1,
        [model],
        policy,
      ),
      runtime.Account(
        "claude",
        mode,
        "b",
        origin(second),
        fleet.LocalLoopback,
        1,
        [model],
        policy,
      ),
    ])
  engine
}

pub fn runtime_two_accounts_skip_observe_or_bounded_failover_test() {
  let #(_, logs) =
    capture_logs(fn() {
      list.each(["api_key", "oauth"], fn(mode) {
        list.each(
          [
            "credits",
            "unknown",
            "quota",
            "exhausted",
            "stalled",
            "truncated",
            "oversized",
            "events",
            "drip",
          ],
          fn(kind) { runtime_case(mode, kind) },
        )
      })
    })
  no_secrets(string.join(logs, "\n"))
}

fn runtime_case(mode, kind) {
  let quota_headers =
    "Content-Type: application/json\r\nRetry-After: 120\r\nanthropic-ratelimit-unified-7d-status: rejected\r\nX-Private: synthetic-f10-private\r\n"
  runtime_case_with_headers(mode, kind, quota_headers)
}

pub fn invalid_timing_two_accounts_never_observes_or_replays_test() {
  let #(_, logs) =
    capture_logs(fn() {
      list.each(["api_key", "oauth"], fn(mode) {
        list.each(
          [
            "Retry-After: Tue, 14 Nov 2023 22:15:20 GMTjunk\r\n",
            "Retry-After: Tue, 14 Nov 2023 22:15:20 GMT, 120\r\n",
            "Retry-After: Tue, 14 Nov 2023 22:15:99 GMT\r\n",
            "Retry-After: 2023-02-29T22:15:20Z\r\n",
            "Retry-After: 2023-11-14T22:15:20+24:00\r\n",
            // Admission validates even a reset whose healthy window is ignored.
            "Retry-After: 120\r\nanthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-5h-reset: Tue, 14 Nov 2023 22:15:20 GMTjunk\r\n",
          ],
          fn(timing) {
            io.println(
              "F10 two-account invalid timing: "
              <> mode
              <> " "
              <> string.inspect(timing),
            )
            runtime_case_with_headers(
              mode,
              "invalid-timing",
              "Content-Type: application/json\r\nanthropic-ratelimit-unified-7d-status: rejected\r\n"
                <> timing,
            )
          },
        )
      })
    })
  no_secrets(string.join(logs, "\n"))
}

fn runtime_case_with_headers(mode, kind, quota_headers) {
  let success = wire(200, "Content-Type: application/json\r\n", "{}")
  let rejecting = case kind {
    "credits" -> [
      #(
        0,
        wire(
          429,
          "Content-Type: application/json\r\nRetry-After: 120\r\n",
          credits_body,
        ),
      ),
    ]
    "unknown" -> [
      #(
        0,
        wire(
          429,
          quota_headers,
          "{\"error\":{\"type\":\"unknown_error\",\"message\":\"synthetic-f10-private\"}}",
        ),
      ),
    ]
    "stalled" -> [
      part(
        0,
        "HTTP/1.1 429 Synthetic\r\n"
          <> quota_headers
          <> "Content-Length: 100\r\n\r\n",
      ),
    ]
    "truncated" -> [
      part(
        0,
        "HTTP/1.1 429 Synthetic\r\n"
          <> quota_headers
          <> "Content-Length: 100\r\n\r\n{}",
      ),
      part(-1, ""),
    ]
    "oversized" -> [#(0, wire(429, quota_headers, string.repeat("x", 100_000)))]
    "events" -> [
      part(
        0,
        "HTTP/1.1 429 Synthetic\r\n"
          <> quota_headers
          <> "Transfer-Encoding: chunked\r\n\r\n",
      ),
      part(0, string.repeat("1\r\n \r\n", 33) <> "0\r\n\r\n"),
    ]
    "drip" -> [
      part(
        0,
        "HTTP/1.1 429 Synthetic\r\n"
          <> quota_headers
          <> "Transfer-Encoding: chunked\r\n\r\n",
      ),
      ..list.repeat(part(90, "1\r\n \r\n"), 10)
    ]
    _ -> [#(0, wire(429, quota_headers, rate_body))]
  }
  let first = fixture([rejecting, [#(0, success)]])
  let second_response = case kind {
    "exhausted" -> wire(429, quota_headers, rate_body)
    _ -> success
  }
  let second = fixture([[#(0, second_response)]])
  let assert Ok(store) = storage.new(directory())
  seed(store, mode, "a")
  seed(store, mode, "b")
  quota.save(store, quota.empty()) |> should.be_ok
  let ledger_before = storage.read_quota_ledger(store)
  let engine = engine(store, mode, first, second)
  let provider = transport.http_classified(adapter.prepare, None)
  let before = monotonic_ms()
  let outcome = runtime.execute(engine, provider, request(mode))
  { monotonic_ms() - before < 1300 } |> should.be_true
  case kind {
    "invalid-timing" -> {
      io.println(
        "F10 actual HTTP result: "
        <> case outcome {
          Ok(response) -> "Ok account=" <> response.account
          Error(error) -> string.inspect(error)
        }
        <> " A sends="
        <> int.to_string(list.length(requests(first)))
        <> " B sends="
        <> int.to_string(list.length(requests(second)))
        <> " ledger unchanged="
        <> string.inspect(storage.read_quota_ledger(store) == ledger_before),
      )
      // Byte equality proves no Observe, not just absence of future cooldown.
      storage.read_quota_ledger(store) |> should.equal(ledger_before)
      requests(second) |> should.equal([])
    }
    _ -> Nil
  }
  case kind, outcome {
    "quota", Ok(response) -> response.account |> should.equal("b")
    "credits", Error(error) -> {
      error
      |> should.equal(contracts.Failure(
        contracts.RequestLimited,
        contracts.Rejected,
        None,
      ))
      runtime.retryable(error) |> should.be_false
    }
    "exhausted", Error(error) ->
      error
      |> should.equal(contracts.Failure(
        contracts.Quota,
        contracts.Rejected,
        Some(120_000),
      ))
    _, Error(error) -> runtime.retryable(error) |> should.be_false
    _, _ -> should.fail()
  }
  let penalized = kind == "quota" || kind == "exhausted"
  requests(first) |> list.length |> should.equal(1)
  requests(second)
  |> list.length
  |> should.equal(case penalized {
    True -> 1
    False -> 0
  })
  runtime.active_leases(engine) |> should.equal(Ok(0))
  await(fn() { closed(first) == 1 }, 300)
  case penalized {
    True -> {
      let assert Ok(ledger) = quota.load(store)
      let key = credentials.key("claude", mode, "a")
      { quota.cooldown_until(ledger, key) > wall_ms() + 110_000 }
      |> should.be_true
      no_secrets(storage.read_quota_ledger(store) |> should.be_ok)
    }
    False -> {
      storage.read_quota_ledger(store) |> should.equal(ledger_before)
      let ordinary =
        contracts.Request(
          ..request(mode),
          pinned_account: Some("a"),
          body: "{\"model\":\"claude-opus-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic ordinary request\"}],\"max_tokens\":16}",
        )
      let assert Ok(response) = runtime.execute(engine, provider, ordinary)
      response.account |> should.equal("a")
      runtime.active_leases(engine) |> should.equal(Ok(0))
      await(fn() { closed(first) == 2 }, 200)
    }
  }
  runtime.stop(engine) |> should.be_ok
  stop(first)
  stop(second)
}

pub fn raw_header_wire_controls_and_non_ascii_cannot_qualify_test() {
  list.each(
    [
      "Content-Type: \u{000b}application/json\r\nanthropic-ratelimit-unified-7d-status: rejected\r\n",
      "Content-Type: \u{200e}application/json\r\nanthropic-ratelimit-unified-7d-status: rejected\r\n",
      "Content-Type: application/json\r\nanthropic-ratelimit-unified-7d-status: \u{200e}rejected\r\n",
      "Content-Type: application/json\r\nanthropic-ratelimit-unified-7d-status: rejected\r\nRetry-After: \u{000b}120\r\n",
      "Content-Type: application/json\r\nanthropic-ratelimit-unified-7d-status: rejected\r\nRetry-After: \u{200e}120\r\n",
    ],
    fn(headers) {
      let upstream = fixture([[#(0, wire(429, headers, rate_body))]])
      let provider = transport.http_classified(adapter.prepare, None)
      let context =
        contracts.Context(
          "claude",
          "api_key",
          "a",
          origin(upstream),
          "synthetic-session",
          contracts.ApiKey("synthetic-key-a"),
        )
      let denied = case provider.open(context, request("api_key")) {
        Error(error) -> !runtime.retryable(error)
        Ok(opened) -> {
          provider.cancel(opened.handle)
          False
        }
      }
      denied |> should.be_true
      await(fn() { closed(upstream) == 1 }, 200)
      requests(upstream) |> list.length |> should.equal(1)
      stop(upstream)
    },
  )
  // HTTP OWS is only SP/HTAB. Both valid edge forms still qualify.
  list.each([" ", "\t "], fn(ows) {
    let upstream =
      fixture([
        [
          #(
            0,
            wire(
              429,
              "Content-Type:"
                <> ows
                <> "application/json"
                <> ows
                <> "\r\nanthropic-ratelimit-unified-7d-status:"
                <> ows
                <> "rejected"
                <> ows
                <> "\r\n",
              rate_body,
            ),
          ),
        ],
      ])
    let provider = transport.http_classified(adapter.prepare, None)
    let context =
      contracts.Context(
        "claude",
        "api_key",
        "a",
        origin(upstream),
        "synthetic-session",
        contracts.ApiKey("synthetic-key-a"),
      )
    let assert Ok(opened) = provider.open(context, request("api_key"))
    opened.status |> should.equal(429)
    provider.rejection(opened.status, opened.headers)
    |> should.equal(
      Some(contracts.Failure(contracts.Quota, contracts.Rejected, Some(60_000))),
    )
    provider.cancel(opened.handle)
    await(fn() { closed(upstream) == 1 }, 200)
    stop(upstream)
  })
}

pub fn main() {
  timing_dates_require_complete_valid_components_test()
  timing_dates_preserve_supported_forms_and_boundaries_test()
  invalid_timing_two_accounts_never_observes_or_replays_test()
  raw_header_wire_controls_and_non_ascii_cannot_qualify_test()
  scope_precedence_and_healthy_windows_test()
  malformed_duplicate_and_unknown_evidence_never_qualifies_test()
  media_and_encoding_reuse_f08_gate_test()
  retry_after_units_limits_and_latest_applicable_reset_test()
  json_byte_depth_value_and_message_budgets_test()
  closed_quota_handle_and_original_success_handle_test()
  runtime_two_accounts_skip_observe_or_bounded_failover_test()
  io.println(
    "PASS: F10 complete timing admission, raw headers, strict classifier and two-account transport/runtime (11 tests)",
  )
}
