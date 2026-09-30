# Devin integration handoff

> Historical v1 handoff, superseded by [EXPANSION.md](EXPANSION.md).
> Do not use old sibling-checkout overlays for current verification.

## Status and ownership

**Experimental loopback-only, one-shot text slice; not Devin parity.**
No root routes, CLI, shared IR/types, dependencies, management or other provider
namespaces were edited. No merge, commit or push is requested by this handoff.

Runtime v2 was inspected and is intentionally insufficient: it stores only
API-key/expiring OAuth material and sends UTF-8 `Capture.body`. The runtime owner,
with coordinator approval, published v3 `SessionToken`/`StaticSession` and
neutral binary `HttpRequest`/`binary_http`. V2 must remain immutable. This stream
does not duplicate storage, refresh workers, selection, leases or sockets.

## Exact coordinator hooks

Import `mimic/providers/devin/bridge` only after integrating the runtime owner's
v3 source. Add `bridge.models()` to the explicit registry:

```text
provider     devin
model        devin/swe-1-7
auth_mode    session_token
protocols    openai-chat, anthropic-messages
operation    generate
capabilities Buffer ONLY
```

The registry entry is for experimental local assembly only; do not advertise it
as a production provider. `prepare` independently validates these fields, body
model, stream=false/absent, content shape, material kind and loopback origin.
No unsupported feature is accepted merely because the caller omits `required`.

1. Pre-create a private 0700 state directory and call `auth/storage.new`.
2. Normalize an operator-supplied token with Devin `auth.format_session_token`.
   Never obtain it from incoming client Authorization or log the result.
3. Save via `auth/runtime_store.save(store,
   auth/runtime.key("devin","session_token",account_id),
   contracts.SessionToken(token, private_metadata))`.
   Profile identity belongs in private_metadata, not captures or model rows.
4. Configure `runtime.Account` with provider/auth mode/model above,
   `auth_policy: credentials.StaticSession`, positive concurrency and explicitly
   approved loopback origin. There is no fake expiry or refresh callback.
5. Start the shared runtime once per private store with the combined registry.
6. At authenticated Chat or Messages ingress, strip incoming credentials,
   framing and Host; create `contracts.Request` with scoped client/request
   session, `Buffered`, no continuation/pinned account, and the original JSON.
7. Call `bridge.execute(runtime, ca_file, request) -> Result(String, Failure)`.
   It uses `transport.binary_http`/`runtime.execute`, validates Connect frames,
   and encodes through the existing shared Chat/Messages dialect modules.
   Render the result with the appropriate client JSON Content-Type.
8. Reject Responses, client SSE, WS, compact and unsupported body features before
   any upstream attempt. Do not route them through a generic OpenAI fallback.

`bridge.adapter(ca_file) -> Adapter(egress.Stream)` and
`bridge.prepare(Context, Request) -> Result(HttpRequest, Failure)` are public for
runtime integration. Request bytes contain credentials: do not persist or
inspect that plan. Headers include exactly one approved Host and a byte-counted
Content-Length; no redirects or client-selected upstream destinations.

### Upstream pull decoding

`response.new/feed/finish` incrementally turns raw Connect chunks into
`Text(String)`, `Usage(ir.Usage)`, `Stop` events. This is **not client SSE** and
does not justify registering Stream. Nonzero cache usage, tools, thinking,
signatures, response dimension groups and unknown semantic fields fail.
`response.buffered` yields the shared `ir.Response`, not a duplicate Responses
API codec. The shared Responses owner has been asked for published signatures;
Responses support is not registered or claimed tested here.

For future Mist streaming integration the new chunk process must synchronously
call `runtime.adopt(stream)` before the original request owner exits, before
scheduling the first pull. Abort on failure; do not reopen or replay. Current
tests cover real runtime ownership transfer between BEAM processes, **not Mist
chunk-init integration**. The coordinator must supply that assembled test.

### Failure policy

Before output, unsupported shapes return `Unsupported/NotSent`. Remote binary
origins fail even if otherwise operator-approved. HTTP/2 is not implemented.
Explicit HTTP429 permits runtime failover; numeric Retry-After up to86400s is
converted to milliseconds. HTTP-date Retry-After remains unsupported in this
bridge. After accepted headers, protobuf/trailer/UTF-8 failures are
`InvalidResponse/Started`; never retry, even for quota-like trailer errors.
No upstream error message or credential text enters returned diagnostics.

## Runnable local verification

All commands run in the attached Devin worktree. Gleam 1.18.1 is already installed.
Use the published immutable v3 snapshot:

```sh
mise exec gleam@1.18.1 -- gleam format --check
python3 docs/devin/verify.py --pure
python3 docs/devin/verify.py --runtime /Users/jerryjohnson/dev/mimic/.delta/worktrees/qhtjz5hs63hm/mimic/build/provider-runtime-contract-v3
```

The script pins the approved manifest digest, requires exactly the 12 published
source/FFI paths and verifies every SHA256 before copying. It creates a fresh
ignored `build/devin-integration-*`
overlay from this worktree's pinned baseline, own Devin sources/tests and only
those 12 runtime files. No sibling checkout edits, VCS data, credentials,
runtime state, compiled caches or owner tests are copied.

Inside the printed overlay it runs:

```sh
mise exec gleam@1.18.1 -- gleam format --check
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam run -m devin_scenarios
```

The independent baseline-plus-pure-protocol run passed 194 tests
(179 baseline + 15 Devin), excluding the runtime bridge and runtime tests. The bridge
requires actual v3: a plain baseline checkout cannot compile these imports.
Do not substitute locally invented runtime stubs to make that build green.
The actual v3 combined run passed 200 tests and six local socket scenarios.
Exact evidence boundaries and immutable export are recorded in `VALIDATION.md`.

`devin_scenarios` is a local runtime-adapter scenario runner, **not** a
conformance-plan driver. It reports assembled_ingress=false, cpa_differential=false
and live_verified=false. Conformance's15 Devin rows remain blocked until actual
root routes and a target driver execute their required assertions. Merely
running this executable does not meet that gate.

## Explicit remaining work

- Production Devin transport compatibility; neither production H1 nor H2/TLS
  fingerprint parity has been established.
- Browser/callback server and token-exchange HTTP flow; pure PKCE URL, state,
  exchange serialization and token formatting are not network login.
- Status/profile/quota unary RPCs and dynamic catalog; only one explicit model.
- System/developer prompts and CPA sanitization; multi-turn history, session
  ordinal/cache state, tools, reasoning/signatures and images.
- Cache/dimension-group usage, compressed Connect frames and wider response
  schemas. Unsupported responses may therefore reject otherwise valid Devin
  replies; this is intentional incomplete coverage, not successful parity.
- Shared Responses HTTP/SSE codec integration; client SSE; compact and WS.
- Assembled ingress, real Mist handoff, fresh-OS-process credential restart
  scenario, CPA differential execution and opt-in live validation.
