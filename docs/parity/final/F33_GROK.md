# F33 — Grok provider preparation only

**SYNTHETIC, UNAPPROVED, NONEXECUTING. Every plan/report is blocked and every
execution/assertion is `not_run`. Historical strict CPA conformance is unchanged
at 0/37. This is not a route qualification, differential result or shipment.**

Only four F33 files are owned: `scripts/parity/f33_grok.py`,
`scripts/parity/test_f33_grok.py`, `test/parity/final/f33_grok.json` and this
document. No root, CI, common-contract, harness, matrix, provider-production or
other worker files are changed. **Minimal root patch: none.**

## Nonexecuting API

The adapter follows F30–F32's provider-only pattern:

- `load_fixture(root=ROOT)` reads and guards this explicit local provider
  payload. It does not import the common contract or admit dependencies.
- `case_plan(value, scenario_id)` returns independent deep copies of identical
  synthetic context and turns for future `cpa` and `mimic` targets. Assertion
  names and expected controls are intentions, never evaluated results.
- `blocked_report(root=ROOT, scenario_id=None)` returns blocked readiness,
  unadmitted dependencies, source/runtime unknowns, the F17 peer finding and
  actual local SHA-256 digests of the four owned files.
- `main(argv=None)` is a report-only CLI with `--case`. Valid preparation returns
  **2**; unknown cases, invalid arguments or invalid/unavailable payloads return sanitized
  **1** rejection with execution `not_run`. It has no launch option.

There is no launcher, comparator, admission harness, continuation API,
credential lookup or provider callback. Imports are limited to standard-library
argument parsing, copying, JSON, hashing, local paths and exit handling.

## Historical mapping, not a replacement inventory

Prepared against MIMIC base `ca86b531cea7e1a509ac8e6038604fe91819ac07` and
historical CPA pin `acdace936fa7df2905500c7f5e0a97d683138dea`.
These source labels are not source verification or future executable bindings.
The unchanged `test/parity/v2/manifest.json` contains these five-field tuples:

| Historical row | Provider | Auth | Input protocol | Upstream mode | Capability |
| --- | --- | --- | --- | --- | --- |
| `xai-api` | `xai` | `api_key` | `chat_completions` | `xai_api` | `http_backend_identity` |
| `xai-oauth` | `xai` | `oauth` | `responses` | `grok_build` | `http_backend_identity` |

Both historical source statuses are `pending`. Each proposal explicitly maps
to one row and its `<row>.final-v1` primary ID, with `provisional_pending`
mapping. The provider scenario IDs are versioned `final-v1-grok-*` extensions,
not new denominator entries. Responses/compact/tool controls mapped to
`xai-api` are additive protocol controls; they do **not** silently replace its
historical Chat tuple. API-key/OAuth and API/proxy remain distinct identities
with distinct symbolic synthetic origin slots.

F01's common contract is **not imported or frozen** here. Mapping and fixture
approval remain pending. The provider schema is not
`mimic.final-parity-contract/v1` or `mimic.final-parity-plan/v1`; provider-only
checks cannot confer those contracts' admission. No global matrix or required
row additions are made.

## Thirteen bounded proposals

All IDs below have prefix `final-v1-grok-`. Targets are proposed ingress/control
strings, not supported-route declarations.

| Suffix | Historical mapping | Purpose / unresolved qualification |
| --- | --- | --- |
| `api-identity` | `xai-api.final-v1` | API-key/API, raw Chat target/query/JSON and ordered duplicate headers |
| `oauth-proxy-identity` | `xai-oauth.final-v1` | OAuth/proxy selection; independent account/manager state, no API fallback |
| `tools-sse-full-history` | `xai-api.final-v1` | Tool declarations, argument chunks, names/call/item IDs, opaque reasoning, usage and full-history result turn; no receipt authority |
| `continuation-http-blocker` | `xai-api.final-v1` | Ordinary Execute reference deletion versus local rejection; decision required |
| `continuation-sse-blocker` | `xai-oauth.final-v1` | ExecuteStream also deletes the reference; SSE does not establish continuation |
| `continuation-compact-blocker` | `xai-api.final-v1` | Compact alone re-adds the reference on a separate base; not ordinary HTTP support |
| `ws-source-runtime-blocker` | `xai-oauth.final-v1` | Raw logical text payload/close and orphan/cross-scope controls; physical source/runtime unknown |
| `image-source-runtime-blocker` | `xai-api.final-v1` | Nested image shape must not disappear; exact image operation/encoding/assembled route unknown |
| `video-source-runtime-blocker` | `xai-oauth.final-v1` | Nested synthetic video shape; exact video operation/frame/encoding/assembled route unknown |
| `request-400` | `xai-api.final-v1` | Invalid request: REQUEST, classified 400, no credential reauthorization |
| `request-403-permission` | `xai-oauth.final-v1` | Permission/model 403 without auth markers: REQUEST, classified 403 |
| `credential-401` | `xai-api.final-v1` | CREDENTIAL, classified 401, selected-account reauthorization intention only |
| `credential-403-bad-credentials` | `xai-oauth.final-v1` | Exact nested `bad-credentials`/token-validation marker: CREDENTIAL, classified 401 |

The four error controls retain exact status/body distinctions from the local
`xai/errors.gleam` classifier as **planned** constraints. They do not execute it
or prove assembled scope mapping. Permission 403 and bad-credential 403 are
deliberately not equivalent. CREDENTIAL reauthorization does not authorize
replay: inference delivery remains conservatively `Uncertain`, and all controls
have `retry=false`. REQUEST errors must not disable/refresh a credential or
trigger account failover. No blanket quota or status-only retry policy is added.

Wire storage preserves raw UTF-8 target/body strings, query order/escaping,
JSON whitespace/extension order, ordered and case-sensitive duplicate header
pairs in both directions, and raw SSE chunks. Provider JSON is not
decoded/re-encoded by the adapter; envelope duplicate keys fail closed.
SSE chunks intentionally split a `data:` prefix and keep CRLF, heartbeat,
argument fragments, opaque reasoning and terminal usage. WS text payloads and
close code/reason stay exact and ordered. They are **logical synthetic
stimuli**, not masking/framing bytes or a measured physical WS fingerprint.
Non-UTF-8, binary, compressed and unsupported protocol representations are
explicitly rejected rather than corrupted. No comparator or normalization runs.

## F17 is a blocker, not a continuation implementation

The supplied F17 **peer finding**, not an independently imported F33 source
qualification, says historical `Execute` and `ExecuteStream` delete
`previous_response_id` inside `prepareResponsesRequestTo`. Compact alone
re-adds it on a **separate base**. Its reasoning/model/session cache is **not a
qualified receipt and does not establish isolation**.

The reference contract remains `unsupported-reference-contract`, feature
**BLOCKED**, with **no production continuation API**. All three HTTP reference
controls retain the raw ID, supply no synthetic successful receipt and remain
decision-required. No full-history reconstruction, receipt authority,
cross-account replay or generalization from compact is implemented.
The local request helper's field behavior and bridge's rejection are context,
not assembled qualification or a reason to normalize away this difference.

F03, F07 and F17–F21 are all `not_admitted`. Media and WS source/runtime
qualification is unknown. Catalog entries, provider URLs, old fixtures,
endpoint planners and source helpers cannot manufacture supported routes.
An executor finding is **not assembled route qualification**. Image/video
cases are shape/rejection blockers on a proposed Responses target, not invented
generation/upload endpoints. The `.invalid` media URLs are inert raw JSON and
are never fetched. Even a scripted WS 101/terminal confers no completed receipt.

## Unchanged hard stops and missing bindings

Every plan/report retains:

- F01 mapping/approval pending and all seven dependencies unadmitted.
- The sourceV3 unconditional Antigravity version-updater startup blocker and
  descendant-containment blocker, with no patch, waiver or service change.
- CPA localhost:8317 identity **unknown**, **do not contact**. No probe,
  reconfiguration, duplicate deployment or claim of qualification is made.
- Unqualified paired target, driver, fixture and account/manager bindings.
- Future `source`, `driver`, `fixture`, `dependency`, `executable`, `shipment`
  and `contract` result hash bindings **null**, `unknown_not_verified`.

`local_file_sha256` describes actual local file bytes only. Those four values
are distinct from, and never substituted for, the missing future run bindings.
Historical strict CPA conformance remains **0/37 unchanged**.

## Focused guard-only validation

Verified locally: **19 focused preparation tests passed** under
`safe_unit_tests.execution_guards`, including in-process CLI blocked **2** and
rejected **1** checks. This is unit evidence only; no target execution occurred.

Run only the F33 pure unit suite under the existing process/network guard;
the shared suite allowlist is unchanged:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import sys
import unittest
sys.path.insert(0, "scripts/parity")
from safe_unit_tests import execution_guards
with execution_guards():
    suite = unittest.defaultTestLoader.loadTestsFromName("test_f33_grok")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
```

Each test also enters `safe_unit_tests.execution_guards`. CLI tests call
`main` in-process; guard controls emit synthetic audit events, not subprocesses
or socket operations. Tests check independent paired copies, byte preservation,
historical mapping, precise scope controls, F17/media/WS blockers, null future
bindings, four local hashes and sanitized CLI exit codes. They are
preparation-only unit evidence, not CPA/MIMIC/provider execution.

No actual process/network target, CPA service, MIMIC runtime, provider, native
client, login or ambient credentials are exercised. Gleam tests/format, full
Python discovery, source/driver qualification, executable/shipment checks,
differential and live/native gates are **not run**. No heavy gate or publication
is requested or implied. The next step is owner-led F01/dependency/reference
qualification, not running this payload as a route test.
