# Final parity umbrella 5: Devin F22–F29

## Scope and admission

This is the umbrella's working integration ledger, not a parity certificate.
The user-provided F22–F29 definitions are authoritative; an unpublished draft
`FINAL_PARITY_WAVE.md` is not an implementation dependency.

The initially attached checkout was clean at `c3ca7e80`. On 2026-10-01,
`jj git fetch --remote origin` and a read-only GitHub ref query verified
`https://github.com/stepandra/mimic.git` main at
`ca86b531cea7e1a509ac8e6038604fe91819ac07`. A new empty JJ change was created
on that exact base. No primary or sibling checkout was edited.

The base's recorded 698 Gleam and 92 Python tests, synthetic full gate, and
separate CI evidence are historical inputs. They have not been rerun by this
umbrella and do not qualify new work.

Only one implementation child is active at a time, with exactly one slice per
child. Each slice must deliver a compiling contract, owned-path hashes,
focused evidence including failed attempts, and a frozen local JJ handoff.
Root gateway/config/CLI, shared transport, vendor, dependency and CI changes
remain in the coordinator's serialized patch lane. An adapter-only checkpoint
is not DONE: actual root admission and CLI workflow evidence are required.

Coordinator-confirmed handoff protocol:

```text
READY_FOR_ADMISSION(
  slice, exact local JJ revision/bookmark + owned hashes,
  compiled API, minimal root patch/base/paths, focused tests/results
)
READY_FOR_GATE(slice, revision, command, timebound)
```

Request the gate slot before any full Gleam/integration run. No full-gate slot
has been granted; focused module runs are permitted. A common-file edit needs
an explicit named serialized patch grant. After bounded F22 qualification,
proceed to independent F23/F27 work without waiting for live permission.

## Non-negotiable gates

- Devin live inference and enrollment are **not authorized**.
- Remote binary transport stays closed. Synthetic H1 success is not evidence
  of production H1, H2, ALPN or TLS fingerprint compatibility.
- CPA identity and containment belong to the foundation owner. This umbrella
  does not inspect credentials, restart/reconfigure CPA, or infer inference
  permission from the coordinator's successful unauthenticated root GET.
- CPA source revision `acdace936fa7df2905500c7f5e0a97d683138dea` is historical,
  pending F01 scope qualification. Source reading is not differential evidence.
- Devin credentials remain permanent `SessionToken` / `StaticSession`.
  Status observations do not rotate grants or imply expiry/refresh.
- No publication, raw Git mutation, second credential manager, arbitrary URL
  fetch, fabricated signatures, or silent unsupported-input loss.

## Slice queue

| Slice | Deliverable | Current state |
| --- | --- | --- |
| F22 | Source-backed bounded transport; CA/hostname/framing/cancel negatives | Recovered local checkpoint; 24 focused tests and synthetic source CLI passed; coordinator admission/full gate pending; not DONE |
| F23 | Actual Chat SSE projection from validated native events | Queued; establishes shared Devin client lifecycle |
| F24 | Messages buffered/SSE preserving supported thinking/tools/media | Queued; depends on F23 lifecycle |
| F25 | Responses JSON/SSE with correct identities and terminal semantics | Queued; shared Responses API coordination requested |
| F26 | Permanent-session PKCE/manual enrollment through common OAuthUI | Queued; common shell interface coordination requested |
| F27 | Explicit configured catalog/aliases/capabilities at gateway | Queued; no claim of live discovery |
| F28 | Bounded authenticated status/quota observations | Queued; no grant rotation |
| F29 | Source-inventoried native system/tool/media/opaque input mapping | Queued; preserve known forms or reject explicitly |

Work may proceed on another independent slice when remote permission blocks
F22. Only one implementation child runs at once; that permission blocker must
remain visible rather than being converted into a passing remote gate.

## Base root integration map

These are inspected base-code boundaries, not new API promises:

- `src/mimic/gateway.gleam`: registry construction selects only the first
  `devin.models()` row. Dispatch admits Devin only through Chat, overwrites its
  operation with `generate`, fixes protocol to `openai-chat`, and executes only
  buffered requests with `devin.execute(engine, None, request)`.
- `src/mimic/gateway/config.gleam`: accepts only `session_token` with exactly
  `["devin/swe-1-7"]`, requires numeric loopback HTTP, and constructs
  `StaticSession`. Provider loopback HTTPS tests do not constitute a configured
  gateway HTTPS workflow.
- `src/mimic/providers/devin/bridge.gleam`: configured registry supports
  buffered Chat/Messages and tools/optional images. Native streaming exists
  but is not registered as client SSE.
- `src/mimic/providers/devin/stream.gleam`: owns native validated event pulls
  and transport adoption/cancellation. F23 must build upon this lifecycle,
  not treat Connect bytes as client SSE or add a parallel parser.

Before broadening root dispatch, retain the client operation/protocol long
enough to choose its correct projection. Shared stream handoff must synchronously
adopt the upstream owner inside Mist initialization, cancel on adoption or
projection failure, preserve a valid prefix once, and never replay Started
failures. Exact compiled APIs and root patches will accompany their owning
slices rather than being guessed here.

## Cross-owner coordination

- Foundation F01–F04: source scope, CPA identity/containment, live authorization.
- Kimi/Grok F20: any shared binary/egress amendment needs one named owner and
  explicit coordinator approval. Neither umbrella currently owns that edit.
- Shared Responses F11: frozen packet `3190bc60381d39f03dac1ebda92cf7ca47676b26`
  is partial only and admission was withheld. Its generic reconstruction closes
  no pinned native-fidelity fixture; signatures may be superseded. F25 must use
  an admitted, hash-matched API rather than fabricate a local substitute.
- OAuthUI F05–F07: common shell belongs to that peer. F26 supplies Devin hooks
  using S5 begin-before-I/O and exact-generation completion/cancellation.
- Coordinator: root admission, CLI workflow integration and heavy-gate schedule.

## Evidence ledger

This umbrella verified the clean base and recovered file hashes. Its F22 child
executed 24 focused synthetic transport tests and the actual source-root CLI
workflow. Neither this umbrella nor that child ran a new full gate, a CPA
differential, a native client, or any live provider operation. Per-slice documents
distinguish source, synthetic socket/TLS, assembled root, differential,
native-client and live evidence.

### F22 interrupted checkpoint recovery

The original F22 child stopped before its final handoff. Its isolated source
changes were not automatically imported into this umbrella. Read-only inspection
located three retained changed paths: `src/mimic/providers/devin/bridge.gleam`,
`test/devin_transport_qualification_test.gleam`, and
`test/mimic_devin_transport_qualification_test_ffi.erl`. Its `build/f22/`
contains attempt 1–6 logs, including the initial port-zero RED result.

The inspected attempt 6 EUnit log reports nine passing tests followed by a
timeout in the grouped truncation test while adding a runtime account. A
separate truncation-only run passed in 2.178 seconds. That isolated pass neither
establishes the timeout's cause nor clears the failed suite. Earlier reported
seven-test success is not a substitute for the expanded suite.

The coordinator approved exactly one replacement F22 child after the original
stopped. It must recover through `apply_patch` into its own attached worktree,
record exact preimage/source/log hashes and recovery provenance, and preserve
attempted-run evidence. The retained checkout must not be edited or used for
new builds. Timeout diagnosis requires bounded phase/readiness/cleanup evidence;
neither silently increasing timeouts nor weakening assertions is accepted.
Independent cases may be split, or a budget justified, with cleanup proof.

Recovery completed with a serialized 24-test run in 16.855 seconds using the
project's gleeunit timeout setting, and a synthetic source-root CLI run in
32.986 seconds. The latter exercised two positives, six framing negatives, one
SSE denial and four configuration denials; cleanup was confirmed. All 29
original/recovery log streams and hashes are archived in `F22_TRANSPORT.md`.
Historic timeout cause and forced-EUnit-timeout cleanup remain unverified.

The parent verified all six imported owned-file hashes and root-patch
applicability against the attached checkout. `F22_ROOT.patch` is still unapplied;
it proposes only source/shipment smoke commands, not broader capabilities.
This is a local checkpoint awaiting coordinator admission, not F22 DONE.
Root, egress and full-gate grants remain unchanged; remote F22 qualification
remains blocked.
