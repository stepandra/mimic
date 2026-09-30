/// Explicit configured mapping, never provider/account discovery.
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
  case
    models != []
    && list.unique(ids) == ids
    && list.all(models, fn(model) {
      string.starts_with(model.id, "devin/")
      && string.length(model.id) > 6
      && model.uid != ""
      && string.byte_size(model.uid) <= 256
      && model.max_tokens > 0
      && model.max_tokens <= 128_000
    })
  {
    True -> Ok(models)
    False -> Error("invalid configured devin models")
  }
}

pub fn resolve(models: List(Model), id: String) -> Result(Model, String) {
  use models <- result.try(validate(models))
  list.find(models, fn(model) { model.id == id })
  |> result.replace_error("unsupported devin model")
}
