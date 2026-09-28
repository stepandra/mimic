# HTTP provider integration evidence

## Provenance and scope

Assembled starting revision:
`f809b8c8a51939383792e6e88d5eb4f98b7ddcc2` from
`https://github.com/stepandra/mimic.git` `main@origin`.
The starting isolated checkout was clean but stale (`c3ca7e80`); it was
advanced with `jj git fetch` and `jj new` on the verified published revision.
No primary checkout was edited and no commit/push was performed.

CPA source pin remains `acdace936fa7df2905500c7f5e0a97d683138dea`.
Native Kimi auth, executor, helper and registration sources are cited in
`kimi/native.md`; this does not infer support from generic OpenAI compatibility.
The WebSocket owner handoff is frozen V2 (14 explicitly hashed files).
The pinned Mist 6.0.3 parser fix and upstream archive verification are documented
separately in `MIST_VENDOR.md`.

All credentials, identities, grants, events and servers in the checks below are
synthetic. No live provider call, account authorization, native-client login,
TLS fingerprint, performance parity or CPA differential success is claimed.

## HTTP checkpoints actually run

- The unmodified published base passed the complete
  `mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh`: 463 Gleam tests,
  seven Python tests, all existing scenarios and source/shipment CLI smoke.
  An earlier test-only invocation hit its 120-second tool deadline; it was
  incomplete, not a test failure.
- The first HTTP assembly checkpoint passed 483 Gleam tests, no failures.
  This count precedes the WS/vendor import and is not the combined final count.
- `scripts/smoke-http-providers.py` passed through actual CLI processes and
  Mist routes. It exercises Claude API/OAuth boundaries and both Kimi domain
  configurations against numeric loopback endpoints, never the public domains.
- Ten Python conformance-driver regressions passed. A direct native Kimi
  driver invocation exercised actual gateway workflows and intentionally
  returned `failed`: ordered-header fidelity is not established by this
  observation driver. This is a missing measurement/check, not a waiver or a
  claim that header-order compatibility has been implemented.

## Regressions covered

Claude:

- Native Messages SSE for API key and OAuth, selected-account Host/auth/private
  account/device identity, fresh request IDs and credential-scoped session IDs.
- Every byte split of UTF-8/native event fixtures; BOM, CRLF, standalone CR,
  incomplete UTF-8, malformed JSON, terminal errors and disconnects. Valid
  frames preceding a malformed frame are delivered regardless of segmentation.
- Explicit 1 MiB SSE frame and 8 MiB buffered JSON budgets. OAuth retains its
  separate 64 KiB / 4096-value / 32-depth guard. Tests cover exact byte bounds
  and valid inference payloads larger than 64 KiB.
- Comment-heavy events use incremental native byte accounting, not a scan of
  every previously buffered line. No end-to-end performance claim is made.
- Synchronous Mist chunk initialization adopts the runtime stream; terminal,
  malformed/disconnected upstream and downstream close do not replay.
- Actual token HTTP singleflight, rotation persistence and fresh-process
  restart; ambiguous duplicate JSON (including 429), disconnect and uncertain
  outcomes preserve the durable recovery fence. Admin replacement defeats
  an in-flight refresh CAS.
- Configured PKCE login reuses the existing callback listener and writes only
  the authoritative runtime store. Invalid path/state/duplicate callback
  fields cause zero token exchanges; callback timeout closes the listener;
  persistence failure cannot produce login success.

Kimi:

- First-class `kimi` API-key and OAuth modes, native model alias registration,
  selected-account origin and explicit base path. API keys and access tokens
  both use native Bearer auth; private OAuth device identity supplies
  `X-Msh-Device-Id`.
- Buffered native Chat and Responses; shared-codec Responses SSE and valid
  prefix before malformed/incomplete terminal, downstream cancellation.
- Configured device start/poll/authorize to runtime persistence, refresh
  singleflight/persistence/restart, ambiguous refresh fences and admin
  deletion defeating stale refresh CAS.
- Unsupported request features and wrong protocol/model routes fail before
  upstream I/O. Provider 401/429 are sanitized, and client-key revocation
  denies the next request without upstream effects.

## Remaining limitations

Kimi tools/media/thinking/temperature transformations, Chat SSE, compact,
continuation and Anthropic delegation are deliberately unsupported. Claude
model-specific CPA request normalization/cloaking is not established.
Generic Kimi compatibility is separate and is not implemented by this slice.
OAuth endpoints and private identity/expiry must be explicitly supplied; no
identity, expiry, profile or fingerprint is fabricated.

The 37-row strict CPA conformance gate remains incomplete and missing cases
must remain red. No CPA executable driver or live evidence was added.
Gemini, Antigravity and Copilot remain excluded; Devin scope is unchanged.
Runtime storage is permission-protected, not encrypted, and restart tests do
not establish power-loss durability.

## Final combined gate

The exact reproducible command is:

```sh
mise exec gleam@1.18.1 -- sh scripts/verify-integration.sh
```

The complete second invocation exited **0** on Gleam 1.18.1 / OTP 29 / macOS:

| Combined check | Observed result |
|---|---|
| Formatting of application/test source | Passed |
| Full assembled Gleam suite | **522 passed, no failures** |
| Python conformance-driver regressions | **10 passed** |
| Existing runtime/provider/Responses/Devin scenarios | Passed |
| Strengthened raw WS `--strict` | Normal 101; ambiguous/version-denied requests closed before upgrade |
| Actual root HTTP CLI workflow | Passed |
| Actual root WS CLI workflow | Passed; opt-in, selected account, coalesced create, revocation |
| Separate-VM Claude runtime fence restoration | Passed |
| Erlang shipment export | Passed |
| HTTP and WS shipment smoke from another working directory | Passed |

The complete output is retained locally at
`build/http-provider-combined-gate-attempt2.log`, SHA-256
`d47d8638b30a536d49a952a4c8bce305615087b09830911d472236e808f6bcfd`.
Expected negative TLS, malformed HTTP and corrupt-stream tests print fixed
failure diagnostics; dependency deprecation warnings remain.

The first combined invocation remains a **failed** result, 520 passed / 1
failed. Its WS negative helper expected an HTTP reply after deliberately
duplicating the version header; the patched parser correctly closed first.
The approved test-only integration delta now distinguishes confirmed peer
close from timeout, connect/send errors, reset and partial headers. It tests
unsupported single version 12 separately from both duplicate orders, checks
zero upstream effects/leases, and requires 101 plus exact Accept on positives.
All 11 targeted gateway WS tests and the strengthened `--strict` passed before
the full rerun. Attempt-1 log SHA-256:
`8f78ffffa74be6837788f059cd0c2e2a085538e8ec45e183cd5ff97660a250ec`.

Frozen WS V2 production hashes remain unchanged (8/8). The original 14-file
manifest remains provenance, not a claim that its test file is still identical
after the approved integration delta. The two runtime-guardian test additions
were hash-verified and passed here; they are a **recipient-tested candidate**,
not a new owner-verified V3 release. The owner's separate historical 485-pass
gate and later 420-pass/74-failure ENOSPC run must not be conflated with these
results. Before this fresh gate, this worktree had 8.06 GB available and a
1 MiB write+fsync probe passed; no sibling/global cleanup was performed.

Strict CPA release was rerun separately and exited **1**, **0/37 required
capability rows passed**, live evidence `not_run`. Its baseline driver remains
the older laboratory driver; it does not acquire new provider coverage merely
because this assembled workflow gate passes. The native Kimi evidence driver
also intentionally keeps its missing ordered-header check red.
