# Executable FINAL-v1 parity contract

The F01 **offline contract implementation works**: consumers can validate the
pinned inventory, select rows and prepare identity-bound cases. This is not a
CPA launcher, provider implementation, assertion evaluator or release gate.
Historical strict conformance remains **0/37**.

The canonical data is [final-v1/contract.json](final-v1/contract.json#L1), read
by [contract.py](../../scripts/parity/contract.py#L1). The separate FINAL wave
requirements remain [FINAL_PARITY_WAVE.md](../FINAL_PARITY_WAVE.md#L79).
Read [the source map](final-v1/SOURCE_MAP.md#L1) for bounded findings and
[the handoff](final-v1/HANDOFF.md#L1) for actual validation and blockers.

## Versions and preserved history

- Schema `mimic.final-parity-contract/v1`, scope `mimic-final-v1`, version 1.
- CPA source pin: `acdace936fa7df2905500c7f5e0a97d683138dea`, unmodified.
  Its archive SHA256 is
  `56c970726edbd07591b77c1b6be18f733368f8a2f52a2f0931c928b30c13b540`.
- The later reviewed source `97f244b8ddb9cbf564b6e6faab0159102cca8617` is
  **comparison only**, not a replacement pin. See [DRIFT.md](final-v1/DRIFT.md#L1).
- Native-client pins are the exact read-only
  [clients.lock.json](../../scripts/native-clients/clients.lock.json#L1) bytes,
  SHA256 `c3e2985192d3725e4ddd2a8ff0634630a5a0798af393182c443e00f5ddfbf85a`.
  Claude `2.1.284` and Codex `0.158.0-linux-x64` are pinned inputs, not executed
  workflows. Kimi, Grok and Devin remain inventory-only/blocked clients.
- All 37 historical IDs, five-field tuples, source markers, required checks,
  fixture paths and fixture bytes are preserved. Their manifest SHA256 is
  `3967cf7f03aff95d39f57d6b2590caecec5ba3f367bab11bde0f233121eb06d9`.
  The historical fixture inventory digest is checked independently; updating a
  row's fixture hash cannot authorize changing old fixture bytes.
- Primary case IDs remain `<historical-row-id>.final-v1`. A new required row
  must use `final-v1-*` and a declared extension/version. There are **no admitted
  extension rows** in this checkpoint.
- A separately versioned operation inventory inside the same document records
  25 mode/scope findings. It adds **zero** rows or passes to the historical
  denominator. Conditional media, unsupported core routes and product proposals
  cannot be converted into successful required support by editing a label.

The historical 22 `source_status: pending` markers are immutable history.
Current bounded mapping is **14/22 mapped, 8 unresolved**; across all 37 rows,
28 are mapped and 9 are partial. `mapped` means a bounded source mapping,
not supported runtime behavior, full configuration qualification or a pass.
Known source differences remain blocking differences rather than normalization.

## Consumer API

```python
from scripts.parity import contract

frozen = contract.load_contract(root=contract.ROOT, source_dir=None)
contract.validate_contract(frozen.document, root=frozen.root, source_dir=None)
rows = contract.select_rows(frozen, provider="kimi")
pins = contract.native_pins(frozen)
plan = contract.case_plan(frozen, row_id="codex-sse")
report = contract.summary(frozen)
operations = contract.select_operations(frozen, provider="xai")
```

- `load_contract(root=ROOT, source_dir=None) -> Contract`: immutable root/raw
  bytes; `.sha256` binds the exact contract bytes, `.document` returns a fresh
  decoded dictionary.
- `validate_contract(value, root=ROOT, source_dir=None) -> None`: raises
  `ContractError` on invalid scope, stale inputs or unsupported claims.
  The optional source directory must be the exact historical public tree;
  every file and inclusive line span is checked. Structural validation alone
  cannot establish that source authenticity check or executable identity.
- `select_rows(contract, provider=None) -> list[dict]`: complete historical
  rows plus explicitly versioned extensions. Unknown/excluded providers fail.
- `case_plan(contract, row_id) -> dict`: nonexecuting synthetic plan, including
  every historical check and universal ingress/identity/wire/security check.
- `summary(contract) -> dict`: distinct mapping, unresolved source, inventory
  and runtime counters. Always zero runtime passes; no destination admission.
- `native_pins` and `select_operations` are additive read-only metadata seams.
  No F30–F34 provider file or common runner was changed.

The `case_plan` shape retains the early F30–F34 interface:

```text
schema = mimic.final-parity-plan/v1
scope_id, contract_sha256, cpa_revision
historical_manifest_sha256, clients_lock_sha256
row, cases, historical_fixture, error_cases
execution_status = not_run
normalization = []
```

Rows retain provider/auth/input-protocol/upstream-mode/capability, source refs,
owner, fixtures, case IDs, extension, evidence and blockers. Case plans retain
route, complete request variants, parameters, assertions, source refs,
expected-reference disposition and error cases. No incremental SSE variant may
omit `stream: true`; variants are whole requests, not patches.

## Scope and transport rules

The operation inventory has independent `source_presence`, `applicability`,
`observation_boundary`, `reference_behavior`, auth/backend selectors and
`runtime_proof: not_run`. `wave_requirement` means requested by the wave, not
runtime qualified. `conditional_scope_pending` and `product_extension_pending`
require explicit scope decisions and separately versioned matrix extensions.

In particular, **native-lite is not one wire mode**:

1. Pinned executor stream tests require exact native-lite terminal/metadata
   preservation; their HTTP/WS axis is **upstream** transport.
2. Downstream HTTP SSE uses an unguarded terminal-output backfill framer,
   including for Codex clients. Transparent sparse terminal passthrough is a
   blocking product difference, not a CPA-supported ingress pass.
3. Downstream WS preserves wire only for lite **and selected auth provider
   Codex**, resetting/recomputing the decision on selection. Internal completed
   output restoration is independent of that wire decision.
4. Nonstream `Execute` unconditionally hydrates before response translation.
   Streaming bootstrap buffering does not prove buffered-lite passthrough.
5. None of those facts grants HTTP receipt, history or WS cursor authority.

Other pinned findings: Kimi native compact rejects with 501 buffered / 400
streaming; ordinary xAI/Grok HTTP deletes `previous_response_id`; compact's
restoration does not enable ordinary continuation; image SSE wraps a buffered
image execution; no video cancel action is registered in the audited core
routes. Binary content download and native result JSON are separate contracts.
Native Kimi Responses SSE, Grok physical WS selection/fail-closed fallback, and
Grok function/namespace/custom-tool policy have separate inventoried modes;
Grok's effective WS chain and approved tool-form matrix remain unqualified.
Full source chains, approved applicability and runtime evidence are not inferred
from route declarations or executor/forwarder unit-test source.

## Safety and ownership

The module performs bounded regular-file reads only. It rejects path traversal,
symlinks, oversized inputs, FIFOs, duplicate keys, nonfinite/overflowing numbers,
non-JSON direct values, invalid UTF-8 strings and excessive nesting. It imports
no process/network/service discovery or credential-environment tooling.
Tests guard import and execution with the existing process/network audit guard.
This accident guard is **not an adversarial native-code sandbox**.

- F02: reusable process/filesystem/network/resource lifetime containment.
- F03: actual CPA source/build/config/fixture identity qualification. The
  existing `8317` service remains untouched and identity `unknown`.
- F04: separately authorized bounded **live** runner, explicit endpoint allowlist
  and worst-case budget reservation before send.
- F30–F34/provider owners and the shared harness: provider payloads, differential
  assertions and actual-ingress runs.
- Coordinator: destination admission, common runner/CLI/build/CI and heavy gates.

```sh
python3 -B scripts/parity/contract.py validate
python3 -B scripts/parity/contract.py inventory --provider xai
python3 -B scripts/parity/contract.py plan --row codex-sse
python3 -B -m unittest discover -s scripts/parity -p test_contract.py -v
```

CLI exit 0 means valid **preparation**, not a compatibility pass. Invalid
contracts/selections exit 1. These commands never launch CPA or native clients,
read operator credentials, contact upstreams or evaluate provider assertions.
