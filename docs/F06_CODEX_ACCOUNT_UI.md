# F06 — operational Codex enrollment in the recovered account UI

## Scope and integration

Codex PKCE enrollment uses the **same** operator page, bootstrap/session/CSRF
boundary, one-active-attempt coordinator, and S5 runtime store as recovered F05.
It does not fork the UI, create a credential manager, seed a second gateway
runtime, or access CPA. Kimi's start/poll/cancel/material path is moved intact
behind the common adapter; the existing public F05 start APIs remain supported.

The root `accounts ui` dispatch is already admitted. **No additional root CLI,
gateway, config, build, dependency, vendor or shipment hook is required.** Root
help may describe the panel as Kimi/Codex rather than Kimi-only.

```text
mimic accounts ui serve CONFIG PRIVATE_DEVICE_IDENTITY PORT
mimic accounts ui serve CONFIG PORT
```

The shorter form is for Codex-only rosters. If any configured Kimi account is
present, the existing private identity file is still required before I/O. No
credentials, identities or callback values are accepted in argv or page input.

The configured Codex `oauth` block is the **existing** gateway contract:

```json
{
  "authorize_url": "https://auth.openai.com/oauth/authorize",
  "token_url": "https://auth.openai.com/oauth/token",
  "redirect_uri": "http://localhost:1455/auth/callback"
}
```

This is source-qualified configuration data, **not approval for live use**.
The temporary callback listener binds only `127.0.0.1`, at the explicit
configured redirect port, and accepts the exact configured Host/path. The
callback port must differ from the operator UI port. IPv6 callbacks, implicit
ports, remote callbacks, encoded callback paths and callback query/fragment
configuration fail explicitly. A port occupied by another service fails the
attempt; it is never taken over. The strict UI API Origin rule is not relaxed
for the cross-site OAuth callback.

## Pinned auth contract

CPA revision `acdace936fa7df2905500c7f5e0a97d683138dea`:

- [`internal/auth/codex/openai_auth.go`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/codex/openai_auth.go):
  client `app_EMoamEEZ73f0CkXaXp7hrann`, published auth/token URLs, callback
  `http://localhost:1455/auth/callback`, `openid email profile offline_access`,
  S256, prompt/login/organizations/simplified-flow options, form token grants.
- [`internal/auth/codex/pkce.go`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/codex/pkce.go):
  random URL-safe RFC 7636 verifier and SHA-256 challenge.

Those exact pinned files were read for F06. F06 invokes the already-compiled
`providers/codex/oauth` policy, not a new endpoint, device grant, token parser or
provider refresh implementation. Its existing 43-character verifier differs
from CPA's 128-character verifier but is within the same RFC 7636 bounds.
`codex/adapter.material` preserves the trusted token-exchange routing hint
`chatgpt_account_id`; JWT payload decoding is not treated as identity/signature
verification. The ID token itself is not stored or exposed by this slice.

## Lifecycle and safety

- The coordinator's S5 reservation succeeds **before** an adapter runs or
  publishes a login URL. Only the coordinator can commit the returned material.
- Verifier and pending login are private worker memory. OAuth state appears only
  as required in the authorized temporary login URL; no separate state/verifier
  response, client storage, logging or persistence is introduced.
- A bounded GET at the configured callback consumes the pending attempt once,
  **including** state mismatch, duplicate state/code or provider rejection.
  Concurrent/replayed callbacks cannot trigger a second exchange. Wrong
  Host/path/method, HTTP/2, bodies and oversized/unsupported query forms are
  rejected before callback admission.
- The callback page is constant no-store/no-referrer text. It reflects no code,
  state, tokens or provider response and distinguishes callback receipt from
  successful installation. Status on the account page remains authoritative.
- Consuming a callback clears the browser login prompt and reports `exchanging`.
  The temporary listener is joined before the single token exchange. There is
  no retry after an unknown exchange outcome. An unconfirmed listener shutdown
  fails as `callback_cleanup_unconfirmed` before any token exchange.
- The Codex attempt has a maximum five-minute monotonic deadline, also bounded
  by the existing session and coordinator attempt deadlines. Expiry, cancel,
  logout and stop compete with the exact S5 ticket before linked network work
  is killed; a monitored listener lifecycle stops its OTP subtree normally.
- Same-token admin save, replacement, deletion or refresh invalidates an older
  ticket. CAS uncertainty is `installation_unconfirmed` or
  `cancellation_unconfirmed`, never a promise of rollback.
- Cancellation retains existing material with a new generation; it does not
  revoke a provider token. Graceful restart invalidates the operator session
  and cancels pending work. Whole-VM loss retains S5's nonce-only pending marker,
  requiring explicit administrative deletion before a new first enrollment.
- Access/refresh/session tokens never enter HTML, JSON status, JS storage,
  bootstrap output, logs, process argv or a browser URL. Login links use
  noopener/noreferrer/no-referrer and the existing generation-bound presentation.

## Compiled provider seam for F07/F26

`account_ui/enrollment` defines:

```gleam
Prompt = DeviceCode(String, String) | BrowserLogin(String)
Clock = fn() -> Int
Emit = fn(Option(Prompt), Int) -> Nil
Adapter(run: fn(Emit, Int, Clock) -> Result(AuthMaterial, String))
```

Emitting `None` clears consumed prompts. Deadlines are monotonic milliseconds;
errors are safe phase names, not provider exception/body text.

`account_ui/enrollment_adapters` owns configured provider selection:

```gleam
Transports(kimi: kimi/oauth.Send, codex: account_ui/codex.Send)
production_transports() -> Transports
supported(Account) -> Bool
validate(Account, device_id: String, ui_port: Int) -> Result(Nil, String)
select(Account, device_id: String, Transports) -> Result(Adapter, String)
```

The additive synthetic seam is
`account_ui.start_with_transports(Config, private_identity_path, port, Transports)`.
The coordinator also exposes `start_with_transports_clock` for deterministic
deadline tests. Production always selects the existing bounded, direct,
no-redirect `gateway/refresh` transport. F07/F26 may add qualified adapter
selection without copying the shell, S5 manager or lifecycle. Neither slice is
implemented here.

## Executed evidence and remaining gates

Every fixture is **synthetic**, inside this attached worktree's ignored
`build/account-ui-f06`, with explicit loopback listeners. No real provider,
account, ambient credential, CPA service or external state directory was used.
Local BEAM runs use `ERL_FLAGS='+S 2:2 +A 2'` and Gleam 1.18.1 via `mise`.

| Focused command | Observed result |
| --- | --- |
| `mise exec gleam@1.18.1 -- gleam build` | PASS |
| `mise exec gleam@1.18.1 -- gleam format --check src/mimic/account_ui.gleam src/mimic/account_ui test/account_ui_codex_test.gleam test/account_ui_test.gleam` | PASS |
| `mise exec gleam@1.18.1 -- gleam run -m account_ui_codex_test` | 10 tests PASS |
| `mise exec gleam@1.18.1 -- gleam run -m account_ui_test` | 12 PASS / 1 FAIL: only inherited F44 raw duplicate-Origin 200, expected close/0; unchanged poll-cancel/admin/delete/store-failure case PASS |
| `python3 scripts/smoke-account-ui-codex.py --kimi-cancel-only` | PASS: safe evidence `before=waiting, cancel_status=200, after=cancelled, error=None, polls=1` |
| `python3 scripts/smoke-account-ui-codex.py` | PASS: actual root UI, synthetic issuer, PKCE verification, real callback, already-running root HTTP gateway; authorize 6 / exchange 6 / Codex refresh 2 / Responses 4; Kimi blocked-poll cancellation also PASS |
| `python3 scripts/smoke-account-ui-codex-browser.py` | PASS: real isolated Chrome, Codex callback/install/gateway/refresh, Kimi login/poll/gateway/refresh, cancel/logout, privacy checks; axe 29 passes / 0 violations / 0 incomplete |
| `python3 scripts/smoke-account-ui-presentation.py` | PASS: all six served-JS out-of-order/visibility/focus regression cases |

The socket smoke additionally proves model-bound two-account isolation,
fresh-process reuse of persisted rotation, blocked-token cancel/admin
replacement/deletion, old callback/session rejection after graceful restart,
whole-VM loss fail-closed reservation and explicit admin recovery. Focused
tests cover mismatched/duplicate state, provider error, callback one-time use,
expiry during wait and exchange, same-token save CAS, invalid callback boundary,
occupied S5 slot, and uncertain exchange with no retry.

Desktop and 390×844 screenshots were inspected; no horizontal overflow was
observed. DOM contained no private sentinel tokens, the bootstrap input was
cleared, document.cookie was empty and local/session storage remained empty.
Browser errors and console were empty. The browser followed the actual served
login link using the installed driver's explicit `--new-tab` action and returned
via stable tab ID `t1`; ordinary pointer-link activation in that driver did not
reach the synthetic issuer in earlier attempts and is not separately qualified.
The temporary browser HOME/TMP/config, empty plugin list and 127.0.0.1-only
domain allowlist prevented use of an ambient browser session.

Final bounded-window logs are under `build/account-ui-f06/`:
`focused-slot.log`, `f05-slot.log`, `kimi-cancel-repro.log`, `root-slot.log`,
`browser-slot.log`, `presentation-slot.log`, and `browser-proof/` screenshots,
accessibility trees, axe report and transcript. All artifacts are local and
synthetic; no real operator code or provider credential was retained.

Inherited **known-red dependency**, not weakened or owned by F06:
F44 must admit the raw Mist duplicate-Origin/singleton and coalesced-pipeline
fixes described in `F05_ACCOUNT_UI.md`. An existing composed F05 poll-cancel
409 was separately reported by the parent. It did not reproduce in either the
unchanged focused test or the safe actual-socket cancellation reproduction in
the exclusive validation window; its cause remains unclassified and the prior
failure is **not waived or attributed to load**. No cancellation/security test
was relaxed. The only F05 test amendment updates its static heading expectation
from Kimi-only to the shared account page.

Full `gleam test`, assembled heavy, root/shipment and live-provider qualification
gates remain parent-owned and were not executed by F06.
