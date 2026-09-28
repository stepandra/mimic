import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import mimic/corpus
import mimic/types.{type Capture, Capture, Header, Transport}
import simplifile

@external(erlang, "mimic_corpus_ffi", "test_root")
fn test_root() -> String

@external(erlang, "mimic_corpus_ffi", "blake3")
fn blake3(data: String) -> Result(String, String)

@external(erlang, "mimic_corpus_ffi", "store")
fn store(root: String, id: String, data: BitArray) -> Result(Nil, String)

fn sample() -> Capture {
  let body =
    "{\"messages\":[{\"content\":\"nested secret\",\"role\":\"user\"}]}"
  Capture(
    client: "synthetic",
    version: "1",
    endpoint: "https://example.test/v1/messages?access_token=sensitive",
    request_kind: "messages",
    method: "POST",
    target: "/v1/messages?token=sensitive",
    http_version: "HTTP/1.1",
    headers: [
      Header("Authorization", "Bearer sensitive"),
      Header("X-TrAcE", "account-uuid"),
      Header("anthropic-beta", "feature-1,feature-2"),
      Header("Content-Type", "application/json"),
      Header("Content-Length", int.to_string(string.byte_size(body))),
    ],
    body: body,
    transport: Transport("http/1.1", None),
  )
}

pub fn encode_decode_round_trip_test() {
  let capture = sample()
  let decoded = corpus.decode(corpus.encode(capture)) |> should.be_ok
  decoded |> should.equal(capture)
}

pub fn redacted_deduplicated_store_test() {
  let root = test_root()
  let capture = sample()
  let id = corpus.add(root, capture) |> should.be_ok
  string.length(id) |> should.equal(64)
  corpus.add(root, capture) |> should.equal(Ok(id))
  let captures = corpus.list(root) |> should.be_ok
  list.length(captures) |> should.equal(1)
  let saved = corpus.load(root, id) |> should.be_ok
  saved.target |> should.equal("/v1/messages?token=REDACTED")
  saved.endpoint
  |> should.equal("https://example.test/v1/messages?access_token=REDACTED")
  saved.body
  |> should.equal(
    "{\"messages\":[{\"content\":\"[REDACTED]\",\"role\":\"user\"}]}",
  )
  saved.headers
  |> list.first
  |> should.equal(Ok(Header("Authorization", "[REDACTED]")))
  let filtered =
    corpus.select(root, "synthetic", "1", capture.endpoint, "messages")
    |> should.be_ok
  list.length(filtered) |> should.equal(1)
  corpus.rotate(root, 1) |> should.equal(Ok(0))
  corpus.rotate(root, 0) |> should.be_error
  corpus.load(root, "not-an-id") |> should.be_error
}

pub fn anthropic_shape_and_nested_secret_test() {
  let old = sample()
  let body =
    "{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":1024,\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"private prompt\"},{\"type\":\"tool_use\",\"name\":\"shell\",\"input\":{\"text\":\"nested credential\"}}]}],\"stream\":true}"
  let capture =
    Capture(
      ..old,
      headers: [
        Header("Authorization", "Bearer secret"),
        Header("Content-Type", "application/json"),
        Header("Content-Length", int.to_string(string.byte_size(body))),
      ],
      body: body,
    )
  let safe = corpus.redact(capture) |> should.be_ok
  string.contains(safe.body, "\"model\":\"claude-sonnet-4-5\"")
  |> should.be_true
  string.contains(safe.body, "\"role\":\"user\"")
  |> should.be_true
  string.contains(safe.body, "\"type\":\"tool_use\"")
  |> should.be_true
  string.contains(safe.body, "\"max_tokens\":1024")
  |> should.be_true
  string.contains(safe.body, "\"text\":\"[REDACTED]\"")
  |> should.be_true
  string.contains(safe.body, "private prompt") |> should.be_false
  string.contains(safe.body, "nested credential") |> should.be_false
}

pub fn unknown_wire_values_fail_closed_test() {
  let old = sample()
  let capture =
    Capture(
      ..old,
      endpoint: "https://example.test/v1/accounts/opaque-token?secret-key=private&token=second",
      target: "/v1/accounts/opaque-token?secret-key=private&token=second",
      headers: [
        Header("User-Agent", "custom account private"),
        Header("anthropic-beta", "interleaved-thinking-2025-05-14"),
        Header("Content-Type", "application/json; charset=utf-8"),
        Header("Content-Length", int.to_string(string.byte_size(old.body))),
      ],
    )
  let safe = corpus.redact(capture) |> should.be_ok
  safe.target
  |> should.equal("/v1/REDACTED/REDACTED?redacted=REDACTED&token=REDACTED")
  safe.headers
  |> should.equal([
    Header("User-Agent", "[REDACTED]"),
    Header("anthropic-beta", "interleaved-thinking-2025-05-14"),
    Header("Content-Type", "application/json"),
    Header(
      "Content-Length",
      int.to_string(string.byte_size(
        "{\"messages\":[{\"content\":\"[REDACTED]\",\"role\":\"user\"}]}",
      )),
    ),
  ])
}

pub fn credential_keyed_map_fails_closed_test() {
  let original = sample()
  let body =
    "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"tool_use\",\"input\":{\"sk-ant-SYNTHETIC-SECRET\":\"value\"}}]}]}"
  let capture =
    Capture(
      ..original,
      headers: [
        Header("Content-Type", "application/json"),
        Header("Content-Length", int.to_string(string.byte_size(body))),
      ],
      body: body,
    )
  corpus.redact(capture) |> should.be_error
  corpus.add(test_root(), capture) |> should.be_error
  let sensitive = "{\"password\":\"synthetic\"}"
  corpus.redact(
    Capture(..capture, body: sensitive, headers: [
      Header("Content-Type", "application/json"),
      Header("Content-Length", int.to_string(string.byte_size(sensitive))),
    ]),
  )
  |> should.be_error
}

pub fn supported_json_media_remains_renderable_test() {
  let old = sample()
  list.each(
    ["APPLICATION/JSON; charset=utf-8", "application/problem+json"],
    fn(media) {
      let capture =
        Capture(..old, headers: [
          Header("Content-Type", media),
          Header("Content-Length", int.to_string(string.byte_size(old.body))),
        ])
      let safe = corpus.redact(capture) |> should.be_ok
      let assert [Header(_, content_type), ..] = safe.headers
      string.contains(content_type, "[REDACTED]") |> should.be_false
      corpus.add(test_root(), capture) |> should.be_ok
    },
  )
}

pub fn existing_corrupt_or_symlink_object_is_not_success_test() {
  let capture = sample()
  let safe = corpus.redact(capture) |> should.be_ok
  let id = blake3(corpus.encode(safe)) |> should.be_ok
  let root = test_root()
  simplifile.create_directory_all(root) |> should.be_ok
  let path = root <> "/" <> id <> ".json.zst"
  simplifile.write(path, "synthetic-corrupt-object") |> should.be_ok
  corpus.add(root, capture) |> should.be_error
  let linked_root = test_root()
  simplifile.create_directory_all(linked_root) |> should.be_ok
  simplifile.create_symlink(path, linked_root <> "/" <> id <> ".json.zst")
  |> should.be_ok
  corpus.add(linked_root, capture) |> should.be_error
}

pub fn newline_is_not_part_of_a_corpus_id_test() {
  let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  store(test_root(), id <> "\n", bit_array.from_string("synthetic"))
  |> should.be_error
}
