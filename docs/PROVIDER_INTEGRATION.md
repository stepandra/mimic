# Assembled provider integration

This document describes the combined application, rather than adding together
results from isolated threads. The CPA comparison is pinned to
`acdace936fa7df2905500c7f5e0a97d683138dea`.

## Operator entry points

Start from `examples/providers.synthetic.json`, which targets only a synthetic
loopback upstream. Replace its absolute state-directory path with a pre-created
operator-owned directory with mode `0700`. Configuration contains no credentials.
It explicitly binds account IDs, provider/auth mode, upstream origin and model
IDs; the server listens on loopback.

The CLI separates credential/key provisioning from configuration:

```sh
gleam run -- providers credential import /absolute/providers.json account-id /absolute/private-credential.json
gleam run -- providers credential login /absolute/providers.json account-id /absolute/private-identity.json
gleam run -- providers credential status /absolute/providers.json account-id
gleam run -- providers credential delete /absolute/providers.json account-id
gleam run -- providers key import /absolute/providers.json client-id /absolute/private-client-key.txt
gleam run -- providers key revoke /absolute/providers.json client-id
gleam run -- serve providers /absolute/providers.json
```

Private import files must be regular, non-symlink files with mode `0600`.
Keep them outside the source repository. A Claude API-key import contains an
`api_key` field. A Codex OAuth import contains `access_token`, `refresh_token`,
`expires_at_ms` and `chatgpt_account_id`. These values are credentials and
private identity, not examples to paste into version-controlled configuration.
Client-key files contain the token as text. Import commands print metadata,
never credential values.

The existing `management` service still owns its legacy storage contract.
Use `providers credential ...` for runtime records; do not write a second
credential manager against the same runtime state directory.

### Exposed gateway capabilities

The configured model selects exactly one provider. No generic fallback makes
an unimplemented provider look supported.

| Provider | Configured auth | Exposed operations | Deliberately unavailable |
|---|---|---|---|
| Claude | `api_key`, `oauth` | Messages JSON/SSE, count_tokens, configured PKCE login/refresh, bounded model policies | Full CPA client profile/cloaking and quota-scope fidelity |
| Codex | `oauth` | Responses buffered/SSE, compact; independently opt-in HTTP and WS continuation | Native sparse Responses-lite and WS-lite fidelity |
| xAI | `api_key` | Native Responses buffered/SSE, compact, supported function/namespace tools | Gateway OAuth, HTTP continuation, physical WS, full media/custom tools |
| Devin | `session_token` | Experimental numeric-loopback buffered Chat; expanded native codec imported | Remote endpoints, Messages route, client streaming, gateway status/catalog/enrollment workflows |
| Kimi | `api_key`, `oauth` | Native Responses JSON/SSE, Chat JSON/SSE, buffered Messages, supported tools/thinking/images, device enrollment/refresh | Messages SSE, compact, opaque continuation, WS, lossy CPA repairs and unsupported media |
| Generic Kimi | `api_key` | Separate `openai-compatible-kimi` buffered Chat, supported text/images/tools without native transforms | OAuth, streaming, native Kimi policy and unsupported media |

`GET /v1/models` lists configured, supported models rather than claiming a live
provider catalog. Client authentication is checked before dispatch; revocation
affects the next request. Provider credentials and Host are taken from the
selected operator account, not forwarded from caller-supplied headers.

Codex auto-refresh requires an explicit account `oauth` object containing the
provider's `authorize_url`, `token_url` and `redirect_uri`. The token endpoint
is validated independently and the request uses verified TLS or explicit
loopback HTTP. Without this object, a still-valid imported credential can be
used, but refresh is unsupported and enters the runtime recovery fence when
required. This is not a hidden background login mechanism.

Claude OAuth configuration requires `oauth.client_id`, `authorize_url`,
`token_url`, and a loopback `redirect_uri`. Private grant imports require
`access_token`, `refresh_token`, explicit `expires_at_ms`, `account_uuid`,
`device_id` (64 lowercase hexadecimal characters), and optional
`organization_uuid`. Configured login uses a private identity file containing
the account/device fields, the existing PKCE/callback listener, native JSON
exchange, and the runtime store. Endpoint-returned identity must agree; no
account, device, expiry, or fingerprint is guessed. OAuth `metadata.user_id`
and session headers bind to the authenticated client and selected account.

Kimi is a first-class provider, not generic OpenAI compatibility. Configure
`provider: "kimi"`, an explicit origin and pinned supported model such as
`kimi-k2.7-code`; aliases map to the native upstream model. `base_path` defaults
to `/coding`, with `""` for direct `/v1` and explicit operator prefixes also
supported. The runtime-selected account supplies origin, base path and auth.
For OAuth, configure `oauth.domain` (`kimi.com` or `kimi.ai`), `device_url` and
`token_url`. Endpoints must be the exact approved auth-domain pair or an
explicit paired loopback test server. Private grants require access/refresh,
explicit expiry and `device_id`. Device enrollment uses a private file with
`device_id`, prints the verification URL/user code, polls in the foreground,
and saves through the runtime store. It does not open a browser or maintain
a second refresh manager. Private device identity also supplies native
`X-Msh-Device-Id`. Unsupported request fields fail rather than being dropped.

The separate generic identity uses `provider: "openai-compatible-kimi"` and
an explicit model and API-prefix `base_path` (default `/v1`). It does not use
native aliases, device metadata or thinking/temperature conversion. Semantic
message and tool-result media are checked even when the caller's capability
list is empty; unsupported nested audio/video/file blocks fail before I/O.

Claude inference 429s are currently handled conservatively: the provider
closes before the runtime can cool or rotate the credential pool, and the
gateway returns sanitized 503. This also disables genuine quota failover until
a bounded request-versus-account classifier is qualified. OAuth token-endpoint
rate-limit deferral is separate and unchanged.

Private credential files use 0600 and state directories use 0700. This is
permission-protected storage, not encryption at rest. Source and shipment
workflows are synthetic; no live login/provider compatibility is established.

`codex_websocket` is a top-level boolean, **false by default**. When explicitly
enabled with a Codex catalog/account, authenticated `GET /v1/responses` uses
the separately owned native WebSocket implementation. Only configured Codex
models receive the WebSocket capability; Claude, Kimi and xAI do not.
Authentication and trusted tenant derivation precede upgrade. Browser Origin,
extensions and subprotocol negotiation are rejected. The vendored pinned Mist
parser rejects duplicate security singleton headers before normalization and
requires HTTP/1.1 for upgrades; this also protects ordinary HTTP/1.x Authorization
and Host boundaries. See `MIST_VENDOR.md` and `PROVIDER_WEBSOCKET.md`.

The WS owner checks the current client key before each new inference and again
after acquisition/refresh before send. Revocation therefore rejects the next
request even on an already-open connection. This is not an atomic/proactive
interruption guarantee for an already-admitted response.

`codex_http_continuation` is a separate top-level boolean, **false by default**.
With an explicit Codex catalog/account, it creates one private in-memory cache:
32 entries, 8 MiB total serialized size, 2 MiB per entry, 15-minute TTL. It
requires a stable `thread-id` or `x-client-request-id`; `thread-id` takes
precedence when both are present, and both must be valid bounded values.
The hint is scoped to the authenticated tenant and authoritative selected
account/credential revision/model/origin, not trusted as an authorization token.
Only validated completed responses followed by clean EOF publish receipts.
Missing/expired/wrong-scope receipts fail without fallback or upstream I/O.
Disabled, headerless and compact paths remain cache-free and reject a supplied
`previous_response_id`. Restart and credential replacement invalidate receipts.
There is no durable conversation-history store or public cache-clear API.

## Boundaries

- The gateway's account/model configuration is operator-owned; incoming
  requests cannot select arbitrary endpoints or authentication material.
- Runtime storage is separate from legacy credential storage. Runtime
  credential mutations must use its CAS-protected APIs. The legacy management
  panel is not an alternative writer for runtime credentials.
- OAuth refresh is performed before sending a provider request. A result that
  might conceal token rotation retains a durable recovery fence. This means
  operator recovery is required; it does not prove provider-side revocation.
- Streaming belongs to the actual response process. The Mist chunk process
  must synchronously adopt the runtime stream; cancellation, terminal errors
  and disconnects release resources without replaying a started request.
- JSON/SSE captures remain UTF-8. Devin's secret-bearing Connect/protobuf
  request is a separate binary plan, never a capture or a diagnostic artifact.
- Storage recovery is tested for process/VM restarts, not power loss. A stale
  filesystem ownership guard requires explicit operator investigation and
  recovery; startup never guesses that another process is dead.

## Evidence and capability claims

The repository contains three different kinds of checks:

1. **Unit and integration tests:** `gleam test` includes imported provider,
   shared runtime/protocol and assembled gateway regressions.
2. **Local workflow gate:** `make integration` runs synthetic localhost
   scenarios and independent-VM restoration, then exports an Erlang shipment.
3. **CPA conformance:** `make parity DRIVERS=...` uses the explicit 37-row
   scope and requires the configured executable reference drivers. Missing or
   unsupported rows fail. It is not replaced by the first two gates.

The historical conformance baseline recorded 3/37 narrow mock successes and
0/37 strict release successes without a CPA executable. Those are baseline
observations, not current combined-build measurements. Source inspection and
locally simulated responses are never labeled live validation.

## Deliberate limits

- No live provider account, native CLI, OAuth browser session or paid upstream
  request is exercised by default.
- A standalone RFC6455 test does not establish physical provider WebSocket
  integration. Unsupported gateway upgrades must be rejected explicitly.
- The Devin slice is experimental: permanent session credentials, one-shot
  buffered text and numeric-loopback-only binary transport. Remote Devin,
  broader conversation/tool/media workflows and native transport qualification
  remain unverified or unsupported.
- Gemini, Antigravity and Copilot are excluded, not marked as passing.
- Conservative rejection of unsupported provider features is not byte-for-byte
  equivalence with CPA's normalization, pruning or omission behavior.

Provider-specific documents retain their source pins, fixture provenance and
unsupported paths. Frozen handoff hashes document the imported inputs; later
integration edits and combined validation must be reviewed as ordinary changes.

## Integration regression: TLS recorder fixture startup

The historical isolated builds sometimes reported `proxy_not_ready` or TLS
timeouts. A deterministic delayed-start probe reproduced `proxy_not_ready`
with the previous fixture: its readiness loop expired before startup's allowed
OpenSSL work, and its upstream accept timeout began before the proxy was ready.

The fixture now monitors the proxy, gives startup a 30-second monotonic
deadline (two OpenSSL commands can each take ten seconds), and starts the
upstream accept window only after proxy readiness. A real CONNECT/TLS/SSE
roundtrip with a 6.2-second injected startup delay failed before this change and
passed afterward. This demonstrates that particular timing defect; it does
not establish that every historical timeout had the same cause. Production
TLS verification and request/response timeouts were not relaxed.
