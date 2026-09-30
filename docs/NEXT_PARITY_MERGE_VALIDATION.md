# Nine-stream parity integration: destination validation

## Result and scope

The **fourth complete destination gate passed**, on the assembled attached
checkout using Gleam 1.18.1 and Erlang/OTP 29:

```sh
PATH="$PWD/.tools/bin:$PATH" GLEAM="$PWD/.tools/gleam" \
  sh scripts/verify-integration.sh
```

This admits a tested integration snapshot, **not complete CPA parity or live
provider qualification**. The user authorized merge and publication to `main`.
The input public base is `3e00808ff0fefbb6728edb1769c17139ef0fd93a`.

| Executed destination gate | Result |
| --- | --- |
| `gleam format --check src test` | Passed |
| `gleam test` | **698 passed, no failures** |
| Doctor and explicit parity-v2 schema validation | Passed |
| Guarded CPA harness unit suite | **47 passed**, no candidate/CPA launch |
| Checkpoint-admission unit suite | **13 passed** |
| Guarded native report contracts | **31 passed**, zero native executions |
| Kimi ordered-wire unittest | **1 passed**, three synthetic auth/domain sessions |
| Runtime, Claude, Codex, Responses, Devin scenarios | Passed |
| Strict raw WS handshake checks | Passed; actual close distinguished from timeout |
| Root gateway, HTTP providers, enrollment, WS and Codex HTTP CLI smokes | Passed |
| Fresh-process Claude credential restoration | Passed without reseeding |
| Erlang shipment export | Passed |
| All five CLI smokes using the shipment from a different working directory | Passed |
| Input integrity across the full gate | **528 files unchanged** |

The Python total is 92 tests across the four named groups, not native-client
workflows. Source/shipment smokes use real local sockets, temporary private
synthetic credentials and actual MIMIC entrypoints.

Final log:
`build/integration/next-wave-destination-attempt4.log`

SHA-256:
`9e53975275d86f3a06b9161b719dc8e53ffdd5a151b96acb2768ae77ab9d0f42`

Pre/post input inventory:
`build/integration/next-wave-source-before-attempt4.json`

SHA-256:
`c156f3508efa8401d2e978733369df1aee8f206d80607547450e6f6aa56e6979`

Only release documentation was updated after this gate. Application, test,
script, dependency and vendor bytes were not changed for the report.
These local results are not a GitHub CI result; CI is verified separately
against the published commit.

## Assembly provenance

The independent threads are not direct Delta children, so `merge_thread`
could not import them. Source integration instead used Jujutsu merges of
their existing Git-backed revisions:

| Stream | Imported source revision |
| --- | --- |
| Integration checkpoint | `8b87e8aae5450b3d73494b6046220cc9ec10e05e` |
| Shared S4/S5/S6 | `f923474a14946c0bf97aaa002316d9c160da16d2` |
| Claude policy/enrollment/429 | `dd75ad60319edc18798a0d13626c07c13980f768` |
| Codex HTTP | `676eda5cad4c5097568d4a6b7c7c8d3e8003534b` |
| xAI v2/v3 | `4d6904657d945ce10dfe4e1e3ea9965ba2b72034` |
| Devin | `b0d7cfe6ac2577fb03892006a7f1438acfb94fa1` |
| Native report admission | `b72de287342991c63883de1e8ecbb29bc4a4ef10` |
| CPA safe-source v3 | `fe4e02c4f5bc3a1c630588d67bee36a6bcda4509` |
| Kimi, including late nested-media correction | `ff0fb6077111464883a592f0672b8f86520021fb` |

Read-only `git bundle create` exported existing `refs/jj/keep` objects to
ignored artifacts in this destination. Only the bundle's advertised ref name
was aliased to a temporary `refs/heads` name for `jj git fetch`; the packed
commit/tree bytes remained unchanged. `git bundle verify`, exact commit IDs
and per-file hashes checked the transfer. No sibling checkout, index or refs
were modified by this mechanism. Native JJ conflict resolution selected the
hash-verified authoritative owner versions.

Eight un-snapshotted integration files were imported literally with
`apply_patch`, then checked against the reviewed 510-file assembly map.
The parent subsequently added gateway wiring, regression tests and corrections
described below. Initial input-map SHA-256:
`32786a628e182cf4f33040b61de1f744deb09207da2c645e12d1948af3c32f0c`.
The Kimi late successor is separately recorded in the release audit.

No runtime state, actual credentials, downloaded native executables, CPA
binary, `.git`, `.jj` or sibling build directories were imported as source.
See [the input/audit ledger](NEXT_PARITY_RELEASE_AUDIT.md) and
[the initial import plan](source-manifests/NEXT_WAVE_IMPORT_PLAN.md).
Frozen owner handoffs and the old integration queue describe their historical
checkpoints; they are not current gateway capability declarations.

## Corrections verified at the destination

- **Enrollment:** S5 exact-slot reservations precede provider activity;
  stale login completion cannot replace an administrative mutation. Shared
  and Claude tests, plus real Kimi CLI/shipment first/re-enrollment races pass.
- **Claude 429:** all Messages/counting paths use the conservative provider
  wrapper before quota observation. Actual two-account API-key/OAuth checks
  prove one upstream send, no pool penalty, and immediate/fresh-VM reuse without
  administrative reset. The deliberate downstream response is sanitized 503,
  and genuine quota 429s also lose automatic failover.
- **Codex HTTP:** explicit default-off bounded nonpersistent continuation,
  authenticated stable hints, selected-account/current-revision scope,
  completed/clean-EOF receipts, synchronous Mist adoption and cleanup.
  Real root/shipment smokes verify history/reasoning replay, tenant/session
  isolation, pre-I/O rejection, replacement and restart invalidation.
- **xAI/shared:** optional raw tool identities are validated before
  request-scoped alias restoration, including event-level argument names.
  The composed actual local WS mismatch regression runs in the regular suite.
- **Origins:** one canonical authority is admitted before provider selection;
  only a validated root slash is removed. Unsafe paths/authority components
  and Devin remote/nonnumeric origins remain denied.
- **Native evidence:** strict report identity/provenance/outcome validation
  rejects status-only and misbound passes. Non-qualifiable workflows remain
  blocked in the unchanged eight-row inventory.
- **Client revocation:** an existing Codex WS revalidates the current client
  key before each new inference and again after acquisition. Denial closes
  the socket and cancels the handle. This is not atomic/proactive interruption
  of a previously admitted response. The post-open denial timing window was
  source-reviewed; the two new tests exercise before-first-create and
  existing-socket-next-create revocation.

Independent read-only reviews found no remaining blocker in the final
admission changes. Their source reviews are separate from the parent-executed
gate above.

## Failed attempts retained, not waived

| Attempt | Outcome and correction | Log SHA-256 |
| --- | --- | --- |
| 1 | Gleam 690 green; full gate failed when generic Kimi accepted nested audio. The omitted late owner patch was reproduced at actual CLI, imported by exact hash, and its positive/negative cases rerun. | `aa39435046117a3cfe6309f64bc98337f60af0eeecf5a6559f731ffbef0f754b` |
| 2 | Failed refresh-count assertion across fresh VMs. Original mode/timing was not recorded, so its exact cause is not claimed. A controlled 5.2-second delay proved the fixture's unstated 5-second fallback window invalid. Explicit synthetic `Retry-After: 300`, window checks and diagnostics fix that test rule without production changes. | `96c362bf59f89c094c4c59bd883957dea3d4cf797ccc00b3e8e46359b01da6f9` |
| 3 | HTTP/enrollment/wire passed; WS smoke proved revoked live connections could send again. Added current-key revalidation plus 13 passing WS tests and real root/shipment regression. | `af08d4b89d77a86804fc65b42ddcd747604a029ebcb72d6ca5aa91a9acc83868` |
| 4 | Entire destination gate passed, exit 0; all 528 recorded inputs unchanged. | `9e53975275d86f3a06b9161b719dc8e53ffdd5a151b96acb2768ae77ab9d0f42` |

An earlier standalone Codex smoke also failed because it attached reasoning
only to the fixture's global first request, which was consumed by the
default-off phase. The fixture now identifies first-turn input semantically
and explicitly checks that the completed response contains reasoning before
testing replay. This was a fixture correction, not a production receipt fix.

The pinned pristine Mist trailing space at `vendor/mist/src/mist.gleam:752`
remains unchanged. Scoped `git diff --check -- . ':!vendor/mist'` passes.
Expected negative TLS/HTTP/WS notices are not hidden. No power-loss,
production-performance or transport-fingerprint qualification is inferred.

## Still not complete parity

Use [the current gateway matrix](PROVIDER_INTEGRATION.md), not provider-only
test totals. In particular xAI OAuth/WS and broader Devin gateway operations
remain unregistered; Devin remote binary/H2 qualification is closed. Native
sparse Responses-lite, parts of Claude policy fidelity, Kimi Messages/generic
streaming and several media/tool transformations remain incomplete.

Historical strict CPA conformance remains **0/37**. This gate validates its
schema and safe harness units, not executable reference/candidate parity.
Reference startup/descendant containment blockers remain enforced; only two
HTTP rows have reference bindings, with 35 unbound and 22 source-pending rows.
All eight actual native workflows remain blocked/unperformed. No live
inference or real-account OAuth login was performed.
