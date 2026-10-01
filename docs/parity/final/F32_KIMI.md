# F32 — preparatory Kimi paired stimuli

**All 20 cases are SYNTHETIC UNAPPROVED proposals. Every plan/report is
`blocked`, every target/assertion execution is `not_run`. This is not CPA/MIMIC
differential evidence, native acceptance, live verification or shipment
approval. Historical strict37 remains 0/37. Minimal root patch: none.**

Inspected source-intent base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
Historical CPA pin: `acdace936fa7df2905500c7f5e0a97d683138dea`.
Neither revision is a future run-bound source or executable hash.

## Ownership and nonexecuting API

Only these files are owned:

- `scripts/parity/f32_kimi.py`
- `scripts/parity/test_f32_kimi.py`
- `test/parity/final/f32_kimi.json`
- `docs/parity/final/F32_KIMI.md`

F32 follows F30/F31's provider-only `load_fixture`, `case_plan`, `blocked_report`
pattern. It does not add another launch, exercise, comparison, admission or
credential harness. No root, CI, provider, shared contract/harness or matrix
edits; no child spawned, commit, mutating Git command, push or peer-code import.
No CPA/MIMIC/provider/native client/login, process worker, network/DNS/listener
or ambient credential access is part of this work.

| API | Meaning |
|---|---|
| `load_fixture(root=ROOT)` | Read only the explicit F32 provider JSON. Necessary envelope/provider/wire checks reject duplicate envelope keys, lossy header shapes, unsupported encodings and admission/execution fields. No provider codec runs. |
| `case_plan(value, scenario_id)` | Copy both registration intents, symbolic context and all selected turns/controls independently for `cpa` and `mimic`. Equal initial values, no shared mutable manager/account data. Never execute or evaluate assertions. |
| `blocked_report(root=ROOT, scenario_id=None)` | All or one case; actual local adapter/fixture byte hashes, null future result bindings, peer-reported checkpoint metadata and unconditional blockers. |
| `main(argv=None)` / `--case` | Print blocked preparation and exit **2**. Invalid/missing fixture or unknown case exits **1** with a sanitized error. No endpoint, credentials, execution, admission, hash-binding or waiver flag. |

Provider fixture schema: `mimic.f32-kimi-fixtures/v1`.
Provider plan schema: `mimic.f32-kimi-preparation/v1`.
Readiness schema: `mimic.f32-kimi-readiness/v1`.
All approval fields are `UNAPPROVED`; mapping is `provisional_pending`.
`expected`, raw response scripts and `planned_assertions` are authored intent,
not captures, observations, synthetic run results or passing checks.

The loader is deliberately not a generic protocol, source, contract or result
validator. It keeps request bodies as UTF-8 strings, including intentionally
invalid protocol bodies and duplicate JSON keys used by negative probes.
Envelope duplicate keys are rejected before dictionary conversion. Provider
duplicate-key/model/media validation must eventually happen on the targets.

## F01 boundary and provisional historical mapping

The peer-described F01 common contract is **not available as an imported/frozen
contract here**. Its nonexecuting API is `load_contract(root=...) -> Contract`
and `case_plan(Contract, row_id)`; the common plan uses
`mimic.final-parity-plan/v1`. Historical IDs, five-field tuples and fixture
hashes remain unchanged, including inherited checks and `error_cases`.
F32 does not import, imitate, compile or qualify that contract.

F32's provider stimulus has registration/auth/domain/model intent, symbolic
account/clock context, ordered turns with raw requests and response chunks, and
declarative controls. This differs from F01's common stimulus; no claim of
drop-in schema compatibility is made.

Every probe explicitly names a historical `row_id` from
[`test/parity/v2/manifest.json`](../../../test/parity/v2/manifest.json#L33-L34)
and the primary `<row-id>.final-v1`. Additive IDs
`<row-id>.<probe>.final-v1` do not replace those primary cases:

| Historical row / unchanged tuple | Proposed probes |
|---|---|
| `kimi-native`: `kimi / oauth / responses / kimi_native / http_backend_identity` | `registration-isolation`, `chat-wire-tools`, `chat-sse`, `responses-sse-history`, `messages-signed-tools-images`, `oauth-com`, `oauth-ai`, `tools-pre-io`, `controls-pre-io`, `media-pre-io`, `state-pre-io`, `model-pre-io` |
| `kimi-generic`: `kimi / api_key / chat_completions / openai_compatible / http_backend_identity` | `chat-wire`, `chat-sse`, `opaque-tools`, `images-no-fetch`, `media-pre-io`, `model-pre-io`, `protocols-pre-io`, `oauth-pre-io` |

Native API-key/Chat/Messages and generic negative OAuth/Responses/Messages
probes are provisional extensions under those historical anchors, not changed
historical tuples or newly admitted global rows. The historical provider label
`kimi` on `kimi-generic` does not collapse the runtime registration
`openai-compatible-kimi` into native `kimi`.

Both historical rows still reference
[`backend-v1.json`](../../../test/parity/fixtures/backend-v1.json#L1-L6).
Its inherited checks are:

- `exact_backend_selected`
- `auth_mode_preserved`
- `native_envelope`
- `no_generic_fallback`
- `ordered_headers_preserved`

Focused tests freeze the actual existing manifest and historical fixture bytes:

| Unmodified input | SHA-256 |
|---|---|
| `test/parity/v2/manifest.json` | `3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9` |
| `test/parity/fixtures/backend-v1.json` | `9cc3a223ec54344afdc11af14f4ca9e72c737301d56b79014302f10af213aa56` |

F01/coordinator must approve these mappings and bind provider payloads without
dropping raw wire data, auth controls, inherited checks or common `error_cases`.
Names mapped to both historical rows do not establish full required coverage.
A generic endpoint, old local fixture, source inspection or plan validation
never counts as CPA execution or supplies a native backend identity.

## Inspected base versus the reported F15 checkpoint

The inspected base is not the admitted F15 coordinator destination:

- Native [`models.registration`](../../../src/mimic/providers/kimi/models.gleam#L62-L85)
  identifies `kimi`, with API-key/OAuth and distinct Chat/Responses/Messages
  operations. Native alias/thinking policy and OAuth private device binding
  belong to this identity, not to generic Chat.
- The base's generic
  [`registration`](../../../src/mimic/providers/kimi_compat/request.gleam#L18-L35)
  and [`prepare_at`](../../../src/mimic/providers/kimi_compat/request.gleam#L51-L76)
  allow buffered API-key Chat only. Base
  [gateway dispatch](../../../src/mimic/gateway.gleam#L657-L668) also denies
  generic streaming. The F32 generic SSE probe does **not** assert that this
  base already implements the reported F15 route.
- Base native Messages streaming is denied by
  [`request.prepare_at`](../../../src/mimic/providers/kimi/request.gleam#L99-L111);
  this is the inspected base, not the coordinator's newer F14 admission.
  F14's hook is not imported or qualified in this F32 checkout.

Peer-reported F15 checkpoint, retained separately in every plan/report:

| Field | Peer report, not independently imported here |
|---|---|
| Coordinator destination | **ACCEPTED**, `8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936` |
| Bookmark | `coordinator-f15-admitted` |
| Provider library, reported unchanged | `85f44ef07144a8a4433933b2f51f1972e4744039` |
| Planned generic route | Root-wired `openai-compatible-kimi`, API-key Chat SSE |
| Reported gates | Focused **22**; full-source **18 requests**; shipment **18 requests**; full Gleam **711**; review reported |
| Relevant reported semantics | Complete `ir.Value` preservation; exact protocol model validation; no native alias/device/thinking transformations; nested media `Unsupported`/`NotSent` rejection |

These are peer-attributed checkpoint facts, not F32 test results or future
hash bindings. No peer code is fetched/imported and no peer gate is rerun.
This is a useful admitted checkpoint for the **planned generic route**,
not all F32 qualification and not CPA differential/native/live evidence.

Dependencies remain:

- F03: not admitted here; qualified reference/paired execution is missing.
- F14: **coordinator-reported root admission**, not imported or qualified here.
  Admitted revision `643941e03e943c501271aca889f387202045cb45` is reported as
  an ancestor of `428b7671452a4c637ca227411f02bc1760d66349` (F23).
  The coordinator reports actual source/shipment positive CLI tests and no
  production review blocker. Whole-integration timeout and split remainder
  remain explicit; this is not independent F32 validation or F03 qualification.
- F15: peer-reported admitted checkpoint, not independently imported or
  run-bound here. Do not describe the coordinator destination as rejected or
  the generic route as unconditionally unimplemented.
- F16: not admitted here.

## Provider-specific intent and wire preservation

**Distinct registrations and isolated state.** Both provider IDs coexist in
either registration order, deliberately using the same configured model
spelling `kimi-k2.7-code`. Native uses a coding prefix (`/coding`); generic uses
an API prefix (`/v1`). The selected symbolic account is `synthetic-b`, not the
first configured account. Provider/auth/account/client/model/session state must
remain scoped. Operator-selected backend authority and actual root routing are
unqualified; the symbolic registration field does not bypass that gate.

**Native Chat/Responses/Messages.** Chat history carries explicit call/result
IDs, raw argument JSON and reasoning; Chat SSE carries reasoning/tool fragments,
provider usage and `[DONE]`. Responses carries standalone reasoning summaries,
opaque encrypted content and explicit function output history, with its own
SSE terminal. Buffered Messages retains synthetic signatures/redacted thinking,
tool-use/result blocks, native budgets and URL/base64 image sources. Native
Messages uses Kimi credentials, not Claude OAuth identity. Actual upstream
alias/control changes and protocol-owned downstream model restoration must be
observed separately; nested user `"model"` fields are not restoration targets.
The requested model spelling is source metadata, not an account entitlement.

**Generic complete values and exact model.** Buffered/SSE Chat proposals keep
ordered extension objects, null/boolean/integer/float/array values, opaque
schema/argument/result text and reasoning fields. The alias-shaped configured
model stays exact; no native coding prefix, device header, alias, schema,
temperature or thinking transformation is permitted. Model-negative bodies
exercise absent/null/numeric/mismatched/escaped-duplicate model fields without
coercion. Responses, Messages and both OAuth domain labels are negative generic
registration probes, never borrowed native support.

**Tools/media before I/O.** Negative stimuli include native schema references,
unpaired tool history, missing reasoning, unsupported thinking/temperature
controls, continuation/compact, and media nested in semantic content/tool
outputs. Generic probes cover audio/video/files in user and tool-result content,
unknown system content and assistant message-level audio, with caller
`required_capabilities: []`. Conversely, media-named schema properties, function
arguments, result text and vendor extensions are opaque data, not a reason for
a recursive name scan. Planned `required_upstream_requests: 0` is an assertion
intent, **not an observed zero-request result**. Request rejection must not
become credential quarantine or a quota/failover claim.

Inline images use a bounded SYNTHETIC one-pixel GIF string, not a capture.
Audio sentinels are SYNTHETIC text, not recordings; signatures are SYNTHETIC,
not real cryptographic acceptance. Remote media uses reserved `.invalid` hosts.
No media is fetched/decoded; supported syntax is not measured media acceptance.
Base64 is an encoding, not a secret-redaction policy.

**Both native OAuth domains.** Separate `kimi.com` and `kimi.ai` cases declare
device/token path intent, form-UTF-8 auth bodies, minimum 5000 ms polling,
900000 ms cap, 300000 ms refresh lead, pending/slow-down/cancel/expiry/denial
branches, two-request refresh barriers, selected private device slot, rotation
persistence before inference and no blind retry after unknown rotation.
Opposite-domain grants must not authorize inference. These auth controls are
declarative branches, not executable token scripts or enrollment observations.
No access/refresh/device-code credential values are stored in the fixture;
only symbolic slots are named. Future approved targets need independently
materialized synthetic credentials/managers, never a shared rotating grant.

**Raw wire data.** Header lists preserve order, duplicates and original case on
both ingress and authored response scripts. `%2f`/`%2F`, repeated query keys,
body whitespace/newlines/Unicode, extension order, raw SSE comments/CRLF,
split field names, tool argument fragments and terminal bytes are preserved.
Ingress headers are not assumed to be blindly forwarded; actual upstream
ordered headers/target/body require separate observations. Chunk lists describe
synthetic write schedules, not claimed TCP read boundaries. The provider module
does not parse/reframe SSE or allocate binary observation buffers. Non-UTF-8,
binary bodies, nonidentity encoding and unplanned transports fail explicitly.

**Differences stay differences.** Native schema/ID/reasoning repair versus
fail-closed rejection, temperature dropping/clamping versus explicit loss
errors, and positive-integer OAuth expiry versus CPA numeric-float parsing are
decision-required. No normalization is allowed, no rounded/fabricated state
becomes a match, and no synthetic protocol script creates a parity pass.

## Unconditional blockers and missing result bindings

- Nonexecuting adapter and SYNTHETIC UNAPPROVED provider cases.
- F01 contract not imported/frozen/mapped; common inherited/error coverage
  binding remains pending.
- F03/F16 not admitted here; F14/F15's reported admitted destinations are not
  independently imported or run-bound here.
- Native Messages streaming not qualified in this checkout.
- Paired CPA/MIMIC driver and fixture bindings unqualified.
- Existing `https://localhost:8317` identity **unknown and untouched**:
  no requests, probes, deployment, login or service reconfiguration.
- SourceV3 hard blocks remain **unconditional**:
  `pinned_cpa_unconditionally_starts_antigravity_version_updater` and
  `candidate_descendant_containment_unavailable`. No fixture flag, supplied
  hash, generic endpoint, old local success, peer admission or waiver removes
  them. No reference patch or duplicate deployment is made.
- Future result source/driver/fixture/dependency/executable/shipment hashes
  are all **null**, as are contract/historical-manifest/clients-lock bindings.

Every actual future result needs owner-qualified source, driver, approved
fixture, dependency, executable, shipment, contract and target bindings.
Actual local adapter/fixture byte checksums are preparation bookkeeping only.
Inspected source revisions and peer checkpoint revisions are not substituted
for any missing run-bound hash.

## Focused validation and handoff

Run only the F32 tests, with imports, API/CLI calls and audit controls inside
the existing safe process/network guard:

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/parity python3 - <<'PY'
import json
import unittest
import safe_unit_tests

with safe_unit_tests.execution_guards():
    suite = unittest.defaultTestLoader.loadTestsFromName('test_f32_kimi')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
print(json.dumps({
    'evidence_class': 'provider-preparation-unit', 'tests': result.testsRun,
    'status': 'passed' if result.wasSuccessful() else 'failed',
    'paired_execution': 'not_run', 'cpa_execution': 'not_run',
    'mimic_execution': 'not_run', 'native_acceptance': 'not_run',
    'live_verified': 'not_run',
}, separators=(',', ':')))
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
```

The focused checks cover paired deep-copy isolation, provisional historical
IDs/tuples/fixture bytes/inherited checks, provider/domain separation, exact
raw wire preservation, authored positive/negative payload intent, null result
hashes, nonwaivable blockers and CLI rejection/sanitization. Guard controls use
audit events, not attempted process or network operations. These checks do not
exercise the provider implementation or execute a differential comparison.

Final focused result: **29 tests passed**, under `execution_guards`, against
all **20** proposed cases. Paired/CPA/MIMIC/native/live execution remains
`not_run`; this is preparation-unit evidence only.

The four owned-file SHA-256 hashes are returned in the handoff after the last
byte changes. The document does not embed its own
self-referential digest. Full Gleam/format/build/source/shipment/native/live
gates, compiled F01 mapping and peer-checkpoint import are **not run here**.
No heavy gate slot was used. Minimal root integration patch: **none**.
