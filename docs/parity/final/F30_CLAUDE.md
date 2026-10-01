# F30 — preparatory Claude differential fixtures

**Execution is blocked. These are unapproved SYNTHETIC plans, not CPA/MIMIC
paired results. Historical strict37 remains 0/37.**

Base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
CPA source reference: `acdace936fa7df2905500c7f5e0a97d683138dea`.
These pins identify source intent; neither is an executable or shipment hash.

## Owned scope

- `scripts/parity/f30_claude.py`: provider-only payload loader, preparation plan
  and blocked-readiness report.
- `scripts/parity/test_f30_claude.py`: pure focused unit controls.
- `test/parity/final/f30_claude.json`: 20 synthetic scenario definitions.
- This report.

No root, CI, common lab/gate, shared harness, production provider, credential
manager, launch/exercise harness or common parity contract is changed.
No worker is spawned. No target, provider, native client, login or listener is
run; no ambient credentials are read. The existing CPA at
`https://localhost:8317` is unqualified and must not be contacted or mutated.

## Provider adapter, not a second harness

`load_fixture(root)` reads only the provider JSON payload.
`case_plan(value, scenario_id)` makes independent, identical copies of the
entire stimulus for future CPA and MIMIC targets. `blocked_report(root,
scenario_id=None)` lists plans, missing bindings and local file-byte SHA256s.
The optional `--case` CLI only prints preparation; it returns **2** for blocked
preparation and **1** for rejected/missing payloads. It has no `--run`, endpoint,
credentials, process, waiver, admission or execution option.

Existing `reference_driver.py` and `local_driver.py` supply the concepts:
authenticated assembled ingress, separately observed upstream requests,
ordered raw header lists, raw body text, fixture identity and target identity.
They are deliberately not imported or forked: their launch/exercise paths are
outside this slice.

The provider payload has schema `mimic.f30-claude-fixtures/v1`, and its plan has
schema `mimic.f30-claude-preparation/v1`. Neither substitutes for
`mimic.final-parity-contract/v1` or `mimic.final-parity-plan/v1`.
All fixtures have `approval=pending_f01_mapping_and_qualification`.

The F01 owner supplies the nonexecuting `contract.py` API:
`load_contract(root)`, `validate_contract(value, root)`, `select_rows(contract,
provider=None)`, `case_plan(contract, row_id)` and `summary(contract)`, with
`docs/parity/final-v1/contract.json` as the common data source. The provider
adapter does not create, validate, patch, auto-import or claim qualification
of that contract. F01 reconciliation must retain its `contract_sha256`,
`scope_id`, historical fixture/hash, exact row tuple, source assessment,
all historical `required_checks`, universal checks and added observations.
Provider scenario IDs below are proposed additive probes, not replacements for
the primary `<historical-row-id>.final-v1` cases.

## Planned cases and pending mapping

Every scenario ID below has prefix `final-v1-claude-`. `row_id` and
`primary_case_id` explicitly reference unchanged historical IDs in
`test/parity/v2/manifest.json`. This is a proposed mapping, never row admission.

| Scenario suffix | Historical row | Purpose |
|---|---|---|
| `messages-wire` | `claude-messages` | Cased/ordered/duplicate ingress and response headers; exact query target, UTF-8 whitespace and extensions; selected API-key isolation |
| `count-wire` | `claude-count` | Separate actual count endpoint/profile and field pruning; scripted synthetic count, not local estimation |
| `sse-tool-thinking` | `claude-thinking` | OAuth Messages SSE, CRLF/comment framing, split `data` field, thinking/signature/tool/usage/terminal data |
| `native-forced-tool` | `claude-tools` | Forced-tool thinking/effort and native sampling/beta policy |
| `translated-five-minute-policy` | `claude-messages` | Already-translated Claude JSON, trusted explicit policy, 5m opt-in; not OpenAI chat translation |
| `subagent-explicit-hour` | `claude-messages` | Trusted subagent policy; explicit valid 1h cache, API-key beta pairing |
| `helper-hour-rejected` | `claude-oauth` | Helper explicit 1h rejection versus CPA stripping; request-scope hardening difference |
| `invalid-cache-order` | `claude-messages` | 1h after 5m rejected instead of deleted/downgraded |
| `duplicate-user-id` | `claude-oauth` | Duplicate/escaped duplicate metadata remains raw; request rejection, not bad credentials |
| `refresh-singleflight` | `claude-oauth` | Expiry, two waiters, one exchange, rotation/private identity/generation and restart intent |
| `refresh-duplicate-envelope` | `claude-oauth` | Ambiguous duplicate grant response, uncertainty fence, no unsafe retry |
| `refresh-429-json` | `claude-oauth` | Unambiguous token-endpoint JSON 429 and persisted completion-time gate, distinct from Messages 429 |
| `request-model-mismatch` | `claude-messages` | Trusted selected-model/body mismatch before send; independent-model binding required |
| `request-400` | `claude-messages` | Request-scoped rejection, no credential poisoning/pool walk |
| `credential-401` | `claude-messages` | Credential-scoped first-account rejection; separately qualified no-pin A→B retry intent |
| `messages-429-fast-refusal` | `claude-oauth` | OAuth fast-mode refusal-looking 429 remains conservative, not classified request scope |
| `messages-429-quota` | `claude-messages` | API-key quota-looking 429 remains conservative, no genuine quota failover claim |
| `refresh-invalid-grant` | `claude-oauth` | Unambiguous definitive token grant rejection, distinct from uncertain refresh outcomes |
| `refresh-429-ambiguous` | `claude-oauth` | Contradictory duplicate token error fields, no quota/invalid-grant inference from status or last value |
| `request-403` | `claude-messages` | Base nonretrying permission rejection, not assumed credential poisoning or universal 403 classification |

These probes are not complete row coverage. Models discovery, OpenAI chat
translation, image acceptance/rejection, full tool-result continuation and full
thinking replay are not supplied or admitted here. The OAuth-row auxiliary
probes do not replace expiry/refresh coverage. F01 owns additive ID/version
approval and final mapping.

## Wire and identity fidelity

- Stimuli and both future copies preserve header pair order, duplicates and
  name case; target strings and UTF-8 body text are not sorted, trimmed or
  decoded/re-encoded. Provider JSON duplicates are intentionally **inside raw
  strings**; duplicate keys in the fixture envelope itself are rejected.
- Capture incoming headers and actual outgoing headers separately. No assertion
  assumes arbitrary incoming headers survive gateway/provider policy. The base
  gateway currently supplies an empty provider header list, so caller beta
  forwarding must be qualified rather than silently assumed.
- Capture raw response/SSE bytes before semantic checks. Scripted `body_chunks`
  describe an input schedule, not proof that downstream TCP reads use identical
  chunk boundaries. Preserve that schedule and frame bytes as separate facts;
  do not reframe or normalize mismatches. Synthetic counts, signatures, model
  names and usage are fixture data, not upstream measurements or entitlements.
- Authentication uses the explicit `synthetic-client` marker on the client leg.
  `synthetic-a`/`synthetic-b` name future isolated fixture credential slots, not
  real secrets. Seed values, account/device/organization/session metadata,
  scheduler ordering, clock/barriers, upstream origins and token endpoint are
  **not bound or qualified yet**. Both targets require the same approved
  synthetic seed plan; no ambient discovery or real grant is a substitute.
- OAuth identity comes from the selected private fixture credential, never
  caller auth/UA/body hints. No production profile, native-client detector,
  fake fingerprint, cloak, registry capability inference or companion network
  workflow is implemented. Unknown IDs, fields, policy/profile, transport,
  non-text bodies and nonidentity compression reject explicitly.
- No normalization is authorized, including volatile request/session IDs.
  Any unavoidable runtime-generated differences need an explicit F01/operator
  decision, not an automatic match. Real credentials/private payloads must never
  enter observations, logs, metrics, grounding packs or reports.

## Exact error-scope intent, not executed classification

`expected` describes source-backed MIMIC intent or a proposed observation, not
the CPA result. `failure`/`send_state` are boundary labels where known; `null`
means unspecified, **not verified**. `retry` refers to automatic Messages pool
replay, not authorization to rerun token exchanges. `quota_effect=none` refers
to the Messages quota ledger, not the distinct persisted refresh gate.

| Input | Expected scope/boundary | Required observation |
|---|---|---|
| Invalid policy/cache/duplicate user ID/model-context mismatch | Request; `Unsupported/NotSent` | Zero upstream requests; no pool replay or credential/quota mutation. Independent model and trusted-policy routes still need bindings. |
| Messages HTTP 400 | Request; no typed adapter rejection at base | Base buffered gateway sanitizes to 502. One A request, none to B; valid A follow-up and unchanged credential/quota state. CPA downstream differences require a decision. |
| Messages HTTP 403 | Base nonretrying path; no typed credential rejection | Base buffered gateway sanitizes to 502, without pool walk. Exact body-aware request-versus-credential policy remains unqualified; no universal permission-error classification is claimed. |
| Messages HTTP 401 | Credential; `CredentialUnavailable/Rejected` | Base runtime marks retryable only without an account pin. A→B ordering and successful second response are proposed observations, not proof of execution or durable quarantine. |
| Unambiguous token `invalid_grant` | Credential-refresh; provider callback `InvalidGrant` | Runtime requires reauthorization; no Messages send or unsafe token replay. Not request error, uncertainty or quota. |
| Malformed/duplicated OAuth grant envelope, including HTTP 429 | Credential-refresh uncertainty; `RefreshUnavailable` | No Messages execution or unsafe token retry; retain recovery fence/generation across restart. Not request error, definitive invalid grant, or quota. |
| Unambiguous token-endpoint JSON HTTP 429 | Credential-refresh gate; `RefreshRateLimited` | With synthetic completion time 1000 ms and Retry-After 17 s, proposed gate is 18000 ms; both waiters share completion time. No Messages quota inference. |
| **Any Messages HTTP 429** | Ambiguous response; `Unsupported/Rejected`, sanitized **503** | Close before body read/runtime observation, one A request, none to B, unchanged quota ledger, no automatic cooldown/failover/retry hints. |

F10 is **not admitted**. A quota-looking body is not evidence of genuine
credential-quota classification, and a fast-mode-looking body is not evidence
of request entitlement classification. The base closes without reading either.
Counting and streaming use the same conservative constructor; the two supplied
429 probes are buffered, not a claim of full auth × operation matrix coverage.

CPA stripping invalid cache TTLs versus MIMIC rejection, helper policy,
duplicate JSON/refresh uncertainty, sanitized downstream errors, and conservative
429 availability are explicitly `decision_required`. Never relabel them
`matched` or hide them through header/body normalization.

## Readiness blockers and provenance

Every provider plan/report remains blocked, regardless of preparation success:

1. This adapter is intentionally nonexecuting.
2. F01 common-contract mapping, approved fixture set and bindings are pending.
3. F03 and F08–F10 are not admitted; no dependency hashes are verified here.
4. Actual paired CPA/MIMIC driver, authenticated ingress, target/executable and
   shipment, origin/token-fixture, seed/identity, clock/barrier, scheduler and
   operator-policy bindings are unqualified.
5. `https://localhost:8317` has unqualified identity; do not contact or mutate it.
6. Every future result needs **source, driver, fixture, dependency, executable
   and shipment hashes**, plus its F01 contract hash. Bind the exact CPA source,
   both targets/drivers, all dependency admissions and actual shipped bytes;
   a source revision or a local file checksum is not a run-bound verification.
   `future_result_hashes` are all `null` with
   `hash_binding_status=unknown_not_verified`. `local_file_sha256` records only
   the actual provider adapter/fixture bytes read in preparation.
7. SourceV3 hard startup blocker
   `pinned_cpa_unconditionally_starts_antigravity_version_updater` remains.
8. SourceV3 hard descendant blocker
   `candidate_descendant_containment_unavailable` remains. Same-PGID cleanup
   is not detached-descendant containment. No field, flag or preparation can
   waive either hard blocker.

Source inventory/historical handoff reports are references, not new verified
source archives or CPA observations. Historical `0/37` and sourceV3 safety
limits are retained from `docs/parity/REVIEW_FIXES_V3.md`.

## Focused validation

Only the following provider-specific suite is authorized in this slice. Suite
loading/import and test execution both occur inside the existing audit guard.
Do not add this module to the shared allowlist or run broad discovery/full gates
as part of F30.

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/parity python3 - <<'PY'
import unittest
from safe_unit_tests import execution_guards
with execution_guards():
    suite = unittest.defaultTestLoader.loadTestsFromName("test_f30_claude")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
```

Executed final focused run: **18 passed, exit 0** (0.259 seconds reported by
unittest), covering all 20 provider scenarios. An earlier 10-second bounded
rerun returned no test output and timed out; the same focused command with a
30-second terminal bound completed successfully. The timeout has no passing
evidence and its cause was not established. Counts are not cumulative.

Tests cover preservation/deep-copy, explicit pending mapping, blocked
reports/unknown hashes, error-scope distinctions, unknown/unsupported/lossy input
rejection, nonzero blocked CLI status and audit event rejection. They do not
launch CPA/MIMIC, bind a port, resolve DNS or prove paired/provider/native
behavior.

Gleam formatting/tests, full gate, heavy builds, actual paired runs, shipment,
native/live provider validation and final sourceV3 qualification are **not run**.
The coordinator owns serialized heavy execution.

## Minimal root integration patch

**None.** Import/review only these four owned files. F01/the coordinator can later
map approved provider scenarios through the common nonexecuting contract API,
without adding another launcher or weakening a gate. That future qualified
integration is deliberately not implemented or auto-selected here.
