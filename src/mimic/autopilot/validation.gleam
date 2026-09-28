import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Artifact {
  Artifact(id: String, text: String)
}

pub type Citation {
  Citation(artifact_id: String, start: Int, end: Int)
}

pub type Class {
  Trivial
  Minor
  Major
  Breaking
}

pub type Classification {
  Classification(class: Class, confidence: Float, evidence: List(Citation))
}

pub type Hypothesis {
  Hypothesis(patch: String, rationale: String, risk_notes: String)
}

pub type Diagnosis {
  Diagnosis(hypothesis: String, next_action: String, patch: String)
}

pub type Narrative {
  Narrative(transition: String)
}

pub type Output {
  Classified(Classification)
  Proposed(Hypothesis)
  Diagnosed(Diagnosis)
  Reported(Narrative)
}

pub fn prepare(artifacts: List(Artifact)) -> Result(List(Artifact), String) {
  let count = list.length(artifacts)
  let raw_total =
    list.fold(artifacts, 0, fn(n, a) { n + string.byte_size(a.text) })
  case
    count > 0
    && count <= 16
    && raw_total <= 24_000
    && list.all(artifacts, fn(a) { string.byte_size(a.text) <= 2000 })
  {
    False -> Error("grounding requires 1..16 bounded curated artifacts")
    True -> {
      let prepared =
        list.map(artifacts, fn(a) { Artifact(..a, text: redact(a.text)) })
      let total =
        list.fold(prepared, 0, fn(n, a) { n + string.byte_size(a.text) })
      case
        total <= 24_000
        && list.all(prepared, fn(a) {
          string.byte_size(a.text) <= 2000
          && string.byte_size(a.id) > 0
          && string.byte_size(a.id) <= 128
          && valid_id(a.id)
        })
        && unique_ids(prepared)
      {
        True -> Ok(prepared)
        False ->
          Error(
            "grounding exceeds bounds or contains invalid/duplicate artifact ids",
          )
      }
    }
  }
}

fn valid_id(id: String) -> Bool {
  id
  |> string.to_graphemes
  |> list.all(fn(c) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.",
      c,
    )
  })
}

fn unique_ids(artifacts: List(Artifact)) -> Bool {
  let ids = list.map(artifacts, fn(a) { a.id })
  list.length(ids) == list.length(list.unique(ids))
}

/// Unstructured artifacts cannot safely associate a sensitive key with a value
/// on another line. Suppress the entire artifact when any credential marker is
/// present, rather than risk leaving a folded or structured value behind.
pub fn redact(text: String) -> String {
  let lower = string.lowercase(text)
  case
    list.any(
      [
        "authorization",
        "api-key",
        "api_key",
        "cookie",
        "token",
        "password",
        "secret",
        "bearer ",
        "sk-",
      ],
      fn(word) { string.contains(lower, word) },
    )
  {
    True -> "[REDACTED]"
    False -> text
  }
}

fn object(
  raw: String,
  fields: List(String),
) -> Result(dict.Dict(String, Dynamic), String) {
  case string.byte_size(raw) <= 16_384 {
    False -> Error("model output exceeds byte limit")
    True -> parse_object(raw, fields)
  }
}

fn parse_object(
  raw: String,
  fields: List(String),
) -> Result(dict.Dict(String, Dynamic), String) {
  use value <- result.try(
    json.parse(raw, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "invalid JSON object" }),
  )
  exact(value, fields)
}

fn exact(
  value: dict.Dict(String, Dynamic),
  fields: List(String),
) -> Result(dict.Dict(String, Dynamic), String) {
  case
    dict.size(value) == list.length(fields)
    && list.all(fields, fn(field) { dict.has_key(value, field) })
  {
    True -> Ok(value)
    False -> Error("missing or unknown field")
  }
}

fn field(
  value: dict.Dict(String, Dynamic),
  name: String,
  decoder,
) -> Result(a, String) {
  use raw <- result.try(
    dict.get(value, name) |> result.map_error(fn(_) { "missing " <> name }),
  )
  decode.run(raw, decoder)
  |> result.map_error(fn(_) { "invalid " <> name })
}

fn text(
  value: dict.Dict(String, Dynamic),
  name: String,
) -> Result(String, String) {
  use s <- result.try(field(value, name, decode.string))
  case string.byte_size(s) > 0 && string.byte_size(s) <= 4096 {
    True -> Ok(s)
    False -> Error("invalid length for " <> name)
  }
}

fn citation(
  raw: Dynamic,
  artifacts: List(Artifact),
) -> Result(Citation, String) {
  use value <- result.try(
    decode.run(raw, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { "invalid citation object" }),
  )
  use value <- result.try(exact(value, ["artifact_id", "start", "end"]))
  use id <- result.try(field(value, "artifact_id", decode.string))
  case list.find(artifacts, fn(a) { a.id == id }) {
    Ok(artifact) -> {
      use start <- result.try(citation_index(value, "start", artifact.text))
      use end <- result.try(citation_index(value, "end", artifact.text))
      case start >= 0 && end > start && end <= string.length(artifact.text) {
        True -> Ok(Citation(id, start, end))
        False ->
          Error("citation references unknown artifact or out-of-bounds span")
      }
    }
    _ -> Error("citation references unknown artifact or out-of-bounds span")
  }
}

/// JSON Schema's integer type includes integral-valued numbers such as 1.0.
/// Keep citation offsets as grapheme indices, independent of UTF-8 byte budgets.
fn citation_index(
  value: dict.Dict(String, Dynamic),
  name: String,
  text: String,
) -> Result(Int, String) {
  use raw <- result.try(
    dict.get(value, name) |> result.map_error(fn(_) { "missing " <> name }),
  )
  case decode.run(raw, decode.int) {
    Ok(n) -> Ok(n)
    Error(_) ->
      case decode.run(raw, decode.float) {
        Ok(n) ->
          case
            n >=. 0.0
            && n <=. int.to_float(string.length(text))
            && int.to_float(float.truncate(n)) == n
          {
            True -> Ok(float.truncate(n))
            False -> Error("invalid " <> name)
          }
        Error(_) -> Error("invalid " <> name)
      }
  }
}

pub fn validate_classifier(
  raw: String,
  artifacts: List(Artifact),
) -> Result(Classification, String) {
  use value <- result.try(object(raw, ["class", "confidence", "evidence"]))
  use label <- result.try(field(value, "class", decode.string))
  let class = case label {
    "TRIVIAL" -> Ok(Trivial)
    "MINOR" -> Ok(Minor)
    "MAJOR" -> Ok(Major)
    "BREAKING" -> Ok(Breaking)
    _ -> Error("invalid class enum")
  }
  use class <- result.try(class)
  use raw_confidence <- result.try(
    dict.get(value, "confidence")
    |> result.map_error(fn(_) { "missing confidence" }),
  )
  let confidence = case decode.run(raw_confidence, decode.float) {
    Ok(n) -> Ok(n)
    Error(_) ->
      decode.run(raw_confidence, decode.int)
      |> result.map(int.to_float)
      |> result.map_error(fn(_) { "invalid confidence" })
  }
  use confidence <- result.try(confidence)
  use citations <- result.try(field(
    value,
    "evidence",
    decode.list(of: decode.dynamic),
  ))
  use evidence <- result.try(
    list.try_map(citations, fn(c) { citation(c, artifacts) }),
  )
  case confidence >=. 0.0 && confidence <=. 1.0 && !list.is_empty(evidence) {
    True -> Ok(Classification(class, confidence, evidence))
    False -> Error("confidence outside 0..1 or empty evidence")
  }
}

/// A proposed patch is never applied here. A complete `persona.toml` artifact
/// authorizes only old-side lines at their declared position; lint, oracle,
/// and canary remain separate gates.
pub fn validate_hypothesis(
  raw: String,
  artifacts: List(Artifact),
) -> Result(Hypothesis, String) {
  use value <- result.try(object(raw, ["patch", "rationale", "risk_notes"]))
  use patch <- result.try(text(value, "patch"))
  use rationale <- result.try(text(value, "rationale"))
  use risk_notes <- result.try(text(value, "risk_notes"))
  use _ <- result.try(bound_patch(patch, artifacts))
  Ok(Hypothesis(patch, rationale, risk_notes))
}

fn bound_patch(
  patch: String,
  artifacts: List(Artifact),
) -> Result(Nil, String) {
  case minimal_diff(patch) {
    False -> Error("patch must be a bounded single-file unified TOML diff")
    True -> {
      use safe <- result.try(prepare(artifacts))
      use base <- result.try(
        list.find(safe, fn(a) { a.id == "persona.toml" })
        |> result.map_error(fn(_) { "patch requires full persona.toml base" }),
      )
      case base.text != "[REDACTED]" && matches_base(patch, base.text) {
        True -> Ok(Nil)
        False -> Error("patch hunk does not match supplied persona.toml base")
      }
    }
  }
}

pub fn minimal_diff(patch: String) -> Bool {
  case string.byte_size(patch) <= 4096 {
    False -> False
    True -> check_diff(patch)
  }
}

fn check_diff(patch: String) -> Bool {
  case diff_hunk(patch) {
    Ok(#(header, lines)) ->
      case hunk_ranges(header) {
        Error(_) -> False
        Ok(#(#(_, expected_old), #(_, expected_new))) -> {
          let #(old, new, changed, valid) =
            list.fold(lines, #(0, 0, 0, True), fn(acc, line) {
              let #(old, new, changed, valid) = acc
              case string.starts_with(line, " ") {
                True -> #(old + 1, new + 1, changed, valid)
                False ->
                  case string.starts_with(line, "+") {
                    True -> #(old, new + 1, changed + 1, valid)
                    False ->
                      case string.starts_with(line, "-") {
                        True -> #(old + 1, new, changed + 1, valid)
                        False -> #(old, new, changed, False)
                      }
                  }
              }
            })
          valid
          && changed > 0
          && changed <= 20
          && old == expected_old
          && new == expected_new
        }
      }
    Error(_) -> False
  }
}

fn diff_hunk(patch: String) -> Result(#(String, List(String)), Nil) {
  let content = case string.ends_with(patch, "\n") {
    True -> string.drop_end(patch, 1)
    False -> patch
  }
  case string.split(content, on: "\n") {
    ["--- a/persona.toml", "+++ b/persona.toml", header, ..lines] ->
      Ok(#(header, lines))
    _ -> Error(Nil)
  }
}

fn matches_base(patch: String, base: String) -> Bool {
  case diff_hunk(patch) {
    Error(_) -> False
    Ok(#(header, lines)) ->
      case hunk_ranges(header) {
        Error(_) -> False
        Ok(#(old, new)) -> match_hunk(old, new, lines, base)
      }
  }
}

fn match_hunk(
  old: #(Int, Int),
  new: #(Int, Int),
  lines: List(String),
  base: String,
) -> Bool {
  let #(old_start, old_count) = old
  let #(new_start, new_count) = new
  let base_lines = case string.ends_with(base, "\n") {
    True -> string.split(string.drop_end(base, 1), on: "\n")
    False -> string.split(base, on: "\n")
  }
  let base_count = case base {
    "" -> 0
    _ -> list.length(base_lines)
  }
  let old_side =
    list.filter_map(lines, fn(line) {
      case string.starts_with(line, "+") {
        True -> Error(Nil)
        False -> Ok(string.drop_start(line, 1))
      }
    })
  let old_offset = case old_count {
    0 -> old_start
    _ -> old_start - 1
  }
  let new_position_valid = case old_count, new_count {
    0, _ -> new_start == old_start + 1
    _, 0 -> new_start == old_start - 1
    _, _ -> new_start == old_start
  }
  { base == "" || string.ends_with(base, "\n") }
  && new_position_valid
  && old_offset >= 0
  && old_offset + old_count <= base_count
  && list.take(list.drop(base_lines, old_offset), old_count) == old_side
}

fn hunk_ranges(header: String) -> Result(#(#(Int, Int), #(Int, Int)), Nil) {
  case string.split(header, on: " ") {
    ["@@", old, new, "@@"] -> {
      use old <- result.try(range_count(old, "-"))
      use new <- result.try(range_count(new, "+"))
      Ok(#(old, new))
    }
    _ -> Error(Nil)
  }
}

fn range_count(value: String, prefix: String) -> Result(#(Int, Int), Nil) {
  case string.starts_with(value, prefix) {
    False -> Error(Nil)
    True ->
      case string.split(string.drop_start(value, 1), on: ",") {
        [start, count] -> {
          use start <- result.try(int.parse(start))
          use count <- result.try(int.parse(count))
          case start >= 0 && count >= 0 && count <= 40 {
            True -> Ok(#(start, count))
            False -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
  }
}

pub fn validate_diagnosis(
  raw: String,
  artifacts: List(Artifact),
) -> Result(Diagnosis, String) {
  use value <- result.try(object(raw, ["hypothesis", "next_action", "patch"]))
  use hypothesis <- result.try(field(value, "hypothesis", decode.string))
  use action <- result.try(field(value, "next_action", decode.string))
  use patch <- result.try(field(value, "patch", decode.string))
  case
    list.contains(["NETWORK", "CODE", "DATA", "ENVIRONMENT"], hypothesis)
    && list.contains(
      ["RETRY_NETWORK", "RECHECK_DATA", "REPAIR_PERSONA", "ASK_HUMAN"],
      action,
    )
  {
    True ->
      case action {
        "REPAIR_PERSONA" -> {
          use _ <- result.try(bound_patch(patch, artifacts))
          Ok(Diagnosis(hypothesis, action, patch))
        }
        _ ->
          case patch == "" {
            True -> Ok(Diagnosis(hypothesis, action, patch))
            False -> Error("patch requires REPAIR_PERSONA action")
          }
      }
    False -> Error("invalid diagnostic action or patch")
  }
}

pub fn validate_reporter(raw: String) -> Result(Narrative, String) {
  use value <- result.try(object(raw, ["transition"]))
  use transition <- result.try(field(value, "transition", decode.string))
  case transition {
    "NO_COMMENTARY" | "REVIEW_REQUESTED" -> Ok(Narrative(transition))
    _ ->
      Error("reporter may choose only a connective enum; engine owns all facts")
  }
}
