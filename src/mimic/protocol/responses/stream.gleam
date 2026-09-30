import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses
import mimic/ir
import mimic/protocol/sse

pub type Outcome {
  Completed
  Incomplete
  Failed
  RemoteError
  Cancelled
}

pub type Event {
  Event(name: String, document: ir.Value)
}

/// Already validated events survive a later malformed frame in the same
/// transport chunk. An Error next contains no reusable stream state.
pub type Batch {
  Batch(events: List(Event), next: Result(Stream, String))
}

type Item {
  Item(
    id: String,
    kind: String,
    call_id: Option(String),
    tool_name: Option(String),
    done: Bool,
    arguments_done: Bool,
    parts: Dict(#(String, Int), Part),
  )
}

type Part {
  Part(kind: String, text_done: Bool, done: Bool)
}

/// Bounded metadata, never accumulated generated content or terminal documents.
pub opaque type Stream {
  Stream(
    framing: sse.Decoder,
    response_id: Option(String),
    sequence: Option(Int),
    items: Dict(Int, Item),
    outcome: Option(Outcome),
    max_frame_bytes: Int,
    max_items: Int,
    max_parts: Int,
  )
}

pub fn new() -> Stream {
  new_with_limits(1_048_576, 4096, 4096)
}

/// Bounds include unfinished lines and all SSE fields, not just JSON data.
pub fn new_with_limits(
  max_frame_bytes: Int,
  max_items: Int,
  max_parts: Int,
) -> Stream {
  Stream(
    sse.new(max_frame_bytes),
    None,
    None,
    dict.new(),
    None,
    max_frame_bytes,
    max_items,
    max_parts,
  )
}

/// Processes one transport chunk atomically. On Error discard this operation's
/// state and cancel transport; it is never safe to retry a partially-read stream.
pub fn feed(
  stream: Stream,
  chunk: BitArray,
) -> Result(#(Stream, List(Event)), String) {
  let batch = feed_partial(stream, chunk)
  use next <- result.try(batch.next)
  Ok(#(next, batch.events))
}

/// Streaming callers should prefer this over atomic feed: TCP chunk boundaries
/// must not decide whether a valid prefix is delivered before a later failure.
pub fn feed_partial(stream: Stream, chunk: BitArray) -> Batch {
  partial_frames(stream, chunk, [])
}

fn partial_frames(
  stream: Stream,
  chunk: BitArray,
  events: List(Event),
) -> Batch {
  case sse.feed_one(stream.framing, chunk) {
    Error(error) -> Batch(list.reverse(events), Error(error))
    Ok(#(framing, frame, rest)) -> {
      let stream = Stream(..stream, framing: framing)
      case frame {
        None -> Batch(list.reverse(events), Ok(stream))
        Some(frame) ->
          case dispatch(stream, frame) {
            Error(error) -> Batch(list.reverse(events), Error(error))
            Ok(#(next, event)) ->
              partial_frames(next, rest, case event {
                None -> events
                Some(event) -> [event, ..events]
              })
          }
      }
    }
  }
}

fn dispatch(
  stream: Stream,
  frame: sse.Frame,
) -> Result(#(Stream, Option(Event)), String) {
  let sse.Frame(name, data) = frame
  case data {
    "" -> Ok(#(stream, None))
    "[DONE]" -> {
      use _ <- result.try(ensure(
        stream.outcome != None,
        "Responses [DONE] without a protocol terminal",
      ))
      Ok(#(stream, None))
    }
    _ -> {
      use document <- result.try(ir.parse(data))
      use actual <- result.try(responses.nonempty_string(document, "type"))
      use _ <- result.try(ensure(
        name == "" || name == actual,
        "Responses SSE event name disagrees with JSON type",
      ))
      use pair <- result.try(push(stream, document))
      Ok(#(pair.0, Some(pair.1)))
    }
  }
}

/// WS transports call this with a complete decoded text message. SSE and WS
/// share event ordering, sequence, item identity and terminal validation.
pub fn push(
  stream: Stream,
  document: ir.Value,
) -> Result(#(Stream, Event), String) {
  use _ <- result.try(ensure(
    stream.outcome == None,
    "Responses event after terminal",
  ))
  use _ <- result.try(ensure(
    bit_array.byte_size(bit_array.from_string(ir.stringify(document)))
      <= stream.max_frame_bytes,
    "Responses event exceeds byte limit",
  ))
  use name <- result.try(responses.nonempty_string(document, "type"))
  use _ <- result.try(ensure(
    safe_event_name(name),
    "invalid Responses event type",
  ))
  use sequence <- result.try(ir.optional_int(document, "sequence_number"))
  use _ <- result.try(case sequence, stream.sequence {
    Some(next), Some(previous) ->
      ensure(next > previous, "Responses sequence_number did not increase")
    Some(next), None -> ensure(next >= 0, "negative Responses sequence_number")
    None, _ -> Ok(Nil)
  })
  let stream = case sequence {
    None -> stream
    Some(_) -> Stream(..stream, sequence: sequence)
  }
  use stream <- result.try(apply_event(stream, name, document))
  Ok(#(stream, Event(name, document)))
}

fn apply_event(
  stream: Stream,
  name: String,
  value: ir.Value,
) -> Result(Stream, String) {
  case name {
    "error" -> {
      let error = case ir.field(value, "error") {
        None -> value
        Some(error) -> error
      }
      use _ <- result.try(responses.nonempty_string(error, "message"))
      Ok(Stream(..stream, outcome: Some(RemoteError)))
    }
    "response.created" -> {
      use _ <- result.try(ensure(
        stream.response_id == None,
        "duplicate response.created",
      ))
      use response <- result.try(event_response(value))
      use _ <- result.try(ensure(
        response.status == responses.InProgress
          || response.status == responses.Queued,
        "response.created has terminal status",
      ))
      use _ <- result.try(ensure(
        response.output == [],
        "response.created contains output",
      ))
      Ok(Stream(..stream, response_id: Some(response.id)))
    }
    "response.completed"
    | "response.incomplete"
    | "response.failed"
    | "response.cancelled" -> terminal(stream, name, value)
    "keepalive" -> Ok(stream)
    _ -> {
      use _ <- result.try(ensure(
        stream.response_id != None,
        "Responses event before response.created",
      ))
      case name {
        "response.in_progress" | "response.queued" -> {
          use response <- result.try(event_response(value))
          use _ <- result.try(ensure(
            Some(response.id) == stream.response_id,
            "Responses response id changed",
          ))
          use _ <- result.try(ensure(
            response.status == responses.InProgress
              || response.status == responses.Queued,
            "nonterminal Responses event has terminal status",
          ))
          Ok(stream)
        }
        "response.output_item.added" -> add_item(stream, value)
        "response.output_item.done" -> finish_item(stream, value)
        "response.content_part.added" ->
          part_event(stream, value, "content", "added")
        "response.content_part.done" ->
          part_event(stream, value, "content", "done")
        "response.reasoning_summary_part.added" ->
          part_event(stream, value, "summary", "added")
        "response.reasoning_summary_part.done" ->
          part_event(stream, value, "summary", "done")
        "response.output_text.delta"
        | "response.output_text.done"
        | "response.refusal.delta"
        | "response.refusal.done"
        | "response.reasoning_text.delta"
        | "response.reasoning_text.done"
        | "response.reasoning_summary_text.delta"
        | "response.reasoning_summary_text.done" ->
          text_event(stream, name, value)
        "response.function_call_arguments.delta"
        | "response.function_call_arguments.done"
        | "response.custom_tool_call_input.delta"
        | "response.custom_tool_call_input.done" ->
          arguments_event(stream, name, value)
        // Unknown native extensions are data. Do not pretend to convert them.
        _ -> Ok(stream)
      }
    }
  }
}

fn add_item(stream: Stream, value: ir.Value) -> Result(Stream, String) {
  use index <- result.try(responses.nonnegative_int(value, "output_index"))
  use _ <- result.try(ensure(
    index == dict.size(stream.items) && index < stream.max_items,
    "Responses output_index is duplicate, out of order or exceeds limit",
  ))
  use item <- result.try(ir.required(value, "item"))
  use _ <- result.try(responses.validate_output_item(item))
  use id <- result.try(responses.nonempty_string(item, "id"))
  use kind <- result.try(responses.nonempty_string(item, "type"))
  use call_id <- result.try(ir.optional_string(item, "call_id"))
  use tool_name <- result.try(ir.optional_string(item, "name"))
  use _ <- result.try(ensure(
    !list.any(dict.values(stream.items), fn(prior) {
      prior.id == id || call_id != None && prior.call_id == call_id
    }),
    "duplicate Responses item id or call_id",
  ))
  Ok(
    Stream(
      ..stream,
      items: dict.insert(
        stream.items,
        index,
        Item(id, kind, call_id, tool_name, False, False, dict.new()),
      ),
    ),
  )
}

fn open_item(stream: Stream, value: ir.Value) -> Result(#(Int, Item), String) {
  use index <- result.try(responses.nonnegative_int(value, "output_index"))
  use item <- result.try(
    dict.get(stream.items, index)
    |> result.map_error(fn(_) { "Responses event for unknown output_index" }),
  )
  use id <- result.try(responses.nonempty_string(value, "item_id"))
  use _ <- result.try(ensure(item.id == id, "Responses item_id changed"))
  use _ <- result.try(ensure(
    !item.done,
    "Responses event for closed output item",
  ))
  Ok(#(index, item))
}

fn finish_item(stream: Stream, value: ir.Value) -> Result(Stream, String) {
  use index <- result.try(responses.nonnegative_int(value, "output_index"))
  use prior <- result.try(
    dict.get(stream.items, index)
    |> result.map_error(fn(_) { "Responses item done without added" }),
  )
  use item <- result.try(ir.required(value, "item"))
  use _ <- result.try(responses.validate_output_item(item))
  use id <- result.try(responses.nonempty_string(item, "id"))
  use kind <- result.try(responses.nonempty_string(item, "type"))
  use call_id <- result.try(ir.optional_string(item, "call_id"))
  use tool_name <- result.try(ir.optional_string(item, "name"))
  use _ <- result.try(ensure(
    !prior.done
      && prior.id == id
      && prior.kind == kind
      && prior.call_id == call_id
      && prior.tool_name == tool_name,
    "Responses output_item.done identity mismatch or duplicate",
  ))
  use _ <- result.try(ensure(
    list.all(dict.values(prior.parts), fn(p) { p.done }),
    "Responses item done with open content parts",
  ))
  use _ <- result.try(ensure(
    kind != "function_call"
      && kind != "custom_tool_call"
      || prior.arguments_done,
    "Responses tool item done before arguments/input done",
  ))
  Ok(
    Stream(
      ..stream,
      items: dict.insert(stream.items, index, Item(..prior, done: True)),
    ),
  )
}

fn part_event(
  stream: Stream,
  value: ir.Value,
  group: String,
  action: String,
) -> Result(Stream, String) {
  use pair <- result.try(open_item(stream, value))
  let #(index, item) = pair
  use part_index <- result.try(responses.nonnegative_int(
    value,
    group <> "_index",
  ))
  let key = #(group, part_index)
  use part <- result.try(ir.required(value, "part"))
  use _ <- result.try(responses.validate_content(part))
  use kind <- result.try(responses.nonempty_string(part, "type"))
  use _ <- result.try(ensure(
    case group, item.kind, kind {
      "summary", "reasoning", "summary_text" -> True
      "content", "reasoning", "reasoning_text" -> True
      "content", "message", _ ->
        kind != "summary_text"
        && kind != "reasoning_text"
        && !string.starts_with(kind, "input_")
      _, _, _ -> False
    },
    "Responses content part on wrong-kind item",
  ))
  use updated <- result.try(case action, dict.get(item.parts, key) {
    "added", Error(_) -> {
      let count =
        dict.keys(item.parts)
        |> list.filter(fn(key) { key.0 == group })
        |> list.length
      use _ <- result.try(ensure(
        dict.size(item.parts) < stream.max_parts && part_index == count,
        "Responses part index out of order or limit exceeded",
      ))
      Ok(Part(kind, False, False))
    }
    "done", Ok(prior) -> {
      use _ <- result.try(ensure(
        !prior.done && prior.kind == kind,
        "Responses part done mismatch",
      ))
      use _ <- result.try(ensure(
        !list.contains(
          ["output_text", "refusal", "summary_text", "reasoning_text"],
          kind,
        )
          || prior.text_done,
        "Responses content part done before text done",
      ))
      Ok(Part(..prior, done: True))
    }
    _, _ -> Error("Responses part done without added or duplicate part")
  })
  Ok(
    Stream(
      ..stream,
      items: dict.insert(
        stream.items,
        index,
        Item(..item, parts: dict.insert(item.parts, key, updated)),
      ),
    ),
  )
}

fn text_event(
  stream: Stream,
  name: String,
  value: ir.Value,
) -> Result(Stream, String) {
  use pair <- result.try(open_item(stream, value))
  let #(index, item) = pair
  let summary = string.starts_with(name, "response.reasoning_summary_text.")
  let group = case summary {
    True -> "summary"
    False -> "content"
  }
  use part_index <- result.try(responses.nonnegative_int(
    value,
    group <> "_index",
  ))
  let key = #(group, part_index)
  use part <- result.try(
    dict.get(item.parts, key)
    |> result.map_error(fn(_) { "Responses text event without content part" }),
  )
  let expected = case summary {
    True -> "summary_text"
    False ->
      name
      |> string.drop_start(9)
      |> string.split(".")
      |> list.first
      |> result.unwrap("")
  }
  use _ <- result.try(ensure(
    !part.done && !part.text_done && part.kind == expected,
    "Responses text event on closed or wrong-kind part",
  ))
  let done = string.ends_with(name, ".done")
  let field = case done, expected {
    False, _ -> "delta"
    True, "refusal" -> "refusal"
    True, _ -> "text"
  }
  use _ <- result.try(ir.string_field(value, field))
  Ok(
    Stream(
      ..stream,
      items: dict.insert(
        stream.items,
        index,
        Item(
          ..item,
          parts: dict.insert(item.parts, key, Part(..part, text_done: done)),
        ),
      ),
    ),
  )
}

fn arguments_event(
  stream: Stream,
  name: String,
  value: ir.Value,
) -> Result(Stream, String) {
  use pair <- result.try(open_item(stream, value))
  let #(index, item) = pair
  let custom = string.starts_with(name, "response.custom_tool_call_input.")
  let kind = case custom {
    True -> "custom_tool_call"
    False -> "function_call"
  }
  use _ <- result.try(ensure(
    item.kind == kind && !item.arguments_done,
    "Responses arguments event on closed or wrong-kind tool",
  ))
  let done = string.ends_with(name, ".done")
  let field = case done, custom {
    False, _ -> "delta"
    True, True -> "input"
    True, False -> "arguments"
  }
  use _ <- result.try(ir.string_field(value, field))
  Ok(
    Stream(
      ..stream,
      items: dict.insert(
        stream.items,
        index,
        Item(..item, arguments_done: done),
      ),
    ),
  )
}

fn event_response(value: ir.Value) -> Result(responses.Response, String) {
  use document <- result.try(ir.required(value, "response"))
  responses.response_from_value(document)
}

fn terminal(
  stream: Stream,
  name: String,
  value: ir.Value,
) -> Result(Stream, String) {
  use response <- result.try(event_response(value))
  use _ <- result.try(ensure(
    stream.response_id == Some(response.id),
    "Responses terminal without created or response id mismatch",
  ))
  let #(status, outcome) = case name {
    "response.completed" -> #(responses.Completed, Completed)
    "response.incomplete" -> #(responses.Incomplete, Incomplete)
    "response.failed" -> #(responses.Failed, Failed)
    _ -> #(responses.Cancelled, Cancelled)
  }
  use _ <- result.try(ensure(
    response.status == status,
    "Responses terminal status mismatch",
  ))
  use _ <- result.try(case outcome {
    Completed -> {
      use _ <- result.try(ensure(
        list.all(dict.values(stream.items), fn(item) { item.done }),
        "response.completed with open output items",
      ))
      use _ <- result.try(ensure(
        list.length(response.output) == dict.size(stream.items),
        "response.completed output does not match streamed items",
      ))
      Ok(Nil)
    }
    _ -> Ok(Nil)
  })
  use _ <- result.try(
    list.index_map(response.output, fn(item, index) { #(index, item) })
    |> list.try_each(fn(pair) {
      use prior <- result.try(
        dict.get(stream.items, pair.0)
        |> result.map_error(fn(_) { "unknown terminal output index" }),
      )
      use id <- result.try(responses.nonempty_string(pair.1, "id"))
      use kind <- result.try(responses.nonempty_string(pair.1, "type"))
      use call_id <- result.try(ir.optional_string(pair.1, "call_id"))
      use tool_name <- result.try(ir.optional_string(pair.1, "name"))
      ensure(
        id == prior.id
          && kind == prior.kind
          && call_id == prior.call_id
          && tool_name == prior.tool_name,
        "terminal Responses output identity mismatch",
      )
    }),
  )
  Ok(Stream(..stream, outcome: Some(outcome), items: dict.new()))
}

pub fn terminal_response(event: Event) -> Result(responses.Response, String) {
  case event.name {
    "response.completed"
    | "response.incomplete"
    | "response.failed"
    | "response.cancelled" -> event_response(event.document)
    _ -> Error("not a Responses terminal response event")
  }
}

pub fn encode_event(event: Event) -> String {
  // Validated events always have a safe name. Still prevent frame injection
  // from a caller constructing the public Event type without validation.
  let prefix = case safe_event_name(event.name) {
    True -> "event: " <> event.name <> "\n"
    False -> ""
  }
  prefix <> "data: " <> ir.stringify(event.document) <> "\n\n"
}

fn safe_event_name(name: String) -> Bool {
  name != ""
  && !string.contains(name, "\r")
  && !string.contains(name, "\n")
  && !string.contains(name, "\u{0000}")
}

pub fn finish(stream: Stream) -> Result(Outcome, String) {
  use _ <- result.try(
    sse.finish(stream.framing)
    |> result.replace_error("truncated Responses SSE frame"),
  )
  case stream.outcome {
    None -> Error("Responses disconnected before protocol terminal")
    Some(outcome) -> Ok(outcome)
  }
}

pub fn cancel(stream: Stream) -> Stream {
  case stream.outcome {
    Some(_) -> stream
    None ->
      Stream(
        ..stream,
        framing: sse.reset(stream.framing),
        items: dict.new(),
        outcome: Some(Cancelled),
      )
  }
}

pub fn outcome(stream: Stream) -> Option(Outcome) {
  stream.outcome
}

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
