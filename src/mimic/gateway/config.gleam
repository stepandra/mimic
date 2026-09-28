import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth/runtime as credential
import mimic/fleet
import mimic/gateway/refresh
import mimic/ir
import mimic/providers/claude/json_guard as strict_json
import mimic/providers/codex/adapter as codex_adapter
import mimic/providers/codex/models
import mimic/providers/codex/oauth as codex_oauth
import mimic/providers/contracts
import mimic/providers/runtime
import mimic/providers/xai/models as xai_models

pub type Config {
  Config(
    version: Int,
    state_dir: String,
    listen_port: Int,
    accounts: List(Account),
    codex_catalog: Option(models.Catalog),
    codex_user_agent: String,
  )
}

pub type Account {
  Account(
    provider: String,
    auth_mode: String,
    id: String,
    origin: String,
    models: List(String),
    egress: fleet.Egress,
    oauth: Option(codex_oauth.Config),
  )
}

/// Configuration is secret-free. A configured model must have explicit codec
/// metadata; no provider/model or endpoint can be selected by the client.
pub fn decode(source: String) -> Result(Config, String) {
  use value <- result.try(strict_json.parse(source) |> safe)
  use version <- result.try(
    ir.required(value, "version") |> result.try(ir.as_int) |> safe,
  )
  use state_dir <- result.try(ir.string_field(value, "state_dir") |> safe)
  use port <- result.try(
    ir.required(value, "listen_port") |> result.try(ir.as_int) |> safe,
  )
  use entries <- result.try(
    ir.required(value, "accounts") |> result.try(ir.as_array) |> safe,
  )
  use accounts <- result.try(list.try_map(entries, account))
  use catalog <- result.try(case ir.field(value, "codex_catalog") {
    None -> Ok(None)
    Some(raw) ->
      models.decode(ir.stringify(raw), models.OperatorSupplied)
      |> safe
      |> result.map(Some)
  })
  let agent = case ir.field(value, "codex_user_agent") {
    Some(ir.String(value)) -> value
    _ -> "mimic-codex/0.1"
  }
  use _ <- result.try(
    case
      version == 1
      && port >= 0
      && port < 65_536
      && string.starts_with(state_dir, "/")
      && !string.contains(state_dir, "\u{0000}")
      && !list.is_empty(accounts)
      && list.length(list.unique(list.map(accounts, fn(a) { a.id })))
      == list.length(accounts)
      && list.length(
        list.unique(
          list.map(accounts, fn(a) { #(a.provider, a.auth_mode, a.id) }),
        ),
      )
      == list.length(accounts)
      && list.all(accounts, fn(a) {
        list.all(accounts, fn(b) {
          a.provider == b.provider
          || list.all(a.models, fn(model) { !list.contains(b.models, model) })
        })
      })
      && safe_header(agent)
    {
      True -> Ok(Nil)
      False -> Error("invalid gateway configuration")
    },
  )
  use _ <- result.try(
    list.try_each(accounts, fn(a) {
      case a.provider, a.auth_mode, catalog {
        "claude", "api_key", _ -> Ok(Nil)
        "xai", "api_key", _ ->
          list.try_each(a.models, fn(model) {
            xai_models.registration(model) |> safe |> result.map(fn(_) { Nil })
          })
        "devin", "session_token", _ if a.models == ["devin/swe-1-7"] -> Ok(Nil)
        "codex", "oauth", Some(catalog) ->
          list.try_each(a.models, fn(model) {
            use item <- result.try(models.lookup(catalog, model) |> safe)
            case item.responses_lite {
              True -> Error("unsupported Codex Responses-lite model")
              False -> Ok(Nil)
            }
          })
        _, _, _ ->
          Error("unsupported provider/auth mode or missing Codex catalog")
      }
    }),
  )
  Ok(Config(version, state_dir, port, accounts, catalog, agent))
}

fn account(value: ir.Value) -> Result(Account, String) {
  use provider <- result.try(ir.string_field(value, "provider") |> safe)
  use auth_mode <- result.try(ir.string_field(value, "auth_mode") |> safe)
  use id <- result.try(ir.string_field(value, "id") |> safe)
  use origin <- result.try(ir.string_field(value, "origin") |> safe)
  use raw_models <- result.try(
    ir.required(value, "models") |> result.try(ir.as_array) |> safe,
  )
  use models <- result.try(
    list.try_map(raw_models, fn(v) { ir.as_string(v) |> safe }),
  )
  use oauth <- result.try(case ir.field(value, "oauth") {
    None -> Ok(None)
    Some(raw) -> {
      use authorize <- result.try(ir.string_field(raw, "authorize_url") |> safe)
      use token <- result.try(ir.string_field(raw, "token_url") |> safe)
      use redirect <- result.try(ir.string_field(raw, "redirect_uri") |> safe)
      let settings = codex_oauth.Config(authorize, token, redirect)
      use _ <- result.try(
        codex_oauth.refresh_request(settings, "synthetic-validation") |> safe,
      )
      use _ <- result.try(refresh.validate(token))
      Ok(Some(settings))
    }
  })
  use parsed <- result.try(uri.parse(origin) |> safe)
  let egress = case parsed.scheme, parsed.host {
    Some("http"), Some("127.0.0.1") | Some("http"), Some("localhost") ->
      Ok(fleet.LocalLoopback)
    Some("https"), Some(_) -> Ok(fleet.OperatorHttps)
    _, _ -> Error("unsupported gateway origin")
  }
  use egress <- result.try(egress)
  use _ <- result.try(case provider {
    "devin" ->
      case parsed.scheme == Some("http") && parsed.host == Some("127.0.0.1") {
        True -> Ok(Nil)
        False -> Error("Devin requires numeric loopback HTTP")
      }
    _ -> Ok(Nil)
  })
  use _ <- result.try(case parsed.path == "" || parsed.path == "/" {
    True -> Ok(Nil)
    False -> Error("gateway origin must not contain a path")
  })
  use _ <- result.try(
    case
      parsed.userinfo == None
      && parsed.query == None
      && parsed.fragment == None
      && case parsed.port {
        None -> True
        Some(port) -> port > 0 && port < 65_536
      }
      && id != ""
      && safe_header(id)
      && !list.is_empty(models)
      && list.all(models, fn(m) { m != "" && safe_header(m) })
      && list.length(list.unique(models)) == list.length(models)
      && { oauth == None || { provider == "codex" && auth_mode == "oauth" } }
    {
      True -> Ok(Nil)
      False -> Error("invalid gateway account")
    },
  )
  use _ <- result.try(
    fleet.validate(fleet.Profile(
      credential.key(provider, auth_mode, id),
      origin,
      egress,
      64,
    ))
    |> safe,
  )
  Ok(Account(provider, auth_mode, id, origin, models, egress, oauth))
}

fn safe_header(s: String) -> Bool {
  !string.contains(s, "\r")
  && !string.contains(s, "\n")
  && !string.contains(s, "\u{0000}")
}

fn safe(value: Result(a, e)) -> Result(a, String) {
  // Never expose parser text from operator input.
  case value {
    Ok(value) -> Ok(value)
    Error(_) -> Error("invalid gateway configuration")
  }
}

pub fn runtime_accounts(config: Config) -> List(runtime.Account) {
  list.map(config.accounts, fn(a) {
    runtime.Account(
      a.provider,
      a.auth_mode,
      a.id,
      a.origin,
      a.egress,
      64,
      a.models,
      case a.provider, a.oauth {
        "codex", Some(settings) ->
          credential.Refreshable(
            codex_adapter.refresh(settings, fn(plan) { refresh.send(plan) }),
          )
        "codex", None ->
          credential.Refreshable(
            contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
          )
        "devin", _ -> credential.StaticSession
        _, _ -> credential.StaticKey
      },
    )
  })
}
