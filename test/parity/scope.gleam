/// Release-scope metadata is separate from execution evidence.
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import parity/lab

pub type Exclusion {
  Exclusion(provider: String, status: String, reason: String)
}

pub type Scope {
  Scope(id: String, exclusions: List(Exclusion))
}

pub fn parse(text: String, manifest: lab.Manifest) -> Result(Scope, String) {
  let exclusion = {
    use provider <- decode.field("provider", decode.string)
    use status <- decode.field("status", decode.string)
    use reason <- decode.field("reason", decode.string)
    decode.success(Exclusion(provider, status, reason))
  }
  let decoder = {
    use id <- decode.optional_field(
      "scope_id",
      "cpa-provider-parity-v1",
      decode.string,
    )
    use exclusions <- decode.optional_field(
      "excluded_providers",
      [],
      decode.list(exclusion),
    )
    decode.success(Scope(id, exclusions))
  }
  use scope <- result.try(
    json.parse(text, decoder)
    |> result.map_error(fn(_) { "invalid release scope metadata" }),
  )
  let excluded = list.map(scope.exclusions, fn(item) { item.provider })
  case
    scope.id != ""
    && list.length(excluded) == list.length(list.unique(excluded))
    && list.all(scope.exclusions, fn(item) {
      item.provider != "" && item.status == "out_of_scope" && item.reason != ""
    })
    && !list.any(manifest.rows, fn(row) {
      list.contains(excluded, row.provider)
    })
  {
    True -> Ok(scope)
    False ->
      Error("excluded providers must be out_of_scope, never active or passing")
  }
}

pub fn exclusions_json(scope: Scope) -> json.Json {
  json.array(scope.exclusions, fn(item) {
    json.object([
      #("provider", json.string(item.provider)),
      #("status", json.string(item.status)),
      #("reason", json.string(item.reason)),
    ])
  })
}
