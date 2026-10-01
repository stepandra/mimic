/// F27 regressions recovered/adapted from the exact prior source packet.
/// All catalog rows, accounts, tokens, sockets and payloads are SYNTHETIC.
import devin_messages_oracle as oracle
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import mimic/auth/runtime as credentials
import mimic/auth/runtime_store
import mimic/auth/storage
import mimic/fleet
import mimic/ir
import mimic/protocol/chat/stream as shared_chat
import mimic/providers/contracts as c
import mimic/providers/devin/bridge
import mimic/providers/devin/catalog
import mimic/providers/devin/catalog_gateway as gateway
import mimic/providers/devin/chat_gateway
import mimic/providers/devin/client
import mimic/providers/devin/configuration
import mimic/providers/devin/connect
import mimic/providers/devin/messages_gateway
import mimic/providers/devin/models
import mimic/providers/devin/protobuf as pb
import mimic/providers/registry
import mimic/providers/runtime

pub type Server

@external(erlang, "mimic_devin_f27_catalog_test_ffi", "with_servers")
fn with_servers(
  first: BitArray,
  second: BitArray,
  inspect: fn(String, BitArray) -> Bool,
  run: fn(String, Server, Server) -> a,
) -> a

@external(erlang, "mimic_devin_f27_catalog_test_ffi", "port")
fn port(server: Server) -> Int

@external(erlang, "mimic_devin_f27_catalog_test_ffi", "counts")
fn counts(server: Server) -> #(Int, Int, Int)

@external(erlang, "mimic_devin_f27_catalog_test_ffi", "finally")
fn finally(run: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "mimic_devin_f27_catalog_test_ffi", "focused")
fn focused() -> Bool

pub fn main() {
  let assert True = focused()
  Nil
}

fn catalog() -> catalog.Catalog {
  let assert Ok(value) =
    catalog.decode(
      "{\"models\":[{\"id\":\"devin/synthetic-model\",\"uid\":\"exact-synthetic-UID-v1\",\"max_tokens\":2048,\"images\":false,\"aliases\":[\"devin/synthetic-alias\",\"devin/not-enabled\"]},{\"id\":\"devin/image\",\"uid\":\"synthetic-image-UID\",\"max_tokens\":4096,\"images\":true,\"aliases\":[\"devin/image-alias\"]}]}",
    )
  value
}

fn settings(first: String, second: String) -> configuration.Configured {
  let assert Ok(value) =
    configuration.new(catalog(), [
      configuration.Account("one", first, ["devin/synthetic-alias"]),
      configuration.Account("two", second, [
        "devin/synthetic-alias", "devin/image-alias",
      ]),
    ])
  value
}

pub fn recovered_catalog_preserves_exact_alias_metadata_test() {
  catalog.lookup(catalog(), "devin/synthetic-alias")
  |> should.equal(
    Ok(catalog.Selection(
      "devin/synthetic-model",
      models.Model(
        "devin/synthetic-alias",
        "exact-synthetic-UID-v1",
        2048,
        False,
      ),
    )),
  )
  models.validate(catalog.mappings(catalog())) |> should.be_ok
  catalog.lookup(catalog(), "devin/synthetic-alias-high") |> should.be_error
  catalog.lookup(catalog(), "devin/SYNTHETIC-alias") |> should.be_error
}

pub fn omission_preserves_original_baseline_test() {
  let assert Ok(value) = configuration.from_root(ir.Object([]))
  catalog.mappings(value) |> should.equal(models.baseline())
  catalog.metadata_source(value) |> should.equal("baseline")
  configuration.enabled(value, ["devin/swe-1-7"]) |> should.be_ok
  configuration.enabled(value, ["devin/synthetic-alias"]) |> should.be_error
  messages_gateway.combined_registration("devin/swe-1-7")
  |> should.equal(messages_gateway.configured_combined_registration(
    "devin/swe-1-7",
    models.baseline(),
  ))
  chat_gateway.registration("devin/swe-1-7")
  |> should.equal(chat_gateway.configured_registration(
    "devin/swe-1-7",
    models.baseline(),
  ))
}

pub fn explicit_enabled_id_allowlist_does_not_enable_siblings_test() {
  let configured = settings("http://127.0.0.1:1", "http://127.0.0.1:2")
  configuration.lookup(configured, "devin/synthetic-alias") |> should.be_ok
  list.each(
    ["devin/synthetic-model", "devin/not-enabled", "devin/image"],
    fn(id) { gateway.registration(configured, id) |> should.be_error },
  )
  configuration.enabled(catalog(), []) |> should.be_error
  configuration.enabled(catalog(), ["devin/unknown"]) |> should.be_error
  configuration.enabled(catalog(), ["devin/image", "devin/image"])
  |> should.be_error
  configuration.new(catalog(), []) |> should.be_ok
  configuration.new(catalog(), [
    configuration.Account("one", "http://127.0.0.1:1", ["devin/image"]),
    configuration.Account("one", "http://127.0.0.1:2", ["devin/image"]),
  ])
  |> should.be_error
}

pub fn registry_and_listing_reflect_only_actual_admitted_operations_test() {
  let configured = settings("http://127.0.0.1:1", "http://127.0.0.1:2")
  let assert Ok(row) = gateway.registration(configured, "devin/synthetic-alias")
  row.protocols
  |> should.equal(["openai-chat", "anthropic-messages", "openai-responses"])
  row.auth_modes |> should.equal(["session_token"])
  row.operations |> should.equal(["generate"])
  row.capabilities |> should.equal([c.Stream, c.Buffer, c.Tools])
  let assert Ok(value) = gateway.listing(configured, row)
  let assert Some(metadata) = ir.field(value, "devin")
  ir.field(metadata, "canonical_id")
  |> should.equal(Some(ir.String("devin/synthetic-model")))
  ir.field(metadata, "native_uid")
  |> should.equal(Some(ir.String("exact-synthetic-UID-v1")))
  ir.field(metadata, "metadata_source")
  |> should.equal(Some(ir.String("operator_config")))
  ir.field(metadata, "live_discovery") |> should.equal(Some(ir.Boolean(False)))
  ir.field(metadata, "images") |> should.equal(Some(ir.Boolean(False)))
  list.each(
    [
      registry.Model(..row, protocols: ["responses"]),
      registry.Model(..row, operations: ["generate", "count"]),
      registry.Model(..row, auth_modes: ["oauth"]),
      registry.Model(..row, capabilities: [c.Stream, c.Buffer, c.Images]),
      registry.Model(..row, capabilities: [c.Buffer]),
    ],
    fn(invalid) { gateway.listing(configured, invalid) |> should.be_error },
  )
  let assert Ok(image) = gateway.registration(configured, "devin/image-alias")
  image.capabilities |> should.equal([c.Stream, c.Buffer, c.Tools, c.Images])
}

pub fn ids_uids_controls_limits_and_conflicting_metadata_reject_test() {
  list.each(
    [
      models.Model("other/x", "u", 1, False),
      models.Model("devin/", "u", 1, False),
      models.Model("devin/../x", "u", 1, False),
      models.Model("devin/x y", "u", 1, False),
      models.Model("devin/é", "u", 1, False),
      models.Model("devin/x\n", "u", 1, False),
      models.Model("devin/x", "", 1, False),
      models.Model("devin/x", "native uid", 1, False),
      models.Model("devin/x", "u\n", 1, False),
      models.Model("devin/x", "u\u{0000}", 1, False),
      models.Model("devin/x", "u\u{007f}", 1, False),
      models.Model("devin/x", "é", 1, False),
      models.Model("devin/x", "u", 0, False),
      models.Model("devin/x", "u", 128_001, False),
    ],
    fn(model) { models.validate([model]) |> should.be_error },
  )
  models.validate([
    models.Model("devin/x", "exact-native:v1/effort+opaque", 128_000, True),
  ])
  |> should.be_ok
  list.each(
    [
      [
        models.Model("devin/x", "u", 1, False),
        models.Model("devin/a", "u", 2, False),
      ],
      [
        models.Model("devin/x", "u", 1, False),
        models.Model("devin/a", "u", 1, True),
      ],
      [
        models.Model("devin/x", "u", 1, False),
        models.Model("devin/x", "v", 1, False),
      ],
    ],
    fn(maps) { models.validate(maps) |> should.be_error },
  )
}

pub fn duplicate_alias_canonical_uid_and_cross_row_collisions_reject_test() {
  let one = models.Model("devin/one", "uid-one", 1, False)
  let two = models.Model("devin/two", "uid-two", 1, False)
  list.each(
    [
      [],
      [catalog.Entry(one, ["devin/one"])],
      [catalog.Entry(one, ["devin/a", "devin/a"])],
      [catalog.Entry(one, ["devin/two"]), catalog.Entry(two, [])],
      [catalog.Entry(one, ["devin/a"]), catalog.Entry(two, ["devin/a"])],
      [catalog.Entry(one, []), catalog.Entry(one, [])],
      [
        catalog.Entry(one, []),
        catalog.Entry(models.Model(..two, uid: one.uid), []),
      ],
      [catalog.Entry(one, ["other/a"])],
      [catalog.Entry(one, ["devin/a b"])],
    ],
    fn(entries) { catalog.new(entries) |> should.be_error },
  )
}

pub fn strict_catalog_types_unknown_fields_and_decoded_duplicate_keys_reject_test() {
  list.each(
    [
      "null", "[]", "{}", "{\"models\":[]}", "{\"models\":{}}",
      "{\"models\":[],\"models\":[]}", "{\"models\":[],\"\\u006dodels\":[]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false}],\"unknown\":true}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false,\"extra\":true}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false,\"aliases\":null}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false,\"aliases\":\"devin/a\"}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false,\"aliases\":[1]}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1.0,\"images\":false}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":true,\"images\":false}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":\"false\"}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1}]}",
      "{\"models\":[{\"id\":\"devin/x\",\"uid\":\"u\",\"max_tokens\":1,\"images\":false,\"uid\":\"other\"}]}",
    ],
    fn(source) { catalog.decode(source) |> should.be_error },
  )
  catalog.decode_value(
    ir.Object([
      #("models", ir.Array([])),
      #("models", ir.Array([])),
    ]),
  )
  |> should.be_error
  configuration.from_root(ir.Object([#("devin_catalog", ir.Null)]))
  |> should.be_error
  configuration.from_root(
    ir.Object([
      #("devin_catalog", ir.Null),
      #("devin_catalog", ir.Null),
    ]),
  )
  |> should.be_error
}

pub fn catalog_row_public_id_byte_depth_and_node_bounds_test() {
  let id = "devin/" <> string.repeat("a", 250)
  let uid = string.repeat("u", 256)
  models.validate([models.Model(id, uid, 1, False)]) |> should.be_ok
  models.validate([models.Model(id <> "a", uid, 1, False)]) |> should.be_error
  models.validate([models.Model(id, uid <> "u", 1, False)]) |> should.be_error
  let entries =
    list.repeat(Nil, 64)
    |> list.index_map(fn(_, index) {
      let n = int.to_string(index)
      catalog.Entry(models.Model("devin/m" <> n, "uid-" <> n, 1, False), [])
    })
  catalog.new(entries) |> should.be_ok
  catalog.new([
    catalog.Entry(models.Model("devin/extra", "uid-extra", 1, False), []),
    ..entries
  ])
  |> should.be_error
  let one = models.Model("devin/one", "uid-one", 1, False)
  let aliases =
    list.repeat(Nil, 255)
    |> list.index_map(fn(_, index) { "devin/a" <> int.to_string(index) })
  catalog.new([catalog.Entry(one, aliases)]) |> should.be_ok
  catalog.new([catalog.Entry(one, ["devin/extra", ..aliases])])
  |> should.be_error
  catalog.decode(string.repeat(" ", 65_537)) |> should.be_error
  catalog.decode_value(
    ir.Object([#("models", ir.String(string.repeat("a", 65_537)))]),
  )
  |> should.be_error
  catalog.decode(
    "{\"models\":"
    <> string.repeat("[", 9)
    <> "0"
    <> string.repeat("]", 9)
    <> "}",
  )
  |> should.be_error
  catalog.decode(
    "{\"models\":[" <> string.join(list.repeat("{}", 4096), ",") <> "]}",
  )
  |> should.be_error
}

fn request(id: String, protocol: String, mode: c.Mode) -> c.Request {
  c.Request(
    "devin",
    "session_token",
    id,
    protocol,
    "generate",
    mode,
    [],
    "synthetic-f27-session",
    None,
    ir.stringify(
      ir.Object([
        #("model", ir.String(id)),
        #("stream", ir.Boolean(mode == c.Streaming)),
        #("max_tokens", ir.Integer(32)),
        #(
          "messages",
          ir.Array([
            ir.Object([
              #("role", ir.String("user")),
              #("content", ir.String("synthetic F27 input")),
            ]),
          ]),
        ),
      ]),
    ),
  )
}

fn context(id: String, origin: String) -> c.Context {
  c.Context(
    "devin",
    "session_token",
    id,
    origin,
    "synthetic-account-scope",
    c.SessionToken("synthetic-f27-" <> id, []),
  )
}

pub fn mapping_binds_selected_account_origin_and_auth_not_dispatch_first_test() {
  let configured = settings("http://127.0.0.1:1", "http://127.0.0.1:2")
  let image = request("devin/image-alias", "openai-chat", c.Buffered)
  let two = context("two", "http://127.0.0.1:2")
  configuration.selected(configured, two, image)
  |> should.equal(
    Ok([models.Model("devin/image-alias", "synthetic-image-UID", 4096, True)]),
  )
  list.each(
    [
      context("one", "http://127.0.0.1:1"),
      context("unknown", "http://127.0.0.1:2"),
      c.Context(..two, origin: "http://127.0.0.1:1"),
      c.Context(..two, provider: "claude"),
      c.Context(..two, auth_mode: "api_key"),
      c.Context(..two, auth_mode: "oauth"),
    ],
    fn(ctx) {
      configuration.selected(configured, ctx, image) |> should.be_error
    },
  )
  configuration.selected(
    configured,
    two,
    c.Request(..image, auth_mode: "oauth"),
  )
  |> should.be_error
}

pub fn auth_capability_protocol_operation_body_and_model_preflight_is_pure_test() {
  let configured = settings("http://127.0.0.1:1", "http://127.0.0.1:2")
  let input = request("devin/synthetic-alias", "openai-chat", c.Buffered)
  list.each(
    [
      request("devin/unknown", "openai-chat", c.Buffered),
      request("devin/not-enabled", "openai-chat", c.Buffered),
      request("devin/synthetic-model", "openai-chat", c.Buffered),
      c.Request(..input, provider: "claude"),
      c.Request(..input, auth_mode: "api_key"),
      c.Request(..input, auth_mode: "oauth"),
      c.Request(..input, protocol: "responses"),
      c.Request(..input, operation: "count"),
      c.Request(..input, required: [c.Images]),
      c.Request(..input, required: [c.Audio]),
      c.Request(..input, required: [c.Continuation]),
      c.Request(..input, required: [c.WebSocket]),
      c.Request(..input, pinned_account: Some("one")),
      c.Request(..input, body: "{}"),
      c.Request(
        ..input,
        body: request("devin/image-alias", "openai-chat", c.Buffered).body,
      ),
      c.Request(
        ..input,
        body: string.replace(
          input.body,
          "\"max_tokens\":32",
          "\"max_tokens\":2049",
        ),
      ),
      c.Request(
        ..input,
        body: string.replace(
          input.body,
          "\"max_tokens\":32",
          "\"max_tokens\":0",
        ),
      ),
      c.Request(
        ..input,
        body: string.replace(input.body, "\"stream\":false", "\"stream\":true"),
      ),
    ],
    fn(input) {
      gateway.validate(configured, input)
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
    },
  )
  gateway.validate(configured, input) |> should.be_ok
  gateway.validate(
    configured,
    request("devin/synthetic-alias", "anthropic-messages", c.Streaming),
  )
  |> should.be_ok
}

pub fn inline_images_follow_selected_model_metadata_before_runtime_test() {
  let configured = settings("http://127.0.0.1:1", "http://127.0.0.1:2")
  let body =
    "{\"model\":\"devin/synthetic-alias\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,aGk=\"}}]}]}"
  let input = request("devin/synthetic-alias", "openai-chat", c.Buffered)
  gateway.validate(configured, c.Request(..input, body: body))
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  gateway.validate(
    configured,
    c.Request(
      ..input,
      model: "devin/image-alias",
      body: string.replace(body, "devin/synthetic-alias", "devin/image-alias"),
    ),
  )
  |> should.be_ok
}

fn origin(server: Server) -> String {
  "http://127.0.0.1:" <> int.to_string(port(server))
}

fn complete() -> BitArray {
  let body = <<
    {
      connect.envelope(
        pb.encode([
          pb.text(3, "synthetic F27 reply"),
          pb.message(7, [pb.Varint(2, 8), pb.Varint(3, 5)]),
        ]),
      )
    }:bits,
    2,
    2:32-big,
    "{}":utf8,
  >>
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: application/connect+proto\r\nContent-Length: "
    <> int.to_string(bit_array.byte_size(body))
    <> "\r\nConnection: close\r\n\r\n"
  <<header:utf8, body:bits>>
}

fn inspect(header: String, body: BitArray) -> Bool {
  let token = case
    string.contains(header, "Basic synthetic-f27-one-synthetic-f27-one")
  {
    True -> "synthetic-f27-one"
    False -> "synthetic-f27-two"
  }
  let decoded = case connect.feed(connect.new(), body) {
    Ok(#(_, [connect.Data(payload)])) -> pb.decode(payload)
    _ -> Error("invalid synthetic request")
  }
  case decoded {
    Ok(fields) -> {
      let metadata = case
        list.find(fields, fn(field) {
          case field {
            pb.Bytes(1, _) -> True
            _ -> False
          }
        })
      {
        Ok(pb.Bytes(1, bytes)) -> pb.decode(bytes)
        _ -> Error("invalid synthetic metadata")
      }
      let options = case
        list.find(fields, fn(field) {
          case field {
            pb.Bytes(8, _) -> True
            _ -> False
          }
        })
      {
        Ok(pb.Bytes(8, bytes)) -> pb.decode(bytes)
        _ -> Error("invalid synthetic options")
      }
      let valid_token = case metadata {
        Ok(fields) -> list.contains(fields, pb.text(3, token))
        _ -> False
      }
      let limit = case options {
        Ok(fields) -> list.contains(fields, pb.Varint(2, 32))
        _ -> False
      }
      valid_token
      && limit
      && {
        list.contains(fields, pb.text(21, "exact-synthetic-UID-v1"))
        || list.contains(fields, pb.text(21, "synthetic-image-UID"))
      }
      && string.contains(
        header,
        "Authorization: Basic " <> token <> "-" <> token,
      )
      && string.starts_with(
        header,
        "POST /exa.api_server_pb.ApiServerService/GetChatMessage HTTP/1.1\r\n",
      )
    }
    _ -> False
  }
}

fn with_runtime(
  state: String,
  primary: Server,
  secondary: Server,
  run: fn(runtime.Runtime, configuration.Configured) -> a,
) -> a {
  let configured = settings(origin(primary), origin(secondary))
  let assert Ok(store) = storage.new(state)
  let accounts =
    [
      #("one", primary, ["devin/synthetic-alias"]),
      #("two", secondary, ["devin/synthetic-alias", "devin/image-alias"]),
    ]
    |> list.map(fn(entry) {
      let assert Ok(_) =
        runtime_store.save(
          store,
          credentials.key("devin", "session_token", entry.0),
          c.SessionToken("synthetic-f27-" <> entry.0, []),
        )
      runtime.Account(
        "devin",
        "session_token",
        entry.0,
        origin(entry.1),
        fleet.LocalLoopback,
        1,
        entry.2,
        credentials.StaticSession,
      )
    })
  let assert Ok(rows) =
    list.try_map(["devin/synthetic-alias", "devin/image-alias"], fn(id) {
      gateway.registration(configured, id)
    })
  let assert Ok(gate) = registry.new(rows)
  let assert Ok(engine) = runtime.start(store, gate, accounts)
  finally(fn() { run(engine, configured) }, fn() {
    let assert Ok(_) = runtime.stop(engine)
    Nil
  })
}

fn drain(handle: client.Client(state), frames: List(String)) -> List(String) {
  let batch = client.next(handle)
  batch.error |> should.equal(None)
  let frames = list.append(frames, batch.frames)
  case batch.done {
    True -> frames
    False -> drain(batch.client, frames)
  }
}

pub fn configured_alias_chat_json_executes_existing_runtime_exact_uid_test() {
  use state, primary, secondary <- with_servers(complete(), complete(), inspect)
  use engine, configured <- with_runtime(state, primary, secondary)
  let assert Ok(body) =
    gateway.execute(
      engine,
      None,
      request("devin/synthetic-alias", "openai-chat", c.Buffered),
      configured,
    )
  let assert Ok(value) = ir.parse(body)
  ir.field(value, "model")
  |> should.equal(Some(ir.String("devin/synthetic-alias")))
  string.contains(body, "synthetic F27 reply") |> should.be_true
  counts(primary) |> should.equal(#(1, 1, 1))
  counts(secondary) |> should.equal(#(0, 0, 0))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn configured_alias_chat_sse_preserves_f23_public_model_and_terminal_test() {
  use state, primary, secondary <- with_servers(complete(), complete(), inspect)
  use engine, configured <- with_runtime(state, primary, secondary)
  let assert Ok(#("one", opened)) =
    gateway.open_chat(
      engine,
      None,
      request("devin/synthetic-alias", "openai-chat", c.Streaming),
      configured,
    )
  let frames = drain(opened, [])
  let received =
    shared_chat.feed_partial(
      shared_chat.new_with_limits(16_777_216, 1, 128),
      bit_array.from_string(string.concat(frames)),
      Ok,
    )
  let assert Ok(next) = received.next
  shared_chat.finish(next) |> should.be_ok
  let documents =
    received.events
    |> list.filter_map(fn(event) {
      case event {
        shared_chat.Event(value) -> Ok(value)
        _ -> Error(Nil)
      }
    })
  list.is_empty(documents) |> should.be_false
  list.each(documents, fn(value) {
    ir.field(value, "model")
    |> should.equal(Some(ir.String("devin/synthetic-alias")))
  })
  string.contains(string.concat(frames), "synthetic F27 reply")
  |> should.be_true
  counts(primary) |> should.equal(#(1, 1, 1))
  counts(secondary) |> should.equal(#(0, 0, 0))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn configured_messages_json_sse_use_corrected_f24_constructor_test() {
  use state, primary, secondary <- with_servers(complete(), complete(), inspect)
  use engine, configured <- with_runtime(state, primary, secondary)
  let assert Ok(body) =
    gateway.execute(
      engine,
      None,
      request("devin/synthetic-alias", "anthropic-messages", c.Buffered),
      configured,
    )
  let assert Ok(value) = ir.parse(body)
  let assert Ok(#("one", opened)) =
    gateway.open_messages(
      engine,
      None,
      request("devin/synthetic-alias", "anthropic-messages", c.Streaming),
      configured,
    )
  let assert Ok(reconstructed) = oracle.reconstruct(drain(opened, []))
  let assert Some(id) = ir.field(value, "id")
  let assert ir.Object(fields) = reconstructed
  ir.Object(
    list.map(fields, fn(field) {
      case field.0 {
        "id" -> #("id", id)
        _ -> field
      }
    }),
  )
  |> should.equal(value)
  counts(primary) |> should.equal(#(2, 2, 2))
  counts(secondary) |> should.equal(#(0, 0, 0))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn model_only_on_second_account_cannot_borrow_first_account_credential_test() {
  use state, primary, secondary <- with_servers(complete(), complete(), inspect)
  use engine, configured <- with_runtime(state, primary, secondary)
  let assert Ok(_) =
    gateway.execute(
      engine,
      None,
      request("devin/image-alias", "openai-chat", c.Buffered),
      configured,
    )
  counts(primary) |> should.equal(#(0, 0, 0))
  counts(secondary) |> should.equal(#(1, 1, 1))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn failover_binds_mapping_and_token_to_actual_second_context_test() {
  use state, primary, secondary <- with_servers(
    <<
      "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n":utf8,
    >>,
    complete(),
    inspect,
  )
  use engine, configured <- with_runtime(state, primary, secondary)
  let assert Ok(_) =
    gateway.execute(
      engine,
      None,
      request("devin/synthetic-alias", "openai-chat", c.Buffered),
      configured,
    )
  counts(primary) |> should.equal(#(1, 1, 1))
  counts(secondary) |> should.equal(#(1, 1, 1))
  runtime.active_leases(engine) |> should.equal(Ok(0))
}

pub fn pure_rejections_do_not_touch_stopped_runtime_credentials_or_sockets_test() {
  use state, primary, secondary <- with_servers(complete(), complete(), inspect)
  let configured = settings(origin(primary), origin(secondary))
  let assert Ok(store) = storage.new(state)
  let assert Ok(_) =
    runtime_store.save(
      store,
      credentials.key("devin", "session_token", "one"),
      c.SessionToken("synthetic-f27-one", []),
    )
  let assert Ok(row) = gateway.registration(configured, "devin/synthetic-alias")
  let assert Ok(gate) = registry.new([row])
  let assert Ok(engine) =
    runtime.start(store, gate, [
      runtime.Account(
        "devin",
        "session_token",
        "one",
        origin(primary),
        fleet.LocalLoopback,
        1,
        [row.id],
        credentials.StaticSession,
      ),
    ])
  let assert Ok(_) = runtime.stop(engine)
  list.each(["openai-chat", "anthropic-messages"], fn(protocol) {
    list.each(
      ["devin/unknown", "devin/not-enabled", "devin/synthetic-model"],
      fn(id) {
        gateway.execute(
          engine,
          None,
          request(id, protocol, c.Buffered),
          configured,
        )
        |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
      },
    )
  })
  let input = request("devin/synthetic-alias", "openai-chat", c.Streaming)
  let rejected = case
    gateway.open_chat(
      engine,
      None,
      c.Request(
        ..input,
        body: request("devin/unknown", "openai-chat", c.Streaming).body,
      ),
      configured,
    )
  {
    Error(c.Failure(c.Unsupported, c.NotSent, None)) -> True
    _ -> False
  }
  rejected |> should.be_true
  let conflicting = [
    models.Model("devin/synthetic-alias", "one-uid", 2048, False),
    models.Model("devin/conflict", "one-uid", 2049, False),
  ]
  let known = request("devin/synthetic-alias", "openai-chat", c.Buffered)
  bridge.execute_configured(engine, None, known, conflicting)
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  let conflict_stream = case
    bridge.open_native_stream(
      engine,
      None,
      request("devin/synthetic-alias", "openai-chat", c.Streaming),
      conflicting,
    )
  {
    Error(c.Failure(c.Unsupported, c.NotSent, None)) -> True
    _ -> False
  }
  conflict_stream |> should.be_true
  messages_gateway.execute_configured(
    engine,
    None,
    request("devin/synthetic-alias", "anthropic-messages", c.Buffered),
    conflicting,
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
  counts(primary) |> should.equal(#(0, 0, 0))
  counts(secondary) |> should.equal(#(0, 0, 0))
}

pub fn direct_prepare_preserves_numeric_loopback_gate_and_unknown_before_credentials_test() {
  let input = request("devin/synthetic-alias", "openai-chat", c.Buffered)
  let configured = catalog.mappings(catalog())
  list.each(
    [
      "https://devin.ai",
      "http://localhost:1",
      "http://[::1]:1",
      "http://127.0.0.1:1/path",
      "http://127.0.0.1:1?query",
    ],
    fn(origin) {
      bridge.prepare_configured(context("one", origin), input, configured)
      |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
    },
  )
  let invalid =
    c.Context(
      ..context("one", "http://127.0.0.1:1"),
      credential: c.ApiKey("synthetic-f27-not-a-session"),
    )
  bridge.prepare_configured(
    invalid,
    request("devin/unknown", "openai-chat", c.Buffered),
    configured,
  )
  |> should.equal(Error(c.Failure(c.Unsupported, c.NotSent, None)))
}
