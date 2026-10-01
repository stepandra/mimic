# F31 — preparatory Codex paired stimuli

**Every plan/report is blocked and not run. These 23 SYNTHETIC proposals are not
approved runtime fixtures or CPA/MIMIC comparisons. Historical strict37 remains
0/37. Minimal root integration patch: none.**

Source-intent base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
CPA pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
Neither pin proves executable, dependency, driver or shipment binding.

## Scope and nonexecuting API

Only these files are owned:

- `scripts/parity/f31_codex.py`
- `scripts/parity/test_f31_codex.py`
- `test/parity/final/f31_codex.json`
- `docs/parity/final/F31_CODEX.md`

F31 follows the current F30 provider-only preparation pattern, not a new harness.
No root, CI, provider implementation, common contract, harness or matrix changes.
No child is spawned, commit made or target launched. No CPA/MIMIC/provider/native
client/login, process worker, network/DNS/listener or ambient credential access.
The existing `https://localhost:8317` identity is unqualified: do not contact it.

| API | Meaning |
|---|---|
| `load_fixture(root=ROOT)` | Read only the explicit F31 provider JSON; reject duplicate envelope keys, unsupported wire data and admission/execution envelope fields. |
| `case_plan(value, scenario_id)` | Deep-copy the shared symbolic `synthetic_context` plus the complete selected provider stimulus independently for `cpa` and `mimic`. Never compare or execute assertions. |
| `blocked_report(root=ROOT, scenario_id=None)` | All or one proposed case; actual local adapter/fixture byte hashes, missing future bindings and unconditional blockers. |
| `main(argv=None)` / `--case` | Print blocked preparation; exit **2**. Invalid/missing data or unknown case exits **1**. No endpoint, credentials, execution, hash-admission or waiver option. |

Payload schema: `mimic.f31-codex-fixtures/v1`.
Preparation schema: `mimic.f31-codex-preparation/v1`.
Approval: `pending_f01_mapping_and_qualification`.
`expected` is source intent or a proposed observation, never an executed result.
The narrow loader is not a source, common-contract, protocol or result validator.
Historical membership is checked against the existing manifest in focused tests;
there is no second row inventory or common validator.

## F01 boundary and provisional historical mapping

F01's peer-reported common contract compiles but is **not imported or frozen**
here. Its API is `case_plan(Contract, row_id)` with plan schema
`mimic.final-parity-plan/v1` and fields:

`scope_id`, `contract_sha256`, `cpa_revision`,
`historical_manifest_sha256`, `clients_lock_sha256`, `row`, `cases`,
`historical_fixture`, `error_cases`, `execution_status=not_run`,
`normalization=[]`.

Its common stimulus is `{description, request: object|null,
variants: [request objects], parameters: {...}}`. F31 deliberately uses a
different provider shape: shared symbolic context, path/transport/policy intent
and ordered `turns` containing raw requests, upstream response scripts and
declarative controls. It does not emit a counterfeit common plan.

Each proposal names an exact historical `row_id` from
`test/parity/v2/manifest.json` and primary `<row-id>.final-v1`. Additive probe IDs
are `<row-id>.<probe>.final-v1`, not replacements for those primary cases.
`f01_mapping=provisional_pending` is explicit in every plan. F01/coordinator must
approve mappings, preserve the historical tuple/fixture/required checks and bind
the common stimulus without dropping the extra raw data or controls.

| Historical row | Proposed probe names |
|---|---|
| `codex-http` | `wire`, `history-replay`, `missing-receipt`, `restart`, `request-errors`, `bounded-retention`, `nonstream-hydration` |
| `codex-sse` | `lite-header`, `lite-markers`, `streaming-bootstrap`, `sparse-strict`, `sparse-reconstruct` |
| `codex-compact` | `separate-operation` |
| `codex-ws` | `same-socket-history`, `socket-replacement`, `lite-unsupported` |
| `codex-alias` | `direct-route` |
| `codex-lifecycle` | `cancel`, `uncertain-terminal`, `trailing-corruption` |
| `codex-isolation` | `scope-bindings` |
| `codex-quota` | `auth-failover`, `reset-units` |

Mapping probes to all eight historical Codex IDs is **not** full row coverage.
The auxiliary 401 probe does not replace 429/reset/failover coverage; Lite probes
do not replace ordinary SSE coverage. Image/media, OAuth enrollment/refresh,
catalog/native-client acceptance, physical WS frames/control and full ingress
policy remain unqualified.

## Provider-specific stimuli

- **HTTP wire / alias:** explicit buffered ingress (`stream:false`) with upstream
  SSE, raw duplicate query parameters and `%2f`/`%2F` spelling, whitespace,
  trailing newline, Unicode and extension-key order. Headers remain ordered
  pairs with original name case and duplicates in both directions.
- **HTTP history:** three turns retain initial input, completed encrypted
  reasoning/function-call output, paired tool result, subsequent completed
  output and final input in order. The encrypted strings/usage counts are
  synthetic, not signatures, live captures or measured tokenizer output.
- **HTTP missing receipt / scope / restart:** reject caller full-history flags,
  item references, wrong selected scope/revision and stale receipts before send.
  Scope probes cover tenant/provider/auth/credential/account/generation/model/
  origin/client/protocol/operation, same-value reenrollment, conflicting thread
  hints and equal response IDs across tenants. A session header is not authority.
  Cache state is nonpersistent; after restart recovery is a separate complete
  standalone request without an incremental id.
- **Compact:** separate `/responses/compact` intent, opaque compaction and JSON
  usage/extensions, not Lite or SSE. Request preparation supports the backend
  compact target; the existing `codex/http.open` continuation wrapper
  [explicitly rejects compact](../../../src/mimic/providers/codex/http.gleam#L47-L50).
  This proposed script is not proof of an assembled compact route.
- **Lite:** header/metadata intent shares the ordinary Responses route.
  Custom/function/namespace declarations and tool-result kinds are preserved,
  parallel calls false and no automatic image-tool injection. Explicit normal
  intent is not overridden by catalog `use_responses_lite`. Malformed/duplicate
  marker rejection versus CPA false fallback remains decision-required.
- **WS:** one physical generation, warmup `generate:false`, ordered text
  `response.create`/tool/usage/completed exchanges and close intent. The
  incremental frame retains the id; the following standalone create has no id.
  Old socket, HTTP receipt, failover and restart probes forbid transparent
  reconnect, id deletion and HTTP fallback. WS Lite remains explicitly
  unsupported by the HTTP Lite slice.
- **Lifecycle/errors:** visible-prefix cancellation, adversarial late terminal,
  failed/uncertain/disconnected execution and trailing malformed or duplicate
  terminal data cannot publish successful receipts or authorize automatic replay.
- **Bounds:** cache, history and codec numeric boundaries are declarative probes,
  not materialized megabyte/100000-event test streams. Capacity/duplicate-id
  publication failure is proposed `Persistence/Started`, not replay permission.

Both future targets receive **identical** input/control/context scripts. The
scripts do not assume arbitrary caller headers survive provider security policy.
Capture ingress and actual outgoing headers/body/target separately. SSE
`body_chunks` are a proposed delivery schedule; TCP read boundaries are separate
observations. WS `text_frames` describe ordered text-message payloads, not a
complete physical framing/masking/ping/fragmentation implementation.
`control` and `parameters` are reviewable intent only; no interpreter runs them.
Seed, clocks, barriers, isolated credentials, catalog/model, scheduler, upstream
origins and both assembled-ingress drivers still need actual qualified bindings.
`synthetic-*` identities and bearer markers are placeholders, never real grants.
Never place real credentials or private scope/history in observations or logs.

## Intentional HTTP continuation difference

The baseline HTTP continuation path is already **default-off and bounded**;
F31 does not enable or change it. Proposed opt-in probes retain the baseline
cache limits: 32 entries, 8 MiB total, 2 MiB per entry, 900000 ms TTL. Provider
history additionally caps JSON at 1 MiB, 4096 items and 900000 ms.

MIMIC requires an authoritative selected-scope server receipt and complete
retained history, replays **all prior input plus actual completed output**, then
deletes `previous_response_id`. Pinned CPA ordinary HTTP deletes that id without
this full-history replay. Missing, cross-scope, expired, cancelled and
restart-lost receipts fail closed in MIMIC. These differences are explicitly
**decision_required, never a normalized match**.

WS is separate: continuation retains the id on the same credential-scoped
physical socket generation. A complete-looking client history, caller account
pin or Boolean flag cannot turn an HTTP/old-socket receipt into WS authority.
Successful publication requires completed, paired, bounded history and clean
EOF; merely forwarding `response.completed` is insufficient.

## F11 partial seam: admission withheld

The early compiled API reference is still only a reference:

- `Policy = Strict | Reconstruct(max_observation_bytes, max_events)`
- `new_with_policy`, `new_with_policy_and_limits`
- `http.open_sse_with_policy`, `websocket.new_with_policy`

Defaults stay **Strict**. Only a trusted **admitted** route may choose a policy;
caller Lite headers/metadata never choose reconstruction. Declared observation
limits are at most **16 MiB / 100000 events**, frame **1 MiB**, items **4096**,
parts **4096**. A compiled constructor is not an accepted runtime consumer.

Latest coordinator correction: packet
`3190bc60381d39f03dac1ebda92cf7ca47676b26` was fetched, **not merged**, and is
**PARTIAL; admission WITHHELD**. Its whole 180-second gate was incomplete.
The coordinator reports all 48 pinned `TestCodexNativeStreamFidelity` stream-mode
leaves denied by the current reconstruct codec, including 16 native selectors
expecting exact metadata plus `completed.output:[]`. F31 does not rerun or claim
those measurements. F12/F13 provider/root consumers remain queued/unadmitted.
Do not freeze the old seam as target-ready.

The existing CPA Lite source-test output is historical local synthetic-test
evidence, **not paired execution**. F31 includes only a newly authored synthetic
analogue: no created/added lifecycle, a nonempty done item, then contradictory
empty completed output with no `object`. Strict and proposed Reconstruct plans
both remain blocked, no successful receipt, no speculative hydration and no
sparse/native root admission. An earlier successor design was discussed for
the 16 native `Stream:true` selectors, with 32 compatibility selectors separate.
**That design approval is not gateway projection approval and is now on HOLD.**
No successor implementation or transparent native route is admitted.

### Assembled boundary correction — supersedes executor-only inference

F01/coordinator review reports that the pinned downstream `responsesSSEFramer`
unconditionally tracks `item.done` and hydrates `completion.output`.
`TestCodexNativeStreamFidelity` varies **upstream HTTP versus WS transport**,
not downstream route selection. Its executor-level native-byte assertions
therefore do **not** prove raw preservation at assembled `/v1/responses`.
These are peer-reported source findings pending frozen full-file/excerpt
bindings, not a locally executed observation.

F01 freeze and F11 implementation/root policy remain on hold until the entire
gateway input → handler selectors → executor format → output framer → client
path is source-bound and tested at the same boundary. F31 now carries an
explicit `assembled_output_framer_source_path_review_hold` blocker.
No executor test, prior design approval or root GET may remove it.

`StreamBootstrapBuffering` with `Stream:true` is **streaming bootstrap**,
not nonstreaming buffered HTTP. `streaming-bootstrap` proposes on/off switches
separately from the HTTP `wire` / `direct-route` `stream:false` cases. Neither
category is executed or qualified here.

### Nonstream source counterevidence

The coordinator/F01 reports pinned `codex_executor_execute.go` `Execute` lines
160–199 collect done items; line 188 **unconditionally**
`patchCodexCompletedOutput` before `TranslateNonStream` at 193–199, with **no
`preserveNativeOutput` guard**. Executor-level native **streaming**
exact-empty-output preservation cannot generalize to either downstream
streaming projection or nonstreaming buffered HTTP.

Reported source file SHA256:
`44c07b9ea934c917fe48e7448109682559c8aacb397c4ae9740583404ed2ef2d`;
reported excerpt SHA256:
`ce26d02200fc2916bf363bcd3f9abc005c410f0d2c898178d6acfd6ee6536eea`.
These are attributed source-counterevidence references, not locally verified
execution/shipment bindings; all F31 future binding hashes remain missing.
F01 source assessment `codex-nonstream-hydration` is pending freeze.

`nonstream-hydration` uses an explicitly separate `stream:false` synthetic
stimulus and records this source intent without executing CPA or hydrating
MIMIC output. A supplied-terminal-only nonstream policy is an **optional,
UNAPPROVED product extension, disabled, not denominator coverage and not CPA
parity**. No synthetic script silently implements it or supplies acceptance.

## Error scope is not inferred from helper code

The existing HTTP adapter's
[header-only rejection hook](../../../src/mimic/providers/codex/adapter.gleam#L356-L377)
returns `CredentialUnavailable/Rejected` for 401 and `Quota/Rejected` for
**any 429**, invoking `errors.classify(status, headers, "", now_ms())`. It does
not inspect the body. Other statuses have no typed header rejection.

The case data keeps that baseline separate from the helper's proposed body-aware
`InvalidRequest`, `ContextTooLarge`, `InvalidReasoning`, `MissingContinuation`,
`AccountQuota`, `ModelCapacity` and `RateLimit` categories. At synthetic time
1000 ms, quota `resets_at:18` seconds and `resets_in_seconds:17` both suggest
17000 ms helper delay; the body-blind baseline has no such delay without headers.
Numeric `Retry-After:17` suggests 17000 ms; duplicate Retry-After yields no delay,
not a last-value or universal quota inference. No helper classification proves
assembled request/credential scope, durable cooldown or actual pool failover.

The 401 A→B script describes eligibility only before output, without account pin
and cancellation; the runtime remains the sole scheduler. Continuation cannot
switch accounts. Failed in-band quota over original **HTTP 200**, 5xx and
disconnects may have executed and cannot be relabeled safe 429 rejections.
Exact CPA/downstream error differences require decisions, not dictionary,
status, session, header or body normalization.

## Blockers and hashes

Every case/report unconditionally retains:

1. F31 is nonexecuting; provider proposals are not approved runtime fixtures.
2. F01 common mapping/freeze and historical/client-lock bindings are pending.
3. **F03, F11, F12, F13 are not admitted**; F11 is fetched/not merged PARTIAL.
4. Both assembled-ingress drivers, actual target/executable/shipment, dependency,
   isolated seed, origin, model/catalog, clock, barrier and scheduler bindings
   remain unqualified.
5. Existing localhost 8317 identity is unqualified and must not be contacted.
6. SourceV3 hard blockers remain unconditional:
   `pinned_cpa_unconditionally_starts_antigravity_version_updater` and
   `candidate_descendant_containment_unavailable`. Same-PGID cleanup is not
   detached-descendant containment. No flag, caller hash or proposal waives them.
7. Source, driver, fixture, dependency, executable and shipment run-binding
   hashes are missing, along with F01 contract, historical-manifest and client-lock
   hashes. `future_result_hashes` are all `null`;
   `hash_binding_status=unknown_not_verified`. Local adapter/fixture SHA256s only
   identify actual local bytes; they cannot supply admission or result evidence.

## Focused validation

Only focused Python units are permitted; imports and suite loading run inside
the existing `safe_unit_tests.execution_guards`. The shared suite allowlist is
unchanged; do not use broad discovery, launchers or heavy gates.

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/parity python3 - <<'PY'
import unittest
from safe_unit_tests import execution_guards
with execution_guards():
    suite = unittest.defaultTestLoader.loadTestsFromName("test_f31_codex")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
```

Focused guarded result: **22 tests passed, exit 0**, covering all 23 provider
proposals. Unit controls inspect preparation/fixture data, deep-copy fidelity,
blocked/hash invariants, provisional mapping, boundary caps, nonzero CLI results
and synthetic audit-event controls only. They do not test the actual provider,
shared codec, common contract or paired acceptance.

Gleam tests/format, builds, full gates, CPA/MIMIC/provider/native/login,
shipment, live validation and actual paired execution are **not run**.
The coordinator owns any later serialized qualification. Root patch: **none**.
