# Provider WebSocket integration

Base: published `origin/main`
`f809b8c8a51939383792e6e88d5eb4f98b7ddcc2`.
CPA source contract: `router-for-me/CLIProxyAPI`
`acdace936fa7df2905500c7f5e0a97d683138dea`.

**Codex OAuth only; explicit operator opt-in, default off.**
Claude, Kimi, xAI, compact, Responses-lite, `response.append`, `generate:false`,
implicit history repair, cross-connection resume, extensions/compression and
subprotocols are not supported by this integration. Native `response.create`
and same-socket incremental `previous_response_id` are distinct from sending
a fresh complete history with no previous ID. No HTTP fallback or automatic
replay follows a failed upgrade, uncertain send, or started response.

## Boundaries and ownership

- `providers/contracts.SessionAdapter` adds bidirectional sessions without
  changing the legacy HTTP `Adapter` constructor.
- `providers/runtime` selects the account, leases it, and acquires credentials
  before adapter open. Its existing execution guardian now serializes sends,
  polls, cancellation and synchronous adoption. The opaque session capability
  has one owner. A revoked owner cannot send, poll, adopt or cancel it.
- Each connection belongs to one execution process and lease. There is no
  global socket pool. Provider, auth mode, account, approved origin, credential,
  tenant, random downstream connection generation and model bind reuse.
- Before **each new send**, runtime reacquires through the existing durable
  credential worker. Deleted, expired/unrefreshable or rotated material closes
  the old session rather than reauthenticating it. A response already in flight
  may finish with its opening identity; subsequent sends must pass this check.
  No OAuth recovery, refresh fence or compare-and-swap rule is bypassed.
- `providers/ws_transport` owns physical HTTP(S)-origin-to-WS(S) upgrade,
  peer/hostname verified TLS, cryptographic client nonces/masks, deadlines and
  bounded framing. Configured origin is authoritative; no redirects or
  endpoint changes. Plaintext is numeric IPv4 loopback only. IPv6 is explicitly
  unsupported in this slice.
- `providers/codex_websocket` constructs selected-account OAuth headers and
  reuses Codex request normalization, provider continuation receipts and the
  shared native Responses message session. Upstream errors are not copied into
  gateway diagnostics. Only a validated completed response grants a receipt.
- `gateway/websocket` is an isolated, request-authenticated route hook. The HTTP
  owner supplies server-derived tenant identity, runtime, catalog, user agent,
  enabled model IDs and optional private test CA. It sends exactly one 101,
  preserving Mist's `Initial(rest)` bytes, and transfers the downstream socket
  synchronously while the old owner is alive. The temporary owner belongs to
  Mist's factory supervisor. It opens upstream only after the first validated
  create identifies the model. Process death closes downstream and triggers
  runtime guardian cleanup of upstream and lease.
- Shared `protocol/responses/frames.feed_one` yields one event plus untouched
  input tail. Both physical directions use it so a later malformed frame in a
  coalesced TCP chunk does not erase a valid event already delivered.

Public route API:

```gleam
Settings(
  catalog: models.Catalog,
  user_agent: String,
  enabled_models: List(String),
  ca_file: Option(String),
)

upgrade_authenticated(
  req: Request(mist.Connection),
  engine: runtime.Runtime,
  tenant: String,
  settings: Settings,
) -> Response(mist.ResponseData)
```

The caller must authenticate before invoking the hook and register WebSocket
capability only for explicitly enabled Codex OAuth models. `Origin` headers are
rejected: this CLI-only API does not implement browser origin authorization.
Cancellation is a WS close/disconnect, not an invented `response.cancel` command.
Active/idle sessions expire after 60 seconds without a create or provider event.
The loop applies pull backpressure and bounded socket read/write timeouts.

## Strict downstream handshake gate: blocked on inherited Mist parser

Actual raw-socket probes against the pinned Mist 6.0.3 route, not a callback
simulation, demonstrate last-value-wins after case normalization:

| Raw request | Observed |
| --- | --- |
| Normal HTTP/1.1 authenticated upgrade | 101 |
| Authorization valid then invalid | 401 |
| Authorization invalid then valid, mixed casing | 101 |
| Upgrade websocket then invalid | 400 |
| Upgrade invalid then websocket | 101 |
| Sec-WebSocket-Key valid then invalid | 400 |
| Sec-WebSocket-Key invalid then valid | 101 |
| Sec-WebSocket-Version 13 then 12 | 400 |
| Sec-WebSocket-Version 12 then 13 | 101 |
| HTTP/1.0 authenticated upgrade | 101 |

Mist's `internal/http.parse_headers` lowercases then inserts into a dictionary;
`parse_request` does not retain HTTP version in the public Request. The route
hook cannot reconstruct lost headers/version. The shared Upgrade validator
rejects duplicate singleton fields **when given the actual header list**, but
that alone is not evidence of strict assembled-ingress conformance.

The dependency/root owner must approve and reproducibly pin a pre-loss parser
fix: reject duplicate singleton auth/WS fields and require HTTP/1.1 for WS
upgrades (or preserve raw metadata and validate it before authentication).
No silent vendored/floating dependency change, separate proxy or second listener
has been introduced. This gate remains **BLOCKED**, not waived by opt-in.

## Local validation

All fixtures are synthetic, loopback-only, with no real provider credentials.
The isolated hook scenario is runnable in a fresh BEAM process:

```sh
mise exec gleam@1.18.1 -- gleam run -m gateway_websocket_test
mise exec gleam@1.18.1 -- gleam run -m gateway_websocket_test -- --probe
mise exec gleam@1.18.1 -- gleam run -m gateway_websocket_test -- --strict
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam format --check src test
mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh
```

The probe command reports current ingress limitations, not a success gate.
The `--strict` command is a hard gate and intentionally fails on the unpatched
baseline Mist parser. Root/dependency integration belongs to the HTTP peer;
the coordinator approved a minimal pinned vendored Mist 6.0.3 correction.

Current owner-worktree evidence with physical transport and route hook assembled:

- **485 Gleam tests passed**, no failures (463 existing plus 22 WS regressions).
- **`scripts/verify-integration.sh` exited 0**, including seven Python parity
  harness tests, existing runtime/provider scenarios, fresh-process credential
  restoration, source gateway smoke and exported-shipment gateway smoke.
- Fresh-process `gateway_websocket_test` scenario exited 0: actual coalesced
  upgrade/create, continuation versus full-history reset, active/idle cleanup,
  fragmented controls, aggregate-size/UTF-8 rejection, no replay before output,
  and real-socket credential rotation followed by explicit reconnect.
- Physical transport tests cover actual local WS and private-CA WSS,
  negative CA/hostname/upgrade validation, segmentation and process-death cleanup.
- Independent reviewer found no additional consequential blocker in the runtime
  guardian, raw takeover or receipt scope; independently exercised ownership/
  rotation and nine compiled hook tests. That review does not certify the
  pending vendor patch or later assembled HTTP-peer build.

The HTTP peer owns root dispatch/configuration tests; isolated hook success
does not establish that its independent checkout has merged the source.
Source-derived Codex beta/endpoint behavior and trusted-test TLS success do not
prove live provider acceptance, upstream TLS fingerprints, CPA differential
parity or remote performance.
