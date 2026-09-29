import gleam/list
import gleam/string
import gleeunit/should
import mimic/dialect/responses
import mimic/ir

// Synthetic protocol boundary fixtures, never provider captures.
pub fn decoded_duplicate_keys_fail_before_map_conversion_test() {
  [
    "{\"model\":\"a\",\"model\":\"b\"}",
    "{\"model\":\"a\",\"\\u006dodel\":\"b\"}",
    "{\"nested\":[{\"x\":1,\"x\":2}]}",
    "{\"😀\":1,\"\\ud83d\\ude00\":2}",
  ]
  |> list.each(fn(source) { ir.parse(source) |> should.be_error })
  responses.decode_request("{\"model\":\"a\",\"input\":[],\"model\":\"b\"}")
  |> should.be_error
}

pub fn native_extensions_and_independent_object_keys_survive_test() {
  let source =
    "{\"model\":\"synthetic\",\"input\":[{\"type\":\"reasoning\",\"encrypted_content\":\"opaque\"}],\"vendor\":{\"x\":1},\"other\":{\"x\":2}}"
  let assert Ok(request) = responses.decode_request(source)
  let assert Ok(roundtrip) =
    responses.decode_request(responses.encode_request(request))
  roundtrip |> should.equal(request)
}

pub fn explicit_json_budgets_are_inclusive_test() {
  ir.parse_bounded("[0]", 3, 1, 2) |> should.be_ok
  ir.parse_bounded("[0]", 2, 1, 2) |> should.be_error
  ir.parse_bounded("[0]", 3, 1, 1) |> should.be_error
  ir.parse_bounded("[[]]", 4, 1, 2) |> should.be_error
  ir.parse_bounded("[[]]", 4, 2, 2) |> should.be_ok
  ir.parse_bounded("\"é\"", 4, 1, 1) |> should.be_ok
  ir.parse_bounded("\"é\"", 3, 1, 1) |> should.be_error
  ir.parse_bounded("0", 0, 1, 1) |> should.be_error
  ir.parse_bounded("0", 1, 0, 1) |> should.be_error
  ir.parse_bounded("0", 1, 1, 0) |> should.be_error
}

pub fn malformed_json_is_still_rejected_by_authoritative_decoder_test() {
  ["[1,]", "{\"a\":1,}", "true false", "01", "\"\\q\"", "{]", ""]
  |> list.each(fn(source) { ir.parse(source) |> should.be_error })
  let secret = "{\"private-secret\":1,\"private-secret\":2}"
  let assert Error(error) = ir.parse(secret)
  string.contains(error, "private-secret") |> should.be_false
}
