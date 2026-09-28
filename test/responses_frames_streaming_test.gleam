import gleam/bit_array
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import mimic/protocol/responses/frames

pub fn feed_one_preserves_valid_prefix_before_coalesced_malformed_frame_test() {
  let assert Ok(decoder) = frames.new(frames.Client, 1024, 1024)
  let assert Ok(frame) = frames.encode_text(frames.Server, "valid", None)
  let bytes = <<frame:bits, 131, 0>>
  int.range(0, bit_array.byte_size(bytes) + 1, Nil, fn(_, split) {
    let assert <<a:bits-size(split * 8), b:bits>> = bytes
    let assert Ok(#(next, first, tail)) = frames.feed_one(decoder, a)
    case first {
      Some(frames.Text("valid")) -> {
        frames.feed_one(next, <<tail:bits, b:bits>>) |> should.be_error
      }
      None -> {
        let assert Ok(#(next, Some(frames.Text("valid")), tail)) =
          frames.feed_one(next, b)
        frames.feed_one(next, tail) |> should.be_error
      }
      _ -> panic as "valid text must be first and returned once"
    }
    Nil
  })
}

pub fn feed_one_empty_control_fragment_and_close_progress_test() {
  let assert Ok(decoder) = frames.new(frames.Client, 32, 32)
  let bytes = <<1, 1, 226, 137, 0, 128, 2, 130, 172, 136, 0>>
  let assert Ok(#(decoder, Some(frames.Ping(<<>>)), rest)) =
    frames.feed_one(decoder, bytes)
  let assert Ok(#(decoder, Some(frames.Text("€")), rest)) =
    frames.feed_one(decoder, rest)
  let assert Ok(#(decoder, Some(frames.Close(None, None)), <<>>)) =
    frames.feed_one(decoder, rest)
  frames.finish(decoder) |> should.be_ok
}
