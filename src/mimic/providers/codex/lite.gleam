/// CPA acdace936: Responses-lite is a request mode on /responses, not compact.
/// Provider policy only; shared Responses owns JSON and tool validation.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/dialect/responses
import mimic/ir
import mimic/providers/codex/normalize
import mimic/types.{type Header}

pub const header = "x-openai-internal-codex-responses-lite"

pub const metadata_key = "ws_request_header_x_openai_internal_codex_responses_lite"

/// Gateway allowlist hook. This mode header is not authentication or proof of
/// history. Never forward client identity headers alongside it.
pub fn header_enabled(headers: List(Header)) -> Result(Bool, String) {
  case list.filter(headers, fn(h) { string.lowercase(h.name) == header }) {
    [] -> Ok(False)
    [h] ->
      case string.lowercase(string.trim(h.value)) {
        "true" -> Ok(True)
        "false" -> Ok(False)
        _ -> Error("invalid Codex Responses-lite header")
      }
    _ -> Error("duplicate Codex Responses-lite header")
  }
}

pub fn enabled(body: ir.Value) -> Result(Bool, String) {
  case ir.field(body, "client_metadata") {
    None -> Ok(False)
    Some(ir.Object(_) as metadata) ->
      case ir.field(metadata, metadata_key) {
        None -> Ok(False)
        Some(ir.Boolean(value)) -> Ok(value)
        Some(ir.String(value)) ->
          case string.lowercase(string.trim(value)) {
            "true" -> Ok(True)
            "false" -> Ok(False)
            _ -> Error("invalid Codex Responses-lite metadata")
          }
        _ -> Error("invalid Codex Responses-lite metadata")
      }
    _ -> Error("Codex client_metadata must be an object")
  }
}

/// Keep additional_tools in input, including namespaces and custom schemas.
/// Image inputs remain supported; image generation is explicitly unsupported.
pub fn normalize(body: ir.Value) -> Result(ir.Value, String) {
  use _ <- result.try(validate_tools(body, ir.field(body, "tools")))
  use _ <- result.try(case ir.field(body, "input") {
    Some(ir.Array(items)) ->
      list.try_each(items, fn(item) {
        case ir.field(item, "type") {
          Some(ir.String("additional_tools")) -> {
            use _ <- result.try(case ir.field(item, "role") {
              Some(ir.String("developer")) -> Ok(Nil)
              _ -> Error("Codex additional_tools requires developer role")
            })
            use tools <- result.try(ir.required(item, "tools"))
            validate_tools(body, Some(tools))
          }
          _ -> Ok(Nil)
        }
      })
    _ -> Ok(Nil)
  })
  Ok(normalize.put(body, "parallel_tool_calls", ir.Boolean(False)))
}

/// Catalog modalities describe image INPUT, not image generation. Unsupported
/// audio/file input is rejected rather than forwarded under a text capability.
pub fn validate_modalities(
  body: ir.Value,
  allowed: List(String),
) -> Result(Nil, String) {
  case ir.field(body, "input") {
    Some(ir.Array(items)) ->
      list.try_each(items, fn(item) {
        list.try_each(["content", "output"], fn(field) {
          case ir.field(item, field) {
            Some(ir.Array(parts)) ->
              list.try_each(parts, fn(part) {
                case ir.field(part, "type") {
                  Some(ir.String("input_image")) ->
                    case list.contains(allowed, "image") {
                      True -> Ok(Nil)
                      False -> Error("Codex model does not support image input")
                    }
                  Some(ir.String("input_audio"))
                  | Some(ir.String("input_file")) ->
                    Error("Codex audio and file input are not supported")
                  _ -> Ok(Nil)
                }
              })
            _ -> Ok(Nil)
          }
        })
      })
    _ -> Ok(Nil)
  }
}

fn validate_tools(body, tools) -> Result(Nil, String) {
  case tools {
    None -> Ok(Nil)
    Some(ir.Array(items) as tools) -> {
      use _ <- result.try(list.try_each(items, supported_tool))
      use _ <- result.try(
        responses.request_from_value(normalize.put(body, "tools", tools)),
      )
      Ok(Nil)
    }
    _ -> Error("Codex tools must be an array")
  }
}

fn supported_tool(tool: ir.Value) -> Result(Nil, String) {
  case ir.field(tool, "type") {
    Some(ir.String("image_generation")) ->
      Error("Codex image generation is not supported")
    Some(ir.String("namespace")) -> {
      use tools <- result.try(ir.required(tool, "tools"))
      use tools <- result.try(ir.as_array(tools))
      list.try_each(tools, supported_tool)
    }
    _ -> Ok(Nil)
  }
}
