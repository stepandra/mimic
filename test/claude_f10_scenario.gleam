/// Actual gateway.start, two actual synthetic accounts, real loopback sockets.
/// main is DEFAULT-OFF evidence only. coordinator must receive the ACTUAL
/// gateway.active_leases function after the coordinator-owned root patch.
import argv
import claude_f10_test as f10
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/storage
import mimic/egress
import mimic/gateway
import mimic/gateway/config
import mimic/providers/claude/rejection
import mimic/quota
import mimic/types.{type WireResponse, Capture, Header, Transport}

@external(erlang, "mimic_claude_f10_test_ffi", "directory")
fn directory() -> String

@external(erlang, "mimic_claude_f10_test_ffi", "private_file")
fn private_file(directory: String, name: String, contents: String) -> String

@external(erlang, "mimic_claude_f10_test_ffi", "fresh_vm")
fn fresh_vm_request(
  config_path: String,
  operation: String,
  streaming: Bool,
  expected_status: Int,
) -> #(Int, String)

@external(erlang, "mimic_egress_ffi", "now_ms")
fn monotonic_ms() -> Int

@external(erlang, "mimic_claude_f10_test_ffi", "with_cli")
fn with_cli(
  executable: String,
  args: List(String),
  action: fn() -> Nil,
) -> #(Bool, Int, String)

const client = "synthetic-f10-client-key-123456789"

const media = "Content-Type: application/json\r\n"

const shared = "anthropic-ratelimit-unified-7d-status: rejected\r\n"

const aggregate = "anthropic-ratelimit-unified-status: rejected\r\n"

const retry = "Retry-After: 120.001\r\n"

const private_header = "X-Private: synthetic-f10-private\r\n"

type Case {
  Case(name: String, script: List(#(Int, BitArray)), quota_seconds: Option(Int))
}

type Diagnostic =
  fn(gateway.Server) -> Result(Int, String)

pub fn main() {
  case argv.load().arguments {
    ["--focused-baseline"] -> focused(False, None)
    ["--focused-classified"] -> focused(True, None)
    ["--cli-focused-baseline", executable, ..prefix] ->
      cli_focused(executable, prefix, False)
    ["--cli-focused-classified", executable, ..prefix] ->
      cli_focused(executable, prefix, True)
    ["--cli-baseline", executable, ..prefix] ->
      cli_matrix(executable, prefix, False)
    ["--cli-classified", executable, ..prefix] ->
      cli_matrix(executable, prefix, True)
    ["--expect-classified"] -> {
      // A deliberate RED control before the root patch. Even if this later
      // passes, it is NOT zero-lease admission; use coordinator(actual query).
      matrix(True, None)
      io.println(
        "PASS: configured route outcomes ONLY; root diagnostic unverified",
      )
    }
    _ -> {
      matrix(False, None)
      io.println(
        "PASS: F10 actual two-account default-conservative gateway matrix; root lease diagnostic unverified",
      )
    }
  }
}

/// Invoke only with `gateway.active_leases`, never an always-zero stand-in.
/// No adapter/handler is injected; config.decode and gateway.start are actual.
pub fn coordinator(query: Diagnostic) {
  matrix(True, Some(query))
  io.println(
    "PASS: F10 actual configured two-account gateway matrix + actual lease query",
  )
}

/// Smaller source/root smoke gate; full `coordinator` remains the admission gate.
pub fn focused_coordinator(query: Diagnostic) {
  focused(True, Some(query))
}

fn focused(classified: Bool, diagnostic: Option(Diagnostic)) {
  let rows =
    list.filter(cases(), fn(row) {
      list.contains(
        [
          "credits-retry-only", "unknown-code", "http-date-suffix",
          "shared-quota",
        ],
        row.name,
      )
    })
  let #(_, logs) =
    f10.capture_logs(fn() {
      list.each(["api_key", "oauth"], fn(mode) {
        list.each(
          [
            #("messages", False),
            #("messages", True),
            #("messages/count_tokens", False),
          ],
          fn(route) {
            list.each(rows, fn(row) {
              run_case(
                mode,
                route.0,
                route.1,
                row,
                Some(classified),
                False,
                diagnostic,
              )
              case classified && row.quota_seconds != None {
                True ->
                  run_case(
                    mode,
                    route.0,
                    route.1,
                    row,
                    Some(True),
                    True,
                    diagnostic,
                  )
                False -> Nil
              }
            })
            run_case(
              mode,
              route.0,
              route.1,
              list.last(rows) |> should.be_ok,
              None,
              False,
              diagnostic,
            )
          },
        )
      })
    })
  f10.no_secrets(string.join(logs, "\n"))
  io.println(
    "PASS: F10 focused configured gateway outcomes; lease query verified only when supplied",
  )
}

fn matrix(classified: Bool, diagnostic: Option(Diagnostic)) {
  let #(_, logs) =
    f10.capture_logs(fn() {
      list.each(["api_key", "oauth"], fn(mode) {
        list.each(
          [
            #("messages", False),
            #("messages", True),
            #("messages/count_tokens", False),
          ],
          fn(route) {
            list.each(cases(), fn(case_) {
              run_case(
                mode,
                route.0,
                route.1,
                case_,
                Some(classified),
                False,
                diagnostic,
              )
              case classified && case_.quota_seconds != None {
                True ->
                  run_case(
                    mode,
                    route.0,
                    route.1,
                    case_,
                    Some(True),
                    True,
                    diagnostic,
                  )
                False -> Nil
              }
            })
            // Omitted flag is also conservative, including under opt-in testing.
            run_case(
              mode,
              route.0,
              route.1,
              list.last(cases()) |> should.be_ok,
              None,
              False,
              diagnostic,
            )
          },
        )
      })
    })
  f10.no_secrets(string.join(logs, "\n"))
}

fn case_(name, headers, body, quota_seconds) {
  Case(
    name,
    [#(0, f10.wire(429, headers <> private_header, body))],
    quota_seconds,
  )
}

fn cases() {
  let headers = media <> retry <> shared
  let chunked =
    "HTTP/1.1 429 Synthetic\r\n"
    <> media
    <> shared
    <> private_header
    <> "Transfer-Encoding: chunked\r\n\r\n"
  let binary_head =
    bit_array.from_string(
      "HTTP/1.1 429 Synthetic\r\n" <> headers <> "Content-Length: 1\r\n\r\n",
    )
  [
    case_("credits-retry-only", media <> retry, f10.credits_body, None),
    case_("ordinary-no-scope", media, f10.rate_body, None),
    case_(
      "unknown-code",
      headers,
      "{\"error\":{\"type\":\"unknown_error\",\"message\":\"synthetic-f10-private\"}}",
      None,
    ),
    case_("malformed-json", headers, "{synthetic-f10-private", None),
    case_(
      "escaped-duplicate-json",
      headers,
      "{\"error\":{\"type\":\"rate_limit_error\",\"ty\\u0070e\":\"rate_limit_error\",\"message\":\"synthetic-f10-private\"}}",
      None,
    ),
    case_(
      "duplicate-scope-header",
      headers <> "Anthropic-Ratelimit-Unified-7d-Status: rejected\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "contradictory-shared",
      headers <> "anthropic-ratelimit-unified-status: allowed\r\n",
      f10.credits_body,
      None,
    ),
    case_(
      "model-only",
      media
        <> retry
        <> "anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-7d-status: allowed_warning\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "fable-only",
      media
        <> retry
        <> aggregate
        <> "anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-7d_oi-status: rejected\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "overage-healthy-omitted-window",
      media
        <> retry
        <> aggregate
        <> "anthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 0\r\nanthropic-ratelimit-unified-overage-status: rejected\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "overage-ambiguous-window",
      media
        <> retry
        <> aggregate
        <> "anthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 1.0\r\nanthropic-ratelimit-unified-overage-status: rejected\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "aggregate-fast-contradiction",
      media <> retry <> aggregate,
      f10.credits_body,
      None,
    ),
    case_(
      "comma-media",
      "Content-Type: application/json,application/problem+json\r\n"
        <> retry
        <> shared,
      f10.rate_body,
      None,
    ),
    case_(
      "raw-vt-media",
      "Content-Type: \u{000b}application/json\r\n" <> retry <> shared,
      f10.rate_body,
      None,
    ),
    case_(
      "raw-unicode-scope",
      media
        <> retry
        <> "anthropic-ratelimit-unified-7d-status: \u{200e}rejected\r\n",
      f10.rate_body,
      None,
    ),
    case_("gzip", headers <> "Content-Encoding: gzip\r\n", f10.rate_body, None),
    Case("invalid-utf8", [#(0, <<binary_head:bits, 255>>)], None),
    case_(
      "oversized",
      headers,
      string.repeat("synthetic-f10-private", 5000),
      None,
    ),
    Case(
      "stalled",
      [
        f10.part(
          0,
          "HTTP/1.1 429 Synthetic\r\n"
            <> headers
            <> private_header
            <> "Content-Length: 100\r\n\r\n",
        ),
      ],
      None,
    ),
    Case(
      "truncated",
      [
        f10.part(
          0,
          "HTTP/1.1 429 Synthetic\r\n"
            <> headers
            <> private_header
            <> "Content-Length: 100\r\n\r\n{}",
        ),
        f10.part(-1, ""),
      ],
      None,
    ),
    Case(
      "drip",
      [f10.part(0, chunked), ..list.repeat(f10.part(90, "1\r\n \r\n"), 10)],
      None,
    ),
    Case(
      "read-events",
      [f10.part(0, chunked <> string.repeat("1\r\n \r\n", 33) <> "0\r\n\r\n")],
      None,
    ),
    Case(
      "uncertain-head",
      [
        f10.part(
          0,
          "HTTP/1.1 unknown Synthetic\r\n"
            <> headers
            <> "Content-Length: 0\r\n\r\n",
        ),
      ],
      None,
    ),
    // Source-derived synthetic F10 review regressions, not CPA execution.
    case_(
      "http-date-suffix",
      media <> shared <> "Retry-After: Tue, 14 Nov 2023 22:15:20 GMTjunk\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "http-date-combined",
      media <> shared <> "Retry-After: Tue, 14 Nov 2023 22:15:20 GMT, 120\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "http-date-time-overflow",
      media <> shared <> "Retry-After: Tue, 14 Nov 2023 22:15:99 GMT\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "rfc3339-calendar",
      media
        <> shared
        <> "anthropic-ratelimit-unified-7d-reset: 2023-02-29T22:15:20Z\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "rfc3339-offset",
      media <> shared <> "Retry-After: 2023-11-14T22:15:20+24:00\r\n",
      f10.rate_body,
      None,
    ),
    case_(
      "rfc3339-leap-second",
      media <> shared <> "Retry-After: 2016-12-31T23:59:60Z\r\n",
      f10.rate_body,
      None,
    ),
    case_("shared-quota", headers, f10.rate_body, Some(121)),
    case_(
      "aggregate-quota",
      media <> retry <> aggregate,
      f10.rate_body,
      Some(121),
    ),
    case_("shared-fast-precedence", headers, f10.credits_body, Some(121)),
    case_("quota-fallback", media <> shared, f10.rate_body, Some(60)),
    case_(
      "exact-body-boundary",
      headers,
      f10.rate_body
        <> string.repeat(
        " ",
        rejection.max_body_bytes - string.byte_size(f10.rate_body),
      ),
      Some(121),
    ),
  ]
}

fn success(operation, streaming) {
  let #(headers, body) = case operation, streaming {
    "messages/count_tokens", _ -> #(media, "{\"input_tokens\":3}")
    _, True -> #(
      "Content-Type: text/event-stream\r\n",
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"synthetic-success\",\"usage\":{\"input_tokens\":3}}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    )
    _, False -> #(
      media,
      "{\"type\":\"message\",\"id\":\"synthetic-success\",\"role\":\"assistant\",\"content\":[]}",
    )
  }
  f10.wire(200, headers, body)
}

fn message(streaming, fast) {
  "{\"model\":\""
  <> f10.model
  <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"synthetic-f10-client-body\"}],\"max_tokens\":16,\"stream\":"
  <> case streaming {
    True -> "true"
    False -> "false"
  }
  <> case fast {
    True -> ",\"speed\":\"fast\"}"
    False -> "}"
  }
}

fn setup(mode, first, second, selected: Option(Bool), listen_port: Int) {
  let dir = directory()
  let flag = case selected {
    None -> ""
    Some(True) -> ",\"claude_quota_classification\":true"
    Some(False) -> ",\"claude_quota_classification\":false"
  }
  let accounts = [
    #("a", f10.origin(first)),
    #("b", f10.origin(second)),
  ]
  let source =
    "{\"version\":1,\"state_dir\":\""
    <> dir
    <> "\",\"listen_port\":"
    <> int.to_string(listen_port)
    <> flag
    <> ",\"accounts\":["
    <> {
      list.map(accounts, fn(account) {
        let oauth = case mode {
          "oauth" ->
            ",\"oauth\":{\"client_id\":\"synthetic-client\",\"authorize_url\":\""
            <> account.1
            <> "/synthetic-authorize\",\"token_url\":\""
            <> account.1
            <> "/synthetic-token\",\"redirect_uri\":\"http://127.0.0.1:9876/callback\"}"
          _ -> ""
        }
        "{\"provider\":\"claude\",\"auth_mode\":\""
        <> mode
        <> "\",\"id\":\""
        <> account.0
        <> "\",\"origin\":\""
        <> account.1
        <> "\",\"models\":[\""
        <> f10.model
        <> "\"]"
        <> oauth
        <> "}"
      })
      |> string.join(",")
    }
    <> "]}"
  let path = private_file(dir, "config.json", source)
  let assert Ok(store) = storage.new(dir)
  f10.seed(store, mode, "a")
  f10.seed(store, mode, "b")
  quota.save(store, quota.empty()) |> should.be_ok
  let client_path = private_file(dir, "client.txt", client)
  gateway.cli(["key", "import", path, "synthetic-client", client_path])
  |> should.be_ok
  let assert Ok(settings) = config.decode(source)
  #(path, settings, store)
}

fn downstream(
  port: Int,
  operation: String,
  body: String,
) -> Result(WireResponse, String) {
  send_request(port, operation, body, "POST")
}

fn send_request(
  port: Int,
  operation: String,
  body: String,
  method: String,
) -> Result(WireResponse, String) {
  let host = "127.0.0.1:" <> int.to_string(port)
  let endpoint = "http://" <> host
  use http_client <- result.try(egress.start(endpoint))
  let capture =
    Capture(
      "synthetic",
      "f10",
      endpoint,
      "test",
      method,
      "/v1/" <> operation,
      "HTTP/1.1",
      [
        Header("Host", host),
        Header("Authorization", "Bearer " <> client),
        Header("Content-Type", "application/json"),
        Header("Content-Length", int.to_string(string.byte_size(body))),
        Header("Connection", "close"),
        // Existing authenticated, request-scoped sticky-session input only;
        // this is NOT a new header or authority for rejection classification.
        Header("X-Client-Request-Id", "synthetic-f10-stable-session"),
      ],
      body,
      Transport("http/1.1", None),
    )
  let response = egress.send(http_client, capture)
  egress.close(http_client) |> should.be_ok
  response
}

fn values(response: WireResponse, name: String) {
  response.headers
  |> list.filter(fn(header) { string.lowercase(header.name) == name })
  |> list.map(fn(header) { header.value })
}

fn sanitized(response: WireResponse) {
  f10.no_secrets(
    response.body
    <> string.join(
      list.map(response.headers, fn(h) { h.name <> ":" <> h.value }),
      "\n",
    ),
  )
  values(response, "x-private") |> should.equal([])
}

fn zero_leases(server, diagnostic) {
  case diagnostic {
    None -> Nil
    Some(query) ->
      f10.await(
        fn() {
          case query(server) {
            Ok(0) -> True
            Ok(_) -> False
            Error(_) -> panic as "Actual gateway lease query unavailable"
          }
        },
        200,
      )
  }
}

fn sent(upstream, expected) {
  f10.requests(upstream) |> list.length |> should.equal(expected)
  f10.await(fn() { f10.closed(upstream) == expected }, 400)
}

fn request_limited(name: String) -> Bool {
  list.contains(
    [
      "credits-retry-only", "model-only", "fable-only",
      "overage-healthy-omitted-window",
    ],
    name,
  )
}

fn run_case(
  mode,
  operation,
  streaming,
  case_: Case,
  selected,
  exhausted,
  diagnostic,
) {
  io.println(
    "F10 gateway "
    <> mode
    <> " "
    <> operation
    <> case streaming {
      True -> " SSE "
      False -> " buffered "
    }
    <> case_.name
    <> case selected {
      Some(True) -> " opt-in"
      Some(False) -> " off"
      None -> " omitted"
    }
    <> case exhausted {
      True -> " exhausted"
      False -> ""
    },
  )
  let ok = success(operation, streaming)
  let first = f10.fixture([case_.script, [#(0, ok)]])
  let second =
    f10.fixture(case exhausted {
      True -> [case_.script]
      False -> [[#(0, ok)]]
    })
  let #(path, settings, store) = setup(mode, first, second, selected, 0)
  let ledger_before = storage.read_quota_ledger(store)
  let assert Ok(server) = gateway.start(settings)
  let before = monotonic_ms()
  let fast =
    list.contains(
      [
        "credits-retry-only",
        "aggregate-fast-contradiction",
        "shared-fast-precedence",
      ],
      case_.name,
    )
  let assert Ok(response) =
    downstream(gateway.port(server), operation, message(streaming, fast))
  { monotonic_ms() - before < 1500 } |> should.be_true
  let penalized = selected == Some(True) && case_.quota_seconds != None
  let expected = case
    penalized,
    exhausted,
    selected == Some(True) && request_limited(case_.name)
  {
    True, True, _ | False, _, True -> 429
    True, False, _ -> 200
    False, _, False -> 503
  }
  response.status |> should.equal(expected)
  sanitized(response)
  case expected {
    429 -> {
      case case_.quota_seconds {
        Some(seconds) ->
          values(response, "retry-after")
          |> should.equal([int.to_string(seconds)])
        None -> values(response, "retry-after") |> should.equal([])
      }
      values(response, "content-type") |> should.equal(["application/json"])
    }
    503 -> {
      values(response, "retry-after") |> should.equal([])
      values(response, "content-type") |> should.equal(["application/json"])
    }
    _ -> values(response, "retry-after") |> should.equal([])
  }
  sent(first, 1)
  sent(second, case penalized {
    True -> 1
    False -> 0
  })
  zero_leases(server, diagnostic)
  let token = case mode {
    "oauth" -> "synthetic-access-a"
    _ -> "synthetic-key-a"
  }
  let first_request = f10.requests(first) |> list.first |> should.be_ok
  {
    string.starts_with(first_request, "POST /v1/" <> operation)
    && string.contains(first_request, token)
  }
  |> should.be_true
  case penalized {
    True -> {
      let assert Ok(ledger) = quota.load(store)
      let assert Some(seconds) = case_.quota_seconds
      let until =
        quota.cooldown_until(ledger, credentials.key("claude", mode, "a"))
      { until > f10.wall_ms() + { seconds - 5 } * 1000 } |> should.be_true
      f10.no_secrets(storage.read_quota_ledger(store) |> should.be_ok)
    }
    False -> storage.read_quota_ledger(store) |> should.equal(ledger_before)
  }
  // Immediate request uses A again if unpenalized, otherwise B; exhaustion
  // stays terminal without sending either credential again.
  let normal_status = case penalized && exhausted {
    True -> 503
    False -> 200
  }
  let assert Ok(normal) =
    downstream(gateway.port(server), operation, message(streaming, False))
  normal.status |> should.equal(normal_status)
  sanitized(normal)
  sent(first, case penalized {
    True -> 1
    False -> 2
  })
  sent(second, case penalized, exhausted {
    True, False -> 2
    True, True -> 1
    False, _ -> 0
  })
  zero_leases(server, diagnostic)
  gateway.stop(server) |> should.be_ok
  // Fresh-VM restoration is mandatory for request scope, unknown scope and
  // every qualified-quota variant. Other adverse rows separately prove an
  // unchanged persisted ledger at rejection and immediate same-account reuse.
  let restore =
    penalized
    || list.contains(["credits-retry-only", "unknown-code"], case_.name)
  case restore {
    True -> {
      let #(exit, output) =
        fresh_vm_request(path, operation, streaming, normal_status)
      f10.no_secrets(output)
      io.print(output)
      io.println("F10 fresh-VM EXIT=" <> int.to_string(exit))
      exit |> should.equal(0)
    }
    False -> Nil
  }
  sent(first, case penalized {
    True -> 1
    False ->
      case restore {
        True -> 3
        False -> 2
      }
  })
  sent(second, case penalized, exhausted {
    True, False ->
      case restore {
        True -> 3
        False -> 2
      }
    True, True -> 1
    False, _ -> 0
  })
  case penalized {
    False -> {
      // Successful 200 observation legitimately persists neutral windows.
      // Only the rejection itself must leave the original bytes unchanged.
      let assert Ok(ledger) = quota.load(store)
      let key = credentials.key("claude", mode, "a")
      { quota.cooldown_until(ledger, key) <= f10.wall_ms() } |> should.be_true
      case quota.lookup(ledger, key) {
        Some(entry) ->
          {
            list.all(entry.windows, fn(window) { window.status != "rejected" })
          }
          |> should.be_true
        None -> Nil
      }
    }
    True -> Nil
  }
  f10.stop(first)
  f10.stop(second)
}

/// Called in a real fresh VM by an OS argument-vector primitive. No reseeding
/// or provider substitution; same persisted config, credentials, key and ledger.
pub fn fresh_vm() {
  io.println("F10 fresh-VM phase: arguments")
  let assert [path, operation, streaming, expected] = argv.load().arguments
  let assert Ok(expected) = int.parse(expected)
  let assert Ok(settings) = gateway.load(path)
  io.println("F10 fresh-VM phase: config loaded")
  let assert Ok(server) = gateway.start(settings)
  io.println("F10 fresh-VM phase: actual gateway started")
  let assert Ok(response) =
    downstream(
      gateway.port(server),
      operation,
      message(streaming == "true", False),
    )
  io.println("F10 fresh-VM phase: response received")
  response.status |> should.equal(expected)
  sanitized(response)
  gateway.stop(server) |> should.be_ok
  io.println("PASS: F10 fresh-VM actual gateway restoration without reseeding")
}

fn cli_focused(executable: String, prefix: List(String), classified: Bool) {
  let rows =
    list.filter(cases(), fn(row) {
      list.contains(["credits-retry-only", "shared-quota"], row.name)
    })
  list.each(["api_key", "oauth"], fn(mode) {
    list.each(
      [
        #("messages", False),
        #("messages", True),
        #("messages/count_tokens", False),
      ],
      fn(route) {
        list.each(rows, fn(row) {
          cli_case(
            executable,
            prefix,
            mode,
            route.0,
            route.1,
            row,
            classified,
            False,
          )
          case classified && row.quota_seconds != None {
            True ->
              cli_case(
                executable,
                prefix,
                mode,
                route.0,
                route.1,
                row,
                True,
                True,
              )
            False -> Nil
          }
        })
        cli_case(
          executable,
          prefix,
          mode,
          route.0,
          route.1,
          list.last(rows) |> should.be_ok,
          False,
          False,
        )
      },
    )
  })
  io.println(
    "PASS: F10 focused actual source/shipment CLI outcomes with real restart; full matrix admission separate",
  )
}

fn cli_matrix(executable: String, prefix: List(String), classified: Bool) {
  list.each(["api_key", "oauth"], fn(mode) {
    list.each(
      [
        #("messages", False),
        #("messages", True),
        #("messages/count_tokens", False),
      ],
      fn(route) {
        list.each(
          list.filter(cases(), fn(row) {
            list.contains(
              [
                "credits-retry-only", "unknown-code", "http-date-suffix",
                "rfc3339-calendar", "shared-quota",
              ],
              row.name,
            )
          }),
          fn(row) {
            cli_case(
              executable,
              prefix,
              mode,
              route.0,
              route.1,
              row,
              classified,
              False,
            )
            case classified && row.quota_seconds != None {
              True ->
                cli_case(
                  executable,
                  prefix,
                  mode,
                  route.0,
                  route.1,
                  row,
                  True,
                  True,
                )
              False -> Nil
            }
          },
        )
        let assert Ok(control) =
          list.find(cases(), fn(row) { row.name == "shared-quota" })
        cli_case(
          executable,
          prefix,
          mode,
          route.0,
          route.1,
          control,
          False,
          False,
        )
      },
    )
  })
  io.println(
    "PASS: F10 actual CLI route outcomes; root lease query requires separate coordinator gateway matrix",
  )
}

fn cli_ready(port: Int, deadline: Int) {
  case monotonic_ms() >= deadline {
    True -> panic as "Actual CLI listener did not become ready"
    False ->
      case send_request(port, "models", "", "GET") {
        Ok(response) if response.status == 200 -> Nil
        _ -> {
          process.sleep(20)
          cli_ready(port, deadline)
        }
      }
  }
}

fn command(executable, args, action) {
  let #(passed, exit, output) = with_cli(executable, args, action)
  f10.no_secrets(output)
  io.print(output)
  io.println("F10 CLI controlled-stop EXIT=" <> int.to_string(exit))
  passed |> should.be_true
  // We request SIGTERM for the owned process group. A launcher may terminate
  // with 143 while its child exits normally; neither is a crash/timeout waiver.
  { exit == 0 || exit == 143 } |> should.be_true
}

fn cli_case(
  executable: String,
  prefix: List(String),
  mode: String,
  operation: String,
  streaming: Bool,
  row: Case,
  classified: Bool,
  exhausted: Bool,
) {
  io.println(
    "F10 CLI "
    <> mode
    <> " "
    <> operation
    <> " "
    <> row.name
    <> case streaming {
      True -> " SSE"
      False -> " buffered"
    }
    <> case classified {
      True -> " opt-in"
      False -> " off"
    }
    <> case exhausted {
      True -> " exhausted"
      False -> ""
    },
  )
  let ok = success(operation, streaming)
  let first = f10.fixture([row.script, [#(0, ok)]])
  let second =
    f10.fixture(case exhausted {
      True -> [row.script]
      False -> [[#(0, ok)]]
    })
  let reserved = f10.fixture([[#(0, <<>>)]])
  let port = f10.port(reserved)
  f10.stop(reserved)
  let #(path, _, store) = setup(mode, first, second, Some(classified), port)
  let before_ledger = storage.read_quota_ledger(store)
  let args = list.append(prefix, ["providers", "serve", path])
  let penalized = classified && row.quota_seconds != None
  let initial_status = case
    penalized,
    exhausted,
    classified && request_limited(row.name)
  {
    True, True, _ | False, _, True -> 429
    True, False, _ -> 200
    False, _, False -> 503
  }
  let normal_status = case penalized && exhausted {
    True -> 503
    False -> 200
  }
  command(executable, args, fn() {
    cli_ready(port, monotonic_ms() + 15_000)
    let before = monotonic_ms()
    let assert Ok(response) =
      downstream(
        port,
        operation,
        message(streaming, row.name == "credits-retry-only"),
      )
    { monotonic_ms() - before < 1500 } |> should.be_true
    response.status |> should.equal(initial_status)
    sanitized(response)
    case initial_status {
      429 -> {
        case row.quota_seconds {
          Some(seconds) ->
            values(response, "retry-after")
            |> should.equal([int.to_string(seconds)])
          None -> values(response, "retry-after") |> should.equal([])
        }
      }
      _ -> values(response, "retry-after") |> should.equal([])
    }
    sent(first, 1)
    sent(second, case penalized {
      True -> 1
      False -> 0
    })
    case penalized {
      False -> storage.read_quota_ledger(store) |> should.equal(before_ledger)
      True -> {
        let assert Ok(ledger) = quota.load(store)
        {
          quota.cooldown_until(ledger, credentials.key("claude", mode, "a"))
          > f10.wall_ms() + 115_000
        }
        |> should.be_true
      }
    }
    let assert Ok(normal) =
      downstream(port, operation, message(streaming, False))
    normal.status |> should.equal(normal_status)
    sanitized(normal)
    sent(first, case penalized {
      True -> 1
      False -> 2
    })
    sent(second, case penalized, exhausted {
      True, False -> 2
      True, True -> 1
      False, _ -> 0
    })
  })
  // Actual CLI process restart from identical persisted state, without reseeding.
  command(executable, args, fn() {
    cli_ready(port, monotonic_ms() + 15_000)
    let assert Ok(restored) =
      downstream(port, operation, message(streaming, False))
    restored.status |> should.equal(normal_status)
    sanitized(restored)
    sent(first, case penalized {
      True -> 1
      False -> 3
    })
    sent(second, case penalized, exhausted {
      True, False -> 3
      True, True -> 1
      False, _ -> 0
    })
  })
  f10.stop(first)
  f10.stop(second)
}
