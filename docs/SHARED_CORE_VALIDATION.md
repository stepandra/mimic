# Shared-core parity wave — final snapshot 4 evidence

## Outcome

The exact source/API snapshot 4 passed the full local integration gate:
**549 Gleam tests, 10 Python tests, all library/integration scenarios, and
source plus Erlang-shipment smoke tests; exit 0**.

This is shared-core readiness, not assembled new-provider parity. The gateway
has not been changed here to consume these new hooks. No CPA differential,
live-provider, production HTTP-version or TLS-fingerprint proof is claimed.

## Provenance and reproducibility

- Verified published base:
  `3e00808ff0fefbb6728edb1769c17139ef0fd93a`, fetched with `jj` from
  `https://github.com/stepandra/mimic.git` and checked against published `main`.
- CPA reference pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
- Local tools: Gleam 1.18.1, OTP 29 / ERTS 17.0.4.
  Existing CI configuration uses OTP 28; no new CI run was performed here.
- Command:

  ```sh
  ERL_FLAGS="+S 2:2 +A 2" mise exec gleam@1.18.1 -- \
    sh scripts/verify-integration.sh
  ```

- Gate log: `build/shared-core/snapshot-4-gate.log`, SHA256
  `2a96a5d22d10a7d022db35751843a2d127b12c20828330132b8d7effd919af7d`.
- Immutable source-only archive: `build/shared-core/snapshot-4/source.tar.gz`,
  SHA256 `f318501aaaa1cbf5a8c477097b871387b6a85f30a9692c2f9cdda1dc524bb5bc`.
- Archive `SHA256SUMS` hash:
  `60bad0938ecf160fc199f9c707821a6552dd72aa8b5cda9e13900ad0af7ba384`.
  Its 17 entries are preserved in
  `source-manifests/shared-core-wave-s4.sha256`; all matched after the gate.
- Previous snapshots 1–3 were not overwritten. The source snapshot includes
  code/tests/API documentation only, not Git/jj metadata, credentials, runtime
  state, build output or dependency copies. This final evidence file and the
  durable manifest were added afterward without changing tested source.

## Exact delta and compatibility

The manifest identifies 10 source files, six test files and one API document.
See `SHARED_CORE_PARITY_WAVE.md` for signatures and integration order.

- Shared JSON parsing rejects duplicate decoded keys and adds bounded parsing.
- Existing Responses SSE framing was extracted for reuse by native Chat.
- Native Chat supports bounded byte input, restoration before validation,
  native extension/media/reasoning retention and valid-prefix-before-error.
- Responses `run_fold` returns caller accumulation only after validated terminal
  plus transport EOF; legacy `run` still stops at the protocol terminal.
- Runtime gains explicit per-account protocol/operation endpoint bindings,
  versioned credential acquisition and `open_scoped`.
- WS reuse now checks exact credential revision, including same-token admin save.
- Generic continuation cache separates tenant/provider/auth/account/generation/
  model/origin/client/protocol/operation, with TTL/count/byte admission.
  `locate` enables trusted account preselection from that same cache; it never
  substitutes for current-generation `open_scoped` plus `get`.

Existing baseline `Account`, `Context`, `Adapter`, `SessionAdapter`, `open`,
`start` and `run` constructors/signatures are unchanged. New-wave Chat consumers
must handle the additive `NamedErrorEvent` variant if matching exhaustively.
Invalid/ambiguous JSON now fails closed instead of selecting a duplicate winner.
Scopes and receipts are private; no credential-derived lookup digest is needed.

## Review and regression evidence

An independent read-only reviewer found two P2 issues in snapshot 3:

1. Named native Chat error events lost SSE dispatch semantics.
2. Native error text incorrectly inherited the 1024-byte identity limit.

Both were fixed and regression-tested before snapshot 4. The reviewer inspected
the fixes and found no other confirmed defects in the reviewed core. The
integration-requested `locate` addition came afterward and has direct tests;
it is not represented as independently reviewed.

The final gate includes:

- All-byte-split and one-byte UTF-8 Chat/Responses framing, fragments, size bounds,
  malformed suffix after a valid prefix, terminal/incomplete/error distinctions.
- Native extensions, tool identity/argument fragments and error encoding.
- Real bounded loopback TLS showing two operation origins share concurrency and
  cooldown under one account, without forwarding to an unapproved route.
- Real TLS terminal followed by invalid HTTP chunk framing: no fold accumulator
  escapes, socket closes and runtime leases reach zero.
- Existing binary HTTP/TLS, WS/WSS, masking/fragmentation/cancellation/ownership
  transfer, refresh CAS, clock/fence and admin mutation regressions.
- Cache scope isolation, duplicate/count/actual-byte admission, TTL boundaries,
  clock rollback/overflow/failure, atomic concurrent admission, empty restart,
  lookup ambiguity and current runtime generation after same-token admin save.

The baseline was separately reproduced at 522 Gleam +10 Python with full script
exit 0. Snapshot 3 passed at 543 +10; final snapshot 4 adds six more tests, for
549. No failures were suppressed. Dependency deprecation warnings and expected
synthetic rejection/TLS diagnostics remain in logs.

## Remaining blockers and ownership

- Integration owns gateway registration, explicit stable authenticated sessions,
  cache instance lifecycle, cancellation publication fences and sender adoption.
  Restart loses receipts; recovery requires trusted full history or a fresh
  request, never a stale-receipt fallback.
- Claude owns native Messages restoration. No Claude/provider namespace was
  modified or competing Messages parser introduced here.
- Native-lite sparse Responses terminal policy remains strict until a separately
  agreed typed policy; no silent terminal hydration.
- Broad cross-dialect reasoning/media/custom-tool/usage projections and Devin
  client-event encoding remain explicitly limited.
- Binary transport remains loopback-qualified H1. Remote experimental HTTPS/H2
  and production qualification were not enabled.

No commits, pushes, automatic merges, dependency changes, primary/sibling
checkout edits, provider calls, accounts or user-environment credentials were used.
