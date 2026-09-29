import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/dialect/openai
import mimic/providers/contracts as c
import mimic/providers/devin/continuation
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb
import mimic/providers/devin/request

@external(erlang, "mimic_auth_test_ffi", "state_directory")
fn directory() -> String

fn context() -> c.Context {
  c.Context(
    "devin",
    "session_token",
    "synthetic-account",
    "http://127.0.0.1:9191",
    "synthetic-runtime-client-key",
    c.SessionToken("synthetic-token", []),
  )
}

fn request() -> c.Request {
  c.Request(
    "devin",
    "session_token",
    "devin/swe-1-7",
    "openai-chat",
    "generate",
    c.Buffered,
    [],
    "synthetic-client-session",
    Some("synthetic-account"),
    "{\"model\":\"devin/swe-1-7\",\"messages\":[{\"role\":\"user\",\"content\":\"first\"},{\"role\":\"user\",\"content\":\"second\"}]}",
  )
}

pub fn native_thread_scoped_ordinal_and_user_boundary_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) =
    runtime_store.save(store, "synthetic", context().credential)
  let assert Ok(record) = runtime_store.load_record(store, "synthetic")
  let assert Ok(scope) = continuation.new(context(), request(), record)
  let assert Ok(next) =
    continuation.advance(scope, context(), request(), record)
  continuation.ordinal(next) |> should.equal(1)
  continuation.session(next) |> should.equal(continuation.session(scope))
  continuation.cascade(next) |> should.equal(continuation.session(scope))
  let assert Ok(input) = openai.decode_request(request().body)
  let assert Ok(bytes) =
    request.encode_continuation(
      input,
      "synthetic-token",
      request.Identity("linux", "", "ignored", "message"),
      models.baseline(),
      next,
    )
  let assert <<0, n:32-big, payload:bytes-size(n)>> = bytes
  let assert Ok(fields) = pb.decode(payload)
  list.contains(
    fields,
    pb.message(15, [
      pb.text(1, continuation.session(scope)),
      pb.Varint(2, 1),
      pb.Varint(3, 4),
    ]),
  )
  |> should.be_true
  list.contains(fields, pb.text(16, continuation.cascade(scope)))
  |> should.be_true
  request.encode_continuation(
    input,
    "other-token",
    request.Identity("linux", "", "", ""),
    models.baseline(),
    next,
  )
  |> should.be_error
}

pub fn continuation_never_crosses_account_client_model_origin_generation_test() {
  let assert Ok(store) = storage.new(directory())
  let assert Ok(_) =
    runtime_store.save(store, "synthetic", context().credential)
  let assert Ok(record) = runtime_store.load_record(store, "synthetic")
  let assert Ok(scope) = continuation.new(context(), request(), record)
  [
    c.Context(..context(), account: "other"),
    c.Context(..context(), session_key: "other"),
    c.Context(..context(), origin: "http://127.0.0.1:9192"),
    c.Context(..context(), credential: c.SessionToken("other-token", [])),
  ]
  |> list.each(fn(context) {
    continuation.advance(scope, context, request(), record) |> should.be_error
  })
  continuation.advance(
    scope,
    context(),
    c.Request(..request(), model: "devin/other"),
    record,
  )
  |> should.be_error
  continuation.advance(
    scope,
    context(),
    c.Request(..request(), pinned_account: None),
    record,
  )
  |> should.be_error
  // Same-token replacement still changes the opaque generation.
  let assert Ok(_) =
    runtime_store.save(store, "synthetic", context().credential)
  let assert Ok(new_record) = runtime_store.load_record(store, "synthetic")
  continuation.advance(scope, context(), request(), new_record)
  |> should.be_error
}
