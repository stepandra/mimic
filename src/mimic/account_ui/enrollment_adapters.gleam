/// The compiled provider selection seam. No endpoints or provider choices
/// arrive from the page: only explicitly configured accounts are admitted.
import gleam/option.{Some}
import gleam/result
import mimic/account_ui/codex
import mimic/account_ui/enrollment
import mimic/account_ui/enrollment_kimi
import mimic/account_ui/enrollment_xai
import mimic/gateway/config.{type Account, CodexOAuth, KimiOAuth, XaiOAuth}
import mimic/gateway/refresh
import mimic/providers/kimi/oauth
import mimic/providers/xai/enrollment as xai
import mimic/providers/xai/oauth as xai_oauth
import mimic/providers/xai/operations

pub type Transports {
  /// F06 constructor/API retained unchanged.
  Transports(kimi: oauth.Send, codex: codex.Send)
  WithXai(kimi: oauth.Send, codex: codex.Send, xai: xai_oauth.Send)
}

pub fn production_transports() -> Transports {
  WithXai(refresh.kimi, refresh.send, xai.send)
}

pub fn with_kimi(transports: Transports, send: oauth.Send) -> Transports {
  case transports {
    Transports(_, codex) -> Transports(send, codex)
    WithXai(_, codex, xai) -> WithXai(send, codex, xai)
  }
}

pub fn with_xai(transports: Transports, send: xai_oauth.Send) -> Transports {
  WithXai(transports.kimi, transports.codex, send)
}

pub fn supported(account: Account) -> Bool {
  case account.provider, account.auth_mode, account.oauth {
    "kimi", "oauth", Some(KimiOAuth(_))
    | "codex", "oauth", Some(CodexOAuth(_))
    | "xai", "oauth", Some(XaiOAuth(_))
    -> True
    _, _, _ -> False
  }
}

pub fn validate(
  account: Account,
  device_id: String,
  ui_port: Int,
) -> Result(Nil, String) {
  case account.provider, account.auth_mode, account.oauth {
    "kimi", "oauth", Some(KimiOAuth(settings)) ->
      oauth.validate(oauth.Config(..settings, device_id:))
      |> result.replace_error(
        "invalid configured Kimi endpoint or private identity",
      )
    "codex", "oauth", Some(CodexOAuth(settings)) ->
      codex.validate(settings, ui_port)
    "xai", "oauth", Some(XaiOAuth(settings)) -> {
      use _ <- result.try(xai.validate(settings))
      operations.validate_account(
        account.id,
        account.auth_mode,
        account.xai_operations,
      )
    }
    _, _, _ -> Error("unsupported configured enrollment provider")
  }
}

pub fn select(
  account: Account,
  device_id: String,
  transports: Transports,
) -> Result(enrollment.Adapter, String) {
  case account.provider, account.auth_mode, account.oauth {
    "kimi", "oauth", Some(KimiOAuth(settings)) ->
      Ok(enrollment_kimi.adapter(
        oauth.Config(..settings, device_id:),
        transports.kimi,
      ))
    "codex", "oauth", Some(CodexOAuth(settings)) ->
      Ok(codex.adapter(settings, transports.codex))
    "xai", "oauth", Some(XaiOAuth(settings)) -> {
      use _ <- result.try(validate(account, device_id, 0))
      let send = case transports {
        WithXai(_, _, send) -> send
        Transports(_, _) -> xai.send
      }
      Ok(enrollment_xai.adapter(settings, send))
    }
    _, _, _ -> Error("unsupported configured enrollment provider")
  }
}
