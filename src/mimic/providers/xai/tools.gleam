import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import mimic/ir

/// Mapping belongs to one prepared request; no global restoration cache.
pub type Ref {
  Ref(wire_name: String, name: String, namespace: String)
}

pub fn prepare(
  declarations: List(ir.Value),
) -> Result(#(List(ir.Value), List(Ref)), String) {
  use pair <- result.try(flatten(declarations, "", [], []))
  let #(tools, refs) = pair
  case list.length(tools) > 200 {
    True ->
      Error("xAI supports at most 200 tools; namespace folding unsupported")
    False -> alias_web_search(tools, refs)
  }
}

fn flatten(
  declarations: List(ir.Value),
  namespace: String,
  tools: List(ir.Value),
  refs: List(Ref),
) -> Result(#(List(ir.Value), List(Ref)), String) {
  case declarations {
    [] -> Ok(#(tools, refs))
    [tool, ..rest] -> {
      use kind <- result.try(ir.string_field(tool, "type"))
      case kind {
        "namespace" if namespace == "" -> {
          use name <- result.try(ir.string_field(tool, "name"))
          use _ <- result.try(nonempty(name))
          use nested <- result.try(ir.required(tool, "tools"))
          use children <- result.try(ir.as_array(nested))
          use pair <- result.try(flatten(children, name, tools, refs))
          flatten(rest, namespace, pair.0, pair.1)
        }
        "function" -> {
          use name <- result.try(ir.string_field(tool, "name"))
          use _ <- result.try(nonempty(name))
          let wire_name = qualify(namespace, name)
          case list.any(refs, fn(ref) { ref.wire_name == wire_name }) {
            True -> Error("xAI tool namespace collision")
            False ->
              flatten(
                rest,
                namespace,
                list.append(tools, [set(tool, "name", ir.String(wire_name))]),
                list.append(refs, [Ref(wire_name, name, namespace)]),
              )
          }
        }
        // Native hosted tools are not callable client functions and must never
        // receive a function alias or enter the call/result pairing table.
        "web_search" | "x_search" if namespace == "" ->
          flatten(rest, namespace, list.append(tools, [tool]), refs)
        _ -> Error("Unsupported xAI tool type or namespaced server tool")
      }
    }
  }
}

fn nonempty(name: String) {
  case string.trim(name) == "" || string.trim(name) != name {
    True -> Error("Invalid xAI tool name")
    False -> Ok(Nil)
  }
}

fn qualify(namespace: String, name: String) -> String {
  let prefix = case string.ends_with(namespace, "__") {
    True -> namespace
    False -> namespace <> "__"
  }
  case
    namespace == ""
    || string.starts_with(name, "mcp__")
    || string.starts_with(name, prefix)
  {
    True -> name
    False -> prefix <> name
  }
}

fn alias_web_search(tools: List(ir.Value), refs: List(Ref)) {
  case
    list.find(refs, fn(ref) { ref.namespace == "" && ref.name == "web_search" })
  {
    Error(_) -> Ok(#(tools, refs))
    Ok(_) -> {
      let alias = available_alias(refs, 0)
      let tools =
        list.map(tools, fn(tool) {
          case ir.string_field(tool, "name") {
            Ok("web_search") -> set(tool, "name", ir.String(alias))
            _ -> tool
          }
        })
      let refs =
        list.map(refs, fn(ref) {
          case ref.namespace == "" && ref.name == "web_search" {
            True -> Ref(..ref, wire_name: alias)
            False -> ref
          }
        })
      Ok(#(tools, refs))
    }
  }
}

fn available_alias(refs: List(Ref), index: Int) -> String {
  let alias = case index {
    0 -> "clientfn_web_search"
    _ -> "clientfn_web_search_" <> int.to_string(index)
  }
  case list.any(refs, fn(ref) { ref.wire_name == alias }) {
    True -> available_alias(refs, index + 1)
    False -> alias
  }
}

/// Rewrites only named tool call/choice objects, never user text or arguments.
pub fn wire_call(value: ir.Value, refs: List(Ref)) -> Result(ir.Value, String) {
  use name <- result.try(ir.string_field(value, "name"))
  use supplied_namespace <- result.try(ir.optional_string(value, "namespace"))
  let namespace = case supplied_namespace {
    Some(namespace) -> namespace
    _ -> ""
  }
  case
    list.find(refs, fn(ref) { ref.name == name && ref.namespace == namespace })
  {
    Ok(ref) ->
      Ok(
        value |> remove(["namespace"]) |> set("name", ir.String(ref.wire_name)),
      )
    Error(_) -> Error("xAI call references an undeclared tool")
  }
}

pub fn restore_call(value: ir.Value, refs: List(Ref)) -> ir.Value {
  case ir.string_field(value, "name") {
    Error(_) -> value
    Ok(name) ->
      case list.find(refs, fn(ref) { ref.wire_name == name }) {
        Error(_) -> value
        Ok(ref) -> {
          let value = set(value, "name", ir.String(ref.name))
          case ref.namespace {
            "" -> remove(value, ["namespace"])
            namespace -> set(value, "namespace", ir.String(namespace))
          }
        }
      }
  }
}

pub fn set(value: ir.Value, key: String, item: ir.Value) -> ir.Value {
  case value {
    ir.Object(fields) -> {
      let fields = case list.key_find(fields, key) {
        Error(_) -> list.append(fields, [#(key, item)])
        Ok(_) ->
          list.map(fields, fn(pair) {
            case pair.0 == key {
              True -> #(key, item)
              False -> pair
            }
          })
      }
      ir.Object(fields)
    }
    _ -> value
  }
}

pub fn remove(value: ir.Value, keys: List(String)) -> ir.Value {
  case value {
    ir.Object(fields) ->
      ir.Object(list.filter(fields, fn(pair) { !list.contains(keys, pair.0) }))
    _ -> value
  }
}
