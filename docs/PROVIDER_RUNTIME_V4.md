# Provider runtime v4: generation-bound refresh recovery

Base: `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
Frozen runtime v2/v3 source snapshots are unchanged.

This extension adds persisted refresh gates, completion-clock Retry-After and
exact-generation CAS. **It changes refresh error semantics despite preserving
the callback signature.** Existing provider bridges must audit their mappings
and rerun integration tests against the final v4 snapshot.

## Refresh outcome migration

`Refresh(fn(OAuthData, Int) -> Result(OAuthData, RefreshFailure))` is unchanged.
The integer passed to the callback comes from the runtime clock.

| Outcome | v4 meaning and transition |
|---|---|
| `Ok(valid OAuthData)` | Atomically persist tokens, preserved identity metadata and `Ready` before returning material |
| `RefreshRateLimited(ms)` — new | Recognized provider rejection, not an error-looking success body; persist `Deferred` |
| `RefreshRetryable` — new | Adapter proves no send or rejection without grant execution; bounded transient backoff to `Deferred` |
| `RefreshUnavailable` | **Unknown outcome:** retain recovery fence; no automatic repeat |
| `InvalidGrant` | Retain recovery fence; explicit replacement/relogin required |
| `RefreshUnsupported` | Retain recovery fence; configuration/credential intervention required, not endless attempts |
| Callback exception or invalid `Ok` result | Outcome may conceal rotation; retain recovery fence |
| Changed private identity | Security stop; retain recovery fence |

A generic transport error, timeout after send, arbitrary HTTP 5xx, or malformed
successful token response is **not proof of safe retry**. Old bridges mapping
these to `RefreshUnavailable` now conservatively require recovery. Do not change
that mapping to `RefreshRetryable` merely to recover old availability.

Claude's richer provider outcomes map as follows:

- Recognized HTTP 429 `RateLimited(ms)` -> `RefreshRateLimited(ms)`.
- `InvalidGrant` / `IdentityChanged` -> `InvalidGrant`.
- Generic `Unavailable` / `InvalidResponse` -> `RefreshUnavailable`.
- `InvalidCallback` remains login validation, not a fabricated refresh outcome.
- Only a transport/adapter with affirmative safe-delivery evidence may return
  `RefreshRetryable`. A status number by itself is insufficient.

Codex and xAI owners have also been notified of this migration. Their prior
v2/v3 tests are historical evidence, not v4 integration approval.

## One private record, one atomic transition

New runtime records use **schema version 2**, containing:

- The existing bounded material/private metadata fields.
- A fresh random `generation` nonce on every write.
- `refresh_gate`: `ready`, `deferred` with absolute `until_ms`, or
  `needs_reauthorization`.

Schema-1 records still read as `Ready`; reads do not rewrite them. An explicit
`save`/relogin always writes a new generation with `Ready`, even when all token
bytes are identical. Status, metadata and material reads do not clear a gate.
Unknown versions, malformed generations/gates and gates on static material
fail closed.

OAuth refresh follows:

1. Read an opaque generation snapshot.
2. CAS-arm `NeedsReauthorization` **before** invoking the external callback.
   Failure to arm means zero callback/network activity.
3. Invoke the provider once under the existing singleflight worker.
4. CAS the result against the armed generation:
   - verified success -> new material + `Ready`;
   - proven safe rejection -> unchanged material + `Deferred`;
   - unknown/terminal result -> retain recovery fence.
5. Only committed success returns new material.

Admin replacement, deletion, and same-token saves defeat stale completion CAS.
There is no sidecar status writer or second refresh manager.

### Meaning of the recovery fence

`NeedsReauthorization` is **not a claim that the provider revoked a token**.
It can be observed during an active refresh or after interruption, unknown
delivery, unsupported refresh, clock failure or failed completion persistence.
It means the runtime cannot safely repeat or use that grant automatically.
An interrupted callback may have rotated the upstream token.

This intentionally trades availability for avoiding duplicate/unknown grant
execution. Explicit operator replacement/relogin is the recovery action.
On completion-write failure, the pre-effect fence remains across restart and
the worker also refuses further use of the same generation in memory.

## Clock and delay rules

The runtime owns both epoch and monotonic clocks. The compatibility
`credentials.get(worker, now_hint)` no longer trusts its hint; use
`credentials.acquire(worker)`. Deterministic tests may supply
`start_with_clock(store, key, policy, fn() -> #(epoch_ms, monotonic_ms))`.
Never expose this clock injection to an incoming request.

The clock is sampled after the callback. A conservative completion epoch is:

```text
max(completion_epoch, start_epoch + elapsed_monotonic_ms)
```

This retains elapsed callback time if the wall clock rolls back. Both expiry
acceptance and persisted deferral use this bound. Example: start `(100000, 0)`,
completion `(99000, 10000)`, Retry-After `5000` -> `Deferred(115000)`.
Restart with corrected epoch `110000` must still wait five seconds; it cannot
lose the old VM's elapsed interval.

Within a VM, both epoch and monotonic deadlines must permit retry. A positive
provider minimum is never shortened by an upper clamp; the existing 5-second
to 5-minute transient backoff may lengthen a smaller value. Zero uses that
bounded fallback. Negative delay, invalid clock, monotonic rollback and checked
timestamp/deadline overflow retain the recovery fence. Supported persisted
timestamps are nonnegative signed-64-bit integer milliseconds.

Static API keys and permanent session tokens do not invoke this clock or refresh
path and never acquire OAuth refresh gates.

## Additive status and generation APIs

`auth/runtime_store` exposes:

```gleam
pub type RefreshStatus {
  Ready
  Deferred(until_ms: Int)
  NeedsReauthorization
}

refresh_status(Store, key) -> Result(RefreshStatus, String)
load_record(Store, key) -> Result(CredentialRecord, String)
record_material(CredentialRecord) -> AuthMaterial
record_status(CredentialRecord) -> RefreshStatus
revision(CredentialRecord) -> Revision
transition(Store, key, CredentialRecord, AuthMaterial, RefreshStatus)
  -> Result(CredentialRecord, String)
```

`CredentialRecord` and `Revision` are opaque. The record contains secrets and
must never be logged or returned by management. Only `refresh_status` and the
existing secret-free `metadata` hook belong in status responses.

Runtime refresh retains a snapshot across the callback and uses `transition`.
Async provider enrichment must likewise retain the snapshot, preserve its gate,
and CAS that exact generation. The compatibility `save_if_unchanged` remains a
**material-value CAS**, preserves gates and is not suitable for guarding an
asynchronous completion against same-value admin replacement.

Public failures add `ReauthorizationRequired/NotSent`. An unpinned request may
try a different untried account; a pinned continuation cannot migrate. Failure
aggregation must never replace a later `Uncertain`/`Started` or terminal failure
with an earlier retry-safe one. Safe availability errors retain Retry-After
information rather than turning into an undifferentiated `NoAccount`.

## Persistence scope and deployment compatibility

The guarantee is for supported local-filesystem **process/VM restart** behavior.
The inherited writer syncs file contents and atomically renames, but directory
fsync is not implemented. **Power-loss and host/filesystem-crash durability are
not established.** No such experiment or stronger guarantee is claimed.

New schema-2 records are deliberately **forward-incompatible with v2/v3
runtime readers**. An isolated-VM check using the saved, compiled frozen-v3
reader rejected a v4-written schema-2 record with `Invalid runtime credential`.

Upgrade with one stopped/started owner per private store. Reads alone do not
migrate old records; saves and refresh transitions do. Do not run mixed owners.
Before deploying, the operator should plan a private, permission-preserving
backup/recovery procedure. No operator data was migrated by this development
work.

Do not strip version/generation/gate fields to force a downgrade: doing so
would bypass the recovery fence. A downgrade requires an explicit credential
recovery/relogin plan into a compatible private store, not automatic reuse of
possibly rotated credentials. Existing stale filesystem-guard recovery rules
from `PROVIDER_RUNTIME_INTEGRATION.md` still apply.

## Validation and handoff

Final validation:

- `mise exec gleam@1.18.1 -- gleam format`
- `mise exec gleam@1.18.1 -- gleam test`: **236 passed** (220 prior + 16 v4).
- `mise exec gleam@1.18.1 -- gleam run -m provider_runtime_scenarios`:
  **52 scenarios passed**, explicitly `assembled_ingress: false`.
- `git diff --check`: clean.

The v4 tests cover a real synthetic loopback JSON-429 exchange under concurrent
acquisition; completion epoch and monotonic boundaries; rollback/restart;
same-token replacement and deletion races; callback interruption after durable
arm; failed arm/completion persistence; safe-retry versus unknown outcomes;
negative/zero/large delays and overflow; read/status behavior; static material;
failure aggregation and pinned/unpinned account behavior. A two-OS-process test
also restores both a latch and a deferred deadline without reseeding or invoking
either callback in the second process.

Independent review identified an unsafe delivery downgrade in error aggregation
and loss of elapsed callback time under wall-clock rollback. Both were corrected
before this snapshot and covered by regressions. Directory-fsync limitations are
explicitly retained above. The synthetic JSON fixture is not Claude's actual
provider parser; that provider integration is a separate consumer gate.

No assembled-ingress, real-provider, CPA differential or power-loss evidence is
inferred. No root files, ingress routing, dependencies or shared wire types were
changed for v4.

## Immutable v4 source snapshot

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/qhtjz5hs63hm/mimic/build/provider-runtime-contract-v4/
```

The snapshot contains exactly 12 source files plus `SHA256SUMS`, no runtime
state or credentials. SHA-256 of the exact manifest:

`b6730e91c13503ce469c7b4e8721791b08135eb2ac28e298ffe874eeba3d3784`.

Compared with v3, four files changed: auth runtime/store, shared runtime contracts,
and provider runtime orchestration. No production FFI changes were needed.
Approved consumers may copy these sources only into ignored integration overlays;
they must verify the manifest and retest their refresh mappings before integration.
Frozen v2/v3 snapshots are unchanged.

| File | SHA-256 |
|---|---|
| `src/mimic/auth/runtime.gleam` | `a96ca5f2d34db0bc1773cb1b38cc93bcf2f6bfdb39ad1f1911af14f41ee5878d` |
| `src/mimic/auth/runtime_store.gleam` | `db6196d1fd3db9a3df6fcbe379237e9db1d0cad2bcec7acb1e0090d51bba3f21` |
| `src/mimic/auth/storage.gleam` | `94dc663a9ad2f201695488b338a6f1679dc65bbee19666033fd3afc854fd8cc0` |
| `src/mimic/egress.gleam` | `835fd7ddbdf3cdd00166fd9487b81030169efd7f7c7f5e3a0cb2ab8874d99dbd` |
| `src/mimic/fleet.gleam` | `412a4212357c56520d7bc04c16de896396de180be0fa96a97a4c08e04bb1d19a` |
| `src/mimic/providers/contracts.gleam` | `eea1edf1badb8f113d5c19340d7bcb7d0350d63797b8a06dc31d8b106bf7ded9` |
| `src/mimic/providers/registry.gleam` | `7df2b417147c3a5ed9d7e5d38e00bfd3f6e93607c2af0361afc13b0d9edb6e9c` |
| `src/mimic/providers/runtime.gleam` | `f11c2e1641b19201b24f162908387c802a50b0b6db88cf25decb0ccdc7361e84` |
| `src/mimic/providers/transport.gleam` | `138b07ba2d05264024bca270070c668eb993cc49a5e5096948874c61c4f2a0f4` |
| `src/mimic/quota.gleam` | `ca1006e8eafc65558edc1b0d94395b5b968a61f46e7e90dec7de5262de297fb1` |
| `src/mimic_egress_ffi.erl` | `d62ad00cdf89f3e4a138eb6b0ed455534fa2dd011b3cab71d1dbb97280fdb7fc` |
| `src/mimic_provider_runtime_ffi.erl` | `3411b07ad4116b7767225317a3c0c36c5966e9f979247089c71fac8193f6df1d` |
