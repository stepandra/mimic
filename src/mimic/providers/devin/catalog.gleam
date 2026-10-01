/// Validated operator configuration, not live discovery or account availability.
/// Recovered from F27 63a0096eadf23e5632a8a86bcd18d1bd294f61ab.
/// Aliases compile into the existing native Model mapping; no effort inference
/// or independently maintained capability set is introduced.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mimic/ir
import mimic/providers/devin/models

pub type Entry {
  Entry(model: models.Model, aliases: List(String))
}

type Source {
  HistoricalCpaPin
  OperatorConfigured
}

pub opaque type Catalog {
  Catalog(source: Source, entries: List(Entry))
}

pub type Selection {
  Selection(canonical_id: String, model: models.Model)
}

const invalid = "invalid configured Devin catalog"

/// Omission preserves the original single-model mapping. The historical source
/// pin is not a current discovery, entitlement or upstream qualification.
pub fn legacy() -> Catalog {
  Catalog(
    HistoricalCpaPin,
    list.map(models.baseline(), fn(model) { Entry(model, []) }),
  )
}

pub fn new(entries: List(Entry)) -> Result(Catalog, String) {
  let native_uids = list.map(entries, fn(entry) { entry.model.uid })
  let public_ids =
    list.fold(entries, 0, fn(count, entry) {
      count + 1 + list.length(entry.aliases)
    })
  use _ <- result.try(
    case
      entries != []
      && list.length(entries) <= 64
      && public_ids <= 256
      && list.unique(native_uids) == native_uids
    {
      True -> Ok(Nil)
      False -> Error(invalid)
    },
  )
  use _ <- result.try(
    models.validate(compile(entries)) |> result.replace_error(invalid),
  )
  Ok(Catalog(OperatorConfigured, entries))
}

/// Repeated decoded keys, unknown fields, nulls and wrong types reject.
pub fn decode(source: String) -> Result(Catalog, String) {
  use value <- result.try(
    ir.parse_bounded(source, 65_536, 8, 4096) |> result.replace_error(invalid),
  )
  decode_value(value)
}

/// Root callers provide an already ambiguity-checked tree. Enforce the same
/// catalog byte/depth/node budget here, not merely in standalone decoding.
pub fn decode_value(value: ir.Value) -> Result(Catalog, String) {
  use _ <- result.try(
    ir.parse_bounded(ir.stringify(value), 65_536, 8, 4096)
    |> result.replace_error(invalid),
  )
  use _ <- result.try(shape(value, ["models"]))
  use raw <- result.try(
    ir.required(value, "models")
    |> result.try(ir.as_array)
    |> result.replace_error(invalid),
  )
  use entries <- result.try(list.try_map(raw, decode_entry))
  new(entries)
}

fn decode_entry(value: ir.Value) -> Result(Entry, String) {
  use _ <- result.try(
    shape(value, ["id", "uid", "max_tokens", "images", "aliases"]),
  )
  use id <- result.try(
    ir.string_field(value, "id") |> result.replace_error(invalid),
  )
  use uid <- result.try(
    ir.string_field(value, "uid") |> result.replace_error(invalid),
  )
  use limit <- result.try(
    ir.required(value, "max_tokens")
    |> result.try(ir.as_int)
    |> result.replace_error(invalid),
  )
  use images <- result.try(
    ir.required(value, "images")
    |> result.try(ir.as_bool)
    |> result.replace_error(invalid),
  )
  use aliases <- result.try(case ir.field(value, "aliases") {
    None -> Ok([])
    Some(value) ->
      ir.as_array(value)
      |> result.try(fn(values) { list.try_map(values, ir.as_string) })
      |> result.replace_error(invalid)
  })
  Ok(Entry(models.Model(id, uid, limit, images), aliases))
}

fn shape(value: ir.Value, allowed: List(String)) -> Result(Nil, String) {
  use fields <- result.try(ir.as_object(value) |> result.replace_error(invalid))
  let keys = list.map(fields, fn(field) { field.0 })
  case
    list.unique(keys) == keys
    && list.all(keys, fn(key) { list.contains(allowed, key) })
  {
    True -> Ok(Nil)
    False -> Error(invalid)
  }
}

fn compile(entries: List(Entry)) -> List(models.Model) {
  list.flat_map(entries, fn(entry) {
    [
      entry.model,
      ..list.map(entry.aliases, fn(alias) {
        models.Model(..entry.model, id: alias)
      })
    ]
  })
}

pub fn mappings(catalog: Catalog) -> List(models.Model) {
  compile(catalog.entries)
}

pub fn lookup(catalog: Catalog, id: String) -> Result(Selection, String) {
  use entry <- result.try(
    list.find(catalog.entries, fn(entry) {
      entry.model.id == id || list.contains(entry.aliases, id)
    })
    |> result.replace_error("unsupported configured Devin model"),
  )
  Ok(Selection(entry.model.id, models.Model(..entry.model, id: id)))
}

pub fn metadata_source(catalog: Catalog) -> String {
  case catalog.source {
    HistoricalCpaPin -> "baseline"
    OperatorConfigured -> "operator_config"
  }
}
