import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses
import mimic/ir

/// The pinned native executor preserves JSON event data. The public HTTP SSE
/// handler separately hydrates completed.output from observed item.done events.
/// Neither projection is a client classification or permission to continue.
pub type Projection {
  Transparent
  HydrateCompleted
}

pub type Gap {
  MissingCreated
  MissingItemIdentity
  MissingOutput
  OpenItems
  UnknownExtension
  NonCompleted
}

pub type Reconstruction {
  Reconstructed(responses.Response)
  Unknown(List(Gap))
}

/// Eligibility is NOT a receipt. HTTP requires clean transport EOF; WS requires
/// the owner's same physical socket and current client/account revision fences.
pub type Authority {
  ContinuationEligible(responses.Response)
  Ineligible(List(Gap))
}

/// Only this observer constructs reports, after validating a protocol terminal.
pub opaque type Report {
  Report(
    status: responses.Status,
    reconstruction: Reconstruction,
    authority: Authority,
  )
}

type Item {
  Item(
    initial: ir.Value,
    final: Option(ir.Value),
    parts: Dict(#(String, Int), Part),
    arguments: Option(String),
    arguments_done: Bool,
    argument_deltas: Bool,
  )
}

type Part {
  Part(
    kind: String,
    text: Option(String),
    text_done: Bool,
    deltas: Bool,
    announced: Bool,
    closed: Bool,
    initial: Option(ir.Value),
    final: Option(ir.Value),
  )
}

/// No transcript: only bounded item observations and a terminal report.
pub opaque type Observer {
  Observer(
    projection: Projection,
    max_bytes: Int,
    max_events: Int,
    max_items: Int,
    max_parts: Int,
    bytes: Int,
    events: Int,
    id: Option(String),
    created: Bool,
    items: Dict(Int, Item),
    unknown: Bool,
    report: Option(Report),
  )
}

pub fn new(
  projection: Projection,
  max_bytes: Int,
  max_events: Int,
  max_items: Int,
  max_parts: Int,
) -> Result(Observer, String) {
  use _ <- result.try(ensure(
    max_bytes > 0
      && max_bytes <= 16_777_216
      && max_events > 0
      && max_events <= 100_000
      && max_items > 0
      && max_items <= 4096
      && max_parts > 0
      && max_parts <= 4096,
    "invalid Responses sparse observation limits",
  ))
  Ok(Observer(
    projection,
    max_bytes,
    max_events,
    max_items,
    max_parts,
    0,
    0,
    None,
    False,
    dict.new(),
    False,
    None,
  ))
}

/// Called after the shared stream's framing/type/sequence validation.
pub fn observe(
  state: Observer,
  name: String,
  document: ir.Value,
  document_bytes: Int,
) -> Result(#(Observer, ir.Value), String) {
  use _ <- result.try(ensure(
    state.report == None,
    "Responses event after terminal",
  ))
  use _ <- result.try(ensure(
    document_bytes > 0
      && state.events < state.max_events
      && state.bytes + document_bytes <= state.max_bytes,
    "Responses sparse observation byte/event limit exceeded",
  ))
  let state =
    Observer(
      ..state,
      bytes: state.bytes + document_bytes,
      events: state.events + 1,
    )
  use state <- result.try(bind_optional_id(state, document, "response_id"))
  case name {
    "codex.response.metadata" | "keepalive" -> Ok(#(state, document))
    "response.created" | "response.in_progress" | "response.queued" -> {
      use state <- result.try(envelope(state, name, document))
      Ok(#(state, document))
    }
    "response.output_item.added" | "response.output_item.done" -> {
      use state <- result.try(item_event(state, name, document))
      Ok(#(state, document))
    }
    "response.content_part.added"
    | "response.content_part.done"
    | "response.reasoning_summary_part.added"
    | "response.reasoning_summary_part.done" -> {
      use state <- result.try(part_event(state, name, document))
      Ok(#(state, document))
    }
    "response.output_text.delta"
    | "response.output_text.done"
    | "response.refusal.delta"
    | "response.refusal.done"
    | "response.reasoning_text.delta"
    | "response.reasoning_text.done"
    | "response.reasoning_summary_text.delta"
    | "response.reasoning_summary_text.done" -> {
      use state <- result.try(text_event(state, name, document))
      Ok(#(state, document))
    }
    "response.function_call_arguments.delta"
    | "response.function_call_arguments.done"
    | "response.custom_tool_call_input.delta"
    | "response.custom_tool_call_input.done" -> {
      use state <- result.try(arguments_event(state, name, document))
      Ok(#(state, document))
    }
    "response.completed"
    | "response.incomplete"
    | "response.failed"
    | "response.cancelled" -> terminal(state, name, document)
    "error" -> {
      let error = ir.field(document, "error") |> option.unwrap(document)
      use _ <- result.try(responses.nonempty_string(error, "message"))
      let report =
        Report(
          responses.Failed,
          Unknown([NonCompleted]),
          Ineligible([NonCompleted]),
        )
      Ok(#(Observer(..state, items: dict.new(), report: Some(report)), document))
    }
    _ -> Error("unsupported sparse Responses event: " <> name)
  }
}

fn bind_optional_id(
  state: Observer,
  value: ir.Value,
  field: String,
) -> Result(Observer, String) {
  case ir.field(value, field) {
    None -> Ok(state)
    Some(_) -> {
      use id <- result.try(responses.nonempty_string(value, field))
      bind_id(state, id)
    }
  }
}

fn bind_id(state: Observer, id: String) -> Result(Observer, String) {
  use _ <- result.try(ensure(
    state.id == None || state.id == Some(id),
    "Responses response id changed",
  ))
  Ok(Observer(..state, id: Some(id)))
}

fn envelope(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(Observer, String) {
  use response <- result.try(ir.required(value, "response"))
  use id <- result.try(responses.nonempty_string(response, "id"))
  use state <- result.try(bind_id(state, id))
  let status = case name {
    "response.queued" -> "queued"
    _ -> "in_progress"
  }
  use _ <- result.try(optional_exact(response, "object", "response"))
  use _ <- result.try(case name, ir.field(response, "status") {
    "response.created", Some(ir.String("queued")) -> Ok(Nil)
    _, _ -> optional_exact(response, "status", status)
  })
  use _ <- result.try(case ir.field(response, "output") {
    None | Some(ir.Array([])) -> Ok(Nil)
    _ -> Error("nonterminal sparse Responses envelope contains output")
  })
  use _ <- result.try(responses.response_from_value(
    response
    |> fill("object", ir.String("response"))
    |> fill("status", ir.String(status))
    |> fill("output", ir.Array([])),
  ))
  use _ <- result.try(usage_integrity(response))
  case name {
    "response.created" -> {
      use _ <- result.try(ensure(
        !state.created && dict.size(state.items) == 0,
        "duplicate or late response.created",
      ))
      Ok(Observer(..state, created: True))
    }
    _ -> Ok(state)
  }
}

fn item_event(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(Observer, String) {
  use index <- result.try(responses.nonnegative_int(value, "output_index"))
  use item <- result.try(ir.required(value, "item"))
  use _ <- result.try(validate_item(state, item))
  use _ <- result.try(check_optional_item_id(value, item))
  use _ <- result.try(unique_item(dict.delete(state.items, index), item))
  let done = name == "response.output_item.done"
  use prior <- result.try(case dict.get(state.items, index) {
    Error(_) -> {
      use _ <- result.try(ensure(
        index == dict.size(state.items) && index < state.max_items,
        "Responses output_index is duplicate, out of order or exceeds limit",
      ))
      use _ <- result.try(unique_item(state.items, item))
      Ok(new_item(item))
    }
    Ok(prior) -> {
      use _ <- result.try(ensure(
        done && prior.final == None,
        "duplicate or closed Responses output item",
      ))
      use _ <- result.try(same_identity(prior.initial, item))
      use _ <- result.try(initial_evidence(prior.initial, item))
      use _ <- result.try(final_evidence(prior, item))
      Ok(prior)
    }
  })
  let prior = case done {
    True -> Item(..prior, final: Some(item))
    False -> prior
  }
  Ok(
    Observer(
      ..state,
      items: dict.insert(state.items, index, prior),
      unknown: state.unknown || !known_item(item),
    ),
  )
}

fn validate_item(state: Observer, item: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(responses.validate_output_item(item))
  use _ <- result.try(
    list.try_each(["id", "call_id", "name"], fn(field) {
      case ir.field(item, field) {
        None -> Ok(Nil)
        Some(_) ->
          responses.nonempty_string(item, field) |> result.map(fn(_) { Nil })
      }
    }),
  )
  use _ <- result.try(
    list.try_each(["content", "summary"], fn(field) {
      case ir.field(item, field) {
        None -> Ok(Nil)
        Some(ir.Array(parts)) -> {
          use _ <- result.try(ensure(
            list.length(parts) <= state.max_parts,
            "Responses sparse part limit exceeded",
          ))
          list.try_each(parts, fn(part) {
            use _ <- result.try(responses.validate_content(part))
            use kind <- result.try(responses.nonempty_string(part, "type"))
            use item_kind <- result.try(responses.nonempty_string(item, "type"))
            valid_part_kind(item_kind, field, kind)
          })
        }
        _ -> Error("Responses output content/summary must be an array")
      }
    }),
  )
  let part_count =
    list.fold(["content", "summary"], 0, fn(count, field) {
      case ir.field(item, field) {
        Some(ir.Array(parts)) -> count + list.length(parts)
        _ -> count
      }
    })
  ensure(part_count <= state.max_parts, "Responses sparse part limit exceeded")
}

fn check_optional_item_id(
  value: ir.Value,
  item: ir.Value,
) -> Result(Nil, String) {
  case ir.field(value, "item_id") {
    None -> Ok(Nil)
    Some(id) ->
      ensure(Some(id) == ir.field(item, "id"), "Responses item_id changed")
  }
}

fn unique_item(items: Dict(Int, Item), item: ir.Value) -> Result(Nil, String) {
  ensure(
    !list.any(dict.values(items), fn(prior) {
      let prior = option.unwrap(prior.final, prior.initial)
      ir.field(item, "id") != None
      && ir.field(prior, "id") == ir.field(item, "id")
      || ir.field(item, "call_id") != None
      && ir.field(prior, "call_id") == ir.field(item, "call_id")
    }),
    "duplicate Responses item id or call_id",
  )
}

fn same_identity(a: ir.Value, b: ir.Value) -> Result(Nil, String) {
  list.try_each(["id", "type", "role", "call_id", "name"], fn(field) {
    case ir.field(a, field), ir.field(b, field) {
      None, _ -> Ok(Nil)
      Some(_), None if field == "id" -> Ok(Nil)
      Some(prior), final ->
        ensure(Some(prior) == final, "Responses output item identity changed")
    }
  })
}

/// Initial bodies are observations, not final snapshots. They cannot disappear.
fn initial_evidence(a: ir.Value, b: ir.Value) -> Result(Nil, String) {
  ir.extras(a, ["status", "id", "type", "role", "call_id", "name"])
  |> list.try_each(fn(pair) {
    use final <- result.try(ir.required(b, pair.0))
    case pair.0, pair.1, final {
      "content", ir.Array(initial), ir.Array(final)
      | "summary", ir.Array(initial), ir.Array(final)
      -> {
        use _ <- result.try(ensure(
          list.length(final) >= list.length(initial),
          "Responses initial content disappeared",
        ))
        list.try_each(list.zip(initial, final), fn(pair) {
          part_evidence(pair.0, pair.1)
        })
      }
      "arguments", ir.String(initial), ir.String(final)
      | "input", ir.String(initial), ir.String(final)
      ->
        ensure(
          string.starts_with(final, initial),
          "Responses initial tool input changed",
        )
      _, initial, final ->
        ensure(equal(initial, final), "Responses initial item evidence changed")
    }
  })
}

fn new_item(initial: ir.Value) -> Item {
  Item(initial, None, dict.new(), None, False, False)
}

fn known_item(item: ir.Value) -> Bool {
  case ir.field(item, "type") {
    Some(ir.String("message"))
    | Some(ir.String("function_call"))
    | Some(ir.String("custom_tool_call"))
    | Some(ir.String("reasoning"))
    | Some(ir.String("compaction")) ->
      list.all(["content", "summary"], fn(field) {
        case ir.field(item, field) {
          None -> True
          Some(ir.Array(parts)) ->
            list.all(parts, fn(part) {
              case ir.field(part, "type") {
                Some(ir.String("output_text"))
                | Some(ir.String("refusal"))
                | Some(ir.String("summary_text"))
                | Some(ir.String("reasoning_text")) -> True
                _ -> False
              }
            })
          _ -> False
        }
      })
    _ -> False
  }
}

fn open_item(
  state: Observer,
  value: ir.Value,
  kind: String,
) -> Result(#(Int, Item), String) {
  use index <- result.try(responses.nonnegative_int(value, "output_index"))
  use id <- result.try(responses.nonempty_string(value, "item_id"))
  case dict.get(state.items, index) {
    Ok(item) -> {
      use _ <- result.try(ensure(
        item.final == None,
        "Responses event for closed output item",
      ))
      use _ <- result.try(ensure(
        ir.field(item.initial, "id") == Some(ir.String(id))
          && ir.field(item.initial, "type") == Some(ir.String(kind)),
        "Responses item_id changed or wrong-kind item",
      ))
      Ok(#(index, item))
    }
    Error(_) -> {
      use _ <- result.try(ensure(
        index == dict.size(state.items) && index < state.max_items,
        "Responses output_index is out of order or exceeds limit",
      ))
      let fields = [#("id", ir.String(id)), #("type", ir.String(kind))]
      let fields = case kind {
        "message" -> [#("role", ir.String("assistant")), ..fields]
        _ -> fields
      }
      let initial = ir.Object(fields)
      use _ <- result.try(unique_item(state.items, initial))
      Ok(#(index, new_item(initial)))
    }
  }
}

fn valid_part_kind(
  item_kind: String,
  group: String,
  kind: String,
) -> Result(Nil, String) {
  ensure(
    case item_kind, group, kind {
      "reasoning", "summary", "summary_text" -> True
      "reasoning", "content", "reasoning_text" -> True
      "message", "content", _ ->
        kind != "summary_text"
        && kind != "reasoning_text"
        && !string.starts_with(kind, "input_")
      _, _, _ -> False
    },
    "Responses content part on wrong-kind item",
  )
}

fn part_kind_item(kind: String) -> String {
  case kind {
    "summary_text" | "reasoning_text" -> "reasoning"
    _ -> "message"
  }
}

fn part_group(kind: String) -> String {
  case kind {
    "summary_text" -> "summary"
    _ -> "content"
  }
}

fn text_field(kind: String) -> String {
  case kind {
    "refusal" -> "refusal"
    _ -> "text"
  }
}

fn optional_text(part: ir.Value, kind: String) -> Option(String) {
  case kind {
    "output_text" | "refusal" | "summary_text" | "reasoning_text" ->
      ir.string_field(part, text_field(kind)) |> option.from_result
    _ -> None
  }
}

fn open_part(
  state: Observer,
  item: Item,
  group: String,
  index: Int,
  kind: String,
) -> Result(Part, String) {
  case dict.get(item.parts, #(group, index)) {
    Ok(part) -> {
      use _ <- result.try(ensure(
        !part.closed && part.kind == kind,
        "Responses closed or wrong-kind part",
      ))
      Ok(part)
    }
    Error(_) -> {
      let count =
        dict.keys(item.parts) |> list.count(fn(key) { key.0 == group })
      use _ <- result.try(ensure(
        index == count && dict.size(item.parts) < state.max_parts,
        "Responses part index out of order or exceeds limit",
      ))
      let seed = case ir.field(item.initial, group) {
        Some(ir.Array(parts)) ->
          parts |> list.drop(index) |> list.first |> option.from_result
        _ -> None
      }
      use _ <- result.try(case seed {
        None -> Ok(Nil)
        Some(seed) ->
          ensure(
            ir.field(seed, "type") == Some(ir.String(kind)),
            "Responses part type disagrees with initial item",
          )
      })
      let text = case seed {
        None -> None
        Some(seed) -> optional_text(seed, kind)
      }
      Ok(Part(kind, text, False, False, False, False, seed, None))
    }
  }
}

fn part_event(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(Observer, String) {
  let group = case
    string.starts_with(name, "response.reasoning_summary_part.")
  {
    True -> "summary"
    False -> "content"
  }
  use part_value <- result.try(ir.required(value, "part"))
  use _ <- result.try(responses.validate_content(part_value))
  use kind <- result.try(responses.nonempty_string(part_value, "type"))
  use _ <- result.try(ensure(
    part_group(kind) == group,
    "Responses part on wrong group",
  ))
  use _ <- result.try(valid_part_kind(part_kind_item(kind), group, kind))
  use pair <- result.try(open_item(state, value, part_kind_item(kind)))
  let #(index, item) = pair
  use part_index <- result.try(responses.nonnegative_int(
    value,
    group <> "_index",
  ))
  use part <- result.try(open_part(state, item, group, part_index, kind))
  let done = string.ends_with(name, ".done")
  use part <- result.try(case done {
    False -> {
      use _ <- result.try(ensure(
        !part.announced && !part.deltas && !part.text_done,
        "duplicate or late Responses part.added",
      ))
      use _ <- result.try(case part.initial {
        None -> Ok(Nil)
        Some(seed) -> part_evidence(seed, part_value)
      })
      Ok(
        Part(
          ..part,
          initial: Some(part_value),
          text: optional_text(part_value, kind),
          announced: True,
        ),
      )
    }
    True -> {
      use _ <- result.try(check_part(part, part_value))
      Ok(Part(..part, final: Some(part_value), text_done: True, closed: True))
    }
  })
  Ok(
    Observer(
      ..state,
      items: dict.insert(
        state.items,
        index,
        Item(..item, parts: dict.insert(item.parts, #(group, part_index), part)),
      ),
    ),
  )
}

fn text_event(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(Observer, String) {
  let kind = case name {
    "response.output_text.delta" | "response.output_text.done" -> "output_text"
    "response.refusal.delta" | "response.refusal.done" -> "refusal"
    "response.reasoning_text.delta" | "response.reasoning_text.done" ->
      "reasoning_text"
    _ -> "summary_text"
  }
  let group = part_group(kind)
  use pair <- result.try(open_item(state, value, part_kind_item(kind)))
  let #(index, item) = pair
  use part_index <- result.try(responses.nonnegative_int(
    value,
    group <> "_index",
  ))
  use part <- result.try(open_part(state, item, group, part_index, kind))
  use _ <- result.try(ensure(
    !part.text_done,
    "Responses text event after text.done",
  ))
  let done = string.ends_with(name, ".done")
  let field = case done {
    True -> text_field(kind)
    False -> "delta"
  }
  use text <- result.try(ir.string_field(value, field))
  use text <- result.try(case done, part.text {
    True, Some(prior) -> {
      use _ <- result.try(ensure(
        case part.deltas {
          True -> text == prior
          False -> string.starts_with(text, prior)
        },
        "Responses text.done disagrees with observed text",
      ))
      Ok(text)
    }
    True, None -> Ok(text)
    False, prior -> Ok(option.unwrap(prior, "") <> text)
  })
  let part =
    Part(
      ..part,
      text: Some(text),
      text_done: done,
      deltas: part.deltas || !done,
    )
  Ok(
    Observer(
      ..state,
      items: dict.insert(
        state.items,
        index,
        Item(..item, parts: dict.insert(item.parts, #(group, part_index), part)),
      ),
    ),
  )
}

fn arguments_event(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(Observer, String) {
  let custom = string.starts_with(name, "response.custom_tool_call_input.")
  let kind = case custom {
    True -> "custom_tool_call"
    False -> "function_call"
  }
  let field = case custom {
    True -> "input"
    False -> "arguments"
  }
  use pair <- result.try(open_item(state, value, kind))
  let #(index, item) = pair
  use _ <- result.try(ensure(
    !item.arguments_done,
    "Responses tool input after done",
  ))
  // Raw supplied identities are checked BEFORE any downstream alias restoration.
  use initial <- result.try(
    list.try_fold(["name", "call_id"], item.initial, fn(initial, field) {
      case ir.field(value, field) {
        None -> Ok(initial)
        Some(_) -> {
          use supplied <- result.try(responses.nonempty_string(value, field))
          use _ <- result.try(case ir.field(initial, field) {
            None -> Ok(Nil)
            Some(prior) ->
              ensure(
                prior == ir.String(supplied),
                "Responses arguments event tool identity mismatch",
              )
          })
          Ok(put(initial, field, ir.String(supplied)))
        }
      }
    }),
  )
  use _ <- result.try(unique_item(dict.delete(state.items, index), initial))
  let done = string.ends_with(name, ".done")
  use text <- result.try(
    ir.string_field(value, case done {
      True -> field
      False -> "delta"
    }),
  )
  let prior = case item.arguments {
    Some(_) as prior -> prior
    None -> ir.string_field(initial, field) |> option.from_result
  }
  use text <- result.try(case done, prior {
    True, Some(prior) -> {
      use _ <- result.try(ensure(
        case item.argument_deltas {
          True -> text == prior
          False -> string.starts_with(text, prior)
        },
        "Responses tool input.done disagrees with observations",
      ))
      Ok(text)
    }
    True, None -> Ok(text)
    False, prior -> Ok(option.unwrap(prior, "") <> text)
  })
  Ok(
    Observer(
      ..state,
      items: dict.insert(
        state.items,
        index,
        Item(
          ..item,
          initial: initial,
          arguments: Some(text),
          arguments_done: done,
          argument_deltas: item.argument_deltas || !done,
        ),
      ),
    ),
  )
}

fn part_evidence(initial: ir.Value, final: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(ensure(
    ir.field(initial, "type") == ir.field(final, "type"),
    "Responses part type changed",
  ))
  ir.extras(initial, [])
  |> list.try_each(fn(pair) {
    use supplied <- result.try(ir.required(final, pair.0))
    case pair.0, pair.1, supplied {
      "text", ir.String(initial), ir.String(final)
      | "refusal", ir.String(initial), ir.String(final)
      ->
        ensure(
          string.starts_with(final, initial),
          "Responses observed text changed",
        )
      "annotations", ir.Array(initial), ir.Array(final) ->
        ensure(
          list.length(final) >= list.length(initial)
            && list.all(list.zip(initial, final), fn(pair) {
            equal(pair.0, pair.1)
          }),
          "Responses observed annotations changed",
        )
      _, initial, final ->
        ensure(
          equal(initial, final),
          "Responses observed part extension changed",
        )
    }
  })
}

fn check_part(part: Part, value: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(ensure(
    ir.field(value, "type") == Some(ir.String(part.kind)),
    "Responses part type changed",
  ))
  use _ <- result.try(case part.initial {
    None -> Ok(Nil)
    Some(initial) -> part_evidence(initial, value)
  })
  use _ <- result.try(case part.text {
    None -> Ok(Nil)
    Some(text) -> {
      use supplied <- result.try(ir.string_field(value, text_field(part.kind)))
      ensure(
        case part.text_done {
          True -> supplied == text
          False -> string.starts_with(supplied, text)
        },
        "Responses final text disagrees with observations",
      )
    }
  })
  case part.final {
    None -> Ok(Nil)
    Some(final) -> ensure(equal(final, value), "Responses final part changed")
  }
}

fn final_evidence(item: Item, value: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(
    dict.to_list(item.parts)
    |> list.try_each(fn(pair) {
      let #(key, part) = pair
      use group <- result.try(ir.required(value, key.0))
      use parts <- result.try(ir.as_array(group))
      use final <- result.try(
        parts
        |> list.drop(key.1)
        |> list.first
        |> result.replace_error("Responses final item omits observed part"),
      )
      check_part(part, final)
    }),
  )
  case item.arguments {
    None -> Ok(Nil)
    Some(text) -> {
      let field = case ir.field(item.initial, "type") {
        Some(ir.String("custom_tool_call")) -> "input"
        _ -> "arguments"
      }
      use supplied <- result.try(ir.string_field(value, field))
      ensure(
        case item.arguments_done {
          True -> supplied == text
          False -> string.starts_with(supplied, text)
        },
        "Responses final tool input disagrees with observations",
      )
    }
  }
}

fn terminal(
  state: Observer,
  name: String,
  value: ir.Value,
) -> Result(#(Observer, ir.Value), String) {
  use response <- result.try(ir.required(value, "response"))
  use id <- result.try(responses.nonempty_string(response, "id"))
  use state <- result.try(bind_id(state, id))
  let #(status_name, status) = case name {
    "response.completed" -> #("completed", responses.Completed)
    "response.incomplete" -> #("incomplete", responses.Incomplete)
    "response.failed" -> #("failed", responses.Failed)
    _ -> #("cancelled", responses.Cancelled)
  }
  use _ <- result.try(optional_exact(response, "object", "response"))
  use _ <- result.try(optional_exact(response, "status", status_name))
  use _ <- result.try(case status {
    responses.Completed ->
      list.try_each(["error", "incomplete_details"], fn(field) {
        case ir.field(response, field) {
          None | Some(ir.Null) -> Ok(Nil)
          _ -> Error("response.completed contains failure/incomplete evidence")
        }
      })
    _ -> Ok(Nil)
  })
  // Validate usage and envelope even when no reconstructable output exists.
  use _ <- result.try(responses.response_from_value(
    response
    |> fill("object", ir.String("response"))
    |> fill("status", ir.String(status_name))
    |> put("output", ir.Array([])),
  ))
  use _ <- result.try(usage_integrity(response))
  let closed =
    list.all(dict.values(state.items), fn(item) { item.final != None })
  let observed =
    dict.to_list(state.items)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.filter_map(fn(pair) { option.to_result(pair.1.final, Nil) })
  use supplied <- result.try(case ir.field(response, "output") {
    None -> Ok(None)
    Some(ir.Array(items)) -> Ok(Some(items))
    _ -> Error("Responses terminal output must be an array")
  })
  use _ <- result.try(case supplied {
    Some([_, ..] as items) -> validate_terminal_items(state, items)
    _ -> Ok(Nil)
  })
  let output = case supplied {
    Some([_, ..] as items) -> Some(items)
    _ if closed && observed != [] -> Some(observed)
    // Native [] is a summary, not proof that unobserved output is empty.
    _ -> None
  }
  let gaps = case output {
    Some(_) -> []
    None if !closed -> [OpenItems]
    None -> [MissingOutput]
  }
  let unknown =
    state.unknown
    || case output {
      None -> False
      Some(items) -> !list.all(items, known_item)
    }
  let gaps =
    list.append(gaps, case unknown {
      True -> [UnknownExtension]
      False -> []
    })
  let missing_identity = case output {
    None -> False
    Some(items) -> list.any(items, fn(item) { ir.field(item, "id") == None })
  }
  let gaps =
    list.append(gaps, case missing_identity {
      True -> [MissingItemIdentity]
      False -> []
    })
  use reconstruction <- result.try(case output, unknown || missing_identity {
    _, True -> Ok(Unknown(gaps))
    None, False -> Ok(Unknown(gaps))
    Some(output), False -> {
      let completed =
        response
        |> fill("object", ir.String("response"))
        |> fill("status", ir.String(status_name))
        |> put("output", ir.Array(output))
      use _ <- result.try(ensure(
        bit_array.byte_size(bit_array.from_string(ir.stringify(completed)))
          <= state.max_bytes,
        "Responses reconstructed response exceeds observation limit",
      ))
      use decoded <- result.try(responses.response_from_value(completed))
      Ok(Reconstructed(decoded))
    }
  })
  let authority_gaps =
    gaps
    |> list.append(case state.created {
      True -> []
      False -> [MissingCreated]
    })
    |> list.append(case status == responses.Completed {
      True -> []
      False -> [NonCompleted]
    })
  let authority = case reconstruction, authority_gaps {
    Reconstructed(response), [] -> ContinuationEligible(response)
    _, _ -> Ineligible(authority_gaps)
  }
  let report = Report(status, reconstruction, authority)
  let projected = case state.projection, status, supplied, output {
    HydrateCompleted, responses.Completed, None, Some([_, ..] as items)
    | HydrateCompleted, responses.Completed, Some([]), Some([_, ..] as items)
    -> put(value, "response", put(response, "output", ir.Array(items)))
    _, _, _, _ -> value
  }
  Ok(#(Observer(..state, items: dict.new(), report: Some(report)), projected))
}

fn validate_terminal_items(
  state: Observer,
  items: List(ir.Value),
) -> Result(Nil, String) {
  use _ <- result.try(ensure(
    list.length(items) >= dict.size(state.items)
      && list.length(items) <= state.max_items,
    "Responses terminal output omits observed items or exceeds limit",
  ))
  // Full sparse snapshots may omit item ids. Validate supplied ids and tool
  // pairing without manufacturing ids just to enter the strict Response codec.
  use _ <- result.try(
    list.try_each(["id", "call_id"], fn(field) {
      list.try_fold(items, [], fn(seen, item) {
        case ir.field(item, field) {
          None -> Ok(seen)
          Some(_) -> {
            use id <- result.try(responses.nonempty_string(item, field))
            use _ <- result.try(ensure(
              !list.contains(seen, id),
              "duplicate Responses terminal item id or call_id",
            ))
            Ok([id, ..seen])
          }
        }
      })
      |> result.map(fn(_) { Nil })
    }),
  )
  list.index_map(items, fn(item, index) { #(item, index) })
  |> list.try_each(fn(pair) {
    use _ <- result.try(validate_item(state, pair.0))
    case dict.get(state.items, pair.1) {
      Error(_) -> Ok(Nil)
      Ok(prior) -> {
        use _ <- result.try(same_identity(prior.initial, pair.0))
        case prior.final {
          Some(final) -> {
            use _ <- result.try(same_identity(final, pair.0))
            ensure(
              equal(
                ir.Object(ir.extras(final, ["id"])),
                ir.Object(ir.extras(pair.0, ["id"])),
              ),
              "Responses terminal output changed final item",
            )
          }
          None -> {
            use _ <- result.try(initial_evidence(prior.initial, pair.0))
            final_evidence(prior, pair.0)
          }
        }
      }
    }
  })
}

fn optional_exact(
  value: ir.Value,
  field: String,
  expected: String,
) -> Result(Nil, String) {
  case ir.field(value, field) {
    None -> Ok(Nil)
    Some(ir.String(actual)) ->
      ensure(actual == expected, "Responses envelope status/object mismatch")
    _ -> Error("Responses envelope status/object must be a string")
  }
}

fn usage_integrity(response: ir.Value) -> Result(Nil, String) {
  case ir.field(response, "usage") {
    None | Some(ir.Null) -> Ok(Nil)
    Some(usage) -> {
      use input <- result.try(responses.nonnegative_int(usage, "input_tokens"))
      use output <- result.try(responses.nonnegative_int(usage, "output_tokens"))
      case ir.field(usage, "total_tokens") {
        None -> Ok(Nil)
        Some(_) -> {
          use total <- result.try(responses.nonnegative_int(
            usage,
            "total_tokens",
          ))
          ensure(
            total == input + output,
            "Responses usage total_tokens disagrees with input/output",
          )
        }
      }
    }
  }
}

pub fn reconstruction(report: Report) -> Reconstruction {
  report.reconstruction
}

pub fn authority(report: Report) -> Authority {
  report.authority
}

pub fn status(report: Report) -> responses.Status {
  report.status
}

pub fn report(state: Observer) -> Option(Report) {
  state.report
}

fn fill(value: ir.Value, key: String, observed: ir.Value) -> ir.Value {
  case ir.field(value, key) {
    None -> put(value, key, observed)
    _ -> value
  }
}

fn put(value: ir.Value, key: String, observed: ir.Value) -> ir.Value {
  ir.Object([#(key, observed), ..ir.extras(value, [key])])
}

/// JSON object order is not an identity/content distinction.
fn equal(a: ir.Value, b: ir.Value) -> Bool {
  case a, b {
    ir.Object(a), ir.Object(b) ->
      list.length(a) == list.length(b)
      && list.all(a, fn(pair) {
        case list.find(b, fn(other) { other.0 == pair.0 }) {
          Ok(other) -> equal(pair.1, other.1)
          Error(_) -> False
        }
      })
    ir.Array(a), ir.Array(b) ->
      list.length(a) == list.length(b)
      && list.all(list.zip(a, b), fn(pair) { equal(pair.0, pair.1) })
    _, _ -> a == b
  }
}

fn ensure(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}
