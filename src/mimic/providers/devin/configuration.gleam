/// Provider-owned root seam recovered from F27. Catalog rows do not enable
/// themselves: each account explicitly allows its public IDs.
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mimic/ir
import mimic/providers/contracts as c
import mimic/providers/devin/catalog
import mimic/providers/devin/models

pub type Account {
  Account(id: String, origin: String, models: List(String))
}

type Binding {
  Binding(id: String, origin: String, models: List(models.Model))
}

pub opaque type Configured {
  Configured(catalog: catalog.Catalog, bindings: List(Binding))
}

pub fn from_root(value: ir.Value) -> Result(catalog.Catalog, String) {
  use fields <- result.try(
    ir.as_object(value)
    |> result.replace_error("invalid Devin catalog configuration"),
  )
  let keys = list.map(fields, fn(field) { field.0 })
  use _ <- result.try(case list.unique(keys) == keys {
    True -> Ok(Nil)
    False -> Error("invalid Devin catalog configuration")
  })
  case ir.field(value, "devin_catalog") {
    None -> Ok(catalog.legacy())
    Some(value) -> catalog.decode_value(value)
  }
}

pub fn enabled(
  configured: catalog.Catalog,
  ids: List(String),
) -> Result(List(models.Model), String) {
  use _ <- result.try(case ids != [] && list.unique(ids) == ids {
    True -> Ok(Nil)
    False -> Error("invalid enabled Devin models")
  })
  list.try_map(ids, fn(id) {
    catalog.lookup(configured, id)
    |> result.map(fn(selection) { selection.model })
  })
}

/// Construct once from the validated root's Devin/session_token accounts.
/// Empty is allowed for a gateway with no Devin accounts. Never bind the
/// dispatcher's first matching account: runtime selection/failover is authoritative.
pub fn new(
  configured: catalog.Catalog,
  accounts: List(Account),
) -> Result(Configured, String) {
  let ids = list.map(accounts, fn(account) { account.id })
  use _ <- result.try(
    case
      list.unique(ids) == ids
      && list.all(accounts, fn(account) {
        account.id != ""
        && account.origin != ""
        && !string.contains(account.id, "\u{0000}")
        && !string.contains(account.origin, "\u{0000}")
      })
    {
      True -> Ok(Nil)
      False -> Error("invalid configured Devin accounts")
    },
  )
  use bindings <- result.try(
    list.try_map(accounts, fn(account) {
      use maps <- result.try(enabled(configured, account.models))
      Ok(Binding(account.id, account.origin, maps))
    }),
  )
  Ok(Configured(configured, bindings))
}

pub fn catalog(configured: Configured) -> catalog.Catalog {
  configured.catalog
}

/// Only explicitly enabled public IDs may be registered, listed or executed.
pub fn lookup(
  configured: Configured,
  id: String,
) -> Result(catalog.Selection, String) {
  use _ <- result.try(
    case
      list.any(configured.bindings, fn(binding) {
        list.any(binding.models, fn(model) { model.id == id })
      })
    {
      True -> Ok(Nil)
      False -> Error("unsupported configured Devin model")
    },
  )
  catalog.lookup(configured.catalog, id)
}

/// Defense in depth at the adapter boundary: resolve using the actual selected
/// account AND its exact configured origin. Never accept OAuth/API-key contexts,
/// a foreign account, a stale origin or a model enabled only on another account.
pub fn selected(
  configured: Configured,
  context: c.Context,
  request: c.Request,
) -> Result(List(models.Model), String) {
  use _ <- result.try(
    case
      context.provider == "devin"
      && context.auth_mode == "session_token"
      && request.provider == "devin"
      && request.auth_mode == "session_token"
    {
      True -> Ok(Nil)
      False -> Error("invalid configured Devin account scope")
    },
  )
  use binding <- result.try(
    list.find(configured.bindings, fn(binding) {
      binding.id == context.account && binding.origin == context.origin
    })
    |> result.replace_error("invalid configured Devin account scope"),
  )
  use model <- result.try(models.resolve(binding.models, request.model))
  Ok([model])
}
