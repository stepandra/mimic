# F16 — current attached-root admission

**SOURCE_ADMITTED on the current composition:** scoped format/check/build,
94 focused Kimi tests and the actual source CLI normalization workflow passed.
This is a bounded synthetic source admission, not shipment/full-gate or
live-provider qualification.

## Scope and provenance

Only the standalone F16 packet from
`d6f307a72a395a137126016362297884e1061a8a` was recovered. The source checkout was
read with exact-revision `git show`; no branch merge, ancestor import, ref
mutation, commit, publication or additional worker was used.

All eight manifest files and `F16_SHA256SUMS` first matched the pinned packet
byte-for-byte. The six runtime/test/smoke files retain their original hashes.
The recovered handoff and source memo add only a provenance note separating
their historical results from this admission; the pinned-source inventory,
excerpts and deliberate fidelity differences remain unchanged.

Owned paths:

- `src/mimic/providers/kimi/transform.gleam`
- `src/mimic/providers/kimi/schema.gleam`
- `test/kimi_transform_test.gleam`
- `test/kimi_schema_test.gleam`
- `test/kimi_normalization_test.gleam`
- `scripts/smoke-kimi-normalization.py`
- `docs/kimi/F16_SOURCE_DECISIONS.md`
- `docs/kimi/F16_HANDOFF.md`
- `docs/kimi/F16_SHA256SUMS`
- This narrow admission record.

No root hook is needed: the existing native request planner invokes
`transform.request` for both Chat and Responses before transport. No root,
shared, other-provider, FFI, dependency, vendor or pre-existing F14/F15 and
F05/F09/F11/F24 file was edited by F16. F44's UI raw-header/pipeline issue
remains separately owned and is not waived by this admission.

## Behavior reviewed

Both native protocols use the same bounded schema and temperature rule while
retaining their native tool envelopes. The schema walker resolves only
original-document local JSON Pointers in schema-defined positions, applies
sibling overrides independently, strips only root definition containers and
adds absent root `type: "object"`. Limits are depth 64, 16,384 work values,
262,144 UTF-8 schema bytes and 1 MiB for the final normalized request.

Opaque defaults, enum/const/examples, vendor values, arguments and history
remain data, not normalization targets. Invalid/cyclic/remote refs, unsupported
scope and expansion limits fail explicitly before I/O. Wrong temperature and
unsupported thinking/model intent are loss errors, not silently removed or
invented controls. Compact, continuation handles and new model support remain
unclaimed and denied. This is not CPA differential or live-provider parity.

The review and current focused/workflow checks found no bug requiring a rewrite
of the recovered implementation. Production, tests and smoke remain byte-exact
to the pinned packet.

## Current evidence

The attached root was validated at observed HEAD
`dd15c610ec39e4f296c30fe02347d0d2b368a629` **plus its current uncommitted
composition**, not by testing the historical standalone checkout. The parent
granted an exclusive bounded validation slot after the F10/F06/F27 lanes;
commands ran sequentially with process-local `ERL_FLAGS='+S 2:2 +A 2'`.
No other worker or parent validation was permitted in that slot.

| Current attached-root gate | Actual result |
| --- | --- |
| Five owned Gleam files: format and format check | Passed, exit 0; original runtime/test hashes unchanged |
| Gleam 1.18.1 build | Passed, exit 0; public dependencies allowed; existing dependency/vendor deprecation warnings retained |
| Explicit EUnit, nine named Kimi modules | **All 94 tests passed**, exit 0: 42 owned-module tests and 52 existing Kimi regressions |
| Python AST syntax | Passed, exit 0 |
| Real-socket fixture self-test | Passed, exit 0; explicitly `mimic_executed:false` |
| Actual current source CLI, real Mist/HTTP loopback | Passed, exit 0: **7 accepted upstream requests; 85 denials with zero upstream sends** |
| Byte preservation during exclusive validation | All **662 pre-validation tracked unowned paths** stayed identical; all eight F16 manifest hashes verified again |
| Shipment export/shipment smoke/full `gleam test` | **Not run by this worker**; parent-owned serialized gates |
| Live provider/accounts/ambient credentials/CPA/reference/native-client differential | **Not run** |

The source workflow exercised both native Chat and Responses in buffered and
streaming modes, compared whole before/after documents, and checked selected
account path/auth, model/control/schema normalization, explicit history IDs,
reasoning, Unicode, raw argument strings and opaque data. The independently
configured generic provider's raw request bytes remained unchanged. Rejected
refs, resource limits (including aggregate request growth), media, ambiguous
keys, temperature loss, history repair and compact/continuation produced no
upstream sends. Only explicit synthetic accounts/credentials and temporary
loopback state were used.

Attempt 1 passed with no test/workflow failure or waiver. Focused validation
took 41.266 seconds and the Python workflow 9.211 seconds; the measured slot
elapsed 62.779 seconds through workflow completion, below the 600-second grant.
These are scheduling observations, not benchmark or upstream profile claims.
The slot was released immediately after static hash checks; no further BEAM,
browser, compile or workflow run is planned by this worker.

The historical 94 focused passes and source/shipment 7 accepted / 85 zero-send
denials in [F16_HANDOFF.md](F16_HANDOFF.md) are not current evidence.
Today's independently run focused/source results above are current evidence;
the prior shipment result remains historical. F44's separately owned defect
is neither fixed nor waived here.

## Bounded validation commands

All commands below were run sequentially in the attached root. `ERL_FLAGS`
applied only to the validation process environment, not user/system config.
The EUnit wildcard was expanded to an explicit argument vector; the exact
expanded invocation is retained in the focused log. No `gleam test` module
argument, shipment export or full heavy gate was invoked.

```sh
export ERL_FLAGS='+S 2:2 +A 2'
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
python3 -c 'import ast,pathlib; ast.parse(pathlib.Path("scripts/smoke-kimi-normalization.py").read_text()); print("F16 Python AST syntax: passed")'
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py --self-test
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke-kimi-normalization.py
```

Ignored current-run artifacts, not imported historical logs:

```text
4a91827bcc7eb60d52c42eb7b150b2e159f8ad131e29e5757336ecc0cefaba4f  build/integration/F16-current-focused-attempt1.log
d2bc75b20cbcb4cc47a284222c72030b3a4235771e95ce97e703a136a077b1c0  build/integration/F16-current-workflow-attempt1.log
```

## Packet hash differences

The six runtime/test/smoke hashes in [F16_SHA256SUMS](F16_SHA256SUMS) remain
exactly those at the pinned recovery revision. Only historical-provenance notes
were added to the two recovered documents; the manifest reflects those notes.
This new admission record is outside the original eight-file manifest.

| Path | Original SHA-256 | Current SHA-256 |
| --- | --- | --- |
| `docs/kimi/F16_SOURCE_DECISIONS.md` | `f9566d3a8381ca48977e3c2ffafce6c661a63c341ffafc0d67e39ff74f1f14cc` | `c02e81b088b95f726057f2c311ac8921a341c4c3919f6b4da36524382254ba7b` |
| `docs/kimi/F16_HANDOFF.md` | `1b340157228303b774196921ce91490d1af19f434059b3bdcc7b33caa2adead0` | `f39b4a433d9dca86b54cd9f4a04c9f9aff8387f891ab256b894f5a2cfadc1b96` |
| `docs/kimi/F16_SHA256SUMS` | `ad77e0e5842ed9a37eda2878b0d853c98508b6226f9d472181bdc2d87bfdce1c` | `25b70912f94503a191aa7ac80354aaf9e13e866dbd6e384003daf2e2ce9b89ba` |
