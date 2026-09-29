import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/providers/contracts.{SessionToken}
import mimic/providers/devin/enrollment

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn config() -> enrollment.Config {
  enrollment.Config(
    "https://app.devin.ai",
    "http://127.0.0.1:9191",
    "http://127.0.0.1:9192/callback",
  )
}

pub fn synthetic_manual_code_pkce_and_permanent_session_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) =
    enrollment.import_session_token(store, "devin-test", "synthetic-previous")
  let assert Ok(pending) = enrollment.begin_manual(config())
  let url = enrollment.authorization_url(pending)
  string.contains(url, "cli_pkce_marker=1") |> should.be_true
  string.contains(url, "redirect_uri=") |> should.be_false
  let send = fn(plan: enrollment.TokenRequest) {
    plan.endpoint |> should.equal("http://127.0.0.1:9191/auth/cli/token")
    string.contains(plan.body, "\"code\":\"synthetic-code\"")
    |> should.be_true
    string.contains(plan.body, "\"code_verifier\":") |> should.be_true
    Ok(#(200, "{\"token\":\"eyJsynthetic\"}"))
  }
  enrollment.complete_code(pending, "synthetic-code", store, "devin-test", send)
  |> should.equal(Ok(Nil))
  runtime_store.load(store, "devin-test")
  |> should.equal(Ok(SessionToken("devin-session-token$eyJsynthetic", [])))
  runtime_store.metadata(store, "devin-test")
  |> should.equal(Ok(runtime_store.Metadata("session_token", None)))
}

pub fn synthetic_callback_query_state_rejection_before_exchange_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(pending) = enrollment.begin_manual(config())
  let send = fn(_plan: enrollment.TokenRequest) {
    panic as "state mismatch must not exchange"
  }
  enrollment.complete_query(
    pending,
    "code=synthetic&state=wrong",
    store,
    "devin-test",
    send,
  )
  |> should.be_error
  runtime_store.load(store, "devin-test") |> should.be_error
}

pub fn synthetic_callback_seam_requires_configured_loopback_test() {
  let assert Ok(pending) = enrollment.begin_callback(config())
  let url = enrollment.authorization_url(pending)
  string.contains(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A9192%2Fcallback")
  |> should.be_true
  enrollment.begin_callback(enrollment.Config(
    "https://app.devin.ai",
    "http://127.0.0.1:9191",
    "http://evil.example/callback",
  ))
  |> should.be_error
  enrollment.begin_manual(enrollment.Config(
    "https://app.devin.ai",
    "https://user:password@api.devin.ai",
    "",
  ))
  |> should.be_error
}

pub fn synthetic_manual_token_import_explicit_only_test() {
  let assert Ok(store) = storage.new(directory())
  enrollment.import_session_token(store, "devin-test", "eyJsynthetic")
  |> should.equal(Ok(Nil))
  runtime_store.load(store, "devin-test")
  |> should.equal(Ok(SessionToken("devin-session-token$eyJsynthetic", [])))
  enrollment.import_session_token(store, "devin-test", "bad token\r\nsecret")
  |> should.be_error
}

pub fn synthetic_exchange_error_never_echoes_response_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) =
    enrollment.import_session_token(store, "devin-test", "synthetic-previous")
  let assert Ok(pending) = enrollment.begin_manual(config())
  enrollment.complete_code(pending, "synthetic", store, "devin-test", fn(_) {
    Ok(#(403, "private-token-body"))
  })
  |> should.equal(Error("Devin token exchange failed"))
  runtime_store.load(store, "devin-test")
  |> should.equal(Ok(SessionToken("synthetic-previous", [])))
}

pub fn synthetic_exchange_cannot_overwrite_new_generation_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) =
    enrollment.import_session_token(store, "devin-test", "synthetic-previous")
  let assert Ok(pending) = enrollment.begin_manual(config())
  enrollment.complete_code(pending, "synthetic", store, "devin-test", fn(_) {
    // Even an admin write of the SAME token creates a new generation.
    let assert Ok(_) =
      enrollment.import_session_token(store, "devin-test", "synthetic-previous")
    Ok(#(200, "{\"token\":\"synthetic-stale-result\"}"))
  })
  |> should.equal(Error("Devin credential changed during enrollment"))
  runtime_store.load(store, "devin-test")
  |> should.equal(Ok(SessionToken("synthetic-previous", [])))
}
