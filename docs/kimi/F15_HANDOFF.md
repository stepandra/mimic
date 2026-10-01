# F15: generic Kimi Chat SSE — library ready, admission pending

## Scope and status

This packet implements **only F15**, under the distinct provider identity
`openai-compatible-kimi`. Base:
`ca86b531cea7e1a509ac8e6038604fe91819ac07`.

The provider library compiled with Gleam **1.18.1**. **22 focused tests passed**,
including a real loopback HTTP/runtime test. The smoke harness's own
real-socket self-test passed. The proposed root patch has **not** been applied;
actual source CLI and exported-shipment workflows have **not** been executed.
This is **library-ready / READY_FOR_ADMISSION**, not F15 DONE.

There were no native client, live provider, OAuth/device, CPA or differential
qualification calls. All fixtures and temporary credential values are synthetic.
No shared protocol/egress/gateway/config/CLI/build/vendor/CI or existing script
source was edited. No further agents, Git mutations, commits or pushes occurred.

The working-copy JJ change, inspected without snapshotting, is
`wqtnlkorvqzlmlzusyzvpykltotmqnsw`; its **pre-freeze** commit is
`d119b97327a96232f2c4051f8e9f3f38353756cb`.
That commit is not a frozen artifact containing these edits. The parent must
freeze the owned files and supply the accepted revision/bookmark to admission.

## Compiled contract and API choices

```gleam
// mimic/providers/kimi_compat/request
registration(model: String) -> Result(registry.Model, String)
prepare_at(
  base_path: String,
  context: contracts.Context,
  request: contracts.Request,
) -> Result(Capture, contracts.Failure)
http_at(
  base_path: fn(contracts.Context) -> Result(String, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(egress.Stream)

// mimic/providers/kimi_compat/adapter
run_chat_for(
  response: runtime.Response,
  request: contracts.Request,
  emit: fn(chat_stream.Event) -> Result(responses_http.Control, String),
) -> Result(chat_stream.Outcome, contracts.Failure)
```

- Registration adds `Stream` alongside `Buffer`, `Tools`, `Images`; protocols
  and operations remain native Chat/API-key only.
- Request mode must agree with the decoded native `stream` value. Streaming
  requires `stream: true`; buffered permits absent/false. Native request bytes,
  options, tools, supported images and opaque extensions are preserved.
- The existing protocol-position media gate applies unchanged to both modes:
  message-level audio and unsupported nested content fail `Unsupported/NotSent`
  before transport I/O. Schema properties, argument strings and vendor data
  are not indiscriminately scanned.
- **No shared seam edit is needed or proposed.** The parent agreed to reuse
  `mimic/protocol/chat/http.open_sse` and `run`, and
  `mimic/protocol/chat/stream.encode_event`. These already own strict header
  validation, byte framing, valid-prefix-before-error delivery and cancellation.
- Only the protocol-owned chunk `model` must equal the requested generic model.
  Error envelopes need no model. Documents remain whole `ir.Value` trees;
  nested vendor/tool values are not restored or transformed. SSE serialization
  normalizes JSON/framing, not field semantics; response byte identity is not
  claimed.
- Protocol failures are `InvalidResponse/Started`; downstream write failures
  are `Cancelled/Started`; typed upstream failures propagate. Each invocation
  gets an independent shared Chat state.

## Minimal parent-owned integration

`F15_GATEWAY.patch` is an exact `apply_patch`-compatible proposal targeting
**only `src/mimic/gateway.gleam`**, against the base above. Its four hunks were
checked in memory for unique exact context against the unchanged shared source.
That is a textual patch check, not a root compile or application result.

The proposal:

1. Imports the shared Chat HTTP codec and generic provider runner.
2. Dispatches generic Chat for both streaming and buffered requests.
3. Uses `runtime.open` for streaming and validates SSE status/media/encoding
   before handing off; invalid headers cancel the runtime handle.
4. Calls the existing `stream_encoded` helper, retaining its synchronous
   `runtime.adopt` ownership transfer. The generic runner owns subsequent
   framing, terminal/error delivery and cancellation.
5. Renames the old buffered function to `serve_kimi_compat_buffered`, without
   changing its existing `runtime.execute`/JSON/media/model behavior.

No config or CLI syntax change is required. The existing account registration
already calls generic `registration`.

Admission requirements:

- Parent freezes this owned packet and sends its JJ revision/bookmark + hashes.
- Coordinator admits/applies/reviews the root proposal in its shared-root lane.
- Coordinator compiles the actual root and executes source + shipment smokes.
- Full format/Gleam/integration gates run only with the coordinator's gate grant.
- Final release/capability documentation must reflect the actual admitted results.

## Focused verification

The final focused command was run once as a single sequential invocation:

```sh
mise exec gleam@1.18.1 -- gleam format \
  src/mimic/providers/kimi_compat \
  test/kimi_compat_test.gleam test/kimi_compat_stream_test.gleam
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- erl -noshell \
  -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([kimi_compat_test, kimi_compat_stream_test], [verbose, {scale_timeouts, 10}]) of ok -> halt(0); _ -> halt(1) end.'
```

Tool timeout: **90000 ms**. Exit **0**, **22 passed** (13 request/registration
tests, 9 stream tests). Log:
`build/integration/F15-focused-attempt4.log`.

Focused coverage:

- Every possible two-part byte split of a synthetic Unicode chunk plus DONE,
  including empty boundary chunks, plus one-byte chunks through the actual
  provider/runtime runner.
- Native content/reasoning/refusal, tool IDs/names/argument deltas, finish reason,
  usage/details, logprobs, fingerprint and unknown opaque documents.
- Valid events precede malformed JSON, duplicate keys, wrong requested model,
  changed stream identity, premature DONE and missing terminal errors.
- Named remote errors retain their complete document without invented DONE.
- Explicit cancellation and failed downstream writes cancel once, without a
  further pull.
- Invalid status/media/charset/duplicate headers/encodings cancel before pull.
- Simultaneously open streams isolate tool and terminal state.
- A new owner synchronously adopts; old-owner pulls and re-adoption fail.
- Real local sockets preserve the generic path/body and reject nested media
  across all message roles without another upstream send.
- Existing nested-media unit cases now exercise both buffered and streaming.

Additional successful checks:

```sh
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/kimi_compat \
  test/kimi_compat_test.gleam test/kimi_compat_stream_test.gleam
PYTHONPYCACHEPREFIX="$DELTA_SCRATCH_DIR/pyc" \
  python3 -m py_compile scripts/smoke-kimi-compat-stream.py
python3 scripts/smoke-kimi-compat-stream.py --self-test
git diff --check -- src/mimic/providers/kimi_compat test/kimi_compat_test.gleam
```

The harness self-test uses real Python loopback sockets and checks incremental
fixture framing. It explicitly reports `mimic_executed: false`. It is not
evidence of actual root or shipment functionality.

## Pending actual workflow commands

After root admission, run the new, scoped smoke:

```sh
python3 scripts/smoke-kimi-compat-stream.py
mise exec gleam@1.18.1 -- gleam export erlang-shipment
python3 scripts/smoke-kimi-compat-stream.py \
  --shipment "$PWD/build/erlang-shipment"
```

It uses the actual CLI to import newly generated private temporary synthetic
credentials/client keys, starts the actual gateway on loopback, and uses real
HTTP sockets. Shipment mode runs from a different working directory. It checks
incremental one-byte UTF-8/SSE delivery, complete native documents and raw
request bytes, concurrently open client/account/model scopes with reused
chat/tool IDs and request hint, valid prefixes before protocol errors, named
remote errors, header rejection, downstream cancellation/upstream close and
reuse, nested-media denial before sends, and unchanged buffered JSON. It rejects
timeouts as evidence of abnormal stream closure. It neither reads existing
credentials nor calls live endpoints, OAuth/device flows or CPA.

Actual workflow results remain **pending**. Parent/coordinator must record
failures as well as passing reruns.

## Failed/interrupted runs retained

| Run | Exact outcome |
| --- | --- |
| Initial full run | Before the coordinator's gate restriction arrived, `git --no-optional-locks status --short --branch && git rev-parse HEAD && mise exec gleam@1.18.1 -- gleam format src/mimic/providers/kimi_compat test/kimi_compat_test.gleam && mise exec gleam@1.18.1 -- gleam test` compiled successfully but the tool closed it after **120000 ms**, before a suite summary. No full-suite pass is claimed. No disk log was redirected, so its log hash is unavailable; the tool transcript is the record. |
| Focused attempt 1 | Format failed: Gleam list spread cannot precede subsequent elements. No tests ran. Corrected only test syntax. |
| Focused attempt 2 | Compilation failed: tests used unavailable `list.range` and `ir.Number`. No tests ran. Replaced with existing `list.repeat/index_map` and JSON tree APIs. |
| Focused attempt 3 | **21 passed / 1 failed**: expected usage tree was manually built in nonsorted order, unlike `ir.parse` canonical object ordering. Corrected the expectation by parsing its synthetic JSON. This log includes accidental concurrent duplicate focused invocations; it is not the final verification. |
| Focused attempt 4 | Single sequential run, **22 passed**, exit 0. Production/provider source was unchanged by the preceding test-only corrections. |

Read-only scoped process inspections after the interrupted run and final
focused run found no `mimic_test` or `beam.smp` processes. No unrelated process
was killed. Own generated Python bytecode was removed; no cache file belongs
in the admission source packet.

Log SHA-256 values:

```text
acdbb4d0d3b388c86a9cad20da57d3a20977a29c47471430fc4bf5c28d930389  build/integration/F15-focused-attempt1.log
0fe0090fac8ab4f720d902c520a3f29442a10fdc794ef595fbdfc070b968743d  build/integration/F15-focused-attempt2.log
46d8e635a9138eb052c95449330647dd155f6c775a98419cc945dd044bbbef6a  build/integration/F15-focused-attempt3.log
24dfc70a352bf7a5c9d5e4d0a317eaae03ffa56ab2d1a7097b0af7653990bba5  build/integration/F15-focused-attempt4.log
4136334d7a312fadd400a2416e96f864fb95012839baf46d310faef045e9d8c3  build/integration/F15-harness-attempt1.log
```

## Owned implementation hashes

This inventory excludes this handoff document's self-hash; that is reported
separately in the final handoff message.

```text
d0e199feb655ad335834272f94612d7720f0e55ebb831679609847b5f063e68c  src/mimic/providers/kimi_compat/adapter.gleam
2054ba1be92910702c9ec5c1660ec26a66d6366c63eb9ae6258628fada8d4584  src/mimic/providers/kimi_compat/request.gleam
f006f61fc5faa56de7c394cbc2df2cdcf34cbef03141a02cd164bafd8c776dc8  test/kimi_compat_test.gleam
db58512d60acb28b685bdf1e5ceb590b03efb868b1ba4dd6dea3c04c175131e8  test/kimi_compat_stream_test.gleam
```

The current script and root patch hashes are supplied in the final handoff;
recheck them after any admission changes. The patch is a proposal artifact,
not an actual edit of shared root source.
