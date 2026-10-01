# F16 native Kimi normalization — library ready, admission pending

**Historical standalone handoff, not current-composition evidence.** Recovered
read-only from packet revision `d6f307a72a395a137126016362297884e1061a8a`;
all eight original manifest hashes and the manifest bytes were verified before
this provenance note was added. The base, missing-F01 observation, prior logs,
94 focused passes and source/shipment 7/85 results below describe that earlier
checkout only. Current attached-root evidence is in
[F16_ADMISSION.md](F16_ADMISSION.md); the old next-action list below is historical,
not a new request for root integration.

## Outcome and scope

**Only F16 is implemented. LIBRARY_READY / READY_FOR_ADMISSION, not F16 DONE.**
Base: `47d9c7cb607ad49cfbe65ddf962c432def3f6a02`, the F14 library over F15.
The parent must auto-merge/freeze this packet; coordinator destination workflows
are still required. No Git/JJ mutations, commits/bookmarks, publication, sibling
edits or additional agents occurred.

| Evidence on this child checkout | Final result |
| --- | --- |
| Gleam 1.18.1 scoped format/check/build | Passed |
| Focused EUnit, nine named Kimi modules | **94 passed**, no failures |
| Python syntax and real-socket fixture self-test | Passed; self-test explicitly `mimic_executed:false` |
| Actual source CLI, real Mist/HTTP loopback | Passed: **7 accepted upstream requests, 85 denials with zero upstream sends** |
| Exported Erlang shipment, same smoke from another cwd | Passed: **7 accepted upstream requests, 85 denials with zero upstream sends** |
| Coordinator's admitted source/shipment after importing F16 | **Pending**, not inferred from child results |
| Full `gleam test` / integration gate | **Not run**; requires coordinator grant |
| CPA / live provider / real credentials / native client / differential | **Not run** |

F01's hash-bound source map is missing and was immediately reported. F16
independently fetched immutable public **historical** source. It does not
qualify Foundation drift freeze, the current pin, port 8317 or a reference
runtime. [F16_SOURCE_DECISIONS.md](F16_SOURCE_DECISIONS.md) freezes all 14
downloaded raw-file hashes and eight byte-exact checked excerpts, including the
actual local-ref/cycle helper and native Responses normalizer call sites.

## Implementation

Owned runtime changes are **only**:

- `src/mimic/providers/kimi/schema.gleam`: one bounded schema normalizer using
  the existing shared JSON tree/codec, not a duplicate codec/resolver.
- `src/mimic/providers/kimi/transform.gleam`: the same tool-schema helper and
  temperature validator run after native validation for both Chat and
  Responses. Responses function tools keep their own envelope rather than
  acquiring a Chat `function` wrapper. Normalized request output is at most
  1 MiB.

```gleam
schema.normalize(parameters: ir.Value) -> Result(ir.Value, String)
schema.normalize_bounded(
  parameters: ir.Value, depth: Int, nodes: Int, bytes: Int,
) -> Result(ir.Value, String)
// Fixed ceilings: depth 64, 16_384 JSON values, 262_144 UTF-8 JSON bytes.
// Callers can only tighten these ceilings.
```

The signature of `transform.request(body, model, protocol, streaming)` is
unchanged. The existing request planner already invokes it before transport,
so no new request/gateway/CLI hook, registration or dependency is required.

The bounded subset expands original-document JSON Pointers only at
schema-defined positions. Sibling keywords override referenced fields, each
expansion is independent, root `$defs`/`definitions` are removed, and absent
root `type` becomes `"object"`, matching the inspected source for this subset.
Depth, node and escaped UTF-8 byte budgets account for expansion work including
unused definitions and overridden expansions; final output is checked again.
Cycles, external/dangling/malformed/non-schema/non-object targets, changed
`$id` scope, dynamic/recursive refs and limits fail before I/O. There is no
filesystem/network resolver, typed cycle hint or constraint-losing fallback.

Reference/model/media semantics do **not** apply to defaults, enum/const/example
values, vendor/unknown keyword objects, user tool arguments or text. Schema
opaque values are only resource-accounted and preserved. Argument strings retain
their internal whitespace and spelling.

### Source correction and fidelity boundaries

Historical Responses **does** invoke tool/temperature normalization
(`kimi_executor.go:426–427,537–538`); native-v2's old summary and the old
transform comment were inaccurate. This packet corrects the shared runtime
rule and explicitly supersedes that summary in the source memo, without editing
unowned historical docs.

Not all historical transformations are reproduced, and these differences
are **not normalization parity**:

- Wrong temperature/type is an explicit loss error rather than silently dropped.
  Native Responses uses `reasoning.effort`; it does not become Chat `thinking`.
  `reasoning.effort:none` does not imply temperature 0.6 in the source helper.
- Existing model aliases/catalog and thinking levels are reused unchanged.
  No suffix/preview aliases, level clamps, numeric-budget conversion or model
  availability is invented.
- Explicit history IDs/reasoning are preserved. Missing/ambiguous IDs and
  missing Chat tool-call reasoning are rejected unless thinking is disabled;
  no previous reasoning/content copy, placeholder, inferred ID or empty-message
  removal is introduced.
- Native Responses summaries/encrypted strings and native Messages signed/
  redacted thinking remain native. No implicit replay cache or cross-dialect
  reasoning conversion is introduced.
- Unsupported media is rejected at actual protocol positions, including tool
  results. Supported image forms are forwarded without fetching them; no
  metadata-to-upstream-acceptance inference is made.
- Compact is explicitly denied in historical CPA. Opaque continuation,
  previous-response/conversation handles and stateful capabilities remain denied.

`request.gleam`, `messages.gleam`, `models.gleam`, `adapter.gleam`, generic F15,
Claude F14 seams, root gateway/CLI/config/dependencies/vendor/CI were not edited.
Read-only byte comparisons against the base verified the first four files,
both generic modules, Claude HTTP/stream, gateway/root main/build manifests
and F14/F15 smoke scripts stayed identical.

## Coordinator admission: no root patch needed

Only the allowed coordinator gateway file was inspected read-only, at observed
HEAD `5a8d8cfd36cecea707a73931ad58c1a384d653d9`:

```text
d78b80c09a0ac5950ffd3c72a18f26e3545f45372f1879c84dbaa3f9fc31ceaa  src/mimic/gateway.gleam
```

Its lines 659–664 already dispatch native Chat/Responses and admitted F14/F15
routes. Lines 961–966 use `kimi_request.http_at` and `runtime.open`; this reaches
the existing `request.prepare_at` → `transform.request` before egress.
The F16 packet does not change synchronous stream ownership/adoption or F14
Messages routing. No root/shared patch is needed or proposed.

Required next actions:

1. Parent freezes the exact owned packet after auto-merge; checks
   `F16_SHA256SUMS`; provides accepted revision/hashes to coordinator.
2. Coordinator imports/reviews it in its serialized root lane and compiles.
3. Run this scoped smoke on the **actual admitted** source and freshly exported
   shipment, not a copied child build. It uses only newly generated synthetic
   credentials and temporary explicit state; no existing credential read.
4. Record failures and reruns. Full destination tests/integration still need
   coordinator authorization; then update capability/release docs based on
   actual admitted evidence.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py
mise exec gleam@1.18.1 -- gleam export erlang-shipment
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py \
  --shipment "$PWD/build/erlang-shipment"
```

The smoke checks whole before/after native documents for both routes/modes,
model/control/schema normalization and preservation of IDs, argument strings,
Unicode text, native reasoning and opaque data. It observes selected second
native account path/auth and independently configured generic raw bytes. It
rejects reference cycles/expansion limits, aggregate request expansion,
unsupported/nested media, duplicate/escaped-duplicate keys, temperature loss,
reasoning/ID repair and compact/continuation **without an upstream send**.
Actual complete HTTP bodies are read; timeout/truncation is an error, not
successful completion/abnormal-close evidence. Existing synthetic SSE fixture
functions are reused rather than introducing another codec.

## Focused verification commands

Final focused run, sequential, timeout 90000 ms, exit 0:

```sh
mise exec gleam@1.18.1 -- gleam format \
  src/mimic/providers/kimi/transform.gleam src/mimic/providers/kimi/schema.gleam \
  test/kimi_transform_test.gleam test/kimi_schema_test.gleam \
  test/kimi_normalization_test.gleam
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/kimi/transform.gleam src/mimic/providers/kimi/schema.gleam \
  test/kimi_transform_test.gleam test/kimi_schema_test.gleam \
  test/kimi_normalization_test.gleam
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- erl -noshell -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([kimi_transform_test, kimi_schema_test, kimi_normalization_test, kimi_request_test, kimi_chat_test, kimi_messages_test, kimi_messages_stream_test, kimi_compat_test, kimi_compat_stream_test], [verbose, {scale_timeouts, 10}]) of ok -> halt(0); _ -> halt(1) end.'
```

There are 42 tests in the three owned modules and 52 existing Kimi regressions.
They include schema keyword traversal, escaped/array pointers, independence,
opaque preservation, invalid/cyclic refs, depth/node/byte/final-request bounds,
all existing model efforts, explicit history/loss differences, pre-I/O media/
state rejection and F14/F15 streaming/real-loopback regression coverage.

Final workflow run, sequential, timeout 180000 ms, exit 0:

```sh
PYTHONPYCACHEPREFIX="$DELTA_SCRATCH_DIR/pyc" \
  python3 -m py_compile scripts/smoke-kimi-normalization.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py --self-test
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py
mise exec gleam@1.18.1 -- gleam export erlang-shipment
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py \
  --shipment "$PWD/build/erlang-shipment"
```

Scoped read-only `git diff --check` passed for tracked changes; scoped format
checked new Gleam files too. Dependency deprecation warnings during shipment
export are retained, not suppressed. Build/manifest/dependency source bytes
were unchanged.

## Attempt history — failures retained, not waived

| Attempt | Result |
| --- | --- |
| Contract 1 | Format failed: `opaque` is a Gleam reserved word. No build/tests ran. |
| Contract 2 | Build failed: unavailable `list.at`, missing recursive tuple annotation. Replaced with `drop/first`, annotated; no tests ran. |
| Contract 3 | Scoped format/build passed; early API/source memo sent. |
| Source excerpt check 1 | Failed: copied cycle helper closing brace was one line beyond stated range. Fixed excerpt range from 786–807 to 786–808; all eight excerpts and 14 raw-file hashes then matched exactly. Tool transcript is the record; no separate log file. |
| Focused 1 | Build failed on comparison/pipeline precedence in test assertion. Fixed test syntax. |
| Focused 2 | 55 passed, one failed: expected every media failure to be `Unsupported`, while shared native decoder can return `InvalidConfiguration/NotSent`. Test now asserts denial and guaranteed `NotSent`, preserving either authoritative boundary. This attempt accidentally had concurrent duplicate invocations writing the same log, producing interleaved output; it is not final evidence. |
| Focused 3 | Single sequential format/check/build and **94 passed**. |
| Harness 1 | Syntax and real-socket self-test passed, explicitly no MIMIC execution. |
| Source/shipment 1 | Actual CLI/shipment passed: each 7 accepted/81 zero-send denials. |
| Focused 4 | Final single sequential run: **94 passed**, including independent tightened-node assertion. Production source unchanged since the early compiled contract. |
| Workflows final | Final script adds aggregate-request-size denial: syntax/self-test/source/export/shipment passed, each MIMIC mode **7 accepted/85 zero-send denials**. |

Log hashes (ignored local artifacts, not imported source):

```text
acbbb6d156ca6eeeb05613a86e3c530d658a81cac99469aaf7383a76e82d74aa  build/integration/F16-contract-attempt1.log
10f9d184fc6d851496ddd7084ccfd9e77458a0df927f8e3e57b694498ef93ef3  build/integration/F16-contract-attempt2.log
587284f4044dcc87b0b9f0af21ce4b4a14b4842c0e8a1c3792cccba59b9a1673  build/integration/F16-contract-attempt3.log
92010073c4f36c8efd614eebeda7697a24701eadcea25cfbe263a7b053f2dfc8  build/integration/F16-focused-attempt1.log
92085ae2edb4298ef93d56cf244922dcb50615b85f789c91f4ed3c9d909f5eaf  build/integration/F16-focused-attempt2.log
493569b42f31c6115fe8637c5bf15a67cd00cf6cfe14fe7253a2ce00cfa409f3  build/integration/F16-focused-attempt3.log
34dc5201c2bd0a9558185fd74848b821fbbd91ccb477d466b4355e74933118e3  build/integration/F16-focused-attempt4.log
d088723e3a8be48f88dae416606fe08658058847a1741cff3fc481b46cd2b2a0  build/integration/F16-harness-attempt1.log
cbc7ed28892a24247d44ac19e8a938c2930546ac96d028422cc4c186a990d97b  build/integration/F16-source-attempt1.log
b5dfaf7acaea3de583ece05e5e53b8930e1589a34dd8db4803e9d6c50e59e59b  build/integration/F16-shipment-attempt1.log
77efa7ab54618e822073cb67d61f3fb4ba5e8c04bfbdd0b4b3f90713ed08a111  build/integration/F16-workflows-final.log
```

`F16_SHA256SUMS` binds the final owned files, including this handoff. It excludes
its own self-hash, which is supplied in the final parent handoff. There is no
child commit/frozen revision claim; the parent owns that operation.
