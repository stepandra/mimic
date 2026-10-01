# F24 — corrected bounded Messages construction

## Status and ownership

This is a corrected **local synthetic subset**, ready for the parent's root
admission workflow. It is not native Devin/Anthropic parity, incremental
streaming, installed-SDK execution, or remote/live qualification.

Own base: `dd15c610ec39e4f296c30fe02347d0d2b368a629`.
Recovered rejected candidate:
`75bc6daa8e095b74f4e1962222e56ea9de53db05`, from prior Devin thread
`ksQQweRIpNx2Sm-sVPBOJ-0quJLOAFRc85IBxBDu1fs15rdKs6m5jRdeJnRz`.
Its historical 29 observer-based tests are **not** SDK qualification.
The recovery used read-only transcript/public-source reads and immutable
`git show` from the attached repository, never historical transcript commands.
No sibling/primary changes, whole-ancestor merge, refs, commits, pushes,
children, credentials, CPA calls or remote Devin calls.

Only these F24-owned paths were changed:

- `src/mimic/providers/devin/messages.gleam`
- `src/mimic/providers/devin/messages_stream.gleam`
- `src/mimic/providers/devin/messages_gateway.gleam`
- `test/devin_messages_projection_test.gleam`
- `test/devin_messages_oracle.gleam`
- `test/mimic_devin_f24_messages_test_ffi.erl`
- this document, `F24_ROOT.patch`, `f24_local_cli.py`

Current F22/F23 modules and tests were not edited. The source decoder, native
stream and generic F23 `client` remain the lifecycle source of truth.
The root gateway/config/CLI belongs to the parent.

## SDK source actually read

Read public immutable sources and their version files in this correction:

- Python **1.11.0**, `18f25547f20cf5f01da69ac611e700e3bc9ebf21`:
  [version](https://github.com/anthropics/anthropic-sdk-python/blob/18f25547f20cf5f01da69ac611e700e3bc9ebf21/src/anthropic/_version.py),
  [accumulator and callbacks](https://github.com/anthropics/anthropic-sdk-python/blob/18f25547f20cf5f01da69ac611e700e3bc9ebf21/src/anthropic/lib/streaming/_messages.py#L346-L534),
  [required thinking signature](https://github.com/anthropics/anthropic-sdk-python/blob/18f25547f20cf5f01da69ac611e700e3bc9ebf21/src/anthropic/types/thinking_block.py#L8-L26).
- TypeScript **0.131.0**, `d49bdab458000bcdffe77bd84b03293f31824fb3`:
  [version](https://github.com/anthropics/anthropic-sdk-typescript/blob/d49bdab458000bcdffe77bd84b03293f31824fb3/package.json),
  [last-content callbacks](https://github.com/anthropics/anthropic-sdk-typescript/blob/d49bdab458000bcdffe77bd84b03293f31824fb3/src/lib/MessageStream.ts#L459-L510),
  [append-then-index accumulator and cumulative usage](https://github.com/anthropics/anthropic-sdk-typescript/blob/d49bdab458000bcdffe77bd84b03293f31824fb3/src/lib/MessageStream.ts#L581-L674).

Both append starts and later index deltas. Both mutate initialized usage;
TypeScript callbacks use `.at(-1)` rather than repairing an arbitrary open
index. Signatures replace the snapshot signature, not append fragments.
Tests use an independent, stricter construction oracle grounded in these
rules, not permissive expectations added to the Claude observer.
No SDK install or execution is claimed.

## One construction rule

The rejected candidate had two unrelated constructors: native buffered
accumulation and incremental SSE index reservations. It accepted unsigned
thinking/absent usage, started blocks `1,2,0` after delayed names, left every
block open until Stop, and split interleaved same-tool/text differently.

The correction uses **one bounded Builder** for both JSON and SSE:

1. A first-seen tool creates one logical slot. Later fragments fill that slot
   (including split UTF-8 arguments and delayed names). They never reserve a
   client index, reopen a block, or split the current text run.
2. Adjacent text/thinking fragments merge in their logical run. A new tool
   separates runs. Native signatures have no block ID, so more than one
   thinking run is explicitly unrepresentable.
3. No success frames are emitted until native Stop, which F23 supplies only
   after Connect EOS **and clean HTTP EOF**. At that barrier the constructor
   requires complete JSON-object tool arguments, names, source-typed signature,
   supported stop semantics, and exact native input/output counters.
4. Both serializers use that identical qualified response. `message_start`
   initializes usage with the actual **final exact native totals**, not guessed
   initial zeros. Final cumulative usage overwrites those same totals.
5. Blocks are emitted in final first-seen order: start `0`, deltas for `0`,
   stop `0`, then start `1`, and so on. Thinking includes its signature before
   stop. There is never more than one open block, including for TS callbacks.

This is **delayed buffered-to-SSE**, not incremental/token-latency native
streaming. It trades latency for an honest construction when initial exact
accounting, delayed names and tool completion are unavailable. Native events
do not expose enough information to close/reopen interleaved Anthropic blocks
incrementally without changing semantics. No model/count/signature is invented.

Supported:

- Plain text, validated JSON-object tools, delayed names and interleaved tool
  fragments, including split UTF-8.
- One thinking run with an explicit `anthropic` source tag and the actual
  nonempty `CAQS…`/`CAIS…` string forms recognized by the **current** native
  history codec. Preserved verbatim; not cryptographically verified.
- Exact counters (including measured zero), cumulative partial snapshots
  completed by the existing native decoder, native cache accounting retained
  in named `devin_usage` metadata (not guessed Anthropic cache semantics).
- Native reasons `1/3 -> max_tokens`, `2/4 -> end_turn`, `10 -> tool_use`.
  The native reason is retained in message metadata; tool stop needs a tool.
- Current native input mapping for signed thinking/tool-call/result history
  and supported inline images. Actual native codec determines associations.

Explicit rejection:

- Absent, negative, incomplete or dimension-estimated usage at completion.
- Unsigned thinking, missing/unknown signature type, OpenAI/sealed/binary opaque
  signatures, ambiguous multiple thinking runs or orphan signatures.
- Custom/invalid/non-object/incomplete/conflicting tools; unknown native fields,
  unsupported blocks/extensions, filtered/unknown/conflicting stop reasons.
- Unsigned/opaque history, unsupported document/audio/redacted blocks,
  orphan tool history and image URLs (no URL fetch).
- Limits exceeded. The buffered route does not silently accept an answer that
  its corresponding SSE representation cannot construct.

## Bounds and resource lifetime

- Native transport bytes: **8 MiB aggregate**, not per chunk.
- Retained semantic bytes: **8 MiB aggregate**, including repeated tool IDs,
  names, usage metadata and signature fragments.
- **16,384** semantic events, **256** logical blocks, **128** tools.
- Both encodings require final JSON <= **512 KiB**. This deliberately bounded
  subset leaves room below the shared Claude codec's **1 MiB/event** limit;
  tool input is sent as one complete fragment. Aggregate SSE <= **8 MiB**.
- **10,000 ms request-wide native I/O deadline**, created once before runtime
  execution, not reset per chunk/account attempt. The small resource wrapper
  delegates all HTTP work to `bridge.configured_adapter`. A monitored timer
  kills only that runtime execution worker at expiration. Existing runtime/
  egress monitors close its socket and release the lease, even during buffering
  or when no further pull occurs. Normal cancel/EOF stops and joins the timer.
- F23's existing synchronous adoption, owner-death cleanup, explicit client
  cancellation and no replay-after-Started behavior remain unchanged.

There is no new idle downstream-close watcher. Explicit cancellation/owner
death while buffering is tested; idle client disconnect detection is not
claimed. Deadline/limits bound that remaining wait. CPU construction is
bounded by input/response/event limits, not presented as a separately measured
real-time scheduling guarantee.

Failure before finalization emits no malformed success prefix; the root sender
can emit a fixed API error. Downstream cancellation after finalization can
receive a **valid** initialized SDK prefix, but no later stop/success. Native
trailer messages/metadata and credentials are never copied into diagnostics.

## Compiled root contract and admission

```gleam
registration(String) -> Result(registry.Model, String)
combined_registration(String) -> Result(registry.Model, String)
execute(runtime.Runtime, Option(String), contracts.Request)
  -> Result(String, contracts.Failure)
open(runtime.Runtime, Option(String), contracts.Request)
  -> Result(#(String, client.Client(messages_stream.State)), contracts.Failure)
serve(Request(mist.Connection), runtime.Runtime, Option(String), contracts.Request)
  -> Response(mist.ResponseData)
```

Optional `configured_registration`, `execute_configured`, `open_configured`
accept the existing `List(models.Model)`, not any unadmitted F27 type/manager.
Default combined registration unites only actual F23 Chat and F24 Messages
capabilities; there is no Responses or remote opt-in.

`F24_ROOT.patch` applies to **actual dd15c610**, with current gateway preimage
SHA256 `489a9e7d542c2626899cf68654a4949f71dbdfa48cd0c80df3cdf229f4c7798f`.
It adds the import, combined registration, authenticated Messages account
selection, original client operation before native `generate` remapping,
`anthropic-messages` protocol and execute/serve dispatch. Config/CLI unchanged.
`git apply --check docs/devin/F24_ROOT.patch` passed. The parent reports its
serialized root hook applied while preserving the newer F09 Claude call.
The owner's isolated root was **not** modified/emulated.

After owned-file admission, parent runs the actual root:

```sh
mise exec gleam@1.18.1 -- python3 -B docs/devin/f24_local_cli.py
```

The script uses fresh private state, CLI-imported synthetic session/client
credentials, actual `/v1/messages`, two operator-configured loopback accounts,
native headers/input-history assertions, 2 buffered+2 SSE positives with strict
reconstruction equality, 8 failures in each mode, and unauthorized/unknown-model/
unsupported-block denials before I/O. A fresh runtime per request proves
primary selection and zero fallback accepts. It tears down server workers,
gateway VM, runtime lock and private state. Internal wall bound 120 s; use an
outer 150 s bound. `--shipment PATH` uses the actual shipped entrypoint.
**Syntax and consumer selfchecks were checked by this owner; actual root
source/shipment execution is parent-owned and pending.** No overlay or
facade-server pass is substituted.

## Verification and retained failed attempts

Exact scoped commands:

```sh
mise exec gleam@1.18.1 -- gleam build
mise exec gleam@1.18.1 -- gleam run -m devin_messages_projection_test
mise exec gleam@1.18.1 -- gleam format \
  src/mimic/providers/devin/messages.gleam \
  src/mimic/providers/devin/messages_stream.gleam \
  src/mimic/providers/devin/messages_gateway.gleam \
  test/devin_messages_projection_test.gleam test/devin_messages_oracle.gleam
git apply --check docs/devin/F24_ROOT.patch
git diff --check
```

History (not erased by later passes):

1. Initial build failed: nested List passed into SSE document flattening.
   Corrected the construction expression; no expectation relaxed.
2. Root artifact initially had incorrect final hunk counts (`22`, then `20`,
   actual `21`); only hunk headers corrected before apply-check passed.
3. Focused test compilation failed: unavailable `list.range`. Replaced with
   indexed fixed list; no test cases removed.
4. First focused run: **17 pass / 9 fail**, 1.712 s. Successes rejected at strict
   IR boundary: positional `ir.Response` put response metadata into
   `message_extensions`. Corrected to named constructor fields.
5. Next run: **26 pass**, 3.163 s.
6. Added consistent JSON/SSE encoded-limit and separate block-limit regression:
   **27 pass**, 2.069 s; build 0.87 s. Scoped format, workflow syntax, diff check
   passed. `build/f24` contained no remaining fixture/private-state directories.
7. Workflow consumer independently passed 1 synthetic positive and 4 historical
   malformed-prefix selfchecks (missing usage, first index 1, overlapping starts,
   unsigned thinking). No gateway process was started. Final format/apply/diff
   checks passed, and HEAD remains the original `dd15c610`.

The dedicated runner uses EUnit with the same timeout scale 10 as gleeunit;
`gleam test` discovers the whole repository, so it was intentionally not run
under the explicit **no full heavy gate** instruction. F22/F23 destination/full
regression, actual SDK execution, shipment/root workflow, CPA differential,
native clients, remote qualification and live authorization remain distinct
unverified gates, not inferred from the focused suite.
