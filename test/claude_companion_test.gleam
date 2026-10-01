/// Synthetic source-contract tests only. No real account or live upstream.
import claude_companion_scenario
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ir
import mimic/providers/claude/companion
import mimic/providers/claude/login
import mimic/providers/claude/oauth
import mimic/providers/contracts
import mimic/types.{Header}

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn device() {
  string.repeat("a", 64)
}

fn operator(account, org) {
  ir.Object(
    [#("device_id", ir.String(device()))]
    |> with_field("account_uuid", account)
    |> with_field("organization_uuid", org),
  )
}

fn with_field(fields, key, value) {
  case value {
    None -> fields
    Some(value) -> list.append(fields, [#(key, ir.String(value))])
  }
}

fn tokens(account, org) {
  oauth.Tokens(
    auth.Credential("synthetic-access", "synthetic-refresh", 100_000),
    oauth.Identity(account, org),
  )
}

fn response(body) {
  oauth.TokenResponse(200, [Header("Content-Type", "application/json")], body)
}

const profile = "{\"account\":{\"uuid\":\"synthetic-account\",\"email\":\"synthetic-private-email\"},\"organization\":{\"uuid\":\"synthetic-org\",\"name\":\"synthetic-private-name\"}}"

const token_body = "{\"access_token\":\"synthetic-access\",\"refresh_token\":\"synthetic-refresh\",\"expires_in\":3600}"

fn approved() {
  let assert Ok(approved) =
    companion.approve(
      "http://127.0.0.1:19444/profile",
      "http://127.0.0.1:19444/roles",
      True,
    )
  approved
}

pub fn approval_and_explicit_endpoint_gate_test() {
  companion.approve("", "", False)
  |> should.equal(Error("Claude companion activity not approved"))
  list.each(
    [
      "", "https://example.test", "https://example.test/",
      "http://example.test/profile",
      "https://user:synthetic-secret@example.test/profile",
      "https://example.test/profile?synthetic-secret",
      "https://example.test/profile#synthetic-secret",
      "https://example.test/profile%0d%0a", "https://example.test\\profile",
      "https://example.test:0/profile", "https://example.test:65536/profile",
      "https://example.test/profile\n",
    ],
    fn(url) {
      companion.approve(url, "https://example.test/roles", True)
      |> should.equal(Error("Invalid Claude companion endpoint"))
      companion.approve("https://example.test/profile", url, True)
      |> should.equal(Error("Invalid Claude companion endpoint"))
    },
  )
  companion.approve(
    "https://operator.example/profile",
    "https://operator.example/roles",
    True,
  )
  |> should.be_ok
}

pub fn profile_requires_account_organization_is_optional_test() {
  companion.parse_profile(response(profile))
  |> should.equal(
    Ok(oauth.Identity(Some("synthetic-account"), Some("synthetic-org"))),
  )
  companion.parse_profile(response(
    "{\"account\":{\"uuid\":\" synthetic-account \"},\"organization\":{}}",
  ))
  |> should.equal(Ok(oauth.Identity(Some("synthetic-account"), None)))
  list.each(
    [
      "{}", "[]", "{\"account\":{}}", "{\"account\":{\"uuid\":\"\"}}",
      "{\"account\":{\"uuid\":\"  \"}}", "{\"account\":{\"uuid\":1}}",
      "{\"account\":{\"uuid\":\"synthetic-account\"},\"organization\":null}",
      "{\"account\":{\"uuid\":\"synthetic-account\"},\"error\":\"synthetic-secret\"}",
      "{\"account\":{\"uuid\":\"synthetic-account\\u0000\"}}",
    ],
    fn(body) {
      companion.parse_profile(response(body))
      |> should.equal(Error("Claude profile unavailable"))
    },
  )
}

pub fn opaque_roles_have_no_guessed_schema_or_entitlements_test() {
  list.each(
    [
      "[\"synthetic-unknown\", {\"nested\":true}]",
      " { \"account_uuid\": \"not-an-identity\", \"device_id\": \"not-a-device\" } ",
      "null", "42", "\"synthetic-private-role\"",
    ],
    fn(body) { companion.parse_roles(response(body)) |> should.equal(Ok(body)) },
  )
}

pub fn one_json_guard_rejects_escaped_duplicates_and_bounds_test() {
  list.each(
    [
      "{\"account\":{\"uuid\":\"synthetic-account\",\"\\u0075uid\":\"conflict\"}}",
      "{\"account\":{\"uuid\":\"synthetic-account\"},\"\\u0061ccount\":{\"uuid\":\"conflict\"}}",
      "{\"account\":{\"uuid\":\"synthetic-account\"},\"extra\":[{\"é\":1,\"\\u00e9\":2}]}",
      "{\"x\":\"" <> string.repeat("x", 65_529) <> "\"}",
      string.repeat("[", 33) <> "0" <> string.repeat("]", 33),
      "[" <> string.join(list.repeat("0", 4096), ",") <> "]",
      "{\"x\":1}synthetic-secret",
    ],
    fn(body) {
      companion.parse_profile(response(body))
      |> should.equal(Error("Claude profile unavailable"))
      companion.parse_roles(response(body))
      |> should.equal(Error("Claude roles unavailable"))
    },
  )
  let exact = "{\"x\":\"" <> string.repeat("x", 65_528) <> "\"}"
  string.byte_size(exact) |> should.equal(65_536)
  companion.parse_roles(response(exact)) |> should.be_ok
  companion.parse_roles(response(
    string.repeat("[", 32) <> "0" <> string.repeat("]", 32),
  ))
  |> should.be_ok
}

pub fn wrong_media_encoding_and_ambiguous_headers_are_advisory_test() {
  list.each(
    [
      [Header("Content-Type", "text/html")],
      [Header("Content-Type", "text/event-stream")],
      [Header("Content-Type", "application/json; charset=latin1")],
      [Header("Content-Type", "application/json; charset=utf-8; boundary=x")],
      [
        Header("Content-Type", "application/json"),
        Header("content-type", "application/json"),
      ],
      [Header("Content-Encoding", "gzip")],
      [Header("Content-Encoding", "br")],
      [
        Header("Content-Encoding", "identity"),
        Header("content-encoding", "identity"),
      ],
      [Header("Content-Encoding", "gzip"), Header("content-encoding", "br")],
    ],
    fn(headers) {
      companion.parse_profile(oauth.TokenResponse(200, headers, profile))
      |> should.equal(Error("Claude profile unavailable"))
      companion.parse_roles(oauth.TokenResponse(200, headers, "{}"))
      |> should.equal(Error("Claude roles unavailable"))
    },
  )
  companion.parse_profile(oauth.TokenResponse(200, [], profile)) |> should.be_ok
  companion.parse_profile(oauth.TokenResponse(
    200,
    [Header("Content-Encoding", "Identity")],
    profile,
  ))
  |> should.be_ok
  companion.parse_profile(oauth.TokenResponse(
    200,
    [Header("content-type", "Application/Problem+JSON; Charset=UTF-8")],
    profile,
  ))
  |> should.be_ok
  list.each([301, 401, 403, 429, 500], fn(status) {
    companion.parse_profile(oauth.TokenResponse(status, [], profile))
    |> should.equal(Error("Claude profile unavailable"))
    companion.parse_roles(oauth.TokenResponse(
      status,
      [],
      "\"synthetic-secret\"",
    ))
    |> should.equal(Error("Claude roles unavailable"))
  })
}

fn malformed_media() {
  [
    "application/json, application/problem+json",
    "application/json,application/problem+json",
    "application/a/b+json",
    "application/problem +json",
    "application/problem\t+json",
    "application/problem\r\n+json",
    "application/problém+json",
    "application/+json",
    "application/(problem)+json",
    "application/problem\\+json",
    "application/json; charset=utf-8; charset=utf-8",
    "\napplication/json",
    "application/json\r\n",
    "\u{00a0}application/json",
  ]
}

pub fn malformed_profile_media_is_rejected_test() {
  list.each(malformed_media(), fn(media) {
    companion.parse_profile(oauth.TokenResponse(
      200,
      [Header("Content-Type", media)],
      profile,
    ))
    |> should.equal(Error("Claude profile unavailable"))
  })
}

pub fn malformed_roles_media_is_rejected_test() {
  list.each(malformed_media(), fn(media) {
    companion.parse_roles(oauth.TokenResponse(
      200,
      [Header("Content-Type", media)],
      "{}",
    ))
    |> should.equal(Error("Claude roles unavailable"))
  })
}

pub fn malformed_token_media_is_rejected_test() {
  list.each(malformed_media(), fn(media) {
    oauth.parse_tokens(
      oauth.TokenResponse(200, [Header("Content-Type", media)], token_body),
      tokens(None, None),
      1000,
    )
    |> should.equal(Error(oauth.InvalidResponse))
  })
}

pub fn valid_single_json_media_keeps_all_consumers_test() {
  list.each(
    [
      "application/json",
      "application/problem+json",
      "Application/Vnd.synthetic-v1+JSON; Charset=UTF-8",
      " application/json ; charset=utf-8 ",
      "application/vnd.a!#$%&'*+-.^_`|~+json",
    ],
    fn(media) {
      let headers = [Header("Content-Type", media)]
      companion.parse_profile(oauth.TokenResponse(200, headers, profile))
      |> should.be_ok
      companion.parse_roles(oauth.TokenResponse(200, headers, "{}"))
      |> should.be_ok
      oauth.parse_tokens(
        oauth.TokenResponse(200, headers, token_body),
        tokens(None, None),
        1000,
      )
      |> should.be_ok
    },
  )
}

pub fn advisory_failures_still_send_profile_then_roles_once_test() {
  list.each([True, False], fn(profile_fails) {
    let sent = process.new_subject()
    let assert Ok(observed) =
      companion.inspect(approved(), "synthetic-access", fn(request) {
        process.send(sent, request.url)
        // Private request comparisons must fail boolean-only.
        {
          request.headers
          == [
            Header("Accept", "application/json"),
            Header("Content-Type", "application/json"),
            Header("Authorization", "Bearer synthetic-access"),
            Header("Cache-Control", "no-cache"),
            Header("Accept-Encoding", "identity"),
          ]
        }
        |> should.be_true
        case string.ends_with(request.url, "/profile"), profile_fails {
          True, True -> Error("synthetic-secret diagnostic")
          True, False -> Ok(response(profile))
          False, _ -> Error("synthetic-secret diagnostic")
        }
      })
    process.receive(sent, 100)
    |> should.equal(Ok("http://127.0.0.1:19444/profile"))
    process.receive(sent, 100)
    |> should.equal(Ok("http://127.0.0.1:19444/roles"))
    process.receive(sent, 0) |> should.be_error
    observed.roles_json |> should.equal(None)
    case profile_fails {
      True -> observed.profile |> should.equal(None)
      False -> { observed.profile != None } |> should.be_true
    }
  })
  companion.inspect(approved(), "synthetic-secret\n", fn(_) {
    panic as "Invalid credentials must not enter transport"
  })
  |> should.equal(Error("Invalid Claude companion credential"))
}

pub fn reconciliation_stores_only_observed_minimal_private_identity_test() {
  let assert Ok(op) = companion.operator(operator(None, None))
  let assert Ok(observed) = companion.parse_profile(response(profile))
  let assert Ok(contracts.OAuth(grant)) =
    companion.reconcile(op, tokens(None, None), Some(observed))
  {
    grant.private_metadata
    == [
      #("device_id", device()),
      #("account_uuid", "synthetic-account"),
      #("organization_uuid", "synthetic-org"),
    ]
  }
  |> should.be_true
  // No role, email, name, UA, device pool or fingerprint has been invented.
  { grant.credential == tokens(None, None).credential } |> should.be_true
  let assert Ok(op) =
    companion.operator(operator(Some("synthetic-account"), None))
  let assert Ok(contracts.OAuth(grant)) =
    companion.reconcile(op, tokens(None, None), None)
  list.map(grant.private_metadata, fn(p) { p.0 })
  |> should.equal(["device_id", "account_uuid"])
}

pub fn identity_conflicts_never_have_source_precedence_test() {
  list.each([True, False], fn(account_conflict) {
    let good = case account_conflict {
      True -> oauth.Identity(Some("synthetic-account"), None)
      False -> oauth.Identity(Some("synthetic-account"), Some("synthetic-org"))
    }
    let bad = case account_conflict {
      True -> oauth.Identity(Some("synthetic-other"), None)
      False ->
        oauth.Identity(Some("synthetic-account"), Some("synthetic-other"))
    }
    list.each(
      [#(good, bad, good), #(bad, good, good), #(good, good, bad)],
      fn(sources) {
        let assert Ok(operator) =
          companion.operator(operator(
            sources.0.account_uuid,
            sources.0.organization_uuid,
          ))
        companion.reconcile(
          operator,
          tokens(sources.1.account_uuid, sources.1.organization_uuid),
          Some(sources.2),
        )
        |> should.equal(Error("Claude OAuth identity mismatch"))
      },
    )
  })
}

pub fn missing_identity_and_unobserved_device_fail_closed_test() {
  let assert Ok(operator) = companion.operator(operator(None, None))
  companion.reconcile(operator, tokens(None, None), None)
  |> should.equal(Error("Claude OAuth account identity required"))
  list.each(
    [
      ir.Object([]),
      ir.Object([#("account_uuid", ir.String("synthetic-account"))]),
      ir.Object([#("device_id", ir.String(string.repeat("A", 64)))]),
      ir.Object([#("device_id", ir.String(""))]),
      ir.Object([
        #("device_id", ir.String(device())),
        #("account_uuid", ir.String("")),
      ]),
      ir.Object([
        #("device_id", ir.String(device())),
        #("device_id", ir.String(device())),
      ]),
      ir.Object([
        #("device_id", ir.String(device())),
        #("organization_uuid", ir.String("synthetic-secret\n")),
      ]),
    ],
    fn(value) {
      companion.operator(value)
      |> should.equal(Error("Invalid Claude operator identity"))
    },
  )
}

pub fn store_free_seam_works_with_one_shell_owned_ticket_test() {
  list.each([False, True], fn(enabled) {
    let assert Ok(store) = storage.new(directory())
    let key = "synthetic-shell-ticket"
    let assert Ok(ticket) = runtime_store.begin_enrollment(store, key)
    let before = storage.read_runtime(store, key)
    let config =
      auth.claude_config(
        "synthetic-client",
        "http://127.0.0.1:19444/authorize",
        "http://127.0.0.1:19444/token",
        "http://127.0.0.1:19444/callback",
      )
    let assert Ok(pending) = oauth.begin(config, key)
    let called = process.new_subject()
    let assert Ok(grant) =
      login.exchange_grant(
        config,
        pending,
        login.Callback(pending.state, "synthetic-code"),
        operator(Some("synthetic-account"), None),
        case enabled {
          True -> Some(approved())
          False -> None
        },
        1000,
        login.Transports(fn(_) { Ok(response(token_body)) }, fn(request) {
          process.send(called, Nil)
          case string.ends_with(request.url, "/profile") {
            True -> Ok(response(profile))
            False -> Ok(response("{\"unknown\":\"synthetic-private-role\"}"))
          }
        }),
      )
    // No store mutation or nested begin: the caller's original ticket commits.
    { storage.read_runtime(store, key) == before } |> should.be_true
    runtime_store.commit_enrollment(ticket, grant) |> should.be_ok
    case enabled {
      False -> process.receive(called, 0) |> should.be_error
      True -> {
        process.receive(called, 100) |> should.be_ok
        process.receive(called, 100) |> should.be_ok
        process.receive(called, 0) |> should.be_error
      }
    }
  })
}

pub fn invalid_callback_or_exchange_never_sends_companions_test() {
  let config =
    auth.claude_config(
      "synthetic-client",
      "http://127.0.0.1:19444/authorize",
      "http://127.0.0.1:19444/token",
      "http://127.0.0.1:19444/callback",
    )
  let assert Ok(pending) = oauth.begin(config, "synthetic")
  list.each([True, False], fn(invalid_callback) {
    login.exchange_grant(
      config,
      pending,
      login.Callback(
        case invalid_callback {
          True -> "wrong"
          False -> pending.state
        },
        "synthetic-code",
      ),
      operator(None, None),
      Some(approved()),
      1000,
      login.Transports(
        fn(_) {
          case invalid_callback {
            True -> panic as "Invalid callback must not exchange"
            False -> Error("synthetic-private-token-error")
          }
        },
        fn(_) { panic as "Failed exchange must not inspect" },
      ),
    )
    |> should.equal(Error("Claude OAuth exchange failed"))
  })
}

pub fn actual_loopback_companion_and_root_route_workflow_test() {
  claude_companion_scenario.local_workflow()
}

pub fn actual_loopback_guarded_token_profile_roles_workflow_test() {
  claude_companion_scenario.local_guarded_workflow()
}

pub fn shell_cancellation_during_companions_defeats_late_commit_test() {
  list.each([False, True], fn(existing) {
    list.each([True, False], fn(at_profile) {
      let assert Ok(store) = storage.new(directory())
      let key = "synthetic-shell-cancellation"
      let old =
        contracts.OAuth(
          contracts.OAuthData(
            tokens(Some("synthetic-account"), None).credential,
            [#("device_id", device()), #("account_uuid", "synthetic-account")],
          ),
        )
      case existing {
        True -> runtime_store.save(store, key, old) |> should.be_ok
        False -> Nil
      }
      let assert Ok(ticket) = runtime_store.begin_enrollment(store, key)
      let config =
        auth.claude_config(
          "synthetic-client",
          "http://127.0.0.1:19444/authorize",
          "http://127.0.0.1:19444/token",
          "http://127.0.0.1:19444/callback",
        )
      let assert Ok(pending) = oauth.begin(config, key)
      let assert Ok(grant) =
        login.exchange_grant(
          config,
          pending,
          login.Callback(pending.state, "synthetic-code"),
          operator(None, None),
          Some(approved()),
          1000,
          login.Transports(fn(_) { Ok(response(token_body)) }, fn(request) {
            case string.ends_with(request.url, "/profile") == at_profile {
              True -> runtime_store.cancel_enrollment(ticket) |> should.be_ok
              False -> Nil
            }
            Ok(
              response(case string.ends_with(request.url, "/profile") {
                True -> profile
                False -> roles_for_cancellation()
              }),
            )
          }),
        )
      runtime_store.commit_enrollment(ticket, grant) |> should.be_error
      case existing {
        True -> { runtime_store.load(store, key) == Ok(old) } |> should.be_true
        False -> storage.read_runtime_slot(store, key) |> should.equal(Ok(None))
      }
    })
  })
}

fn roles_for_cancellation() {
  "{\"account_uuid\":\"synthetic-not-an-identity\"}"
}
