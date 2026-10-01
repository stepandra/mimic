/// Independent pinned OpenAI Python2.26.0 generated-model shape checks.
/// These are not the permissive shared Responses observer or SDK execution.
/// Pin:15afa21e54952c06e2ac4d3e3a82f144c2cf9ed9.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub fn error_event(frame: String, sequence: Int) -> Result(ir.Value, String) {
  use value <- result.try(case frame {
    "event: error\ndata: " <> json -> ir.parse(json)
    _ -> Error("not a typed Responses error frame")
  })
  use fields <- result.try(ir.as_object(value))
  use _ <- result.try(check(
    list.sort(list.map(fields, fn(field) { field.0 }), string_order)
      == ["code", "message", "param", "sequence_number", "type"],
    "Responses ErrorEvent is not flat",
  ))
  use _ <- result.try(check(
    ir.field(value, "type") == Some(ir.String("error"))
      && ir.field(value, "sequence_number") == Some(ir.Integer(sequence))
      && sequence >= 0,
    "invalid Responses ErrorEvent discriminator or sequence",
  ))
  use message <- result.try(ir.string_field(value, "message"))
  use _ <- result.try(check(message != "", "missing Responses error message"))
  use _ <- result.try(ir.optional_string(value, "code"))
  use _ <- result.try(ir.optional_string(value, "param"))
  Ok(value)
}

pub fn response(value: ir.Value) -> Result(Nil, String) {
  use _ <- result.try(ir.as_object(value))
  use _ <- result.try(check(
    ir.field(value, "object") == Some(ir.String("response")),
    "not a Responses document",
  ))
  use _ <- result.try(ir.string_field(value, "id"))
  use _ <- result.try(ir.string_field(value, "model"))
  use _ <- result.try(case ir.field(value, "created_at") {
    Some(ir.Integer(n)) if n >= 0 -> Ok(Nil)
    Some(ir.Decimal(n)) if n >=. 0.0 -> Ok(Nil)
    _ -> Error("invalid Responses creation time")
  })
  use _ <- result.try(
    ir.required(value, "parallel_tool_calls") |> result.try(ir.as_bool),
  )
  use choice <- result.try(ir.string_field(value, "tool_choice"))
  use _ <- result.try(check(
    choice == "auto" || choice == "none",
    "unsupported admitted Responses tool choice",
  ))
  use tools <- result.try(
    ir.required(value, "tools") |> result.try(ir.as_array),
  )
  use _ <- result.try(
    list.try_each(tools, fn(tool) {
      use _ <- result.try(check(
        ir.field(tool, "type") == Some(ir.String("function"))
          && ir.field(tool, "strict") == Some(ir.Boolean(False)),
        "not an admitted non-strict function tool",
      ))
      use _ <- result.try(ir.string_field(tool, "name"))
      use _ <- result.try(
        ir.required(tool, "parameters") |> result.try(ir.as_object),
      )
      Ok(Nil)
    }),
  )
  use _ <- result.try(ir.required(value, "output") |> result.try(ir.as_array))
  case ir.field(value, "usage") {
    None | Some(ir.Null) -> Ok(Nil)
    Some(usage) -> {
      use input <- result.try(nonnegative(usage, "input_tokens"))
      use output <- result.try(nonnegative(usage, "output_tokens"))
      use total <- result.try(nonnegative(usage, "total_tokens"))
      use details <- result.try(ir.required(usage, "input_tokens_details"))
      use _ <- result.try(ir.as_object(details))
      use _ <- result.try(nonnegative(details, "cached_tokens"))
      use details <- result.try(ir.required(usage, "output_tokens_details"))
      use _ <- result.try(ir.as_object(details))
      use _ <- result.try(nonnegative(details, "reasoning_tokens"))
      check(input + output == total, "inconsistent Responses usage totals")
    }
  }
}

fn nonnegative(value: ir.Value, key: String) -> Result(Int, String) {
  use count <- result.try(ir.required(value, key) |> result.try(ir.as_int))
  use _ <- result.try(check(count >= 0, "negative Responses token count"))
  Ok(count)
}

fn check(ok: Bool, message: String) -> Result(Nil, String) {
  case ok {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn string_order(left: String, right: String) {
  string.compare(left, right)
}
