import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/corpus
import mimic/types.{type Capture, type Header, Header, Transport}

pub type Change {
  Change(axis: String, path: String, before: String, after: String)
}

pub type Report {
  Report(changes: List(Change))
}

pub fn diff(before: Capture, after: Capture) -> Result(Report, String) {
  let types.Capture(
    headers: old_headers,
    body: old_body,
    transport: Transport(alpn: old_alpn, ja4: old_ja4),
    http_version: old_version,
    ..,
  ) = before
  let types.Capture(
    headers: new_headers,
    body: new_body,
    transport: Transport(alpn: new_alpn, ja4: new_ja4),
    http_version: new_version,
    ..,
  ) = after
  use body_changes <- result.try(json_changes(old_body, new_body))
  let changes =
    list.flatten([
      header_changes(old_headers, new_headers),
      beta_changes(old_headers, new_headers),
      body_changes,
      changed("transport", "alpn", old_alpn, new_alpn),
      changed("transport", "http_version", old_version, new_version),
      changed(
        "transport",
        "ja4",
        display_option(old_ja4),
        display_option(new_ja4),
      ),
    ])
  Ok(Report(changes))
}

fn display_option(value) -> String {
  case value {
    None -> "unknown"
    Some(value) -> value
  }
}

fn changed(
  axis: String,
  path: String,
  before: String,
  after: String,
) -> List(Change) {
  case before == after {
    True -> []
    False -> [Change(axis, path, before, after)]
  }
}

fn names(headers: List(Header)) -> List(String) {
  list.map(headers, fn(h) {
    let Header(name, _) = h
    name
  })
}

fn header_changes(before: List(Header), after: List(Header)) -> List(Change) {
  let old_names = names(before)
  let new_names = names(after)
  let old_lower = list.map(old_names, string.lowercase)
  let new_lower = list.map(new_names, string.lowercase)
  let names_change = case old_lower == new_lower {
    True -> []
    False -> [
      Change(
        "headers",
        "names/order",
        string.join(old_names, with: ","),
        string.join(new_names, with: ","),
      ),
    ]
  }
  list.append(names_change, case_changes(before, after, 0))
}

fn case_changes(
  before: List(Header),
  after: List(Header),
  index: Int,
) -> List(Change) {
  case before, after {
    [Header(old_name, old_value), ..rest_before],
      [Header(new_name, new_value), ..rest_after]
    -> {
      let path = int.to_string(index)
      let name_changes = case
        string.lowercase(old_name) == string.lowercase(new_name)
      {
        True -> changed("headers", path <> "/case", old_name, new_name)
        False -> []
      }
      let value_changes = case
        string.lowercase(old_name) == string.lowercase(new_name)
        && string.lowercase(old_name) != "anthropic-beta"
      {
        True -> changed("headers", path <> "/value", old_value, new_value)
        False -> []
      }
      list.flatten([
        name_changes,
        value_changes,
        case_changes(rest_before, rest_after, index + 1),
      ])
    }
    _, _ -> []
  }
}

fn beta_values(headers: List(Header)) -> List(String) {
  headers
  |> list.filter_map(fn(h) {
    let Header(name, value) = h
    case string.lowercase(name) == "anthropic-beta" {
      True -> Ok(value)
      False -> Error(Nil)
    }
  })
  |> list.flat_map(fn(value) {
    string.split(value, on: ",") |> list.map(string.trim)
  })
}

fn beta_changes(before: List(Header), after: List(Header)) -> List(Change) {
  let old = beta_values(before)
  let new = beta_values(after)
  case old == new {
    True -> []
    False -> [
      Change(
        "betas",
        "anthropic-beta",
        string.join(old, with: ","),
        string.join(new, with: ","),
      ),
    ]
  }
}

fn json_changes(before: String, after: String) -> Result(List(Change), String) {
  case before, after {
    "", "" -> Ok([])
    "", _ -> Ok([Change("json", "$", "absent", "present")])
    _, "" -> Ok([Change("json", "$", "present", "absent")])
    _, _ -> {
      use old <- result.try(
        json.parse(before, decode.dynamic)
        |> result.map_error(fn(_) { "Invalid baseline JSON body" }),
      )
      use new <- result.try(
        json.parse(after, decode.dynamic)
        |> result.map_error(fn(_) { "Invalid candidate JSON body" }),
      )
      Ok(compare_json(old, new, "$"))
    }
  }
}

fn type_name(value: Dynamic) -> String {
  case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
    Ok(_) -> "object"
    Error(_) ->
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(_) -> "array"
        Error(_) ->
          case decode.run(value, decode.string) {
            Ok(_) -> "string"
            Error(_) ->
              case decode.run(value, decode.int) {
                Ok(_) -> "number"
                Error(_) ->
                  case decode.run(value, decode.float) {
                    Ok(_) -> "number"
                    Error(_) ->
                      case decode.run(value, decode.bool) {
                        Ok(_) -> "boolean"
                        Error(_) -> "null"
                      }
                  }
              }
          }
      }
  }
}

fn compare_json(before: Dynamic, after: Dynamic, path: String) -> List(Change) {
  let old_type = type_name(before)
  let new_type = type_name(after)
  case old_type == new_type {
    False -> [Change("json", path, old_type, new_type)]
    True ->
      case old_type {
        "object" -> {
          let assert Ok(old) =
            decode.run(before, decode.dict(decode.string, decode.dynamic))
          let assert Ok(new) =
            decode.run(after, decode.dict(decode.string, decode.dynamic))
          let keys =
            list.unique(
              list.flatten([
                list.map(dict.to_list(old), fn(pair) { pair.0 }),
                list.map(dict.to_list(new), fn(pair) { pair.0 }),
              ]),
            )
            |> list.sort(string.compare)
          list.flat_map(keys, fn(key) {
            let next_path = path <> "." <> key
            case dict.get(old, key), dict.get(new, key) {
              Ok(a), Ok(b) -> compare_json(a, b, next_path)
              Ok(_), Error(_) -> [
                Change("json", next_path, "present", "absent"),
              ]
              Error(_), Ok(_) -> [
                Change("json", next_path, "absent", "present"),
              ]
              Error(_), Error(_) -> []
            }
          })
        }
        "array" -> {
          let assert Ok(old) = decode.run(before, decode.list(decode.dynamic))
          let assert Ok(new) = decode.run(after, decode.list(decode.dynamic))
          compare_array(old, new, path, 0)
        }
        _ -> []
      }
  }
}

fn compare_array(
  before: List(Dynamic),
  after: List(Dynamic),
  path: String,
  index: Int,
) -> List(Change) {
  let next = path <> "[" <> int.to_string(index) <> "]"
  case before, after {
    [], [] -> []
    [old, ..old_rest], [new, ..new_rest] ->
      list.append(
        compare_json(old, new, next),
        compare_array(old_rest, new_rest, path, index + 1),
      )
    [_, ..old_rest], [] -> [
      Change("json", next, "present", "absent"),
      ..compare_array(old_rest, [], path, index + 1)
    ]
    [], [_, ..new_rest] -> [
      Change("json", next, "absent", "present"),
      ..compare_array([], new_rest, path, index + 1)
    ]
  }
}

pub fn report_json(report: Report) -> String {
  let Report(changes) = report
  json.object([
    #("schema", json.int(1)),
    #(
      "changes",
      json.array(changes, fn(change) {
        let Change(axis, path, before, after) = change
        json.object([
          #("axis", json.string(axis)),
          #("path", json.string(path)),
          #("before", json.string(before)),
          #("after", json.string(after)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

pub fn human(report: Report) -> String {
  let Report(changes) = report
  case changes {
    [] -> "No wire drift"
    _ ->
      changes
      |> list.map(fn(c) {
        let Change(axis, path, before, after) = c
        axis <> " " <> path <> ": " <> before <> " -> " <> after
      })
      |> string.join(with: "\n")
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["json", root, before_id, after_id] -> {
      use before <- result.try(corpus.load(root, before_id))
      use after <- result.try(corpus.load(root, after_id))
      use report <- result.try(diff(before, after))
      Ok(report_json(report))
    }
    ["human", root, before_id, after_id] -> {
      use before <- result.try(corpus.load(root, before_id))
      use after <- result.try(corpus.load(root, after_id))
      use report <- result.try(diff(before, after))
      Ok(human(report))
    }
    _ -> Error("Usage: differ json|human <root> <before-id> <after-id>")
  }
}
