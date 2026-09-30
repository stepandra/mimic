# xAI native adapter handoff v2

Base: `https://github.com/stepandra/mimic.git`,
`3e00808ff0fefbb6728edb1769c17139ef0fd93a` (`origin/main` verified before edits).
CPA source pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.

This is an **adapter handoff**, not a claim that the root gateway has enabled
these features, that CPA parity passed, or that a live xAI account was used.
All wire bodies, credentials, headers and certificates in the tests are
synthetic. No consumer browser automation, account scraping or ambient
credential discovery is implemented or authorized.

## Integration surface

- `xai/bridge.oauth_policy(config, send)` returns the existing runtime
  `Refreshable` policy using `bridge.refresher`. Device enrollment remains
  `oauth.discover/start/poll`, followed by `bridge.oauth_material` and durable
  `runtime_store.save` **before activation**. Preserve the approved
  `token_endpoint` private metadata. API keys remain `StaticKey`, with no
  invented expiry. There is no second refresh manager.
- `xai/adapter.selected_http(config, ca_file)` returns `Adapter(xai.Handle)`.
  It derives the `/v1` base from **each selected Context.origin**, not the
  first account. `http(config, ca_file)` also exists for explicit fixed-base
  callers and enforces exact origin equality. Keys come only from Context.
- `xai/adapter.collect` and `run` retain their existing signatures. The new
  opaque HTTP handle binds alias refs to the exact prepared request and
  selected account. Shared Responses framing/lifecycle validates wire events
  before aliases are restored. All accepted 2xx SSE statuses use this path.
  A malformed suffix in a batch preserves its nonterminal prefix but withholds
  terminal success before returning an error. No generated content is cached.
- `xai_websocket.selected_adapter(tenant, config, ca_file)` returns
  `SessionAdapter(Handle)`. `adapter` uses an explicit fixed WS base. Both
  use the existing shared physical transport and Responses Session; they do
  not import or clone the Codex provider. WS requires explicit enablement.
- `xai/models.registration_for(id, config)` advertises the chosen auth mode,
  Buffer/Stream/Tools, and WebSocket/Continuation only when enabled. The old
  `registration(id)` intentionally remains API-key HTTP Buffer/Stream-only
  until the root owner switches its raw transport to the native adapter.
  A registry entry is not evidence of model entitlement.

### Exclusive protocol-origin bindings

Shared-core S3 was inspected read-only:
`source.tar.gz` SHA-256
`f6c39981bd331612b67e5bd21dd582f138facd2767b4479ba09d84a7cf9d85e8`.
It provides `runtime.start_with_bindings` and
`EndpointBinding(provider, auth_mode, account, protocol, operation, origin, egress)`.
Integration approved this plan. Bindings must be explicit operator config,
exclusive for that account, and resolved after account selection. They share
the same credential worker/store key, not duplicate grants.

For a Grok Build OAuth account, the recommended request labels are:

| Runtime protocol / operation | Explicit approved origin | Wire target |
|---|---|---|
| `responses` / `responses` | `https://cli-chat-proxy.grok.com` | `/v1/responses` |
| `responses` / `responses/compact` | `https://api.x.ai` | `/v1/responses/compact` |
| `responses` / `responses/websocket` | `https://api.x.ai` | `/v1/responses` upgrade |

The distinct WS operation prevents HTTP and WS sharing an indistinguishable
binding key. `selected_adapter` requires `responses/websocket`; only the
explicit-base `adapter` accepts legacy operation `responses`.
It never rewrites a selected proxy origin to
the API host; an unapproved/mismatching origin fails before connection.
The gateway owns this binding/configuration wiring. S3 has not been imported
into the xAI worker's base. `test/xai_binding_s3_test.gleam.fixture` is a
versioned executable fixture to compile as a `.gleam` test with S3; it exercises
one OAuth grant with distinct HTTP/WS origins and rejects legacy WS-label
binding misuse and an unconfigured compact operation. Assembled gateway
binding behavior must still be tested by integration after import.

`using_api=true` routes HTTP to the public API by default. In proxy mode an
absent/default-public HTTP base resolves to the CLI proxy; an explicit
non-default override remains explicit. Compact and WS select independent
bases. Proxy-host compact/WS are rejected even with host case/path variants.
No token is silently moved to the source-described alternate host.

### Tools and continuation limits

Function schemas and unknown schema fields are retained. One-level namespaces
flatten with `namespace__name`, preserving existing qualified and `mcp__`
names. A client function `web_search` receives a collision-free
`clientfn_web_search[_N]` alias, independently from native hosted `web_search`.
Native `web_search` and CPA-source-backed `x_search` declarations and their
structured tool choices are retained. Hosted result events are not converted
into client function results. Function arguments are never text-replaced.

Restoration happens only after shared wire identity validation. Two namespaces
with the same short function name cannot disguise an upstream identity change.
HTTP full-transcript input is checked with shared call/result pairing. WS
continues only from a completed receipt on the same physical connection,
tenant, credential, account, model and client session. Only the current
request's declarations supply its reverse map; there is no global alias cache.
Runtime credential rotation closes the existing connection. No reconnection,
uncertain-send replay or implicit history reconstruction occurs.

Remaining explicit exclusions:

- HTTP `previous_response_id`: no trusted HTTP receipt is attached to this
  adapter. CPA's HTTP transform strips the field, so MIMIC rejects rather than
  silently losing state. WS continuation is supported separately.
- Compact tool declarations/choices or sampling/output limits that would be
  silently dropped; compact output is not a tool-restoration path.
- Dynamic/custom tools, image-generation tools, namespace dispatcher folding
  over 200 tools, duplicate logical/wire tool names, media input and warmup
  `generate=false`. These have not earned a round-trip capability claim.
- Bare 401/429 inference responses do not prove non-execution. Their delivery
  classification is Uncertain, never an automatic replay authorization.

## Exact local drivers

Use the pinned toolchain, with bounded BEAM schedulers on shared hosts:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam run -m xai_native_scenarios
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh
```

The first driver emits one JSON observation **after every invoked assertion
passes**, with `scope=xai_native_adapter` and explicit false fields for
assembled ingress, CPA differential and live provider. It runs:

- Real loopback discovery/device/token/refresh, plus injected malformed,
  escaped-duplicate/nested-duplicate and contradictory auth responses.
- API-key and OAuth HTTP separately, holding two selected accounts with
  different origins/credentials/alias maps open concurrently and consuming
  responses in reverse order; HTTP 200 and 201; terminal JSON usage.
- Valid SSE prefix then malformed data; terminal plus known malformed suffix.
- Real loopback WS and verified WSS, each with API key and OAuth separately;
  created/keepalive/tool lifecycle/terminal usage, scoped result continuation,
  orphan/client/account rejection, close/cancel and fresh-socket rejection.
- Runtime API-key and OAuth rotation invalidation without a second send;
  cross-origin handshake rejection and namespace wire-identity mismatch.

The existing `xai_scenario` remains honest about its unsupported assembled
ingress fixture. Do not replace that result with this adapter driver's success.
Native-client QA can use these hooks for synthetic Grok workflows; actual
native CLI observations still require its independently pinned executable and
explicit operator endpoint/credential/budget authorization.

## Evidence

See `xai-source-api-v2.json` for the versioned source-derived policy snapshot,
immutable source URLs/hashes, official documentation observations and limits.
It is not a packet capture, TLS fingerprint or live model-availability result.

Validation on the xAI-owned base plus changes:

- `scripts/verify-integration.sh`: exit **0**, **530 Gleam tests**, **10 Python
  tests**, doctor/parity validation, all existing source scenarios and gateway
  smoke tests, Erlang shipment and all shipment smokes passed. Log:
  `build/xai-native/release-gate.log`, SHA-256
  `3a3b4220debadcde5e6cbb3990e23b6b29d17875a60111d740b3ba508f67184c`.
- `xai_native_scenarios`: exit **0**, all advertised JSON adapter observations
  true; assembled ingress, CPA differential and live provider explicitly false.
- The S3 binding fixture was compiled/run in a **generated build-only overlay**
  of this tree plus the exact S3 archive; exit **0**, same grant/two explicit
  origins, legacy WS-label rejection and unbound compact rejection all passed.
  Neither sibling worktrees nor shared-core source in this worktree were edited.
- Source audit raw artifacts are retained in
  `build/xai-native/upstream-v2.tar.gz`, SHA-256
  `cea38656164c6bfc27b9feec5f641833465d75898f8ebe41aa6f96882befa1e4`.
  Its internal `MANIFEST.json` identifies every fetched URL, byte count,
  timestamp and SHA-256. All seven immutable CPA source hashes matched the
  audited pin; official HTML is explicitly a mutable-source snapshot.

Integration still owns the root route, config/enrollment and assembled
Grok-client tests. This handoff does not mark those gates green on its behalf.
Machine-readable exact commands, outcomes and log hashes are frozen in
`xai-native-v2-results.json`.
