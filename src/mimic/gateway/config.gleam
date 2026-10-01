import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import mimic/auth
import mimic/auth/runtime as credential
import mimic/fleet
import mimic/gateway/refresh
import mimic/ir
import mimic/providers/claude/adapter as claude_adapter
import mimic/providers/claude/client_profile as claude_profile
import mimic/providers/claude/companion as claude_companion
import mimic/providers/claude/json_guard as strict_json
import mimic/providers/claude/policy as claude_policy
import mimic/providers/codex/adapter as codex_adapter
import mimic/providers/codex/models
import mimic/providers/codex/oauth as codex_oauth
import mimic/providers/contracts
import mimic/providers/devin/configuration as devin_configuration
import mimic/providers/kimi/models as kimi_models
import mimic/providers/kimi/oauth as kimi_oauth
import mimic/providers/kimi_compat/request as kimi_compat
import mimic/providers/registry
import mimic/providers/runtime
import mimic/providers/xai/bridge as xai_bridge
import mimic/providers/xai/endpoint as xai_endpoint
import mimic/providers/xai/enrollment as xai_enrollment
import mimic/providers/xai/oauth as xai_oauth
import mimic/providers/xai/operations as xai_operations
import mimic/types.{type Capture, type Header, Header}

pub type Config {
  Config(
    version: Int,
    state_dir: String,
    listen_port: Int,
    accounts: List(Account),
    codex_catalog: Option(models.Catalog),
    codex_user_agent: String,
    codex_websocket: Bool,
    codex_http_continuation: Bool,
    claude_quota_classification: Bool,
    devin: devin_configuration.Configured,
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
    oauth: Option(OAuthConfig),
    base_path: String,
    claude_policy: claude_policy.Policy,
    claude_client_headers: List(Header),
    xai_operations: List(xai_operations.Binding),
  )
}

pub type OAuthConfig {
  CodexOAuth(codex_oauth.Config)
  ClaudeOAuth(auth.Config)
  ClaudeCompanionOAuth(auth.Config, claude_companion.Approved)
  KimiOAuth(kimi_oauth.Config)
  XaiOAuth(xai_oauth.Config)
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
  use devin_catalog <- result.try(devin_configuration.from_root(value) |> safe)
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
  use websocket <- result.try(
    ir.optional_bool(value, "codex_websocket", False) |> safe,
  )
  use http_continuation <- result.try(
    ir.optional_bool(value, "codex_http_continuation", False) |> safe,
  )
  use claude_quota_classification <- result.try(
    ir.optional_bool(value, "claude_quota_classification", False) |> safe,
  )
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
      && {
        !{ websocket || http_continuation }
        || {
          catalog != None
          && list.any(accounts, fn(account) { account.provider == "codex" })
        }
      }
    {
      True -> Ok(Nil)
      False -> Error("invalid gateway configuration")
    },
  )
  use _ <- result.try(
    list.try_each(accounts, fn(a) {
      case a.provider, a.auth_mode, catalog {
        "claude", "api_key", _ ->
          case a.oauth {
            Some(ClaudeCompanionOAuth(_, _)) ->
              Error("Claude companion requires OAuth mode")
            _ -> Ok(Nil)
          }
        "claude", "oauth", _ ->
          case a.oauth {
            Some(ClaudeOAuth(_)) | Some(ClaudeCompanionOAuth(_, _)) -> Ok(Nil)
            _ -> Error("Claude OAuth requires explicit endpoints")
          }
        "xai", "api_key", _ | "xai", "oauth", _ -> {
          use _ <- result.try(case a.auth_mode, a.oauth {
            "api_key", None | "oauth", Some(XaiOAuth(_)) -> Ok(Nil)
            _, _ -> Error("xAI OAuth requires explicit discovery")
          })
          list.try_each(a.models, fn(model) {
            xai_operations.registration(
              a.id,
              a.auth_mode,
              a.xai_operations,
              model,
            )
            |> safe
            |> result.map(fn(_) { Nil })
          })
        }
        "openai-compatible-kimi", "api_key", _ ->
          list.try_each(a.models, fn(model) {
            kimi_compat.registration(model) |> safe |> result.map(fn(_) { Nil })
          })
        "kimi", "api_key", _ | "kimi", "oauth", _ -> {
          use _ <- result.try(case a.auth_mode, a.oauth {
            "oauth", Some(KimiOAuth(_)) | "api_key", _ -> Ok(Nil)
            _, _ -> Error("Kimi OAuth requires explicit endpoints")
          })
          list.try_each(a.models, fn(model) {
            kimi_models.registration(model) |> safe |> result.map(fn(_) { Nil })
          })
        }
        "devin", "session_token", _ ->
          devin_configuration.enabled(devin_catalog, a.models)
          |> safe
          |> result.map(fn(_) { Nil })
        "codex", "oauth", Some(catalog) ->
          list.try_each(a.models, fn(model) {
            use item <- result.try(models.lookup(catalog, model) |> safe)
            codex_adapter.registration(item)
            |> safe
            |> result.map(fn(_) { Nil })
          })
        _, _, _ ->
          Error("unsupported provider/auth mode or missing Codex catalog")
      }
    }),
  )
  use devin <- result.try(
    devin_configuration.new(
      devin_catalog,
      accounts
        |> list.filter(fn(a) { a.provider == "devin" })
        |> list.map(fn(a) {
          devin_configuration.Account(a.id, a.origin, a.models)
        }),
    )
    |> safe,
  )
  Ok(Config(
    version,
    state_dir,
    port,
    accounts,
    catalog,
    agent,
    websocket,
    http_continuation,
    claude_quota_classification,
    devin,
  ))
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
  use #(policy, client_headers) <- result.try(decode_claude_options(
    value,
    provider,
    auth_mode,
  ))
  use operations <- result.try(decode_xai_options(
    value,
    provider,
    auth_mode,
    id,
  ))
  use oauth <- result.try(case ir.field(value, "oauth") {
    None -> Ok(None)
    Some(raw) -> decode_oauth(provider, raw) |> result.map(Some)
  })
  use base_path <- result.try(case provider, ir.field(value, "base_path") {
    "kimi", None -> Ok("/coding")
    "openai-compatible-kimi", None -> Ok("/v1")
    "kimi", Some(ir.String(path))
    | "openai-compatible-kimi", Some(ir.String(path))
    -> {
      case
        { path == "" || string.starts_with(path, "/") }
        && !string.ends_with(path, "/")
        && !string.contains(path, "..")
        && !string.contains(path, "//")
        && !string.contains(path, "?")
        && !string.contains(path, "#")
        && !string.contains(path, "%")
        && !string.contains(path, "\\")
        && !string.contains(path, " ")
        && safe_header(path)
      {
        True -> Ok(path)
        False -> Error("invalid Kimi base path")
      }
    }
    _, None -> Ok("")
    _, _ -> Error("base_path is only supported for native or generic Kimi")
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
      && { oauth == None || auth_mode == "oauth" }
    {
      True -> Ok(Nil)
      False -> Error("invalid gateway account")
    },
  )
  // Admit one canonical authority for configuration, runtime scope and adapter
  // equality. Only the already-validated empty/root path may be normalized.
  let origin = case parsed.path {
    "/" -> string.drop_end(origin, 1)
    _ -> origin
  }
  use _ <- result.try(
    fleet.validate(fleet.Profile(
      credential.key(provider, auth_mode, id),
      origin,
      egress,
      64,
    ))
    |> safe,
  )
  Ok(Account(
    provider,
    auth_mode,
    id,
    origin,
    models,
    egress,
    oauth,
    base_path,
    policy,
    client_headers,
    operations,
  ))
}

fn decode_xai_options(
  value: ir.Value,
  provider: String,
  auth_mode: String,
  account: String,
) -> Result(List(xai_operations.Binding), String) {
  case provider, ir.field(value, "xai_operations") {
    "xai", None -> {
      use _ <- result.try(
        xai_operations.validate_account(account, auth_mode, []) |> safe,
      )
      Ok([])
    }
    "xai", Some(raw) -> xai_operations.decode(account, auth_mode, raw) |> safe
    _, None -> Ok([])
    _, Some(_) -> Error("xAI operations require an xAI account")
  }
}

fn decode_claude_options(
  value: ir.Value,
  provider: String,
  auth_mode: String,
) -> Result(#(claude_policy.Policy, List(Header)), String) {
  let raw_policy = ir.field(value, "claude_policy")
  let raw_headers = ir.field(value, "claude_client_headers")
  use _ <- result.try(
    case provider == "claude" || { raw_policy == None && raw_headers == None } {
      True -> Ok(Nil)
      False ->
        Error("Claude policy and client headers require a Claude account")
    },
  )
  use policy <- result.try(case raw_policy {
    None -> Ok(claude_policy.native())
    Some(raw) -> {
      use fields <- result.try(ir.as_object(raw) |> safe)
      use _ <- result.try(case list.length(fields) == 3 {
        True -> Ok(Nil)
        False -> Error("Claude policy requires exactly input, turn and cache")
      })
      use input <- result.try(ir.string_field(raw, "input") |> safe)
      use turn <- result.try(ir.string_field(raw, "turn") |> safe)
      use cache <- result.try(ir.string_field(raw, "cache") |> safe)
      use input <- result.try(case input {
        "native" -> Ok(claude_policy.NativeMessages)
        "translated" -> Ok(claude_policy.TranslatedMessages)
        _ -> Error("unsupported Claude input policy")
      })
      use turn <- result.try(case turn {
        "conversation" -> Ok(claude_policy.Conversation)
        "subagent" -> Ok(claude_policy.Subagent)
        "helper" -> Ok(claude_policy.Helper)
        _ -> Error("unsupported Claude turn policy")
      })
      use cache <- result.try(case cache {
        "preserve" -> Ok(claude_policy.PreserveCache)
        "5m" -> Ok(claude_policy.DefaultFiveMinutes)
        "1h" if auth_mode == "oauth" -> Ok(claude_policy.ApprovedOneHour)
        _ -> Error("unsupported Claude cache policy")
      })
      Ok(claude_policy.Policy(input, turn, cache))
    }
  })
  use _ <- result.try(claude_policy.validate(policy) |> safe)
  use headers <- result.try(case raw_headers {
    None -> Ok([])
    Some(raw) -> {
      use values <- result.try(ir.as_array(raw) |> safe)
      list.try_map(values, fn(value) {
        case value {
          ir.Array([ir.String(name), ir.String(value)]) ->
            Ok(Header(name, value))
          _ -> Error("Claude client headers must be name/value pairs")
        }
      })
    }
  })
  use _ <- result.try(claude_profile.validate_headers(headers) |> safe)
  Ok(#(policy, headers))
}

/// Trusted policy is selected after the runtime chooses its actual account.
/// Caller headers cannot select policy or authorize a different identity/origin.
pub fn prepare_claude(
  settings: Config,
  context: contracts.Context,
  req: contracts.Request,
) -> Result(Capture, contracts.Failure) {
  let denied = contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  use account <- result.try(
    list.find(settings.accounts, fn(account) {
      account.id == context.account
      && account.provider == "claude"
      && context.provider == account.provider
      && account.auth_mode == context.auth_mode
      && account.origin == context.origin
      && list.contains(account.models, req.model)
    })
    |> result.replace_error(denied),
  )
  use profile <- result.try(
    claude_profile.from_operator(context, account.claude_client_headers)
    |> result.replace_error(denied),
  )
  claude_adapter.prepare_with_policy(
    context,
    req,
    account.claude_policy,
    profile,
  )
}

fn decode_oauth(
  provider: String,
  raw: ir.Value,
) -> Result(OAuthConfig, String) {
  use _ <- result.try(
    case provider == "claude" || ir.field(raw, "companion") == None {
      True -> Ok(Nil)
      False -> Error("companion configuration is only supported for Claude")
    },
  )
  case provider {
    "xai" -> xai_enrollment.decode_config(raw) |> safe |> result.map(XaiOAuth)
    "kimi" -> {
      use domain <- result.try(ir.string_field(raw, "domain") |> safe)
      use device <- result.try(ir.string_field(raw, "device_url") |> safe)
      use token <- result.try(ir.string_field(raw, "token_url") |> safe)
      use _ <- result.try(refresh.validate(device))
      use _ <- result.try(refresh.validate(token))
      let settings = kimi_oauth.Config(domain, device, token, "")
      use _ <- result.try(kimi_oauth.validate_endpoints(settings) |> safe)
      Ok(KimiOAuth(settings))
    }
    _ -> decode_pkce_oauth(provider, raw)
  }
}

fn decode_pkce_oauth(
  provider: String,
  raw: ir.Value,
) -> Result(OAuthConfig, String) {
  use authorize <- result.try(ir.string_field(raw, "authorize_url") |> safe)
  use token <- result.try(ir.string_field(raw, "token_url") |> safe)
  use redirect <- result.try(ir.string_field(raw, "redirect_uri") |> safe)
  use _ <- result.try(refresh.validate(token))
  case provider {
    "codex" -> {
      let settings = codex_oauth.Config(authorize, token, redirect)
      use _ <- result.try(
        codex_oauth.refresh_request(settings, "synthetic-validation") |> safe,
      )
      Ok(CodexOAuth(settings))
    }
    "claude" -> {
      use client <- result.try(ir.string_field(raw, "client_id") |> safe)
      use _ <- result.try(refresh.validate(authorize))
      let settings = auth.claude_config(client, authorize, token, redirect)
      use _ <- result.try(
        auth.begin_login(settings, "configuration-check") |> safe,
      )
      case ir.field(raw, "companion") {
        None -> Ok(ClaudeOAuth(settings))
        Some(companion) -> {
          use _ <- result.try(ir.as_object(companion) |> safe)
          use profile <- result.try(
            ir.string_field(companion, "profile_url") |> safe,
          )
          use roles <- result.try(
            ir.string_field(companion, "roles_url") |> safe,
          )
          use approved <- result.try(
            ir.required(companion, "approved") |> result.try(ir.as_bool) |> safe,
          )
          use approved <- result.try(
            claude_companion.approve(profile, roles, approved) |> safe,
          )
          Ok(ClaudeCompanionOAuth(settings, approved))
        }
      }
    }
    _ -> Error("unsupported OAuth provider")
  }
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
        "codex", Some(CodexOAuth(settings)) ->
          credential.Refreshable(
            codex_adapter.refresh(settings, fn(plan) { refresh.send(plan) }),
          )
        "claude", Some(ClaudeOAuth(settings))
        | "claude", Some(ClaudeCompanionOAuth(settings, _))
        ->
          credential.Refreshable(claude_adapter.refresher(
            settings,
            refresh.claude,
          ))
        "kimi", Some(KimiOAuth(settings)) ->
          credential.Refreshable(kimi_oauth.refresher(settings, refresh.kimi))
        "xai", Some(XaiOAuth(settings)) ->
          xai_bridge.oauth_policy(settings, xai_enrollment.send)
        "codex", _ ->
          credential.Refreshable(
            contracts.Refresh(fn(_, _) { Error(contracts.RefreshUnsupported) }),
          )
        "devin", _ -> credential.StaticSession
        _, _ -> credential.StaticKey
      },
    )
  })
}

/// Derived from immutable operator account bindings, never from caller headers.
pub fn runtime_bindings(config: Config) -> List(runtime.EndpointBinding) {
  config.accounts
  |> list.flat_map(fn(account) {
    xai_operations.runtime_bindings(account.xai_operations)
  })
}

/// Select an auth partition only after this account admits the public operation.
/// Existing same-operation mixed-auth priority remains configuration order.
pub fn admits_operation(
  account: Account,
  model: String,
  operation: String,
) -> Bool {
  case account.provider {
    "xai" ->
      xai_operations.registration(
        account.id,
        account.auth_mode,
        account.xai_operations,
        model,
      )
      |> result.map(fn(row) { list.contains(row.operations, operation) })
      |> result.unwrap(False)
    _ -> True
  }
}

/// Union only the operation/auth rows actually admitted for configured accounts.
pub fn xai_registration(
  config: Config,
  model: String,
) -> Result(registry.Model, String) {
  use rows <- result.try(
    config.accounts
    |> list.filter(fn(a) {
      a.provider == "xai" && list.contains(a.models, model)
    })
    |> list.try_map(fn(a) {
      xai_operations.registration(a.id, a.auth_mode, a.xai_operations, model)
    }),
  )
  case rows {
    [] -> Error("configured xAI model required")
    [first, ..] ->
      Ok(
        registry.Model(
          ..first,
          auth_modes: list.unique(
            list.flat_map(rows, fn(row) { row.auth_modes }),
          ),
          protocols: list.unique(list.flat_map(rows, fn(row) { row.protocols })),
          operations: list.unique(
            list.flat_map(rows, fn(row) { row.operations }),
          ),
          capabilities: list.unique(
            list.flat_map(rows, fn(row) { row.capabilities }),
          ),
        ),
      )
  }
}

/// Runtime-selected operation origins are authoritative only through the exact
/// configured account binding. Legacy API-key accounts retain their own origin.
pub fn xai_endpoint(
  config: Config,
  context: contracts.Context,
  request: contracts.Request,
) -> Result(xai_endpoint.Config, contracts.Failure) {
  let denied = contracts.Failure(contracts.Unsupported, contracts.NotSent, None)
  use account <- result.try(
    list.find(config.accounts, fn(a) {
      a.provider == "xai"
      && context.provider == a.provider
      && request.provider == a.provider
      && a.id == context.account
      && a.auth_mode == context.auth_mode
      && request.auth_mode == a.auth_mode
      && list.contains(a.models, request.model)
    })
    |> result.replace_error(denied),
  )
  case account.auth_mode, account.xai_operations {
    "api_key", [] -> {
      use _ <- result.try(case context.origin == account.origin {
        True -> Ok(Nil)
        False -> Error(denied)
      })
      Ok(
        xai_endpoint.Config(
          xai_endpoint.ApiKey,
          True,
          False,
          Some(account.origin <> "/v1"),
          Some(account.origin <> "/v1"),
          None,
          case account.egress {
            fleet.LocalLoopback -> xai_endpoint.LocalMock
            _ -> xai_endpoint.VerifiedTls
          },
        ),
      )
    }
    _, bindings ->
      xai_operations.select(bindings, context, request)
      |> result.replace_error(denied)
  }
}
