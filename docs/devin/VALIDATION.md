# Devin validation ledger

> Historical v1 evidence. Current executed evidence and blocked gates are in
> [EXPANSION.md](EXPANSION.md). `verify.py` now tests the actual checkout at the
> published base ancestry and no longer creates source-copy overlays.

This file records executed evidence, not intended coverage.

## Pure protocol gate

Command: `python3 docs/devin/verify.py --pure`

Result: **194 passed, no failures** (179 pinned baseline + 15 Devin tests).
The overlay excludes `bridge.gleam`, `devin_runtime_test.gleam` and
`devin_scenarios.gleam`; it does not imply runtime integration passed.
Formatting also passed in that overlay.

Executed overlay:
`build/devin-integration-jcxtkqt7`.

An earlier run reported 193 passed/1 failure because the verification script
omitted a baseline `examples/g_report_facts.json` fixture. The script now copies
only baseline-tracked example files; the corrected fresh overlay passed all 194.
No baseline application/test source was changed to hide that failure.

Independent read-only review identified three correctness issues, all fixed
and regression-tested:

- Protobuf field ordering cannot change stop semantics; stop cannot reopen.
- Partial usage messages preserve prior counters; duplicate output fields use
  last-value assignment, while duplicate input fields accumulate.
- SWE-1.7 uses the pinned model-specific 64000 cap instead of the generic 128000
  wire-helper fallback.

The reviewer subsequently confirmed these fixes by source inspection, not an
independent execution.

## Runtime adapter gate — passed locally

Verified immutable runtime v3 snapshot:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/qhtjz5hs63hm/mimic/build/provider-runtime-contract-v3/
SHA256(SHA256SUMS) = 33f373d1f498b7f1f81a4043aa3f530451c01d56fe1c7d1b3fdc66535026e3a1
```

All 12 published source hashes were checked before copying into the ignored
overlay. The verifier now pins the manifest digest as well as the allowlist.
No runtime-owner tests or foreign-owned sources are tracked in this change.

Command:

```sh
python3 docs/devin/verify.py --runtime \
  /Users/jerryjohnson/dev/mimic/.delta/worktrees/qhtjz5hs63hm/mimic/build/provider-runtime-contract-v3
```

Executed overlay: `build/devin-integration-y09l0m2d`.

- `gleam format --check`: passed.
- `gleam test`: **200 passed, no failures**: 179 baseline + 15 Devin pure +
  6 Devin runtime tests, compiled against the actual runtime v3 sources.
- `gleam run -m devin_scenarios`: **6 scenarios passed**.

The six scenarios exercise real loopback sockets: buffered Chat/Messages,
literal authentication and token-bearing protobuf metadata, absence of
User-Agent/Accept-Encoding, zero-I/O feature/material rejection, remote-origin
rejection, HTTP 429 failover, no replay on quota trailer failure, and runtime
adopt/pull/cancel with old-owner revocation and zero terminal leases.

The first combined compile found an adapter-local `result.then` typo, fixed to
`result.try` before the passing run. No runtime dependency was patched.

The executable's result explicitly states:

```json
{"scope":"devin_runtime_adapter","scenarios_passed":6,"assembled_ingress":false,"cpa_differential":false,"live_verified":false}
```

This does not establish client SSE, Mist chunk-init adoption, assembled ingress,
CPA differential execution, fresh-process provider restart or live behavior.
Runtime-owner evidence is separate; its larger test totals are not added here.

## Owner-only immutable export

Read-only export path:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/fmgzrj7d0m1k/mimic/build/devin-provider-v1/
```

It contains exactly this stream's source, namespaced tests and `docs/devin`
files plus `SHA256SUMS`. Files are mode 0444 and directories 0555.
No runtime sources, baseline files, CPA source, compiled caches, credential
records or mock server state are included. Verify from the export directory:

```sh
shasum -a 256 -c SHA256SUMS
```

This is an experimental slice handoff, not automatic merge authorization or a
claim that the 15 required Devin conformance rows have passed.
