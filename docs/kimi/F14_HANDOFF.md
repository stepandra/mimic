# F14 native Kimi Messages SSE — library ready, admission pending

## Outcome

**Only F14 is implemented.** Provider base:
`85f44ef07144a8a4433933b2f51f1972e4744039`, the frozen F15 library over
`ca86b531cea7e1a509ac8e6038604fe91819ac07`.

Gleam **1.18.1** format/check/build passed. The final focused EUnit run passed
**26 tests**: 5 Kimi Messages planner tests, 15 new streaming tests, and 6
existing Claude stream regressions. The new harness's real-socket fixture and
clean/truncated/timeout reader controls passed.

The root gateway was **not edited**. Its two-hunk integration proposal targets
the coordinator's actual admitted F15 root
`8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936`, inspected read-only. Actual F14 source
CLI and exported-shipment smokes remain **unexecuted / pending admission**.
This packet is **LIBRARY_READY / READY_FOR_ADMISSION**, **not F14 DONE**.

No full `gleam test` or integration gate ran in this child. No native client,
live provider, real credential, CPA or differential access/qualification. No
agents were spawned, no mutating Git/JJ commands, commits/bookmarks/pushes, no
sibling edits. All fixture and generated test credential values are synthetic.
Parent must freeze the auto-merged packet after this child completes.

## Implementation and ownership

- `kimi/request.prepare_at` passes the actual requested streaming mode to the
  existing `messages.prepare`. Mode/body disagreement fails before transport.
  Native tools, signed thinking, extensions, existing auth/domain/path checks
  and request validation remain unchanged.
- `kimi/adapter.run_messages_for` validates native Kimi Messages/Streaming
  context, selects a registered public model's upstream ID, and calls the
  actual Claude HTTP/observer codec. Invalid/empty/guessed models cancel before
  pull. There is no provider-local SSE parser or shared provider state/cache.
- The **named Claude owner grant** was explicitly amended by the parent to
  permit only `claude/http.gleam` and `claude/stream.gleam`, followed by owner
  source-review approval. Claude adapter was not edited. F09 was not started
  and was to preserve these files/seam.
- The additive `new_with_model` / `run_with_model` seam operates at the existing
  parsed observer boundary. It validates `message_start.message.model` against
  the trusted selected upstream mapping **before** replacing **only that field**
  with the requested public model. A public alias returned upstream instead of
  its expected upstream ID is rejected, even if otherwise known.
- The start event's data lines are reserialized from the same parsed document.
  Its event/id/retry/comment/extension lines retain order. Root/nested vendor
  `model` fields, tool input/argument JSON, thinking/signatures, redacted data,
  usage/details and unknown events are not recursively restored. Every
  non-start frame remains raw. Default Claude `new` / `run` are opt-out and
  retain their original frames.
- Input framing/UTF-8/header/lifecycle/usage/terminal validation and cleanup
  remain in the actual Claude codec. Restored output also must fit **1 MiB**.
  Exactly 1 MiB passes; one byte above fails without emitting that event.
- Malformed events after a valid same-read prefix preserve that prefix and
  cancel once. Missing terminal events and invalid usage are errors. A delivered
  `Failed(error_kind)` is a remote-error terminal, not successful message
  completion, invented `message_stop`/DONE or permission to replay.
- Protocol/upstream-codec failures map to `InvalidResponse/Started`;
  downstream close or explicit cancel maps to `Cancelled/Started`. The existing
  Claude lifecycle returns string errors, not typed upstream failures; this
  packet does not claim to change or enrich that contract.

`F14_CONTRACT.md` contains the compiled signatures. `F14_CLAUDE_SEAM.patch`
contains exact formatted hunks; applying them **in memory** to the base
reconstructed both compiled Claude files byte-for-byte. This is textual/source
evidence, not destination or live qualification.

Kimi `messages.gleam` and F15 provider/test/script bytes are unchanged. No new
normalization, catalog, dependency, CLI, config, vendor or CI edit is included.

## Minimal coordinator-owned gateway admission

`F14_GATEWAY.patch` targets only `src/mimic/gateway.gleam` at the admitted F15
root above. Both hunks were checked for unique exact context without writing
the sibling checkout:

1. Dispatch native Kimi Messages in both buffered and streaming modes.
2. Add a Messages branch under the existing `serve_kimi` SSE header gate. Call
   `stream_encoded(req, opened, runner)` and `kimi.run_messages_for`.

The existing helper's synchronous `runtime.adopt` ownership handoff is reused;
no alternate adoption path or ownership process is proposed. Buffered behavior
and all F15 dispatch/helper changes stay intact.

Admission sequence:

1. Parent auto-merges/freezes the exact owned packet and reports its accepted
   revision/bookmark and hashes to the coordinator and Claude owner.
2. Coordinator admits/applies/reviews the root proposal in its own root lane.
3. Coordinator compiles and runs actual source/shipment smokes below.
4. Full Gleam/integration gates require an explicit coordinator grant. Record
   failures and successful reruns; do not substitute this library result for
   destination gates or release-capability evidence.

## Focused verification

Final command, sequential; tool timeout **90000 ms**, exit **0**:

```sh
mise exec gleam@1.18.1 -- gleam format \
  src/mimic/providers/kimi/adapter.gleam \
  src/mimic/providers/kimi/request.gleam \
  src/mimic/providers/claude/http.gleam \
  src/mimic/providers/claude/stream.gleam \
  test/kimi_messages_test.gleam test/kimi_messages_stream_test.gleam
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/kimi/adapter.gleam \
  src/mimic/providers/kimi/request.gleam \
  src/mimic/providers/claude/http.gleam \
  src/mimic/providers/claude/stream.gleam \
  test/kimi_messages_test.gleam test/kimi_messages_stream_test.gleam
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- erl -noshell \
  -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([kimi_messages_test, kimi_messages_stream_test, claude_provider_stream_test], [verbose, {scale_timeouts, 10}]) of ok -> halt(0); _ -> halt(1) end.'
```

Final log: `build/integration/F14-focused-attempt3.log`.

Focused coverage includes every possible two-part **byte** split of the full
Unicode/native tool/thinking/signature/usage fixture with LF, CRLF, CR and BOM;
all byte splits of valid-prefix-before-error; actual runtime runner one-byte
chunks; raw default Claude behavior; missing/wrong/duplicate/escaped-duplicate
models; negative usage/UTF-8/lifecycle/EOF; header rejection before pull; named
errors; downstream failure/cancel without another pull; concurrent model/session
states including aliases sharing an upstream ID; every registered model mapping;
synchronous new-owner adoption; input/output size boundaries; a real local
HTTP/runtime request verifying native path, auth and streaming body.

Additional checks:

```sh
PYTHONPYCACHEPREFIX="$DELTA_SCRATCH_DIR/pyc" \
  python3 -m py_compile scripts/smoke-kimi-messages-stream.py
python3 scripts/smoke-kimi-messages-stream.py --self-test
git diff --check -- src/mimic/providers/kimi/adapter.gleam \
  src/mimic/providers/kimi/request.gleam \
  src/mimic/providers/claude/http.gleam \
  src/mimic/providers/claude/stream.gleam test/kimi_messages_test.gleam
```

The harness self-test explicitly reports **`mimic_executed: false`**. It is
fixture/client evidence only. Its reader parses actual HTTP chunk boundaries:
terminating zero chunk + trailer terminator, actual TCP truncation and timeout
are separate. Real socket-pair controls cover each; timeout never counts as
abnormal-close evidence. This avoids the coordinator-reported F15
`HTTPResponse.readline` pitfall without editing F15.

Read-only hash comparisons also verified that this child's inherited gateway,
F15 provider/script and `kimi/messages.gleam` remained identical to its base.
The scoped Git whitespace check above covers tracked source/test changes;
patch artifacts deliberately retain blank-line context markers.

## Actual workflows to execute after admission

```sh
python3 scripts/smoke-kimi-messages-stream.py
mise exec gleam@1.18.1 -- gleam export erlang-shipment
python3 scripts/smoke-kimi-messages-stream.py \
  --shipment "$PWD/build/erlang-shipment"
```

The harness uses actual MIMIC CLI credential/client-key imports into a new
private temporary synthetic state directory, actual gateway launch and real
loopback HTTP sockets. Shipment mode runs from a different working directory.
It checks incremental one-byte upstream frames, tools/thinking/signatures/usage,
only protocol-owned model restoration, raw non-start frames, concurrent
client/account/public-alias isolation with the same upstream model and reused
message/tool IDs/hint, valid prefix and actual abnormal close for model/protocol
errors, remote error without fabricated stop, bounded header failure without
retries, downstream cancellation/upstream close/reuse, pre-send denial and
unchanged buffered semantics. It does not read existing credentials.

These actual MIMIC workflows are **pending**, not claimed passed.

## Attempt history retained

No validation run failed or timed out in this child. The full history is:

| Attempt | Result |
| --- | --- |
| Contract 1 | Pinned format/build passed. Dependencies were resolved locally; no manifest/vendor source edit. |
| Focused 1 | 24 passed. Initial 13 stream tests, 5 planner tests, 6 existing Claude tests. |
| Harness 1 | Python syntax and real-socket fixture/reader self-test passed; no MIMIC execution. |
| Focused 2 | 26 passed after adding all-model/shared-upstream alias and invalid runner-context tests. |
| Focused 3 | Final format/check/build and 26 tests passed, including exact restored-output equality and one-byte-over boundaries. |

Editing-history exceptions are retained separately, not validation passes: one
large test `apply_patch` was interrupted by incoming messages, its absence was
verified before retrying in smaller operations; one later mixed script/doc
patch applied the script but could not match the doc header because the draft
selector included an extra literal `+`. The doc-only hunk was corrected and
both final proposal reconstructions verified. No failed actual-root smoke is
hidden: none was attempted before admission.

Log SHA-256:

```text
dcb6f0ccbe949df4611745c8f0a17b188d41c795ceebfa6482ef6f1a41888bf3  build/integration/F14-contract-attempt1.log
3997159d152c94b1912d8cf391e8591eec075bf7d77fe1f42072b6b6cd3a7ba1  build/integration/F14-focused-attempt1.log
22507d61f291a97f56176c5a89e6da3158ffd17244f168f6ed4778393596e7f9  build/integration/F14-harness-attempt1.log
8a9d145860141d67dcd77b14fed5f386c7e56546004744c8c1c19b94cb79f894  build/integration/F14-focused-attempt2.log
c6f1fba10630bb2de22724cb46f766116e7928fcdc71456c6a74a619b87ac4f6  build/integration/F14-focused-attempt3.log
```

## Exact packet hashes

See `F14_SHA256SUMS` for implementation/proposal/contract hashes, plus the
unchanged Messages normalizer hash. This handoff and inventory exclude their
own self-hashes; those are supplied separately in the final parent message.
Parent/coordinator must freeze and validate the destination inventory, not
infer a frozen revision from this child's unchanged `HEAD`.
