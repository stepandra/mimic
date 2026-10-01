/// Bounded historical Kimi local-reference normalization, not a schema validator.
/// CPA acdace936, util/gemini_schema.go:688-807 and kimi_executor.go:1244-1263.
/// Only schema-defined positions have reference semantics. Opaque keyword values
/// are size-accounted, never interpreted or rewritten.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir

pub const max_depth = 64

pub const max_nodes = 16_384

pub const max_bytes = 262_144

type Shape {
  Schema
  SchemaMap
  SchemaArray
  Dependencies
}

type Budget {
  Budget(depth: Int, nodes: Int, bytes: Int)
}

pub fn normalize(parameters: ir.Value) -> Result(ir.Value, String) {
  normalize_bounded(parameters, max_depth, max_nodes, max_bytes)
}

/// Callers may tighten, but never raise, the fixed admission ceilings. The work
/// budget includes definitions and overridden expansions, not only final output.
pub fn normalize_bounded(
  parameters: ir.Value,
  depth: Int,
  nodes: Int,
  bytes: Int,
) -> Result(ir.Value, String) {
  use _ <- result.try(
    case
      depth > 0
      && depth <= max_depth
      && nodes > 0
      && nodes <= max_nodes
      && bytes > 0
      && bytes <= max_bytes
    {
      True -> Ok(Nil)
      False -> Error("Invalid Kimi schema limits")
    },
  )
  // Reuse the shared bounded codec, including its duplicate-key guard, even for
  // a tree constructed by a library caller rather than parsed from a request.
  use root <- result.try(ir.parse_bounded(
    ir.stringify(parameters),
    bytes,
    depth,
    nodes,
  ))
  use _ <- result.try(ir.as_object(root))
  use expanded <- result.try(walk(
    root,
    root,
    Schema,
    [],
    1,
    Budget(depth, nodes, bytes),
  ))
  let value = case expanded.0 {
    ir.Object(fields) ->
      ir.Object(
        list.filter(fields, fn(pair) {
          pair.0 != "$defs" && pair.0 != "definitions"
        }),
      )
    _ -> expanded.0
  }
  use value <- result.try(case ir.field(value, "type") {
    None -> Ok(merge(value, [#("type", ir.String("object"))]))
    Some(ir.String("object")) -> Ok(value)
    _ -> Error("Kimi tool parameters must be an object schema")
  })
  ir.parse_bounded(ir.stringify(value), bytes, depth, nodes)
}

fn spend(
  budget: Budget,
  depth: Int,
  nodes: Int,
  bytes: Int,
) -> Result(Budget, String) {
  case depth <= budget.depth && nodes <= budget.nodes && bytes <= budget.bytes {
    True -> Ok(Budget(budget.depth, budget.nodes - nodes, budget.bytes - bytes))
    False -> Error("Kimi schema expansion limit exceeded")
  }
}

fn key_cost(key: String) -> Int {
  // Includes colon and a conservative comma for every field.
  string.byte_size(ir.stringify(ir.String(key))) + 2
}

fn walk(
  value: ir.Value,
  root: ir.Value,
  shape: Shape,
  active: List(List(String)),
  depth: Int,
  budget: Budget,
) -> Result(#(ir.Value, Budget), String) {
  case shape, value {
    Schema, ir.Boolean(_) -> account_opaque(value, depth, budget)
    Schema, ir.Object(fields) -> {
      use budget <- result.try(spend(budget, depth, 1, 2))
      use _ <- result.try(
        case
          list.any(["$id", "$dynamicRef", "$recursiveRef"], fn(key) {
            ir.field(value, key) != None
          })
        {
          True -> Error("Unsupported Kimi schema reference scope")
          False -> Ok(Nil)
        },
      )
      use base <- result.try(case ir.field(value, "$ref") {
        None -> Ok(#(ir.Object([]), budget))
        Some(ir.String(ref)) -> {
          use path <- result.try(pointer(ref))
          use _ <- result.try(case list.contains(active, path) {
            True -> Error("Cyclic Kimi schema reference")
            False -> Ok(Nil)
          })
          use target <- result.try(resolve(root, path, Schema))
          walk(target, root, Schema, [path, ..active], depth + 1, budget)
        }
        _ -> Error("Invalid Kimi schema reference")
      })
      use siblings <- result.try(walk_fields(
        list.filter(fields, fn(pair) { pair.0 != "$ref" }),
        root,
        Schema,
        active,
        depth,
        base.1,
      ))
      Ok(#(merge(base.0, siblings.0), siblings.1))
    }
    SchemaMap, ir.Object(fields) | Dependencies, ir.Object(fields) -> {
      use budget <- result.try(spend(budget, depth, 1, 2))
      use output <- result.try(walk_fields(
        fields,
        root,
        shape,
        active,
        depth,
        budget,
      ))
      Ok(#(ir.Object(output.0), output.1))
    }
    SchemaArray, ir.Array(items) -> {
      use budget <- result.try(spend(budget, depth, 1, 2))
      use output <- result.try(
        list.try_fold(items, #([], budget), fn(state, item) {
          use budget <- result.try(spend(state.1, depth, 0, 1))
          use output <- result.try(walk(
            item,
            root,
            Schema,
            active,
            depth + 1,
            budget,
          ))
          Ok(#([output.0, ..state.0], output.1))
        }),
      )
      Ok(#(ir.Array(list.reverse(output.0)), output.1))
    }
    _, _ -> Error("Invalid Kimi schema position")
  }
}

fn walk_fields(
  fields: List(#(String, ir.Value)),
  root: ir.Value,
  shape: Shape,
  active: List(List(String)),
  depth: Int,
  budget: Budget,
) -> Result(#(List(#(String, ir.Value)), Budget), String) {
  use output <- result.try(
    list.try_fold(fields, #([], budget), fn(state, pair) {
      use budget <- result.try(spend(state.1, depth, 0, key_cost(pair.0)))
      use output <- result.try(case shape, pair.1 {
        Dependencies, ir.Array(items) -> {
          use _ <- result.try(
            case
              list.all(items, fn(item) {
                case item {
                  ir.String(_) -> True
                  _ -> False
                }
              })
            {
              True -> Ok(Nil)
              False -> Error("Invalid Kimi property dependencies")
            },
          )
          account_opaque(pair.1, depth + 1, budget)
        }
        SchemaMap, _ | Dependencies, _ ->
          walk(pair.1, root, Schema, active, depth + 1, budget)
        _, _ ->
          case keyword(pair.0, pair.1) {
            Some(shape) -> walk(pair.1, root, shape, active, depth + 1, budget)
            None -> account_opaque(pair.1, depth + 1, budget)
          }
      })
      Ok(#([#(pair.0, output.0), ..state.0], output.1))
    }),
  )
  Ok(#(list.reverse(output.0), output.1))
}

fn keyword(key: String, value: ir.Value) {
  case key {
    "properties"
    | "patternProperties"
    | "dependentSchemas"
    | "$defs"
    | "definitions" -> Some(SchemaMap)
    "allOf" | "anyOf" | "oneOf" | "prefixItems" -> Some(SchemaArray)
    "items" ->
      case value {
        ir.Array(_) -> Some(SchemaArray)
        _ -> Some(Schema)
      }
    "additionalProperties"
    | "unevaluatedProperties"
    | "propertyNames"
    | "contains"
    | "not"
    | "if"
    | "then"
    | "else"
    | "additionalItems"
    | "unevaluatedItems"
    | "contentSchema" -> Some(Schema)
    "dependencies" -> Some(Dependencies)
    _ -> None
  }
}

fn pointer(ref: String) {
  case string.starts_with(ref, "#/") && !string.contains(ref, "%") {
    False -> Error("Kimi schema requires an in-document JSON Pointer")
    True ->
      string.drop_start(ref, 2)
      |> string.split("/")
      |> list.try_map(fn(part) {
        // Validate escape sequences before the ordered RFC 6901 replacement.
        let rest = part |> string.replace("~1", "") |> string.replace("~0", "")
        case string.contains(rest, "~") {
          True -> Error("Invalid Kimi schema pointer escape")
          False ->
            Ok(part |> string.replace("~1", "/") |> string.replace("~0", "~"))
        }
      })
  }
}

// A reference may target only an object schema reached through schema-defined
// positions, never a default/enum/example/vendor object that happens to be JSON.
fn resolve(
  value: ir.Value,
  path: List(String),
  shape: Shape,
) -> Result(ir.Value, String) {
  case path, shape, value {
    [], Schema, ir.Object(_) -> Ok(value)
    [key, ..rest], Schema, ir.Object(_) -> {
      use child <- result.try(ir.required(value, key))
      case keyword(key, child) {
        Some(shape) -> resolve(child, rest, shape)
        None -> Error("Kimi reference target is not a schema position")
      }
    }
    [key, ..rest], SchemaMap, ir.Object(_)
    | [key, ..rest], Dependencies, ir.Object(_)
    -> {
      use child <- result.try(ir.required(value, key))
      resolve(child, rest, Schema)
    }
    [index, ..rest], SchemaArray, ir.Array(items) -> {
      use number <- result.try(
        int.parse(index)
        |> result.map_error(fn(_) { "Invalid Kimi schema array pointer" }),
      )
      use _ <- result.try(case number >= 0 && int.to_string(number) == index {
        True -> Ok(Nil)
        False -> Error("Invalid Kimi schema array pointer")
      })
      use child <- result.try(
        list.drop(items, number)
        |> list.first
        |> result.map_error(fn(_) { "Dangling Kimi schema reference" }),
      )
      resolve(child, rest, Schema)
    }
    _, _, _ -> Error("Dangling or unsupported Kimi schema reference")
  }
}

fn merge(base: ir.Value, siblings: List(#(String, ir.Value))) -> ir.Value {
  let names = list.map(siblings, fn(pair) { pair.0 })
  let fields = case base {
    ir.Object(fields) ->
      list.filter(fields, fn(pair) { !list.contains(names, pair.0) })
    _ -> []
  }
  ir.Object(list.append(fields, siblings))
}

// Resource accounting only. No reference/key/model/media semantics apply here.
fn account_opaque(
  value: ir.Value,
  depth: Int,
  budget: Budget,
) -> Result(#(ir.Value, Budget), String) {
  case value {
    ir.Object(fields) -> {
      use budget <- result.try(spend(budget, depth, 1, 2))
      use budget <- result.try(
        list.try_fold(fields, budget, fn(budget, pair) {
          use budget <- result.try(spend(budget, depth, 0, key_cost(pair.0)))
          account_opaque(pair.1, depth + 1, budget)
          |> result.map(fn(output) { output.1 })
        }),
      )
      Ok(#(value, budget))
    }
    ir.Array(items) -> {
      use budget <- result.try(spend(budget, depth, 1, 2))
      use budget <- result.try(
        list.try_fold(items, budget, fn(budget, item) {
          use budget <- result.try(spend(budget, depth, 0, 1))
          account_opaque(item, depth + 1, budget)
          |> result.map(fn(output) { output.1 })
        }),
      )
      Ok(#(value, budget))
    }
    _ -> {
      use budget <- result.try(spend(
        budget,
        depth,
        1,
        string.byte_size(ir.stringify(value)),
      ))
      Ok(#(value, budget))
    }
  }
}
