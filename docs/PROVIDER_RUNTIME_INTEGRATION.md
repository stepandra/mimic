# Provider runtime integration proposal and validation

This document records the v2 integration boundary. The additive v3
`SessionToken`/`StaticSession` and binary `HttpRequest` APIs are specified in
`PROVIDER_RUNTIME_V3.md`; use that snapshot for Devin integration. Binary
transport remains numeric-loopback-only pending real upstream HTTP-version
qualification. The startup, ownership, cancellation, CAS CRUD and recovery
requirements here still apply.
The current refresh-policy and credential schema upgrade is specified in
`PROVIDER_RUNTIME_V4.md`. Its recovery fences and conservative error mapping
must be integrated explicitly; the historical v2 backoff description below is
not the current refresh policy.

**Coordinator-owned integration remains required.** This branch does not change
`src/mimic.gleam`, `src/mimic/ingress.gleam`, shared wire types, dependencies or CI.
The existing managed CLI still takes its old one-credential path. Do not infer
assembled-provider parity from the runtime library tests.

Base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
CPA pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.

## Pinned source comparison

Inspected reference points at that exact CPA revision:

- `sdk/cliproxy/auth/conductor_refresh.go`, `refreshAuthForRequest`: request-path
  refresh uses a credential lock and rechecks whether another request already
  refreshed the token. MIMIC uses a store-scoped credential worker plus atomic
  persistence-before-use, not a copied Go scheduler.
- `sdk/cliproxy/auth/conductor_stream.go`: bootstrap buffers until a payload or
  error, with overload/refresh paths. MIMIC deliberately commits at returned
  headers instead and never retries after that point.
- `internal/registry/model_registry.go`, `RegisterClient`,
  `GetAvailableModels`, `SetModelQuotaExceeded`: CPA projects client/model quota
  into dynamic availability. This slice provides explicit shared registration
  and account eligibility, **not** complete dynamic CPA model-quota projection.

Source inspection is not differential or live-provider evidence.

## Proposed ingress patch boundaries

1. **Startup:** add an operator-configured runtime entry point to ingress:

   ```gleam
   pub fn start_managed_runtime(
     port: Int,
     state_dir: String,
     provider: String,
     auth_mode: String,
     runtime: providers_runtime.Runtime,
     adapter: contracts.Adapter(egress.Stream),
     upstream_dialect: dialect.Dialect,
   ) -> Result(process.Pid, String)
   ```

   This signature is a proposal, not an implemented ingress function. Keep
   binding `127.0.0.1`; HTTPS upstream permission is unrelated to listener
   exposure. The application owner constructs the registry and approved account
   list, opens the private auth store, then calls `runtime.start` once. Install
   the runtime in the application supervision tree before starting the listener.
   Never run the old `ingress/control` quota writer against the same store
   alongside this runtime: that legacy path predates the ownership guard.

2. **`managed_forward` / `prepare_managed`:** remove the ordering
   `auth.load(single_id) -> build Authorization -> control.acquire`.
   Replace it with:

   ```text
   authenticated incoming request
     -> active-persona gate + model/protocol/capability validation
     -> contracts.Request(provider, auth_mode, model, protocol, operation,
                          mode, required, scoped_session, pinned_account, body)
     -> runtime.open(runtime, adapter, request)
   ```

   The provider `prepare(Context, Request)` callback runs **after** account
   selection and refreshed credential acquisition. Any persona materialization
   that depends on credentials must run inside this callback, with
   `Context.origin` and `Context.credential`, not the old global upstream/id.
   Strip incoming Authorization, API keys, proxy credentials, cookies, Host and
   framing headers before constructing the provider request. Keep the provider's
   selected authentication header in its required order and case; do not append
   an assumed Bearer token.

   Build session IDs from the authenticated client identity plus the client's
   session/request ID. Do not let two clients select the same upstream state by
   sending the same `x-client-request-id`. Provider continuation requests must
   include `pinned_account`; reject them if their originating account is unknown.

3. **Transport replacement:** standard provider bridges use
   `transport.http(prepare, rejection, ca_file)`. They must render exactly one
   Host matching `Context.origin`, including a non-default port. This replaces
   `upstream_open_preserve` in the new path. Do not simultaneously call
   `control.acquire`, `control.observe` or `control.release`: the runtime owns
   those responsibilities. Custom callbacks are trusted code, not a sandbox.

4. **Streaming:** retain ingress's incremental UTF-8 buffering and dialect
   codec. Replace `upstream_next` with `runtime.next` and every close/release
   branch with `runtime.cancel`.

   **Mandatory process handoff:** Mist `chunked` starts a separate response
   process. Its `init` callback must synchronously call
   `runtime.adopt(response.stream)` **before returning**, while the request
   process is still alive. Do not send the initial NextChunk message until
   adoption succeeds.

   ```gleam
   // Inside mist.chunked init, in the NEW response process:
   case providers_runtime.adopt(response.stream) {
     Ok(Nil) -> {
       // Record stream in chunk state, then schedule first pull.
     }
     Error(_) -> {
       // Abort this response; never reopen/retry the upstream.
     }
   }
   ```

   The opaque stream handle is the transfer capability. Guardian checks both
   processes are alive, registers the replacement monitor before removing the
   old monitor, then acknowledges. Transfers during pull/cancel or after owner
   death fail. Old owners cannot pull, cancel or re-adopt. A response process
   dying closes its process-owned upstream and releases its lease.

   Mist may already have sent response headers when init fails. That path must
   abort the downstream stream, not attempt a new HTTP response. On downstream
   send failure, codec error or request cancellation, the **current owner** calls
   `runtime.cancel`. On successful EOF the runtime already cleans up; an extra
   cancellation is harmless. Never retry based on a codec/stream failure.

5. **Buffered execution:** use `runtime.execute` and feed its BitArray body
   into the existing codec. It has an 8 MiB bound and the same conservative
   no-replay policy. A failure after accepted headers is `Started`, even if the
   caller has not yet written its buffered response.

6. **Model route:** `/v1/models` should serialize `registry.models(registry)`,
   filtered by the configured provider/auth mode. Do not derive model rows from
   credential files or make implicit provider discovery requests.

7. **Error mapping proposal:** `Unsupported` -> 422; `InvalidConfiguration`,
   `CredentialUnavailable`, `NoAccount`, `Persistence` -> 503; upstream
   `Unavailable`/`InvalidResponse` -> 502. A confirmed `Quota` may map to 429.
   Translate a provided relative retry delay to Retry-After only before output.
   Never log raw request/response plans, Context, OAuthData or callback exceptions.
   After `Started`, terminate the stream with a fixed diagnostic; do not replay
   or write a second JSON error response.

## Management credential CRUD

Use these runtime-owned hooks, **not** raw filesystem writes:

| Operation | Hook |
|---|---|
| Key identity | `auth/runtime.key(provider, auth_mode, account)` |
| Create/replace | `auth/runtime_store.save(store, key, material)` |
| Delete | `auth/runtime_store.delete(store, key)` |
| Safe inspection | `auth/runtime_store.metadata(store, key)` |
| Explicit legacy import | `auth/runtime_store.import_legacy_oauth(store, legacy_id, key, metadata)` |

Safe metadata contains only `kind` and optional expiry. The management owner
already knows configured provider/account IDs; enumerate those bindings and
inspect each independently. Missing/corrupt records must not expose private
content or break the legacy OAuth listing. Never return `load` or OAuthData.

Records live in a separate `runtime-*.json` namespace. A bare API key never enters
legacy `credential-*.json`. Refresh CAS and every supported admin save/delete
share a per-record atomic filesystem mutation guard. If an admin changes/deletes
the record during refresh, the stale refresh cannot overwrite/resurrect it or
return its rotated token. The next acquisition reads the authoritative file.
Revocation does not retract bytes already sent by an in-flight request.
Filesystem mutations run in an independent monitored worker. Cancelling or
stopping the requesting auth/admin process cannot strand the mutation lock:
the worker finishes the atomic operation and releases it. A cancelled/timed-out
write does not promise rollback; inspect the authoritative record before deciding
what to do next. A hard VM crash remains different and can leave a stale guard.

The stored private metadata is **identity metadata**, not a cache of mutable
provider discovery output. Omission preserves fields; changing a previously
present value is rejected. Codex uses `chatgpt_account_id`, distinct from the
internal account ID. Provider decoders still own JWT/identity validation.

## Shutdown, ownership and recovery

- The owner stops accepting new requests, cancels active response tasks, then
  calls `runtime.stop`. It stops credential workers and closes active execution
  processes before releasing the store guard.
- One runtime owns a local private store. `.provider-runtime-owner/nonce` is
  created under an atomic mkdir; another actor, path alias or BEAM VM fails
  startup. The guard only releases the nonce it owns.
- A hard VM crash can leave `.provider-runtime-owner` and/or per-record
  `.mutation-runtime-*.json` directories. Startup/mutation then fails closed.
  There is no PID guessing, automatic takeover or distributed locking.
- **Explicit recovery procedure:** stop all services/processes that can use that
  store; establish that no owner remains; inspect the private directory locally
  without printing credentials; retain the credential/ledger files; then have
  the operator explicitly remove only the confirmed stale guard directory and
  its nonce (or empty mutation guard). Restart exactly one owner. Do not use a
  wildcard delete or automate this recovery. Network filesystems and power-loss
  durability are not validated.

## Runnable evidence

From this checkout, with the already-installed toolchain:

```sh
mise exec gleam@1.18.1 -- gleam format --check
mise exec gleam@1.18.1 -- gleam test
mise exec gleam@1.18.1 -- gleam run -m provider_runtime_scenarios
```

At the v2 checkpoint, **203 tests passed** (179 base + 24 runtime).
The separate scenario command then passed 19 acceptance scenarios. It explicitly
reports `scope: runtime_library`, `assembled_ingress: false` and no live calls.
Negative TLS tests intentionally emit Unknown CA / hostname mismatch notices.

Evidence includes:

- Two real loopback TLS upstreams, synthetic credential isolation, 429 failover
  before returned headers, chunk delivery, truncated-stream no replay, socket
  EOF on cancel, certificate/hostname verification and Host/origin rejection.
- Concurrent request-path refresh singleflight, API-key/OAuth mismatch with
  zero adapter calls, coexistence with legacy listing, identity preservation,
  failed-persistence rejection, replacement/deletion-vs-refresh races.
- A persistence requester killed while its filesystem critical section is
  active cannot strand the record lock; a subsequent supported write succeeds.
- Cancellation/panic cleanup, caller death, synchronous owner adoption, old-owner
  revocation, cancel/adopt races, and rejection of closed/dead-owner adoption.
- A real second BEAM VM rejected by store ownership; two fresh BEAM VMs
  exercising and then restoring rotated tokens/private identity/cooldown without
  reseeding the restart phase. The restart scenario uses mock adapters.

No assembled client-facing ingress request is made by this new runtime suite.
It is **not** a CPA lab plan driver and cannot satisfy
`assembled_ingress: true`. HTTP token-exchange counting under concurrent actual
ingress requests, provider-specific compatibility, CPA differential execution
and live accounts remain separate integration/conformance gates.

## Supported boundaries and explicit gaps

Implemented: explicit provider/model/auth-mode/capability registration; static
API keys and expiring OAuth; fixed 60-second refresh lead; bounded per-credential
refresh backoff; atomic private persistence; multi-account selection; durable
credential cooldown; pre-output safe failover; direct HTTP/1.1 JSON/SSE pull and
buffered execution; verified HTTPS with optional operator CA; ownership,
cancellation and secret-safe typed errors.

Not implemented: assembled ingress/CLI/management wiring, provider login/device
protocols or codecs, WebSocket/HTTP2/proxies/bound-address transport, automatic
discovery, configurable provider refresh lead (xAI CPA uses 5 minutes), proactive
background refresh, retry-on-401 refresh, CPA model-level cooldown policy,
automatic stale-guard recovery or live-provider validation. The transport
currently bounds bodies/streams to 8 MiB and individual reads to 5 seconds;
compressed bodies, trailers and close-delimited response bodies fail explicitly.
Register only capabilities that the selected adapter actually implements.
