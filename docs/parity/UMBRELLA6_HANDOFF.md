# F30–F34 umbrella 6 preparation handoff

**Local, unpublished preparation. Not differential evidence or release approval.**

The canonical wave plan is coordinator-owned `docs/FINAL_PARITY_WAVE.md`.
This handoff records only this umbrella's scope, checks and blockers; it is
not a second wave plan.

This umbrella owns F30–F34 provider-specific cases, plan adapters and reports.
It does not own provider implementation, the common contract/matrix (F01),
reference qualification/launch (F03), root wiring or CI. Implementation is
delegated one slice per child, with at most one implementation child active.

## Verified starting point

The attached worktree was clean at `c3ca7e805b8e4c3f8271468fbbe46271a5b0e8f4`.
After adding the requested GitHub source remote and fetching through JJ, a
clean change was created on exact
`ca86b531cea7e1a509ac8e6038604fe91819ac07`. The `local` remote was not used
for publication. No sibling/primary checkout was edited.

`docs/NEXT_PARITY_MERGE_VALIDATION.md` records 698 Gleam and 92 Python tests,
full-source/shipment gates and their limitations. Those are historical
integration results, **not parity**. This umbrella has not re-executed the
full gate or independently re-verified CI.

Initial local checks:

- `python3 scripts/parity/safe_unit_tests.py`: **47 passed**, under its
  process/network audit guard. Candidate build/runtime, CPA execution and
  live verification were all `not_run`.
- `mise exec gleam@1.18.1 -- gleam --version`: `gleam 1.18.1`.
- No nested `AGENT.md` or `AGENTS.md` found beneath `scripts`, `test`, `docs`.

| Unmodified baseline input | SHA-256 |
| --- | --- |
| `docs/NEXT_PARITY_MERGE_VALIDATION.md` | `8a87f8fa0ddcc8914b6b31d384f237a9f51ee1bdb45ca39f0e60502a14b04f9d` |
| `scripts/parity/reference_driver.py` | `3b3a0f9e2fbcc8e2f975d8f0c3cdcaaf3787a0b7bbd14d4527ed97f461b9bcdc` |
| `scripts/parity/safe_unit_tests.py` | `cf547a7ccf5dbee1504c1b75bf30a8b6011ef2a3b0c375deef6a0927fc691c32` |
| `test/parity/v2/manifest.json` | `3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9` |

## Slice boundaries and admission prerequisites

| Slice | Required scope | Execution prerequisites |
| --- | --- | --- |
| F30 Claude | Messages/counting/SSE; ordered, cased duplicate headers; body/target; policies; OAuth/refresh; request versus credential error scope | F03, F08–F10 |
| F31 Codex | Separate HTTP/compact/Lite/WS; histories/reasoning/tools/usage; scope/errors/cancel/failover/restart | F03, F12–F13 |
| F32 Kimi | Native versus generic registrations; both OAuth domains; Chat/Responses/Messages; tools/media controls; ordered headers | F03, F14–F16 |
| F33 Grok | API-key/OAuth and API/proxy; tools/continuation/WS; source-qualified image/video; exact failure scope | F03, F07, F17–F21 |
| F34 Devin | Native Connect/protobuf and client projections; bounded known-synthetic binary evidence | F03, F23–F29 |

Dependencies are **not admitted here**. Preparatory synthetic cases are not
approved runtime routes. Generic endpoints, old local fixtures, source
inspection, mocked results and plan validation cannot count as CPA execution.
The base Claude conservative all-429-to-503 behavior must not be described as
genuine-quota failover. Codex full-history replay versus CPA `previous_response_id`
deletion is a decision-required difference, never normalization.

## Shared contract, not five harnesses

Foundation's announced seam is a nonexecuting
`scripts/parity/contract.py` with `load_contract`, `validate_contract`,
`select_rows`, `case_plan` and `summary`. Its owned inventory is
`docs/parity/final-v1/contract.json`, schema
`mimic.final-parity-contract/v1`, scope `mimic-final-v1`.
At this draft checkpoint this is a peer-announced contract, not a locally
imported or compiled artifact.

Historical row IDs and their five-field tuples/fixture hashes stay unchanged.
The primary case ID is `<row-id>.final-v1`. Extensions use additive
`final-v1-*` IDs with explicit versions. F01 alone admits new required rows.
Provider-specific scenario IDs must map explicitly to that inventory; they
cannot silently replace it.

`case_plan(contract, row_id)` returns schema `mimic.final-parity-plan/v1`,
the contract hash, scope, CPA revision, a copied row and copied cases.
Provider preparation must preserve request target/body and ordered header
lists, not convert headers to dictionaries. Launch, containment, common
comparison and report admission remain shared responsibilities.

## Hard stops and future result requirements

- Historical strict CPA conformance remains **0/37**. Missing, unsupported,
  skipped or wrongly bound required cases block admission.
- CPA `https://localhost:8317` was only reported by the initiating coordinator
  as responding to an unauthenticated root GET with valid TLS. This umbrella
  has not contacted it. That observation does not qualify identity, config,
  source pin, fixture routing or containment.
- Historical pin `acdace936fa7df2905500c7f5e0a97d683138dea` retains its
  unconditional updater and descendant-containment blockers. Source-v3 hard
  blocks stay enforced until their owner resolves them; no waiver, silent
  reference patch, duplicate deployment or service reconfiguration.
- Every actual result must bind source, driver, fixture, dependency,
  executable and shipment hashes plus the common contract and qualified
  target identity. Unknown bindings are missing, not invented digest values.
- Use identical approved synthetic stimuli on both qualified targets and
  independent synthetic account state. Never share rotating grants between
  CPA and MIMIC managers.
- Hardening differences require an explicit decision; they cannot produce a
  green exact-match result.
- Binary evidence must be bounded and known synthetic. Base64 is an encoding,
  not redaction. Devin credentials also occur inside protobuf bodies.
- No native clients, actual providers, logins or ambient credentials are
  authorized for this task. Standing live permission still requires F04 and
  explicit accounts/endpoints/models/data/budgets; Claude needs its extra
  CPA check, and Devin remote/live qualification is separate.

## Handoff protocol

Each slice sends `READY_FOR_ADMISSION(slice, JJ revision/bookmark, hashes,
compiled contract, minimal root patch, focused gates)` with preparation-only
versus execution-ready status explicit. No root patch is presumed.
Heavy checks send `READY_FOR_GATE(revision, command, bound)` to the initiating
coordinator before using its serialized slot. Gleam checks use
`mise exec gleam@1.18.1 -- ...`; full tests/format/shipment remain unverified
in this umbrella until actually run against an identified snapshot.

No automatic push, release, shared-branch rewrite, or other umbrella creation.

## Delivered preparation checkpoint

All five implementation slices have completed, one child at a time. They
provide provider-only case loaders, independent identical paired stimulus
plans, and blocked readiness reports. They do **not** provide five execution
harnesses or a substitute for F01/F03. Each CLI exits 2 for blocked preparation
and 1 for invalid input; there is no run/admission flag.

| Slice | Proposed synthetic scenarios | Focused guarded tests |
| --- | ---: | ---: |
| [F30 Claude](final/F30_CLAUDE.md) | 20 | 18 |
| [F31 Codex](final/F31_CODEX.md) | 23 | 22 |
| [F32 Kimi](final/F32_KIMI.md) | 20 | 29 |
| [F33 Grok](final/F33_GROK.md) | 13 | 19 |
| [F34 Devin](final/F34_DEVIN.md) | 25 | 31 |
| Total | **101 proposals, not required matrix rows** | **119** |

The parent reran all five suites together with the unchanged 47-test safe
harness suite: **166 passed**, with imports and test execution inside
`safe_unit_tests.execution_guards`. This is preparation/harness-unit evidence
only; CPA/MIMIC/provider/native/live execution was `not_run`.

An independent read-only F34 review also reran its 31 guarded tests and found
no blocking preparation defect: closed bounded synthetic vocabulary, unknown
credential rejection, partial-sketch labeling, blocked outcomes and separation
of peer-reported F23 admission from local qualification all held. This is not
an independent runtime or differential review.

```sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=scripts/parity python3 - <<'PY'
import unittest
from safe_unit_tests import execution_guards, suite
with execution_guards():
    tests = suite()
    for name in ("test_f30_claude", "test_f31_codex", "test_f32_kimi",
                 "test_f33_grok", "test_f34_devin"):
        tests.addTests(unittest.defaultTestLoader.loadTestsFromName(name))
    result = unittest.TextTestRunner(verbosity=1).run(tests)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
shasum -a 256 -c docs/parity/final/UMBRELLA6_SHA256SUMS
```

[The checksum inventory](final/UMBRELLA6_SHA256SUMS) binds the 20 delivered
provider files only, not this handoff or itself. These are local byte hashes,
not executable/shipment/dependency qualification. All future run-bound hashes
in reports are still null. Root patch: **none**; no common runner, gate,
manifest, production source, dependency, root build or CI file changed.

### Corrections and interruption history

- F31's first child stopped without a verified delivery. Its later completion
  auto-imported two unfinished drafts; the parent removed them before the
  replacement child's four-file delivery. Those drafts are not retained.
- F33's first child stopped and failed its continuation with a model-response
  read error. No files reached the parent. One replacement completed F33.
- F31's parent-reviewed successor distinguishes executor upstream HTTP/WS
  fidelity from downstream `/v1/responses` framing. Earlier assembled raw
  preservation inference is withdrawn; full-path source review is an explicit
  blocker. Earlier F31 admission hashes are superseded by this inventory.
- F32's successor labels F14 as coordinator-reported admitted at
  `643941e03e943c501271aca889f387202045cb45`, **not imported/run-bound here**,
  rather than globally pending. F15 is similarly peer-reported admitted.
  Earlier F32 admission hashes are superseded by this inventory.
- F23 experimental local Chat SSE is reported admitted at the coordinator,
  not imported or qualified here. F34 does not infer Messages/Responses,
  remote transport, raw trailers or exact status fidelity from that checkpoint.
- F09's corrected successor was reported as
  `2ca01f015fad2f11d41766300b52948937c3fe24`: beta stage ordering is
  header/profile plus advisor before protocol/body extras, then final gates.
  F30 has not imported the earlier goldens; future mapping must use the
  corrected contract and full-alias Haiku predicate.

F01's corrected frozen catalog and F03 qualification remain unavailable here.
No report may turn source inspection, plan validity or mocked expectations
into differential success. Full Gleam/format/source/shipment/CI gates were
not rerun for this preparation-only change; they remain coordinator-controlled.
