# F25 — bounded Devin Responses projection

**Not admitted.** Independent review found gaps not covered by the historical
90-test receipt. `F25_REVIEW_REPAIR.md` supersedes current contract/validation
claims below while source repairs and user approval of usage representation
remain pending. No validation of this repaired revision has run during HOLD.

## Checkpoint, not parity admission

Source implementation and a real authenticated root CLI/shipment harness are
present. No compile/BEAM/socket/workflow ran during the initial validation HOLD.
After explicit grants, scoped format/build and **90 focused tests passed** on
an exact copied parent snapshot containing qualified F28. Python consumer checks
also passed. Receipts, retained failures and input hashes are in
`F25_VALIDATION.md`. Root wiring/source/shipment/full-suite execution remains
parent-owned and pending; this is not actual-route or full parity admission.

Base inspected read-only: `dd15c610ec39e4f296c30fe02347d0d2b368a629`.
Historical rejected Devin packet `75bc6daa8e095b74f4e1962222e56ea9de53db05`
was inspected with read-only `git ls-tree`; it contains Chat/Messages/native
codecs but **no Responses projection**. No historical test claim is reused as
new evidence. No children, Git/JJ mutations, commits, source overlays, ambient
credentials, native SDK, CPA process, browser authorization or live/remote Devin.

### Owned paths and approved seams

- New provider modules: `responses_request.gleam`, `responses.gleam`,
  `responses_stream.gleam`, `responses_gateway.gleam` under
  `src/mimic/providers/devin/`.
- New `test/devin_responses_projection_test.gleam`,
  `test/devin_responses_oracle.gleam`,
  `test/mimic_devin_f25_responses_test_ffi.erl`.
- New this document, `F25_ROOT_HOOKS.md`, `f25_local_cli.py`,
  `f25_consumer_selfcheck.py`, `F25_VALIDATION.md` and hash records.
- Parent-approved minimal existing-file changes: bridge protocol decode branch;
  catalog gateway registration/validation/buffer/SSE dispatch and additive
  `open_responses`; F27's single exact protocol-list expectation.

F24 builder/stream/depth tests, F22 transport, root/config/CLI, runtime/auth/
store/vendor and shared Responses/S6 codecs are untouched. Only the parent may
enable `POST /v1/responses` at the actual root.

## Immutable public source actually inspected

CPA pin `acdace936fa7df2905500c7f5e0a97d683138dea`. The paths below were read
as public source, not executed. Source comments and source tests do not prove
upstream/client compatibility. Native codec provenance remains in
`SOURCE_CONTRACT.md` and `CPA_SHA256SUMS`.

| Path at the pin | SHA256 of fetched bytes | Relevant rule |
|---|---|---|
| `internal/translator/openai/interactions/responses/interactions_openai_responses_request.go` | `e6a1209dd6a4cd8de65fb93eac8a56ac7443b42d33679355fe7cecc757b6feea` | Responses input/call/result/media translation, not Chat JSON renaming |
| `internal/translator/openai/interactions/responses/interactions_openai_responses_response.go` | `0d711909072697d4a5d71d17b0503d9ee5c36b3a77c1274ceb4d9461d4eec452` | Thought -> summary, function items, length/filter terminal mapping, recognized encrypted content |
| `internal/signature/provider_compatibility.go` | `1fa2dc9184156f2c41779b503e630b32b32b8b1ac02542ea3d1103991fcbe51e` | Recognized signature-provider predicate; no cryptographic validity claim |
| `internal/signature/gpt_validation.go` | `8f8ec355890c7d1bf24ad5b3fb5e8126ffcbc80b3a369c22f518e31c9091cd3b` | Explicit `gAAAA` base64url, version 0x80, >=73 bytes, positive 16-byte ciphertext blocks |

For example, the pinned response translator's usage routine defaults unknown
counters to numeric zero. **F25 deliberately does not reproduce that loss.**
Likewise CPA's broad recognized-provider predicate is not permission to guess
an Anthropic/sealed/binary signature into OpenAI encrypted content.

Pinned official Python SDK source has now been inspected in the review repair;
no installed Python/TS Responses SDK was executed here. The new
consumer is an independent strict append/done/terminal oracle; it is not called
an SDK or NativeSDK qualification.

## One JSON/SSE construction and acceptance rule

Validated native `response.Event`s are the only producer input. The existing
native decoder handles Connect/protobuf, split UTF-8, trailer errors and
cumulative usage. F23's native `Stream` withholds `Stop` until native Connect
EOS **and clean HTTP EOF**; F25 reuses it, not another parser.

1. A first-seen function call creates one logical output slot keyed by its
   actual native call ID. Later argument/name fragments fill the original slot.
   They never reserve/reopen an index or split the current text run.
2. Adjacent text/thinking fragments merge. A new tool separates logical runs.
   The native signature has no block ID, so multiple distinct thinking runs
   remain explicitly unsupported rather than guessed.
3. Stop finalization requires exact nonnegative native input/output counters,
   supported explicit stop semantics, complete names/UTF-8/JSON-object function
   arguments and unambiguous reasoning signature associations.
4. One opaque `Projection` contains both qualified JSON and SSE frames.
   Final JSON is bounded and decoded by the strict shared Responses document
   API; every emitted frame is pushed through the shared strict Responses/S6
   observer **before either encoding is accepted**.
5. SSE serializes created -> sequential item/part added -> delta -> text/args
   done -> part/item done -> completed/incomplete. Optional raw tool `name` and
   `call_id` are included and must match the established item. Monotonic
   sequence numbers start at zero. Full terminal content must reconstruct
   exactly from deltas in the independent test/CLI consumer.

This is **delayed buffered-to-SSE**. No opening/output/success frame escapes
before the entire common response has passed finalization. It is not a claim
of incremental native/token latency. The created envelope initializes usage
with the actual final exact counters; no provisional zeros are fabricated.

### Identities and accounting

- `resp_devin_<fresh uuid>` is a new local client projection identity, not a
  claim to preserve upstream IDs omitted by the current native event API.
- Output IDs derive from that response identity plus first-seen index. Raw
  native call IDs remain separate `call_id`s, so item IDs cannot repair pairing.
- `model` is the requested, admitted public alias. F27's adapter resolves native
  UID/max/images from the **actual selected Context account and exact origin**,
  including failover, not the dispatcher's first account.
- `created_at` is the local projection creation epoch in seconds, not an
  upstream timestamp. Integer milliseconds remain the native runtime clocks.
- `usage.total_tokens` is the arithmetic sum of two qualified exact counters.
  Native cache/status/request-ID/model accounting is retained in named `devin`
  metadata via the corrected F24 exact-usage qualification rule. No guessed
  Responses reasoning/cache details or counts from text length are added.

### Supported native output subset

- Text and validated JSON-object function calls, including delayed names,
  interleaved calls and split UTF-8 arguments.
- One unsigned reasoning summary (Responses permits no encrypted content), or
  one summary with the actual explicit `openai` signature whose `gAAAA…` outer
  shape matches the pinned transport validator. The exact string is retained.
  This does not verify authenticity/decryptability.
- Exact zero, positive totals, cumulative partial native snapshots that become
  exact before Stop, and preserved native cache accounting.
- Reasons `2/4 -> completed`, `1/3 -> incomplete/max_output_tokens`,
  `11 -> incomplete/content_filter`; `10 -> completed` with a real function
  call. Original reason remains in named metadata.

### Explicitly unsupported output

- Missing semantic reason, unknown/conflicting reason, native tool stop without
  a call, missing/truncated EOS or HTTP EOF, data after EOS, malformed/unknown
  native fields or trailer failure.
- Missing/partial/negative/dimension-estimated accounting. A successful HTTP
  request does not qualify unknown usage.
- Invalid/custom/non-object/incomplete/conflicting function arguments or names.
- Orphan/ambiguous signatures, unknown source tags, Anthropic/sealed/binary
  opaque signatures, malformed GPT envelope, multiple reasoning runs.
- Bounds exceeded. JSON cannot silently succeed where the matching SSE cannot.

## Native Responses request input

`responses_request.decode` builds the existing typed `ir.Request` directly;
the shared Responses parser validates structure/pairing and the CURRENT native
encoder remains authoritative for tools/media/options. The bridge adds exactly
one new protocol decode branch.

Accepted narrow inputs:

- Explicit string input, or user/assistant message history with string content
  and role-appropriate `input_text`/`output_text` parts.
- `instructions`, positive configured `max_output_tokens`, current native
  `temperature` range, `stream` consistent with the runtime mode.
- Flat function tools with name/description/object parameters; complete
  function calls and string results locally paired by `call_id` in this request.
- One summary per reasoning-history item, optionally with explicit qualified
  GPT encrypted content; native history encoder determines final association.
- Supported inline image data URLs mapped to the existing native media codec;
  remote URLs are never fetched.
- `store:false` or omission; absent/null previous ID means no continuation.

Reject unknown fields and unrepresentable control/data instead of dropping it:
strict/namespace/custom/hosted tools, tool choice, reasoning controls, output
formats, files/audio, image URLs/file IDs/detail settings, nonempty annotations,
system/developer message-role guessing, incomplete history status, item refs,
sealed/unknown encrypted history, stored responses and non-null previous IDs.
An empty native tool-definition list remains unsupported by the current native
encoder. No namespace normalization or orphan-tool repair is invented.

Continuation is **not** granted by projection. No receipt/cache/state/cursor is
created. A full local history may pair calls/results but does not acquire
`Continuation`/WS capability. Cross-tenant/account/model previous IDs reject
before credential acquisition/I/O, including IDs emitted by this route.

## Bounds and resource lifecycle

- Input/native bytes and retained semantic bytes: **8 MiB aggregate** each.
- Native semantic events: **16,384**; logical output items: **256**;
  function calls/tool definitions: **128**.
- Request/tool/final JSON depth: **128**; decoded value limit: **65,536**.
- Qualified final JSON: **512 KiB**. Shared strict SSE frame bound: **1 MiB**;
  aggregate serialized SSE: **8 MiB**.
- F28 original absolute monotonic native deadline: **10,000 ms**, not reset by
  chunks/account failover; runtime's documented extra cleanup allowance:
  **1,000 ms**. F25 adds aggregate byte accounting only, no duplicate timer.
- Existing synchronous client adoption, explicit cancel, owner-death cleanup,
  Started/no-replay rule and existing HTTP transport are reused.
- Cooperative construction checks use that **same original deadline** before
  each native event and after final JSON/SSE construction. An expired budget
  cannot publish success; no timer/process is added or budget reset after EOF.

The focused composed native-client deadline/cancel/owner-death test passed
using the exact parent F28 runtime bytes; the actual-root 10s JSON/SSE slow
trickle/shipment gate remains pending. CPU construction is bounded by bytes/events/items/
depth; a single bounded pure operation is not hard-preempted or presented as a
separately measured real-time scheduling guarantee.
There is no new idle downstream disconnect watcher: a disconnect during delayed
construction is bounded by original runtime deadline/owner lifetime, not
claimed immediate. Native/runtime failure attempts a safe `error` event even
for runtime cancellation; downstream write failure cannot produce success.

All services/fixtures remain numeric loopback. F22's remote/H2 qualification
and separate Devin authorization gate remain closed.

## Written regression coverage and bounded validation request

New focused module has 18 test entrypoints covering pure construction/limits,
all native byte splits, independent content equality, exact/partial/estimated
usage, reasoning/tool variants, S6 identity, request-specific capabilities,
unknown input before I/O, model/account/origin/auth mapping, absent tenant
receipt, actual native sockets, nativefail/truncation, 429 failover, cancel/
owner-death/original deadline and downstream cancel/error. It does not import
root or pretend its fixture socket is an actual `/v1/responses` route.

FFI runner also includes unchanged Chat/Messages/F27/S6 suites. The actual-root
CLI harness has:

- Seven JSON + seven SSE positive variants and delta reconstruction equality.
- Twelve failures in both modes; all must avoid success and Started replay.
- Unauthorized/unknown/unenabled/compact/unsupported/cross-tenant denials before
  native I/O; exact selected-context 429 failover and model-only-on-B selection.
- Four ordinary Chat/Messages JSON/SSE schema regressions.
- Four cleanup variants: JSON and SSE original-deadline slow trickle (defeats
  per-pull idle timeout), downstream close while buffering, VM-owner stop.
  Dedicated provider tests cover explicit client cancel and adopted-owner death.
- Fresh private synthetic CLI-imported grants/client keys, runtime per row,
  server/VM/runtime-lock/private-state teardown and secret non-echo assertions.
- `--shipment PATH` uses the actual shipped entrypoint. No source overlay.

After explicit grant, owner requests one serialized slot:

1. Format **only** new/approved paths, build via Gleam 1.18.1.
2. Run `gleam run -m devin_responses_projection_test` under
   `ERL_FLAGS='+S 2:2 +A 2'`, bounded **150 s**.
3. Python syntax/independent consumer selfcheck (no socket/CLI), bounded **15 s**.
4. Return measured successes/failures and release slot. Parent separately runs
   full `gleam test` and actual-root source/shipment harness (internal bound
   **240 s**, recommended outer **270 s** each).

The owner executed steps 1–3 after explicit grants on the exact parent snapshot.
See `F25_VALIDATION.md` for the passing run and all retained failed attempts.
Root source/shipment and full-suite gates were not executed by this owner.

| Gate | Current evidence |
|---|---|
| Source/contracts/pinned public bytes inspected | Read-only facts above |
| Format/compile/focused provider tests | Passed; all 90 focused tests, including all 18 F25 |
| F28 composed native-client deadlines/cleanup | Passed on exact parent runtime bytes; root/shipment still pending |
| Python syntax/independent consumer checks | Passed; 6 syntax files, 6 positives, 4 negatives and safe-error control |
| Actual root source route | Parent-owned, pending root hook and run |
| Shipment actual route | Parent-owned, pending shipment and run |
| Full assembled `gleam test` | Parent-owned, pending |
| Installed SDK/native client/CPA differential | Not executed; not qualified |
| Remote/live Devin authorization/transport | Not authorized; gate remains closed |
