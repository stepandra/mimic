# F25 tested correction packet — local synthetic gates only

**Historical receipt, not current admission.** Independent review found
production/schema/publication gaps after this90-test run. Current source-only
repairs and the blocked usage contract choice are in `F25_REVIEW_REPAIR.md`.
Neither these results nor the old hash packet validate the repaired revision.

## Result

- Scoped Gleam 1.18.1 build passed.
- **All 90 focused tests passed**: F25 18, F27 18, unchanged F23 19,
  unchanged F24 29, shared S6 6.
- Pure Python syntax/consumer checks passed: six syntax files, six positive
  constructions, four rejected malformed controls, safe-error control and
  a correctly encoded Fixed32 usage-dimension fixture.
- No actual root CLI/source/shipment workflow, full `gleam test`, installed
  SDK/native client, CPA differential, browser, remote or live Devin execution.

The parent granted one exclusive bounded validation slot and renewed it after
the initial focused failure for **fixture-only** corrections. The parent's
shared atomic `build/closure/validation.lock` was created fail-closed for each
bounded sequence and released in `finally`; no foreign lock was removed.
No command remains running, and no worker follow-up is deferred.

## Exact assembled input, not an owner-side runtime stub

Read-only source snapshot:

`/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic`

Copied verbatim `src`, `test`, `priv`, `vendor`, `gleam.toml`, `manifest.toml`
to this worker's ignored:

`build/f25-validation/1790880919-68108/project`

Only F25 owned/approved files were overlaid after scoped formatting/correction.
The parent runtime, root/config, vendor and shared codecs were neither edited
nor stubbed. Existing dependency/build cache was copied, then the assembled
package was rebuilt.

All **469** parent input files are recorded in
`build/f25-validation/1790880919-68108/parent-input-sha256.txt`.
Manifest SHA256:
`f4a08b38f90945424da162ba1919921945007b8dacbad87a23ffab738e73bbec`.

| Input | SHA256 |
|---|---|
| `src/mimic/providers/runtime.gleam` | `2e14d174415c94fd5e7f3d03823bbf65fa4ab3545721308bbc605dd11069e534` |
| `src/mimic/gateway.gleam` | `23e03870be3fd099f9273821fc8f2fdab4c1b6b17b13b064e482f9ca24343740` |
| `src/mimic/gateway/config.gleam` | `aa79c72766efd4212ffe9c53d34f4bc3d2c5e42ef178edc1c9eb98d8dffcee54` |
| `gleam.toml` | `c8875821158a7d52ed6412fbafb89f90ea69dbe8a3fe525277af13d5392b3386` |
| `manifest.toml` | `16234c9e08cd2d5f8e267c1ae51f1ee04ac03a283be99866fe5d74eb0e698b87` |
| `src/mimic/protocol/responses/stream.gleam` | `42b9477d6d137268fa662bacbd74beeb56b4ca2b7d75600e2a1c3852db57116b` |
| `src/mimic/providers/devin/response.gleam` | `913cc99bd257f889c2ff565b8de16ccc0020b6fd45ac83227faa5bf390a15ca6` |
| `src/mimic/providers/devin/stream.gleam` | `0a2ed4f7f5d9150f2c22a77536588b9c42d98f4f9e7e9509d9620bbd905a54d6` |

This worker's main checkout still intentionally does not import/edit F28
runtime. The tested composition uses the exact parent bytes above. The parent
must import the final owned packet into its assembled source, not replace its
runtime with this worker's older baseline.

## Retained attempts and corrections

1. Parent composed compile failed at the depth-test branch: `should.be_ok`
   returns its success payload while `should.be_error` returns its error payload.
   Both branches now explicitly discard that payload and return `Nil`.
2. `build-1.log`: passed, **4.277 s** wall; `focused-1.log`: **84 passed /
   6 failed**, **3.340 s**. Execution stopped and the lock was released.
   - Five tests compared parsed JSON object field-list order against a
     constructed tree's insertion order. Expectations now pass through JSON
     parsing; all fields/values and array/item/content order are preserved.
     The independent append/done/terminal oracle is unchanged.
   - The stalled native fixture omitted required
     `Content-Type: application/connect+proto`, so it failed before opening a
     stream. The exact header was added. Its held body, original absolute
     deadline, cancellation, adopted-owner death and actual peer-EOF/lease
     assertions were not relaxed.
3. Parent explicitly approved those narrow fixture-only corrections.
   `format-2.log`: **0.356 s**; `build-2.log`: passed, **0.620 s**;
   `focused-2.log`: **all 90 passed**, **4.203 s** wall.
4. Initial inline Python selfcheck fixture helper used `name` for both event
   type and tool name, causing a `TypeError`. The failed attempt is retained in
   `python-checks-1.log` and the conversation output. A reproducible dedicated
   `f25_consumer_selfcheck.py` uses `event_type`.
5. Obvious native fixture contract correction: the CLI estimated-usage metric
   changed wire tag 18 to **21** (field 2, Fixed32), so its negative is a real
   dimension-estimate case, not malformed protobuf. The pure check verifies
   that exact wire type.
6. `python-checks-2.log`: passed, **0.129 s** wall. No socket/CLI/SDK was started.

All logs have separate names under
`build/f25-validation/1790880919-68108/`; failed logs were not overwritten.
Python final input hashes are in `python-final-input-sha256.txt` there.

## Commands and publication boundary

From the copied project, direct-terminal bounded processes used:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  gleam run -m devin_responses_projection_test
```

Pure Python check, from the attached worker repository:

```sh
python3 -B docs/devin/f25_consumer_selfcheck.py
```

`F25_SOURCE_SHA256SUMS` remains the **historical pre-format HOLD** hash record.
`F25_SHA256SUMS` is the final current owned/approved packet. No Git/JJ
mutation/commit, child agent, outside-checkout edit or live authorization occurred.

The root contract/harness is delivered, but actual `/v1/responses` source and
shipment receipts, full assembled suite, native SDK, CPA differential and live
qualification are **pending parent-owned gates**, not included in this result.
