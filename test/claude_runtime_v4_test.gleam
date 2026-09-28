// Synthetic Claude consumer regression against the assembled runtime-v4 tree.
import argv
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleeunit/should
import mimic/auth
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/ir
import mimic/providers/claude/oauth
import mimic/providers/contracts as runtime
import mimic/types.{Header}
import mist

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn private_directory() -> String

const success = "{\"access_token\":\"synthetic-rotated-access\",\"refresh_token\":\"synthetic-rotated-refresh\",\"expires_in\":3600}"

type Clock {
  Clock(epoch: Int, monotonic: Int, requests: Int)
}

type ClockMessage {
  Read(process.Subject(#(Int, Int)))
  Set(Int, Int, process.Subject(Nil))
  Hit(process.Subject(Int))
  Count(process.Subject(Int))
}

fn clock() {
  let assert Ok(started) =
    actor.new(Clock(100_000, 0, 0))
    |> actor.on_message(fn(state, message) {
      case message {
        Read(reply) -> {
          process.send(reply, #(state.epoch, state.monotonic))
          actor.continue(state)
        }
        Set(epoch, monotonic, reply) -> {
          process.send(reply, Nil)
          actor.continue(Clock(..state, epoch: epoch, monotonic: monotonic))
        }
        Hit(reply) -> {
          process.send(reply, state.requests + 1)
          actor.continue(Clock(..state, requests: state.requests + 1))
        }
        Count(reply) -> {
          process.send(reply, state.requests)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  started
}

fn sample(clock) {
  actor.call(clock, 5000, Read)
}

fn set_clock(clock, epoch, monotonic) {
  actor.call(clock, 5000, fn(reply) { Set(epoch, monotonic, reply) })
}

fn hit(clock) {
  actor.call(clock, 5000, Hit)
}

fn count(clock) {
  actor.call(clock, 5000, Count)
}

fn stop(pid) {
  process.unlink(pid)
  process.send_exit(pid)
}

fn old() {
  runtime.OAuthData(auth.Credential("synthetic-old", "synthetic-refresh", 0), [
    #("account_uuid", "synthetic-account"),
    #("organization_uuid", "synthetic-org"),
    #(
      "claude_device_id",
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ),
    #("synthetic-unrelated", "keep"),
  ])
}

fn field(metadata, key) -> Option(String) {
  case list.key_find(metadata, key) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn put(metadata: List(#(String, String)), key: String, value: Option(String)) {
  case value {
    None -> metadata
    Some(value) ->
      list.append(list.filter(metadata, fn(entry) { entry.0 != key }), [
        #(key, value),
      ])
  }
}

// This is the migration under test. No generic error implies safe retry.
fn bridge(cfg, timeout_ms) {
  runtime.Refresh(fn(data, now) {
    let previous =
      oauth.Tokens(
        data.credential,
        oauth.Identity(
          field(data.private_metadata, "account_uuid"),
          field(data.private_metadata, "organization_uuid"),
        ),
      )
    oauth.refresh(cfg, previous, now, fn(req) { post(req, timeout_ms) })
    |> result.map(fn(tokens) {
      runtime.OAuthData(
        tokens.credential,
        data.private_metadata
          |> put("account_uuid", tokens.identity.account_uuid)
          |> put("organization_uuid", tokens.identity.organization_uuid),
      )
    })
    |> result.map_error(fn(failure) {
      case failure {
        oauth.RateLimited(ms) -> runtime.RefreshRateLimited(ms)
        oauth.InvalidGrant | oauth.IdentityChanged -> runtime.InvalidGrant
        oauth.Unavailable | oauth.InvalidResponse -> runtime.RefreshUnavailable
        oauth.InvalidCallback -> runtime.RefreshUnsupported
      }
    })
  })
}

fn post(plan: oauth.TokenRequest, timeout_ms) {
  use req <- result.try(
    request.to(plan.url)
    |> result.map_error(fn(_) { "Invalid synthetic token URL" }),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(plan.body)
  let req =
    list.fold(plan.headers, req, fn(req, h) {
      request.set_header(req, h.name, h.value)
    })
  use reply <- result.try(
    httpc.configure()
    |> httpc.timeout(timeout_ms)
    |> httpc.dispatch(req)
    |> result.map_error(fn(_) { "Unknown synthetic exchange outcome" }),
  )
  Ok(oauth.TokenResponse(
    reply.status,
    list.map(reply.headers, fn(h) { Header(h.0, h.1) }),
    reply.body,
  ))
}

fn cfg(port) {
  let origin = "http://127.0.0.1:" <> int.to_string(port)
  auth.claude_config(
    "synthetic-client",
    origin <> "/authorize",
    origin <> "/token",
    "http://127.0.0.1:9222/callback",
  )
}

fn server(handler) {
  let ready = process.new_subject()
  let assert Ok(server) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.read_request_body(
      bytes_limit: 8192,
      failure_response: response.new(413)
        |> response.set_body(mist.Bytes(bytes_tree.new())),
    )
    |> mist.start
  let assert Ok(port) = process.receive(ready, 5000)
  #(server.pid, cfg(port))
}

fn json_response(status, body) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn verify_json_request(req: request.Request(BitArray)) {
  req.method |> should.equal(http.Post)
  req.path |> should.equal("/token")
  list.key_find(req.headers, "content-type")
  |> should.equal(Ok("application/json"))
  let assert Ok(text) = bit_array.to_string(req.body)
  let assert Ok(body) = ir.parse(text)
  ir.string_field(body, "grant_type") |> should.equal(Ok("refresh_token"))
  ir.string_field(body, "refresh_token")
  |> should.equal(Ok("synthetic-refresh"))
}

fn store() {
  let assert Ok(store) = storage.new(private_directory())
  runtime_store.save(store, "synthetic", runtime.OAuth(old()))
  |> should.equal(Ok(Nil))
  store
}

fn start_worker(store, key, refresh, clock) {
  let assert Ok(worker) =
    credentials.start_with_clock(
      store,
      key,
      credentials.Refreshable(refresh),
      fn() { sample(clock) },
    )
  worker
}

fn reauthorization() {
  Error(runtime.Failure(runtime.ReauthorizationRequired, runtime.NotSent, None))
}

pub fn concurrent_json_429_completion_deadline_test() {
  let clock = clock()
  let #(server, cfg) =
    server(fn(req) {
      verify_json_request(req)
      case hit(clock.data) {
        1 -> {
          set_clock(clock.data, 200_000, 100_000)
          json_response(429, "{\"error\":\"synthetic-rate-limit\"}")
          |> response.set_header("retry-after", "17")
        }
        _ -> json_response(200, success)
      }
    })
  let store = store()
  let refresh = bridge(cfg, 5000)
  let worker = start_worker(store, "synthetic", refresh, clock.data)
  let replies = process.new_subject()
  list.each([1, 2], fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(replies, credentials.acquire(worker))
      })
    Nil
  })
  let expected =
    Error(runtime.Failure(
      runtime.CredentialUnavailable,
      runtime.NotSent,
      Some(17_000),
    ))
  process.receive(replies, 10_000) |> should.equal(Ok(expected))
  process.receive(replies, 10_000) |> should.equal(Ok(expected))
  count(clock.data) |> should.equal(1)
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.Deferred(217_000)))
  credentials.stop(worker)
  let restored = start_worker(store, "synthetic", refresh, clock.data)
  set_clock(clock.data, 216_999, 116_999)
  credentials.acquire(restored)
  |> should.equal(
    Error(runtime.Failure(
      runtime.CredentialUnavailable,
      runtime.NotSent,
      Some(1),
    )),
  )
  count(clock.data) |> should.equal(1)
  set_clock(clock.data, 217_000, 117_000)
  let assert Ok(material) = credentials.acquire(restored)
  count(clock.data) |> should.equal(2)
  runtime_store.load(store, "synthetic") |> should.equal(Ok(material))
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.Ready))
  let assert runtime.OAuth(data) = material
  data.credential.access_token |> should.equal("synthetic-rotated-access")
  data.credential.refresh_token |> should.equal("synthetic-rotated-refresh")
  data.credential.expires_at_ms |> should.equal(3_817_000)
  list.key_find(data.private_metadata, "synthetic-unrelated")
  |> should.equal(Ok("keep"))
  credentials.stop(restored)
  stop(server)
  stop(clock.pid)
}

pub fn malformed_success_and_5xx_require_recovery_test() {
  list.each(
    [
      #(200, "{\"error\":\"rate_limited\",\"retry_after\":17}"),
      #(200, "not-json"),
      #(500, "{\"error\":\"synthetic-server-error\"}"),
      #(400, "{\"error\":\"invalid_grant\"}"),
      #(
        200,
        "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-new\"}",
      ),
      #(
        200,
        "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"refresh_token\":\"synthetic-new\",\"\\u0072efresh_token\":\"synthetic-stale\"}",
      ),
      #(
        200,
        "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"extra\":[{\"é\":1,\"\\u00e9\":2}]}",
      ),
      #(429, "{\"error\":\"rate_limit_error\",\"error\":\"invalid_grant\"}"),
      #(
        429,
        "{\"error\":\"rate_limit_error\",\"\\u0065rror\":\"invalid_grant\"}",
      ),
      #(
        429,
        "{\"error\":{\"type\":\"rate_limit_error\",\"type\":\"invalid_grant\"}}",
      ),
      #(
        429,
        "{\"error\":\"rate_limit_error\",\"refresh_token\":\"synthetic-maybe-rotated\"}",
      ),
    ],
    fn(case_) {
      let clock = clock()
      let #(server, cfg) =
        server(fn(req) {
          verify_json_request(req)
          let _ = hit(clock.data)
          json_response(case_.0, case_.1)
          |> response.set_header("retry-after", "17")
        })
      let store = store()
      let refresh = bridge(cfg, 5000)
      let worker = start_worker(store, "synthetic", refresh, clock.data)
      credentials.acquire(worker) |> should.equal(reauthorization())
      runtime_store.refresh_status(store, "synthetic")
      |> should.equal(Ok(runtime_store.NeedsReauthorization))
      credentials.stop(worker)
      let restored = start_worker(store, "synthetic", refresh, clock.data)
      set_clock(clock.data, 999_999, 899_999)
      credentials.acquire(restored) |> should.equal(reauthorization())
      count(clock.data) |> should.equal(1)
      // An explicit same-token admin save, not a read, clears the gate.
      runtime_store.load(store, "synthetic")
      |> should.equal(Ok(runtime.OAuth(old())))
      runtime_store.refresh_status(store, "synthetic")
      |> should.equal(Ok(runtime_store.NeedsReauthorization))
      runtime_store.save(store, "synthetic", runtime.OAuth(old()))
      |> should.equal(Ok(Nil))
      runtime_store.refresh_status(store, "synthetic")
      |> should.equal(Ok(runtime_store.Ready))
      credentials.stop(restored)
      stop(server)
      stop(clock.pid)
    },
  )
}

pub fn sent_timeout_retains_recovery_fence_test() {
  let clock = clock()
  let received = process.new_subject()
  let #(server, cfg) =
    server(fn(req) {
      verify_json_request(req)
      let _ = hit(clock.data)
      let release = process.new_subject()
      process.send(received, release)
      // The peer received the grant; it might rotate before a response arrives.
      let _ = process.receive(release, 10_000)
      json_response(200, success)
    })
  let store = store()
  let refresh = bridge(cfg, 1000)
  let worker = start_worker(store, "synthetic", refresh, clock.data)
  let replies = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(replies, credentials.acquire(worker))
    })
  let assert Ok(release) = process.receive(received, 5000)
  process.receive(replies, 10_000) |> should.equal(Ok(reauthorization()))
  process.send(release, Nil)
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  credentials.stop(worker)
  let restored = start_worker(store, "synthetic", refresh, clock.data)
  credentials.acquire(restored) |> should.equal(reauthorization())
  count(clock.data) |> should.equal(1)
  credentials.stop(restored)
  stop(server)
  stop(clock.pid)
}

pub fn successful_refresh_is_singleflight_and_persisted_test() {
  let clock = clock()
  let #(server, cfg) =
    server(fn(req) {
      verify_json_request(req)
      let _ = hit(clock.data)
      json_response(200, success)
    })
  let store = store()
  let worker = start_worker(store, "synthetic", bridge(cfg, 5000), clock.data)
  let replies = process.new_subject()
  list.each([1, 2], fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(replies, credentials.acquire(worker))
      })
    Nil
  })
  let assert Ok(Ok(first)) = process.receive(replies, 10_000)
  process.receive(replies, 10_000) |> should.equal(Ok(Ok(first)))
  runtime_store.load(store, "synthetic") |> should.equal(Ok(first))
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.Ready))
  count(clock.data) |> should.equal(1)
  credentials.stop(worker)
  stop(server)
  stop(clock.pid)
}

pub fn same_token_admin_replacement_defeats_refresh_cas_test() {
  let clock = clock()
  let received = process.new_subject()
  let #(server, cfg) =
    server(fn(req) {
      verify_json_request(req)
      let release = process.new_subject()
      process.send(received, release)
      let assert Ok(Nil) = process.receive(release, 10_000)
      json_response(200, success)
    })
  let store = store()
  let worker = start_worker(store, "synthetic", bridge(cfg, 5000), clock.data)
  let replies = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(replies, credentials.acquire(worker))
    })
  let assert Ok(release) = process.receive(received, 5000)
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.NeedsReauthorization))
  runtime_store.save(store, "synthetic", runtime.OAuth(old()))
  |> should.equal(Ok(Nil))
  process.send(release, Nil)
  process.receive(replies, 10_000)
  |> should.equal(
    Ok(Error(runtime.Failure(runtime.Persistence, runtime.NotSent, None))),
  )
  runtime_store.load(store, "synthetic")
  |> should.equal(Ok(runtime.OAuth(old())))
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.Ready))
  credentials.stop(worker)
  stop(server)
  stop(clock.pid)
}

pub fn proven_not_sent_is_separate_from_claude_unknown_error_test() {
  let clock = clock()
  let store = store()
  // This callback is an affirmative preflight rejection: no transport function
  // is called. Claude's generic string transport errors cannot express this.
  let refresh = runtime.Refresh(fn(_, _) { Error(runtime.RefreshRetryable) })
  let worker = start_worker(store, "synthetic", refresh, clock.data)
  credentials.acquire(worker)
  |> should.equal(
    Error(runtime.Failure(
      runtime.CredentialUnavailable,
      runtime.NotSent,
      Some(5000),
    )),
  )
  runtime_store.refresh_status(store, "synthetic")
  |> should.equal(Ok(runtime_store.Deferred(105_000)))
  count(clock.data) |> should.equal(0)
  credentials.stop(worker)
  stop(clock.pid)
}

fn seed(path) {
  let assert Ok(store) = storage.new(path)
  list.each(
    [
      #("deferred", 429, "{\"error\":\"synthetic\"}"),
      #("fenced", 200, "{\"error\":\"synthetic\"}"),
      #(
        "duplicate-success",
        200,
        "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"refresh_token\":\"synthetic-stale\",\"refresh_token\":\"synthetic-new\"}",
      ),
      #(
        "duplicate-error",
        429,
        "{\"error\":\"rate_limit_error\",\"\\u0065rror\":\"invalid_grant\"}",
      ),
      #(
        "duplicate-nested",
        200,
        "{\"access_token\":\"synthetic\",\"expires_in\":3600,\"extra\":[{\"é\":1,\"\\u00e9\":2}]}",
      ),
    ],
    fn(case_) {
      let clock = clock()
      let #(server, cfg) =
        server(fn(req) {
          verify_json_request(req)
          json_response(case_.1, case_.2)
          |> response.set_header("retry-after", "17")
        })
      runtime_store.save(store, case_.0, runtime.OAuth(old()))
      |> should.equal(Ok(Nil))
      let worker = start_worker(store, case_.0, bridge(cfg, 5000), clock.data)
      let _ = credentials.acquire(worker)
      let expected = case case_.0 {
        "deferred" -> runtime_store.Deferred(117_000)
        _ -> runtime_store.NeedsReauthorization
      }
      runtime_store.refresh_status(store, case_.0) |> should.equal(Ok(expected))
      credentials.stop(worker)
      stop(server)
      stop(clock.pid)
    },
  )
  io.println("PASS: actual Claude JSON outcomes persisted for fresh-VM restore")
}

fn restore(path) {
  let assert Ok(store) = storage.new(path)
  let invoked = process.new_subject()
  let refresh =
    runtime.Refresh(fn(_, _) {
      process.send(invoked, Nil)
      Error(runtime.RefreshUnavailable)
    })
  list.each(
    [
      "deferred",
      "fenced",
      "duplicate-success",
      "duplicate-error",
      "duplicate-nested",
    ],
    fn(key) {
      let assert Ok(worker) =
        credentials.start_with_clock(
          store,
          key,
          credentials.Refreshable(refresh),
          fn() { #(110_000, 0) },
        )
      let expected = case key {
        "deferred" ->
          Error(runtime.Failure(
            runtime.CredentialUnavailable,
            runtime.NotSent,
            Some(7000),
          ))
        _ -> reauthorization()
      }
      credentials.acquire(worker) |> should.equal(expected)
      runtime_store.load(store, key) |> should.equal(Ok(runtime.OAuth(old())))
      credentials.stop(worker)
    },
  )
  process.receive(invoked, 50) |> should.equal(Error(Nil))
  io.println(
    "PASS: fresh VM preserves deferral/fence without reseed or exchange",
  )
}

pub fn main() {
  case argv.load().arguments {
    ["seed", path] -> seed(path)
    ["restore", path] -> restore(path)
    [] -> {
      concurrent_json_429_completion_deadline_test()
      malformed_success_and_5xx_require_recovery_test()
      sent_timeout_retains_recovery_fence_test()
      successful_refresh_is_singleflight_and_persisted_test()
      same_token_admin_replacement_defeats_refresh_cas_test()
      proven_not_sent_is_separate_from_claude_unknown_error_test()
      io.println(
        "PASS: 6 Claude/runtime-v4 integration scenarios; assembled_ingress=false",
      )
    }
    _ ->
      panic as "Expected no args, or seed/restore with an explicit private directory"
  }
}
