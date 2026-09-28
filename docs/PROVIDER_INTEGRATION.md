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
| Claude | `api_key` | Buffered Messages JSON, count_tokens | Gateway SSE/OAuth, model-specific CPA normalization/cloaking |
| Codex | `oauth` | Responses buffered/SSE, compact | Physical WS, continuation, Responses-lite |
| xAI | `api_key` | Native Responses buffered/SSE, compact | Gateway OAuth, tools, continuation, physical WS |
| Devin | `session_token` | Experimental buffered one-shot Chat | Remote endpoints, Messages route, streaming, tools, broader conversation/media workflows |
| Kimi | — | Not registered | Native Kimi adapter/integration not delivered |

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

The Claude OAuth library/consumer tests remain available without advertising
OAuth as an exposed gateway mode. Similarly, standalone shared WebSocket
framing tests do not enable a gateway WebSocket route.

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
