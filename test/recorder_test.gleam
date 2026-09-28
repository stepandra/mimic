import gleam/list
import gleeunit/should
import mimic/corpus
import mimic/recorder
import mimic/types.{Header}

@external(erlang, "mimic_corpus_ffi", "test_root")
fn test_root() -> String

pub fn offline_capture_test() {
  let root = test_root()
  let raw =
    "POST /v1/messages HTTP/1.1\r\nX-Api-Key: secret\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let id =
    recorder.record_request(root, raw, "synthetic", "1", "local", "messages")
    |> should.be_ok
  let safe = corpus.load(root, id) |> should.be_ok
  safe.headers
  |> list.first
  |> should.equal(Ok(Header("X-Api-Key", "[REDACTED]")))
}
