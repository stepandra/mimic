# Provider runtime contract v1

For the additive permanent-session and explicitly gated binary transport API,
see `PROVIDER_RUNTIME_V3.md`. The v1/v2 source snapshots below remain historical
and unchanged.
For current persisted refresh gates and the semantic error-mapping migration,
see `PROVIDER_RUNTIME_V4.md`; frozen v3 is also unchanged.

Base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
CPA reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.
This is a runtime contract, not a claim of full CPA/provider compatibility.

## Authoritative definitions

`src/mimic/providers/contracts.gleam` owns neutral types:

```gleam
AuthMaterial = ApiKey(String) | OAuth(OAuthData)
OAuthData(credential: auth.Credential,
          private_metadata: List(#(String, String)))
Refresh(fn(OAuthData, Int) -> Result(OAuthData, RefreshFailure))
RefreshFailure = InvalidGrant | RefreshUnavailable | RefreshUnsupported

Context(provider, auth_mode, account, origin, session_key, credential)
Request(provider, auth_mode, model, protocol, operation, mode,
        required, session, pinned_account, body)
Opened(status: Int, headers: List(types.Header), handle: handle)

Adapter(
  open: fn(Context, Request) -> Result(Opened(handle), Failure),
  next: fn(handle) -> Result(Option(#(BitArray, handle)), Failure),
  cancel: fn(handle) -> Nil,
  rejection: fn(Int, List(Header)) -> Option(Failure),
)
Failure(reason: Reason, delivery: Delivery, retry_after_ms: Option(Int))
```

The above shorthand is explanatory; import the actual Gleam file, not a local
copy of these type definitions. `Context.account` is the configured **internal**
account ID. For Codex, `chatgpt_account_id` is private OAuth metadata, never that
internal ID. Private fields are bounded, unique-key strings, atomically saved
with token rotation. Omitted fields are preserved. Provider refresh decoders
must reject a changed provider identity.

`Request.auth_mode` is a selector, not proof of credential kind. The registered
account policy `StaticKey` / `Refreshable(Refresh)` validates loaded material
before invoking the adapter. Static keys have no expiry or dummy refresh token.
Providers decide the authentication header; runtime never guesses Bearer.

`registry.Model(provider, id, auth_modes, protocols, operations, capabilities)`
is explicit configuration. Register `responses`, `responses/compact`, etc. as
distinct operation names. Streaming HTTP is **not** WebSocket capability.

## Runtime entry points

- `runtime.start(Store, Registry, List(Account)) -> Result(Runtime, Failure)`
- `runtime.open(Runtime, Adapter(h), Request) -> Result(Response, Failure)`
- `runtime.next(Stream) -> Result(Option(BitArray), Failure)`
- `runtime.cancel(Stream) -> Nil` (idempotent)
- `runtime.adopt(Stream) -> Result(Nil, Failure)` (additive v2 process handoff)
- `runtime.execute(Runtime, Adapter(h), Request) -> Result(BufferedResponse, Failure)`
- `runtime.stop(Runtime) -> Result(Nil, Failure)`
- `runtime.active_leases(Runtime) -> Result(Int, Failure)` (secret-free)
- `transport.http(prepare, rejection, ca_file) -> Adapter(egress.Stream)`

The HTTP prepare hook is
`fn(Context, Request) -> Result(types.Capture, Failure)`.
The returned capture is an **in-memory request plan**, not a record to persist.
The standard transport requires `capture.endpoint == context.origin`.
`ca_file: Option(String)` is explicit operator trust, not a TLS-disable option.

Account fields: `provider`, `auth_mode`, `id`, `origin`, `egress`, `max_in_flight`,
`models`, `auth_policy`. HTTPS must explicitly use `fleet.OperatorHttps`.

## Safety and lifecycle

- `NotSent`: no request bytes sent; `Rejected`: provider guarantees no execution;
  `Uncertain`: delivery may have occurred; `Started`: headers/body returned.
- Only `Quota`, `Unavailable`, `CredentialUnavailable` with `NotSent` or
  `Rejected` may fail over to an untried account. Never retry `Uncertain` or
  `Started`, even for operations that might happen to be idempotent.
- Returning headers commits a stream; there is no invisible bootstrap body
  buffering. This is deliberately more conservative than CPA stream bootstrap.
- A continuation must pin its originating account. Do not reuse provider-side
  session state across failover. The runtime session key includes credential
  identity.
- Handles/sockets belong to the execution process. Custom adapters are trusted
  code and must respect the endpoint and process-ownership contract. The
  standard transport enforces endpoint equality and does no redirect following.
- `cancel` callbacks must be idempotent. Exceptions are caught without exposing
  reason/stack/arguments. Process death closes sockets and coordinator monitors
  release leases even if a callback fails.
- One owner per private store, enforced by an atomic local-filesystem guard.
  Hard VM crashes leave the guard closed; operator recovery is explicit.

## Credential storage and management integration

`credentials.key(provider, auth_mode, account)` is a collision-free scoped key.
`runtime_store.save(Store, key, AuthMaterial)` writes a versioned
`runtime-<base64-key>.json` record using existing private atomic-write primitives.
Legacy `credential-*.json` OAuth records and their metadata listing are unchanged.
`runtime_store.import_legacy_oauth` is an explicit migration, not fallback.
Never expose `runtime_store.load` or `OAuthData` from management endpoints.
New management listing/create/delete hooks require coordinator integration;
existing management does not list the new namespace.

Final-source additions are described in `PROVIDER_RUNTIME_INTEGRATION.md`:
owner adoption/revocation, safe metadata/delete hooks, atomic refresh CAS against
admin mutation, Host authority binding and immutable private identity fields.
The immutable first snapshot below predates those additions.

## First compiled dependency snapshot

This immutable, generated source-only snapshot is for approved peer **ignored
integration overlays**, not for adding foreign ownership files to their deltas:

`build/provider-runtime-contract-v1/` in the Provider runtime worktree.

It was captured after `gleam format` and a full **188-test passing** run.
It includes no runtime state, credentials, fixtures, build dependencies, root
files, or provider-specific code. SHA-256:

| File | SHA-256 |
|---|---|
| `src/mimic/providers/contracts.gleam` | `2e0200739a103bef7915d532594035a497d6eb8efd851c7d96212553a7940b9d` |
| `src/mimic/providers/registry.gleam` | `7df2b417147c3a5ed9d7e5d38e00bfd3f6e93607c2af0361afc13b0d9edb6e9c` |
| `src/mimic/providers/runtime.gleam` | `3e479e4c4f3ae6edc8df932e8ee13dd9c77e548dbaa59cc36a3c62bf7214dd72` |
| `src/mimic/providers/transport.gleam` | `d2f38f38ea4c7157312423164038ff3cc8518a5c3f562f23f482028d5d48a6dc` |
| `src/mimic/auth/runtime.gleam` | `6ce21e06bf4de1b68b511996f2fd8cc66f02632297e24c0f1a6baaaa2767a6b6` |
| `src/mimic/auth/runtime_store.gleam` | `dd69b2ad72efbec635f681552475fe342e9fce639b6d58377ff9d600b21e1e5b` |
| `src/mimic/auth/storage.gleam` | `cb3c4281128a47efd32216226ec75027afa44184a1bdaeabcea63b4c96103729` |
| `src/mimic/egress.gleam` | `85a891cfef2ca4c1b890f484f8a375f1213ad5a7507f1fd1f6f9fba6f7d5c8bc` |
| `src/mimic/fleet.gleam` | `412a4212357c56520d7bc04c16de896396de180be0fa96a97a4c08e04bb1d19a` |
| `src/mimic/quota.gleam` | `ca1006e8eafc65558edc1b0d94395b5b968a61f46e7e90dec7de5262de297fb1` |
| `src/mimic_egress_ffi.erl` | `d62ad00cdf89f3e4a138eb6b0ed455534fa2dd011b3cab71d1dbb97280fdb7fc` |
| `src/mimic_provider_runtime_ffi.erl` | `46aa23b5e0fb21f0342ab05ffe03db75b939a28ac997aadb10c8127ee2c72003` |

Further implementation hardening is separate from this immutable snapshot.
The final integration must use the final reviewed source, not blindly the first
snapshot. Current gaps: ingress/CLI/management wiring, WS/HTTP2, provider-specific
adapters and live-account evidence are not implemented by this runtime stream.
