import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import mimic/ir
import mimic/providers/devin/connect
import mimic/providers/devin/protobuf as pb

pub type Event {
  Text(String)
  Usage(ir.Usage)
  Stop
}

pub opaque type Decoder {
  Decoder(
    connect: connect.Decoder,
    pending_text: BitArray,
    stopped: Bool,
    usage: Option(ir.Usage),
  )
}

pub fn new() -> Decoder {
  Decoder(connect.new(), <<>>, False, None)
}

pub fn feed(
  decoder: Decoder,
  bytes: BitArray,
) -> Result(#(Decoder, List(Event)), String) {
  use #(framing, frames) <- result.try(connect.feed(decoder.connect, bytes))
  use #(decoder, events) <- result.try(consume(decoder, frames, []))
  Ok(#(Decoder(..decoder, connect: framing), events))
}

pub fn finish(decoder: Decoder) -> Result(Nil, String) {
  use _ <- result.try(connect.finish(decoder.connect))
  case decoder.pending_text {
    <<>> -> Ok(Nil)
    _ -> Error("truncated devin UTF-8 text")
  }
}

fn consume(
  decoder: Decoder,
  frames: List(connect.Frame),
  events: List(Event),
) -> Result(#(Decoder, List(Event)), String) {
  case frames {
    [] -> Ok(#(decoder, list.reverse(events)))
    [connect.End, ..rest] -> {
      case decoder.pending_text {
        <<>> -> consume(decoder, rest, [Stop, ..events])
        _ -> Error("truncated devin UTF-8 text")
      }
    }
    [connect.Data(bytes), ..rest] -> {
      use fields <- result.try(pb.decode(bytes))
      use #(decoder, next) <- result.try(fields_to_events(decoder, fields, []))
      // A protobuf message is unordered: its stop marker applies after all
      // content in that message, regardless of its physical field position.
      let stop =
        list.fold(fields, 0, fn(last, field) {
          case field {
            pb.Varint(5, reason) -> reason
            _ -> last
          }
        })
      consume(
        Decoder(..decoder, stopped: decoder.stopped || stop != 0),
        rest,
        list.append(list.reverse(next), events),
      )
    }
  }
}

fn fields_to_events(
  decoder: Decoder,
  fields: List(pb.Field),
  events: List(Event),
) -> Result(#(Decoder, List(Event)), String) {
  case fields {
    [] -> Ok(#(decoder, list.reverse(events)))
    [field, ..rest] -> {
      case field {
        pb.Bytes(3, text) if !decoder.stopped -> {
          use #(text, pending) <- result.try(
            utf8(<<decoder.pending_text:bits, text:bits>>),
          )
          let events = case text {
            "" -> events
            _ -> [Text(text), ..events]
          }
          fields_to_events(
            Decoder(..decoder, pending_text: pending),
            rest,
            events,
          )
        }
        pb.Varint(5, reason) if reason == 0 || reason == 2 || reason == 4 ->
          fields_to_events(decoder, rest, events)
        pb.Bytes(7, bytes) -> {
          use usage <- result.try(decode_usage(bytes))
          let usage = merge_usage(decoder.usage, usage)
          fields_to_events(Decoder(..decoder, usage: Some(usage)), rest, [
            Usage(usage),
            ..events
          ])
        }
        // Known non-content metadata. Unknown fields are not silently lost.
        pb.Bytes(1, _)
        | pb.Bytes(2, _)
        | pb.Varint(2, _)
        | pb.Varint(4, _)
        | pb.Fixed64(12, _)
        | pb.Bytes(17, _) -> fields_to_events(decoder, rest, events)
        _ -> Error("unsupported devin response field or stop reason")
      }
    }
  }
}

/// Validate split UTF-8 without unbounded buffering. At most three bytes wait.
fn utf8(bytes: BitArray) -> Result(#(String, BitArray), String) {
  utf8_prefix(bytes, <<>>)
}

fn utf8_prefix(
  remaining: BitArray,
  valid: BitArray,
) -> Result(#(String, BitArray), String) {
  case remaining {
    <<codepoint:utf8_codepoint, rest:bits>> ->
      utf8_prefix(rest, <<valid:bits, codepoint:utf8_codepoint>>)
    <<>> -> {
      use text <- result.try(
        bit_array.to_string(valid)
        |> result.replace_error("invalid devin UTF-8"),
      )
      Ok(#(text, <<>>))
    }
    _ -> {
      use _ <- result.try(case possible_prefix(remaining) {
        True -> Ok(Nil)
        False -> Error("invalid devin UTF-8")
      })
      use text <- result.try(
        bit_array.to_string(valid)
        |> result.replace_error("invalid devin UTF-8"),
      )
      Ok(#(text, remaining))
    }
  }
}

fn possible_prefix(bytes: BitArray) -> Bool {
  case bytes {
    <<a>> -> a >= 194 && a <= 244
    <<a, b>> if b >= 128 && b <= 191 ->
      { a == 224 && b >= 160 }
      || { a >= 225 && a <= 236 }
      || { a == 237 && b <= 159 }
      || { a >= 238 && a <= 239 }
      || { a == 240 && b >= 144 }
      || { a >= 241 && a <= 243 }
      || { a == 244 && b <= 143 }
    <<a, b, c>> if c >= 128 && c <= 191 && b >= 128 && b <= 191 ->
      { a == 240 && b >= 144 }
      || { a >= 241 && a <= 243 }
      || { a == 244 && b <= 143 }
    _ -> False
  }
}

fn decode_usage(bytes: BitArray) -> Result(ir.Usage, String) {
  use fields <- result.try(pb.decode(bytes))
  // Cache usage needs codec-specific mappings; reject rather than claim zeros.
  use values <- result.try(
    list.try_map(fields, fn(field) {
      case field {
        pb.Varint(2, n) -> Ok(#(n, None))
        pb.Varint(3, n) -> Ok(#(0, Some(n)))
        pb.Varint(4, 0)
        | pb.Varint(5, 0)
        | pb.Varint(6, 200)
        | pb.Varint(6, 0)
        | pb.Bytes(8, _)
        | pb.Bytes(9, _) -> Ok(#(0, None))
        _ -> Error("unsupported devin usage field")
      }
    }),
  )
  let #(input, output) =
    list.fold(values, #(0, 0), fn(acc, value) {
      #(acc.0 + value.0, option.unwrap(value.1, acc.1))
    })
  Ok(ir.Usage(input, output, []))
}

fn merge_usage(previous: Option(ir.Usage), next: ir.Usage) -> ir.Usage {
  case previous {
    None -> next
    Some(previous) ->
      ir.Usage(
        case next.input_tokens > 0 {
          True -> next.input_tokens
          False -> previous.input_tokens
        },
        case next.output_tokens > 0 {
          True -> next.output_tokens
          False -> previous.output_tokens
        },
        [],
      )
  }
}

pub fn buffered(
  bytes: BitArray,
  id: String,
  model: String,
) -> Result(ir.Response, String) {
  use #(decoder, events) <- result.try(feed(new(), bytes))
  use _ <- result.try(finish(decoder))
  let #(text, usage) =
    list.fold(events, #("", None), fn(acc, event) {
      case event {
        Text(text) -> #(acc.0 <> text, acc.1)
        Usage(usage) -> #(acc.0, Some(usage))
        Stop -> acc
      }
    })
  Ok(ir.Response(
    id,
    model,
    [ir.Text(text, [])],
    True,
    Some("end_turn"),
    usage,
    [],
    [],
    [],
    ir.Constructed,
  ))
}
