# F23 Chat SSE — READY_FOR_ADMISSION, NOT DONE

## Result and admission boundary

Provider-owned Chat projection and a reusable Devin client lifecycle compile on
base `96e68387c309027baf58bd010c817b968d81ec2e` (`umbrella5-f22-local`).
**19 focused synthetic tests passed** in the direct serialized attempt10
(EUnit 3.222 seconds; build 0.63 seconds). The earlier direct attempt09 passed
18 tests in 3.787 seconds. Tests are not added together.

The default [bridge registration](../../src/mimic/providers/devin/bridge.gleam#L24)
is unchanged and does **not** advertise client streaming. The explicit
[Chat registration constructor](../../src/mimic/providers/devin/chat_gateway.gleam#L31)
is a numeric-loopback, Chat-only integration opt-in, not remote qualification.

**Root admission and actual-root CLI execution are pending.** The worker did
not apply `F23_ROOT.patch` and has no shared/root patch grant. Compilation of the
Mist facade is not an assembled root/CLI gate. The coordinator must apply the
hash-matched artifact, build the actual root and run the F23 script, including
the retained F22 safety assertion adaptation, before claiming F23 DONE.

| Evidence class | This checkpoint |
| --- | --- |
| Source | Historical CPA `acdace936fa7df2905500c7f5e0a97d683138dea`, awaiting F01 qualification; actual local decoder/runtime/Mist/shared codec source inspected |
| Synthetic unit/native-wire | Seven focused cases, including actual `response.feed_prefix` text/signature and dimension-usage decoding, plus pure typed projection negatives |
| Synthetic provider sockets | Twelve focused loopback H1 cases; actual shared runtime/egress, prefix/terminal/cancel/adoption and zero-backup assertions |
| Actual root/CLI Chat SSE | **Pending**; the new actual-root script is syntax checked, not executed |
| Shipment / full Gleam / integration | **Unexecuted**; no heavy-gate grant |
| CPA differential / authentic native client | **Unperformed** |
| Remote H1 / TLS / ALPN / H2 | **Not qualified; remote binary remains closed** |
| LIVE / inference / enrollment | **Not authorized or attempted** |

No child agent, CPA connection, real credential read, inference/login, Git
mutation, JJ freeze/commit, publication, source overlay or sibling edit occurred.
Parent freezes the imported result after successful auto-merge; this worker
does not claim an independently frozen F23 JJ revision.

## Design decision

The actual shared Chat APIs were read, not renamed into an assumed encoder:

- [`protocol/chat/http`](../../src/mimic/protocol/chat/http.gleam#L9) receives SSE
  from an upstream and validates media/framing/terminal behavior.
- [`protocol/chat/stream`](../../src/mimic/protocol/chat/stream.gleam#L72)
  validates incoming Chat document events, preserving unknown extensions.
  Its [`encode_event`](../../src/mimic/protocol/chat/stream.gleam#L377)
  only serializes a Chat event document into SSE; it is not a Devin translator.
- Shared [`dialect/openai.encode_response`](../../src/mimic/dialect/openai.gleam#L417)
  encodes buffered responses, not native-event streaming. Its usage conversion
  cannot represent absent counts/signature provenance by relabeling.

| Approach | Assessment |
| --- | --- |
| Label native Connect bytes as SSE | Rejected: framed protobuf is binary, not UTF-8 client SSE, and EOF is not native success |
| Add provider translation into shared Chat/parser/gateway core | Wider serialized-owner change; no applicable shared encoder exists on this base; would couple provider semantics into the receiving validator |
| Provider projection + one native lifecycle + shared Chat document serialization/validation | Chosen: no duplicate Connect parser; narrow root facade; F24/F25 reuse the lifecycle rather than a copied decoder |

No production changes were required in `bridge.gleam`, `response.gleam`,
`stream.gleam` or `connect.gleam`. The native source of truth remains
[`response.feed_prefix`](../../src/mimic/providers/devin/response.gleam#L64),
[`stream.next`](../../src/mimic/providers/devin/stream.gleam#L36) and
[`stream.project`](../../src/mimic/providers/devin/stream.gleam#L89).

## Compiled typed contract

Modules are under `src/mimic/providers/devin/`. Public errors use `String`
except existing runtime `contracts.Failure`. Times are integer milliseconds
except the explicit Chat `created_seconds` field.

```gleam
// client.gleam — protocol-independent F24/F25 seam
opaque Client(state)
Batch(client: Client(state), frames: List(String), done: Bool,
      error: Option(contracts.Failure))
Outcome = Finished | Cancelled
new(native.Stream, state,
    fn(state, response.Event) -> Result(#(state, List(String)), String))
  -> Client(state)
adopt(Client(state)) -> Result(Nil, contracts.Failure)
cancel(Client(state)) -> Nil
next(Client(state)) -> Batch(state)
run(Client(state), fn(String) -> Result(responses_http.Control, String))
  -> Result(Outcome, contracts.Failure)

// chat.gleam — provider-specific document projection, no byte parser
opaque State
new(id: String, model: String, created_seconds: Int) -> Result(State, String)
encode(State, response.Event) -> Result(#(State, List(String)), String)
failure(contracts.Failure) -> String

// chat_gateway.gleam — compiled root/Mist facade
registration(model: String) -> Result(registry.Model, String)
open(runtime.Runtime, Option(String), contracts.Request)
  -> Result(#(String, client.Client(chat.State)), contracts.Failure)
serve(Request(mist.Connection), runtime.Runtime, Option(String), contracts.Request)
  -> Response(mist.ResponseData)
send(Request(mist.Connection), client.Client(chat.State))
  -> Response(mist.ResponseData)
```

`client.Finished` describes native transport/projector completion, not a claim
that the generated answer is complete: length and filtered terminations still
produce the corresponding incomplete Chat finish reason.

### Lifecycle invariants

1. Open uses `bridge.open_native_stream` and the existing runtime adapter,
   credentials, leases, policy and retry rules. It never treats native bytes
   as SSE or asks a receiving Chat parser to decode protobuf.
2. `client.next` calls `native.next` once and projects validated events through
   `native.project`. Return frames must be delivered once before inspecting the
   failure. Projection failure preserves preceding frames and cancels transport.
3. Success is only the native Stop published after valid Connect terminal
   **and clean HTTP framing EOF**. Neither Reason nor Connect EOS alone emits
   a client finish or DONE. A truncated trailer/HTTP body or bytes after EOS
   yields a safe failure, never a late success marker.
4. `client.adopt` runs synchronously in Mist initialization before the old owner
   can exit. It cancels on adoption failure. The shared guard retains owner-death
   cleanup; revoked owners cannot pull or cancel the new owner's stream.
5. Emit cancellation or downstream-send failure cancels the adopted upstream
   and releases its lease. Failures remain `Started`; no account replay,
   cooldown inference or credential rotation is added.
6. A terminal client handle returns empty frames and no repeated error on later
   pulls. The facade sends at most one fixed named `event: error` after a valid
   prefix and aborts HTTP chunking; no successful terminator is appended.

Downstream disconnect detection follows the existing synchronous shared
gateway convention: a failed send or sender death cancels the native stream.
No new idle-client-close watcher is claimed. The pending root fixture wakes a
native pull after a downstream RST to exercise the failed-send path. Provider
socket tests separately observe actual upstream EOF, not fixture teardown or
a timeout, for projector failure and downstream cancellation.

### Preserved forms and explicit limits

- One stable generated Chat ID/model/created timestamp and one assistant-role
  prefix per request; ordered text and `reasoning_content` deltas.
- Binary signatures use independently **unpadded base64** encoded
  `devin_signature_delta` plus `devin_signature_encoding: "base64"`. Decode each
  delta and concatenate bytes; concatenating base64 strings is not equivalent.
  `devin_signature_type` is retained as a separate native metadata delta.
  No UTF-8 guess, vendor-signature invention or native-client claim.
- Tool indices follow native first-seen IDs; ID/name remain stable. Known
  function arguments retain whitespace and split UTF-8. Missing names or
  incomplete UTF-8 wait for later native deltas; raw JSON must validate at Stop.
  Limits are 128 tools and 8 MiB aggregate retained argument bytes.
  Custom/invalid-JSON tool forms, conflicting names, incomplete arguments and
  unknown semantic fields explicitly reject rather than disappear.
- Native reasons 1/3 -> `length`, 2/4 -> `stop`, 10 -> `tool_calls`,
  11 -> `content_filter`. `devin_stop_reason` retains the native integer without
  prematurely finishing the choice. Contradictory reasons and tool-stop with
  no tool call reject. Absent native reason follows the existing buffered
  decoder's end-turn convention, choosing tool-calls if calls were received.
- Usage is emitted only with known standard counters; absent counters and total
  remain absent rather than exact zero. `devin_usage_source` is
  `native_accounting` or `dimension_estimate`; `devin_usage_partial`,
  `devin_input_known` and `devin_output_known` always label presence.
  Cache write/read, status, native model and request ID are preserved inside
  `devin_usage`; no guessed standard cache-billing field is invented.
  Unknown usage extensions reject.
- Trailer behavior is lifecycle preservation, **not exact native trailer
  status/metadata fidelity**. Existing safe `InvalidResponse/Started` is kept.
  Raw metadata/messages are not forwarded because they may echo secrets.
  No status-string scraping, extra parser, auth rotation or trailer retry exists.
- Buffered Chat, Messages, Responses, catalog expansion, enrollment, quota and
  new input media semantics are not implemented by F23.

## Exact root admission artifact

[`F23_ROOT.patch`](F23_ROOT.patch#L1) is unapplied. Base:
`96e68387c309027baf58bd010c817b968d81ec2e`. Only proposed shared paths:

| Path | SHA-256 preimage |
| --- | --- |
| `src/mimic/gateway.gleam` | `d0fe0c567c827749f6f645865af2fc1f12ad18648fd30011962d9fa393dbcd1d` |
| `docs/devin/f22_local_cli.py` | `9538f62a9a6e0db004aa1fb59434d7da1b6fb5c31e09a620a8366e3829f3f90e` |

The root changes are exactly:

```gleam
import mimic/providers/devin/chat_gateway as devin_chat
// registry branch:
#("devin", model) -> devin_chat.registration(model) |> sanitized
// new streaming dispatch, existing buffered dispatch unchanged:
"devin", "generate", True -> devin_chat.serve(req, engine, None, request)
```

The artifact explicitly adapts F22's old buffered-only Chat-stream 422 check
to a streaming **unsupported Responses route** 422/no-I/O assertion. The safety
check is not deleted. F23's separate script owns the new Chat-stream positive.
Frozen F22 source/tests/docs and the parent `FINAL_UMBRELLA5.md` remain untouched.
Read-only `git apply --check docs/devin/F23_ROOT.patch` passed.

The current root already overwrites Devin's client operation with `generate`;
F23 needs only the existing Chat route. F24/F25 must coordinate preservation
of their client operation/protocol in the serialized root lane, not pretend
this F23-only dispatch admits those protocols.

## Focused commands and history

Gleam 1.18.1 via `mise exec gleam@1.18.1`; Erlang/OTP 29. No full
`gleam test` or integration run. Focused direct EUnit mirrors the existing
gleeunit `ScaleTimeouts(10)` setting, with external wall bounds and normal
cleanup acknowledgment. Failed attempts remain in the portable archive below.

```sh
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/devin/client.gleam \
  src/mimic/providers/devin/chat.gleam \
  src/mimic/providers/devin/chat_gateway.gleam \
  test/devin_chat_projection_test.gleam
erl -noshell -pa build/dev/erlang/*/ebin -eval \
  'R=eunit:test(devin_chat_projection_test,[verbose,{scale_timeouts,10}]),timer:sleep(1000),case R of ok->halt(0);_->halt(1) end.'
git apply --check docs/devin/F23_ROOT.patch
```

Attempts09/10 used one direct terminal call per run, an atomic
`build/f23/serialized.lock` directory/trap and exclusive creation of their unique
log. Attempt10 bounded build to45s and EUnit to75s, with outer140s. The test
fixture awaits worker/scope death and verifies removal of its own state
directory. Final enumeration found zero state directories and no serialized
lock. Forced-EUnit-timeout cleanup was implemented via a monitored scope but
not separately exercised; no stronger cleanup claim is made.

| Attempt | Outcome, not waived |
| --- | --- |
| 01 | Small generic lifecycle compiled; exit0, 16.106s including dependencies |
| 02 | Chat facade build failed: removed `None` import was still needed; corrected |
| 03 | Chat/projector/Mist facade compiled; exit0, 4.568s |
| 04 | Build passed; 1 passed /14 failed in20.026s: ordered constructed IR compared against canonical parsed objects, and incomplete fixed-length fixtures hid prefix bytes |
| 05 | After coherent comparison/fixture fixes, 14 passed /1 failed in1.365s: test expected padded base64 while existing signature convention is unpadded; corrected expectation, not signature bytes |
| 06 | Scoped format check failed on new adoption-test layout; no EUnit run |
| 07 | Wrapper duplicated an invocation despite lock/exclusive log; reports18 passed but **inadmissible as final serialized evidence** |
| 08 | Wrapper duplicated again; reports18 passed but **inadmissible as final serialized evidence** |
| 09 | One direct terminal invocation; **18 passed3.787s**, peer EOF/leases/backup/cleanup assertions |
| 10 | One direct terminal invocation; build passed0.63s; **19 passed3.222s**, adds decoded native dimension-estimate/partial-accounting regression |

The source corrections fix the rule, not the failing examples:
JSON object-key canonicalization is not a change of semantics, so successful
shared validation plus one event replaces ordered-list structural equality.
Partial socket fixtures use complete chunked prefix frames before a missing
HTTP terminator; production fixed-length framing was not weakened.

### Pending actual-root workflow

After coordinator admission, run the real root, not an overlay/facade server:

```sh
PYTHONDONTWRITEBYTECODE=1 mise exec gleam@1.18.1 -- \
  python3 -B docs/devin/f23_local_cli.py
```

The script creates only private synthetic state/client/session values and
operator-owned `127.0.0.1` fixture endpoints. Intended assertions: two fresh-VM
permanent-grant streaming successes, length/filtered success, seven independent
Started failures, actual downstream-RST cancellation, correct native request
headers/protobuf, stable client identities, binary signature reconstruction,
split-UTF8 tool arguments, partial/native usage, no backup replay, owner-lock
and fixture/state cleanup. Its internal120s alarm requires outer150s cleanup
allowance and the serialized gate slot. `--shipment` is available, but no
shipment run is claimed here.

## Owned hashes

All eight owned files were absent at the base; existing production/shared files
were not edited. The document's own final hash is supplied in the handoff to
avoid self-referential hashing.

| Owned path | SHA-256 |
| --- | --- |
| `src/mimic/providers/devin/client.gleam` | `08f4414cf4cf519417ddbc6836873cf672377d2cd4688cb7f0b277f549592f36` |
| `src/mimic/providers/devin/chat.gleam` | `a467c90dc7a91783d68bd8a15382e06b015d8d256bbade82fe069ed5d65a4367` |
| `src/mimic/providers/devin/chat_gateway.gleam` | `249eb630c4ea08836db1601b35c0ac304adeba70e03fe70b1a0ca6d6644e375d` |
| `test/devin_chat_projection_test.gleam` | `749dcfa832f4a873554be5009275aab29399b041f826b1ad61461f645aaac531` |
| `test/mimic_devin_chat_projection_test_ffi.erl` | `3034c79b0e6d6cd5ca32dca5a5f4c515dc9c36d52517bdc9ae766da3751c1079` |
| `docs/devin/F23_ROOT.patch` | `c984af0047c125206a27f296ff818ca46f943bdc6d1e747061e4d9568ca115a1` |
| `docs/devin/f23_local_cli.py` | `a3da0978c53865c6355ec58729aef71a258c46d0b5f93723eddc24ffaa10a3bb` |

Unchanged native preimage hashes:

```text
df57541ea2831248cebfb145b041a774f47e64095d4e44d826f95951108cd226  bridge.gleam
0a2ed4f7f5d9150f2c22a77536588b9c42d98f4f9e7e9509d9620bbd905a54d6  stream.gleam
913cc99bd257f889c2ff565b8de16ccc0020b6fd45ac83227faa5bf390a15ca6  response.gleam
```

### Portable exact-byte log archive

The ignored `build/f23/attempt*.log` streams are retained locally. The archive
below retains all ten logs through the parent import. Remove whitespace from
the base64 packet, decode it, gzip-decompress, then JSON-decode to a mapping of
filename -> exact UTF-8 log text. No credentials or request plans were logged.

| Log | SHA-256 |
| --- | --- |
| `attempt01-contract-build.log` | `a99b117b5578eb71db81613ffdbdf10690edf9fb15d68bf6949955d8054ab420` |
| `attempt02-chat-build.log` | `a14dd66ac15cc726bbf5af20baa66149b768f88758114c44c185aba93d56d0d9` |
| `attempt03-chat-build.log` | `e64481ec3c2a671876c1b7780be3081238b4a4522df45be556e55df78d79a35b` |
| `attempt04-focused.log` | `493a8ad8f877084aa2f223e815994ac4c52f69bc063671718953168e7c047811` |
| `attempt05-focused.log` | `09a20aef3d81ad42cbda9391d099f8a650453c8035763989a5e9545dbfbbed8b` |
| `attempt06-focused.log` | `b9742a7ac63bbb9bf7e0dc1761f9323dfdb2894f0a816711be54d3308e7483a5` |
| `attempt07-focused.log` | `0af9f8235e29f897b89b62465c744743f94f711d5c01e673324a103c67aa33ac` |
| `attempt08-focused-serialized.log` | `275638de9e7138b4c1d3a213fbee98c9f3a1b4f17a7fbbc0ecff12f74d4c1d49` |
| `attempt09-direct-eunit.log` | `458be3ca3841efe785435ac05390e957a08ef811596ff691933ecb2d939d40aa` |
| `attempt10-final-native-usage.log` | `2919623456517d76d79cde996d6615393ca5fa7f9d0eac9a3d3c52b98a6b2de2` |

```base64
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
```
