/// Explicit configured mapping, never provider/account discovery.
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub type Model {
  Model(id: String, uid: String, max_tokens: Int, images: Bool)
}

/// Transcribed from CPA's pinned catalog and default UID resolver.
pub fn baseline() -> List(Model) {
  [Model("devin/swe-1-7", "swe-1-7", 64_000, True)]
}

pub fn validate(models: List(Model)) -> Result(List(Model), String) {
  let ids = list.map(models, fn(model) { model.id })
  let uids = list.map(models, fn(model) { model.uid })
  let metadata =
    list.map(models, fn(model) { #(model.uid, model.max_tokens, model.images) })
  case
    models != []
    && list.length(models) <= 256
    && list.unique(ids) == ids
    // Aliases can share one native UID, but never conflicting limits/modalities.
    && list.length(list.unique(metadata)) == list.length(list.unique(uids))
    && list.all(models, fn(model) {
      valid_id(model.id)
      && valid_uid(model.uid)
      && model.max_tokens > 0
      && model.max_tokens <= 128_000
    })
  {
    True -> Ok(models)
    False -> Error("invalid configured devin models")
  }
}

// Exact case-sensitive namespaced tokens, not paths/URLs/effort expressions.
fn valid_id(id: String) -> Bool {
  case bit_array.from_string(id) {
    <<"devin/":utf8, first, rest:bits>> ->
      string.byte_size(id) <= 256 && alphanumeric(first) && id_tail(rest)
    _ -> False
  }
}

fn id_tail(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>> ->
      { alphanumeric(byte) || byte == 45 || byte == 46 || byte == 95 }
      && id_tail(rest)
    _ -> False
  }
}

fn alphanumeric(byte: Int) -> Bool {
  { byte >= 48 && byte <= 57 }
  || { byte >= 65 && byte <= 90 }
  || { byte >= 97 && byte <= 122 }
}

// Native UIDs are opaque visible-ASCII tokens; their punctuation is not parsed.
fn valid_uid(uid: String) -> Bool {
  uid != ""
  && string.byte_size(uid) <= 256
  && uid_bytes(bit_array.from_string(uid))
}

fn uid_bytes(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>> if byte >= 33 && byte <= 126 -> uid_bytes(rest)
    _ -> False
  }
}

pub fn resolve(models: List(Model), id: String) -> Result(Model, String) {
  use models <- result.try(validate(models))
  list.find(models, fn(model) { model.id == id })
  |> result.replace_error("unsupported devin model")
}
