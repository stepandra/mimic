import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mimic/corpus
import mimic/types.{type Capture, Header}
import simplifile
import tom.{type Toml}

/// An ordered wire profile. `notes` records draft uncertainty, not wire rules.
pub type Persona {
  Persona(
    client: String,
    version: String,
    source: String,
    alpn: String,
    ja4: Option(String),
    headers: List(HeaderRule),
    betas: List(BetaRule),
    forbidden_betas: List(List(String)),
    identity: Identity,
    timing: Timing,
    notes: List(String),
  )
}

pub type HeaderRule {
  HeaderRule(name: String, source: String, value: String, request_kind: String)
}

pub type BetaRule {
  BetaRule(value: String, request_kind: String)
}

pub type Identity {
  Identity(session: String)
}

pub type Timing {
  Timing(jitter_ms: Int)
}

pub fn parse(input: String) -> Result(Persona, String) {
  use table <- result.try(
    tom.parse(input)
    |> result.map_error(fn(error) { "Invalid TOML: " <> string.inspect(error) }),
  )
  use _ <- result.try(allowed_keys(
    table,
    [
      "meta",
      "transport",
      "headers",
      "betas",
      "forbidden_betas",
      "identity",
      "timing",
      "notes",
    ],
    "root",
  ))
  use meta <- result.try(required_table(table, ["meta"]))
  use transport <- result.try(required_table(table, ["transport"]))
  use _ <- result.try(allowed_keys(
    meta,
    ["client", "version", "source"],
    "meta",
  ))
  use _ <- result.try(allowed_keys(transport, ["alpn", "ja4"], "transport"))
  use client <- result.try(required_string(meta, ["client"]))
  use version <- result.try(required_string(meta, ["version"]))
  use source <- result.try(required_string(meta, ["source"]))
  use alpn <- result.try(required_string(transport, ["alpn"]))
  use ja4 <- result.try(optional_string(transport, ["ja4"]))
  use headers <- result.try(parse_headers(table))
  use betas <- result.try(parse_betas(table))
  use forbidden <- result.try(parse_forbidden(table))
  use identity <- result.try(parse_identity(table))
  use timing <- result.try(parse_timing(table))
  use notes <- result.try(string_array_or_empty(table, ["notes"]))
  Ok(Persona(
    client,
    version,
    source,
    alpn,
    ja4,
    headers,
    betas,
    forbidden,
    identity,
    timing,
    notes,
  ))
}

fn allowed_keys(
  table: Dict(String, Toml),
  names: List(String),
  context: String,
) -> Result(Nil, String) {
  case list.filter(dict.keys(table), fn(key) { !list.contains(names, key) }) {
    [] -> Ok(Nil)
    unknown ->
      Error(
        "Unsupported " <> context <> " field(s): " <> string.join(unknown, ", "),
      )
  }
}

fn required_table(
  table: Dict(String, Toml),
  path: List(String),
) -> Result(Dict(String, Toml), String) {
  tom.get_table(table, path)
  |> result.map_error(fn(_) { "Expected table " <> string.join(path, ".") })
}

fn required_string(
  table: Dict(String, Toml),
  path: List(String),
) -> Result(String, String) {
  tom.get_string(table, path)
  |> result.map_error(fn(_) { "Expected string " <> string.join(path, ".") })
}

fn optional_string(
  table: Dict(String, Toml),
  path: List(String),
) -> Result(Option(String), String) {
  case tom.get(table, path) {
    Error(tom.NotFound(_)) -> Ok(None)
    Ok(tom.String(value)) -> Ok(Some(value))
    _ -> Error("Expected string " <> string.join(path, "."))
  }
}

fn default_string(
  table: Dict(String, Toml),
  path: List(String),
  default: String,
) -> Result(String, String) {
  optional_string(table, path)
  |> result.map(fn(value) {
    case value {
      Some(x) -> x
      None -> default
    }
  })
}

fn tables(
  table: Dict(String, Toml),
  key: String,
) -> Result(List(Dict(String, Toml)), String) {
  case tom.get(table, [key]) {
    Error(tom.NotFound(_)) -> Ok([])
    Ok(tom.ArrayOfTables(values)) -> Ok(values)
    _ -> Error("Expected array of tables " <> key)
  }
}

fn parse_headers(
  table: Dict(String, Toml),
) -> Result(List(HeaderRule), String) {
  use entries <- result.try(tables(table, "headers"))
  list.try_map(entries, fn(entry) {
    use _ <- result.try(allowed_keys(
      entry,
      ["name", "source", "value", "request_kind"],
      "headers",
    ))
    use name <- result.try(required_string(entry, ["name"]))
    use source <- result.try(required_string(entry, ["source"]))
    use value <- result.try(default_string(entry, ["value"], ""))
    use kind <- result.try(default_string(entry, ["request_kind"], "*"))
    Ok(HeaderRule(name, source, value, kind))
  })
}

fn parse_betas(table: Dict(String, Toml)) -> Result(List(BetaRule), String) {
  use entries <- result.try(tables(table, "betas"))
  list.try_map(entries, fn(entry) {
    use _ <- result.try(allowed_keys(entry, ["value", "request_kind"], "betas"))
    use value <- result.try(required_string(entry, ["value"]))
    use kind <- result.try(default_string(entry, ["request_kind"], "*"))
    Ok(BetaRule(value, kind))
  })
}

fn parse_forbidden(
  table: Dict(String, Toml),
) -> Result(List(List(String)), String) {
  case tom.get(table, ["forbidden_betas"]) {
    Error(tom.NotFound(_)) -> Ok([])
    Ok(tom.Array(groups)) ->
      list.try_map(groups, fn(group) {
        case group {
          tom.Array(items) ->
            list.try_map(items, fn(item) {
              case item {
                tom.String(value) -> Ok(value)
                _ -> Error("forbidden_betas must contain strings")
              }
            })
          _ -> Error("forbidden_betas must be an array of string arrays")
        }
      })
    _ -> Error("forbidden_betas must be an array of string arrays")
  }
}

fn string_array_or_empty(
  table: Dict(String, Toml),
  path: List(String),
) -> Result(List(String), String) {
  case tom.get(table, path) {
    Error(tom.NotFound(_)) -> Ok([])
    Ok(tom.Array(items)) ->
      list.try_map(items, fn(item) {
        case item {
          tom.String(value) -> Ok(value)
          _ -> Error("Expected strings in " <> string.join(path, "."))
        }
      })
    _ -> Error("Expected string array " <> string.join(path, "."))
  }
}

fn parse_identity(table: Dict(String, Toml)) -> Result(Identity, String) {
  case tom.get_table(table, ["identity"]) {
    Error(tom.NotFound(_)) -> Ok(Identity("passthrough"))
    Ok(t) -> {
      use _ <- result.try(allowed_keys(t, ["session"], "identity"))
      default_string(t, ["session"], "passthrough") |> result.map(Identity)
    }
    _ -> Error("Expected identity table")
  }
}

fn parse_timing(table: Dict(String, Toml)) -> Result(Timing, String) {
  case tom.get_table(table, ["timing"]) {
    Error(tom.NotFound(_)) -> Ok(Timing(0))
    Ok(t) -> {
      use _ <- result.try(allowed_keys(t, ["jitter_ms"], "timing"))
      case tom.get(t, ["jitter_ms"]) {
        Error(tom.NotFound(_)) -> Ok(Timing(0))
        Ok(tom.Int(ms)) -> Ok(Timing(ms))
        _ -> Error("Expected integer timing.jitter_ms")
      }
    }
    _ -> Error("Expected timing table")
  }
}

pub fn lint(persona: Persona) -> List(String) {
  let header_names =
    list.map(persona.headers, fn(rule) { string.lowercase(rule.name) })
  let kinds =
    list.unique([
      "*",
      ..list.append(
        list.map(persona.headers, fn(rule) { rule.request_kind }),
        list.map(persona.betas, fn(rule) { rule.request_kind }),
      )
    ])
  []
  |> add_if(
    persona.client == "" || persona.version == "",
    "meta.client and meta.version are required",
  )
  |> add_if(
    persona.source != "synthetic"
      && persona.source != "measured"
      && persona.source != "hand",
    "meta.source must be synthetic, measured, or hand",
  )
  |> add_if(
    persona.alpn != "http/1.1" && persona.alpn != "none",
    "Only HTTP/1.1 or no ALPN is supported",
  )
  |> add_if(
    persona.ja4 != None,
    "TLS fingerprint reproduction is unsupported; remove transport.ja4",
  )
  |> add_if(
    !list.contains(header_names, "host"),
    "A Host header rule is required",
  )
  |> add_if(
    list.contains(header_names, "transfer-encoding"),
    "Request Transfer-Encoding is unsupported",
  )
  |> add_if(
    persona.identity.session != "passthrough",
    "Only identity.session = passthrough is supported",
  )
  |> add_if(
    persona.timing.jitter_ms != 0,
    "Only timing.jitter_ms = 0 is supported",
  )
  |> add_if(
    list.any(persona.headers, invalid_header_rule),
    "Header rule has an invalid name, source, value, or request_kind",
  )
  |> add_if(
    list.any(persona.betas, fn(b) {
      b.value == "" || !safe_field(b.value) || b.request_kind == ""
    }),
    "Beta rule has an invalid value or request_kind",
  )
  |> add_if(
    list.any(persona.betas, fn(b) {
      !list.any(persona.headers, fn(h) {
        h.source == "betas"
        && string.lowercase(h.name) == "anthropic-beta"
        && { h.request_kind == "*" || h.request_kind == b.request_kind }
      })
    }),
    "Beta rules require an applicable anthropic-beta header with source = betas",
  )
  |> add_if(
    list.any(persona.forbidden_betas, fn(group) { list.length(group) < 2 }),
    "Each forbidden_betas group needs at least two values",
  )
  |> add_if(
    list.any(kinds, fn(kind) {
      let selected = known_betas(persona, kind)
      list.any(persona.forbidden_betas, fn(group) {
        list.all(group, fn(b) { list.contains(selected, b) })
      })
    }),
    "Forbidden beta combination appears in profile",
  )
  |> add_if(
    list.any(kinds, fn(kind) {
      let names =
        list.map(
          list.filter(persona.headers, fn(h) {
            h.request_kind == "*" || h.request_kind == kind
          }),
          fn(h) { string.lowercase(h.name) },
        )
      list.length(list.filter(names, fn(name) { name == "host" })) > 1
    }),
    "At most one Host rule may apply to a request kind",
  )
  |> list.reverse
}

/// The static portion of the emitted beta headers: fixed values and configured
/// beta rules. Passthrough values are unknown until materialization, which must
/// apply the same forbidden-combination check to the final ordered headers.
fn known_betas(persona: Persona, kind: String) -> List(String) {
  persona.headers
  |> list.filter(fn(h) {
    string.lowercase(h.name) == "anthropic-beta"
    && { h.request_kind == "*" || h.request_kind == kind }
  })
  |> list.flat_map(fn(h) {
    case h.source {
      "fixed" -> string.split(h.value, on: ",") |> list.map(string.trim)
      "betas" ->
        persona.betas
        |> list.filter(fn(b) { b.request_kind == "*" || b.request_kind == kind })
        |> list.flat_map(fn(b) {
          string.split(b.value, on: ",") |> list.map(string.trim)
        })
      _ -> []
    }
  })
}

fn add_if(
  errors: List(String),
  condition: Bool,
  message: String,
) -> List(String) {
  case condition {
    True -> [message, ..errors]
    False -> errors
  }
}

fn safe_field(value: String) -> Bool {
  !string.contains(value, "\r")
  && !string.contains(value, "\n")
  && !string.contains(value, "\u{0000}")
}

fn valid_name(name: String) -> Bool {
  name != ""
  && string.byte_size(name) == string.length(name)
  && list.all(string.to_graphemes(name), fn(c) {
    string.contains(
      "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
      c,
    )
  })
}

fn invalid_header_rule(rule: HeaderRule) -> Bool {
  let lower = string.lowercase(rule.name)
  !valid_name(rule.name)
  || !safe_field(rule.value)
  || rule.request_kind == ""
  || !list.contains(
    ["fixed", "passthrough", "uuid", "timestamp", "betas"],
    rule.source,
  )
  || { rule.source == "betas" && lower != "anthropic-beta" }
  || {
    rule.source == "fixed"
    && {
      lower == "authorization"
      || lower == "x-api-key"
      || lower == "proxy-authorization"
    }
  }
  || { rule.source == "fixed" && rule.value == "" }
  || { rule.source == "fixed" && string.contains(rule.value, "[REDACTED]") }
  || { rule.source != "fixed" && rule.value != "" }
}

fn quoted(value: String) -> String {
  json.to_string(json.string(value))
}

pub fn render(persona: Persona) -> String {
  let header_lines =
    list.map(persona.headers, fn(h) {
      "\n[[headers]]\nname = "
      <> quoted(h.name)
      <> "\nsource = "
      <> quoted(h.source)
      <> "\nvalue = "
      <> quoted(h.value)
      <> "\nrequest_kind = "
      <> quoted(h.request_kind)
      <> "\n"
    })
  let beta_lines =
    list.map(persona.betas, fn(b) {
      "\n[[betas]]\nvalue = "
      <> quoted(b.value)
      <> "\nrequest_kind = "
      <> quoted(b.request_kind)
      <> "\n"
    })
  let forbidden =
    list.map(persona.forbidden_betas, fn(group) {
      "[" <> string.join(list.map(group, quoted), ", ") <> "]"
    })
  "forbidden_betas = ["
  <> string.join(forbidden, ", ")
  <> "]\n"
  <> "notes = ["
  <> string.join(list.map(persona.notes, quoted), ", ")
  <> "]\n\n"
  <> "[meta]\nclient = "
  <> quoted(persona.client)
  <> "\nversion = "
  <> quoted(persona.version)
  <> "\nsource = "
  <> quoted(persona.source)
  <> "\n\n[transport]\nalpn = "
  <> quoted(persona.alpn)
  <> case persona.ja4 {
    Some(value) -> "\nja4 = " <> quoted(value)
    None -> ""
  }
  <> "\n\n[identity]\nsession = "
  <> quoted(persona.identity.session)
  <> "\n\n[timing]\njitter_ms = "
  <> int.to_string(persona.timing.jitter_ms)
  <> "\n"
  <> string.join(header_lines, "")
  <> string.join(beta_lines, "")
}

/// Draft only rules observed in every sample of a kind. Unstable values remain
/// passthrough and uncertainty is reported in notes.
pub fn draft(captures: List(Capture)) -> Result(Persona, String) {
  case captures {
    [] -> Error("Cannot draft a persona from an empty corpus")
    [first, ..] -> {
      let same =
        list.all(captures, fn(c) {
          c.client == first.client
          && c.version == first.version
          && c.transport.alpn == first.transport.alpn
          && c.http_version == "HTTP/1.1"
        })
      case same {
        False ->
          Error("Draft requires one client/version/ALPN and HTTP/1.1 captures")
        True -> {
          let kinds = list.unique(list.map(captures, fn(c) { c.request_kind }))
          let rules =
            list.flat_map(kinds, fn(kind) {
              let samples =
                list.filter(captures, fn(c) { c.request_kind == kind })
              case samples {
                [] -> []
                [sample, ..] ->
                  list.filter_map(
                    list.index_map(sample.headers, fn(header, index) {
                      #(header, index)
                    }),
                    fn(item) {
                      let #(header, index) = item
                      let Header(name, value) = header
                      let values =
                        list.map(samples, fn(c) {
                          list.filter(c.headers, fn(h) {
                            let Header(n, _) = h
                            string.lowercase(n) == string.lowercase(name)
                          })
                        })
                      let occurrence =
                        list.count(list.take(sample.headers, index), fn(h) {
                          let Header(n, _) = h
                          string.lowercase(n) == string.lowercase(name)
                        })
                      let count =
                        list.count(sample.headers, fn(h) {
                          let Header(n, _) = h
                          string.lowercase(n) == string.lowercase(name)
                        })
                      case
                        list.all(values, fn(found) {
                          list.length(found) == count
                        })
                      {
                        False -> Error(Nil)
                        True -> {
                          let fixed =
                            !string.contains(value, "[REDACTED]")
                            && list.all(values, fn(found) {
                              case list.drop(found, occurrence) {
                                [Header(n, v), ..] -> n == name && v == value
                                [] -> False
                              }
                            })
                          let source = case string.lowercase(name) {
                            "anthropic-beta" ->
                              case fixed {
                                True -> "fixed"
                                False -> "passthrough"
                              }
                            // Authority and framing belong to the runtime
                            // request, not a captured ephemeral lab endpoint.
                            "host" | "content-length" -> "passthrough"
                            "authorization"
                            | "x-api-key"
                            | "proxy-authorization" -> "passthrough"
                            _ ->
                              case fixed {
                                True -> "fixed"
                                False -> "passthrough"
                              }
                          }
                          // Preserve each occurrence (including duplicate headers).
                          Ok(HeaderRule(
                            name,
                            source,
                            case source {
                              "fixed" -> value
                              _ -> ""
                            },
                            kind,
                          ))
                        }
                      }
                    },
                  )
              }
            })
          let notes = [
            "Synthetic draft: verify header ordering, conditional beta combinations, identity generators and timing against independently measured captures.",
            "Only headers present in every sample of a request kind are emitted; varying or redacted values use passthrough and need runtime values.",
            "Host and Content-Length use runtime values so a draft does not pin an ephemeral capture endpoint or stale body length.",
            "TLS ClientHello/JA4, body constraints and timing distributions were not inferred.",
          ]
          let persona =
            Persona(
              first.client,
              first.version,
              "synthetic",
              first.transport.alpn,
              None,
              rules,
              [],
              [],
              Identity("passthrough"),
              Timing(0),
              notes,
            )
          case lint(persona) {
            [] -> Ok(persona)
            errors ->
              Error(
                "Draft cannot produce a valid profile: "
                <> string.join(errors, "; "),
              )
          }
        }
      }
    }
  }
}

pub fn cli(args: List(String)) -> Result(String, String) {
  case args {
    ["draft", root] -> {
      use captures <- result.try(corpus.list(root))
      draft(captures) |> result.map(render)
    }
    ["draft", root, client, version] -> {
      use captures <- result.try(corpus.list(root))
      captures
      |> list.filter(fn(c) { c.client == client && c.version == version })
      |> draft
      |> result.map(render)
    }
    ["lint", path] | ["validate", path] -> {
      use text <- result.try(
        simplifile.read(path)
        |> result.map_error(fn(_) { "Cannot read persona: " <> path }),
      )
      use persona <- result.try(parse(text))
      case lint(persona) {
        [] -> Ok("Persona valid")
        errors -> Error(string.join(errors, "\n"))
      }
    }
    _ ->
      Error(
        "Usage: persona lint|validate <persona.toml> | draft <corpus-root> [client version]",
      )
  }
}
