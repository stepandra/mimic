# F04 runner review recovery

**FOCUSED REVIEW GATE PASSED / QUIESCENT, NOT LIVE ACCEPTANCE OR FULL-SUITE DONE.**
Live/native admission remains **BLOCKED**: the Linux C launcher is not approved
and F02/F03 are unqualified. Supplied digests remain identity claims, never
runtime proof. No native, live, provider, CPA, browser, Docker or VM action is
authorized by this work.

## Recovery provenance

Read-only source:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/v0yy112bvded/mimic`.
Recovery destination:
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/64cjh4e39ygn/mimic`.
Only owned deltas were applied with `apply_patch`; no source checkout/ref
mutation, duplicate baseline copy, root hook/config/build edit or import has
been performed. The historical thread ID was not resolvable locally, so exact
preserved source—not an inferred thread state—was used.

The following six recovery-stage files were byte-identical to the stopped
worker before the missing regressions and terminal-bound refinements were
added. These hashes prove recovery only, not successful compilation/tests:

```text
79783dfb2148fd4f6aa79709b0be87061f791462ea762b7f78bcaa9e0da46671  src/mimic/live.gleam
60b81781da23df3628471eaade79a0a45a1c946d9bc671deb10a8bf58a4c2635  src/mimic/live/http.gleam
d0bbb768946bc1790a671ffedafafce9157d6c8fe05ff0590b0798e9f8b82253  src/mimic/live/runner.gleam
0ddca62b6537580d280aa2869a01a4f9dcb492c4add1b661227bc495976cf84a  test/live_test.gleam
14e9340bff93a954374521a02b3560536a741a60b2b5b541439993337fde3da6  test/live_execution_test.gleam
8eb0c931b452bb689fb37fa9acecb6fe2d926be283b15923950a29297239bfed  test/mimic_live_test_ffi.erl
```

`admission`, `budget`, `identity`, `policy`, `synthetic` and production
`mimic_live_ffi` were already identical to the parent baseline and were not
copied. The parent root dispatch is already wired to `live`.

## The three corrections

1. **Check ordered usage before any later pull.** The HTTP adapter reuses
   unchanged bounded `sse.feed_one`/`sse.finish`; each parsed frame can yield
   `ObservedUsage(Usage, connection)`. Raw body bytes first yield `Data` exactly
   once for the existing byte/chunk budget. Chunk-separator reads are delayed
   until already-read frame observations have been checked. A complete known
   over-ceiling snapshot ends execution and closes the run before a coalesced
   lower snapshot, truncated tail or never-arriving terminal can overwrite it.
   No unmetered usage-byte channel is introduced.
2. **Separate peer-close evidence from timeouts and server drops.** Test FFI
   `peer_read` returns only OS tags: closed, reset, timeout, data or error.
   Positive assertions require closed/reset observed before fixture cleanup.
   A deliberate server-side drop is labeled separately. A real open-peer
   negative control keeps the client open through an old 500ms error-only probe
   and a typed 500ms probe: the former's predicate would wrongly accept closure;
   the latter must produce timeout and fail the close predicate. The old tests
   proved neither actual production closure nor a production leak.
3. **RFC `tchar` header names.** Only ASCII letters, digits and
   `!#$%&'*+-.^_` plus backtick, `|` and `~` are accepted. Printable separators,
   spaces, controls and non-ASCII bytes are rejected. The genuine CRLF fix still
   uses exact terminal `split_once`, never grapheme-count trimming.

## Supported synthetic usage contract

JSON has an optional top-level `usage` field. Missing or null is unknown and
never clears earlier counts. An asserted non-null field must be exactly:

```json
{"usage":{"input_tokens":1,"output_tokens":2}}
```

Both values are cumulative nonnegative integers, with no additional usage
keys, and cannot decrease. Partial/delta/ill-typed asserted usage is an explicit
contract error; negative or decreasing assertions retain prior validated
counts, close the socket and close the run. Malformed JSON/SSE is an explicit
read error rather than unknown usage, retaining prior counts and closing the
socket. `End(None)` retains counts; `End(Some(...))` uses the same validation
and counts toward the 1024-observation cap.

An over-ceiling snapshot is retained as breach evidence, with observed cost
unknown. Budget reservation still precedes worker launch; reservations never
refund. Duplicate admission, exact endpoint/route/body allowlists, zero retries,
64KiB byte/frame caps and existing chunk/deadline/socket bounds remain unchanged.
Generic injectable transports are trusted test code, not a sandbox or a claim
about universal provider semantics.

## Focused regression matrix (passed)

All cases below are covered by the eight offline and twenty execution test
functions invoked by their dedicated mains. Both mains returned exit 0, and
the execution main also completed the existing actual synthetic CLI harness.
This does not imply a full `gleam test` or root composition pass.

- Runner pull-order witness: high usage prevents every later pull/cancel is
  observed; no refund or reopening.
- Cumulative input/output decreases and negatives; `End(None)`, equal terminal
  counts and decreasing `End(Some(...))`.
- Exactly 1024 versus 1025 observations, including a terminal snapshot.
- Real HTTP coalesced high-then-low, high-then-truncated and high-with-no-further
  chunk separator/terminal.
- Event prefix, comment, `data:` without a space, multiline JSON, CRLF and a UTF-8
  codepoint split across the actual adapter's 4096-byte pulls.
- Known counts followed by missing/null usage.
- Decreasing, partial, delta, extra-key, nullable-member, string, array, boolean
  and negative asserted usage.
- Exact versus one-byte-short HTTP usage-body budget, and truncated SSE after
  a prior valid snapshot.
- Open-peer timeout negative control and strict positive closure evidence for
  the original success/cancellation/timeout/error fixtures.
- RFC header-name regression and the unchanged exact CRLF cases.

## Actual single-slot validation evidence

The parent granted exactly one immediate 300-second slot, including cleanup.
The duplicated grant was not treated as a second permission. The shared lock
was acquired atomically with token
`f04-review-f272b071407d48d8afbadad759e9de55`; cleanup and the descendant/input
audit completed at **208.25 seconds**. No background or deferred run remains.

Artifacts are retained under:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/64cjh4e39ygn/mimic/build/f04-review-f272b071407d48d8afbadad759e9de55
```

The first startup attempt failed before any compiler subprocess launched because
bare `gleam` was absent from PATH. Its empty `logs/01-version.log` and
`SETUP_FAILURE.json` are retained; this was a setup failure, not a test failure.
The parent confirmed the installed executable and the remaining direct calls
used `/opt/homebrew/bin/mise exec gleam@1.18.1 -- gleam`, with
`ERL_FLAGS='+S 2:2 +A 2'` and the existing Erlang environment.

| Retained log | Actually reached result |
| --- | --- |
| `logs/01b-version.log` | Gleam 1.18.1, exit 0 |
| `logs/02-owned-format.log` | Only ten owned Gleam paths formatted, exit 0 |
| `logs/03-closure-check.log` | Exact dependency closure `gleam check`, exit 0, no warnings |
| `logs/04-offline.log` | Dedicated main: all eight offline functions passed, exit 0 |
| `logs/05-execution-cli.log` | Dedicated main: all twenty execution functions and the existing actual synthetic CLI harness passed, exit 0 |

No genuine semantic failure occurred; no assertions were weakened and no
corrective test rerun was performed. The unchanged CLI workflow still retained
one request / 89 input / 32 output / 274 synthetic nano-USD, rejected the new-ID
retry and duplicate, and reported usage/cost unknown, running identity unverified
and native/live/differential not run.

`SOURCE_RECEIPT.json` records **17 exact input paths** and **108 files under the
eight unchanged pinned packages' `src/**` directories**. Exact copied input and
package-source hashes matched again after execution. There are no source stubs,
logic overlays or edits to the shared parser/binary/socket FFIs. Receipt SHA256:

```text
5af23d103c4c44f075059729cde7f7efdeb5e6d324ece0ab21f2ce8c56c46cbf
```

`AUDIT.json` records empty owned process-group/descendant lists both before and
after cleanup, an empty private fixture directory, matched hashes and removal
of only the verified token/inode-owned shared lock. All five launched direct
commands exited. No full suite, root composition, live/native/provider/CPA/
browser/Docker/VM action was run.

## Approved bounded plan (executed once, not repeat permission)

The single granted slot followed this sequence:

1. Atomically `mkdir` the shared coordination lock
   `/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock`.
   If it exists, stop without taking over. Record ownership and remove only
   this invocation's own lock after all directly invoked processes have exited.
2. Use Gleam **1.18.1**, `ERL_FLAGS='+S 2:2 +A 2'`, unique no-clobber logs and
   directly awaited commands. No background/deferred runs or automatic retries.
3. Format only owned Gleam paths. Prepare a new exact closure with the 15
   historical source/test/contract paths plus the unchanged shared SSE parser
   and its binary OS primitive: **17 input paths**. Reuse exact pinned package
   sources; hash every input/package source. No stubs, overlays or edited shared
   parser, F01 data, root config or domain logic.
4. Run the focused closure compile gate, dedicated offline tests, dedicated
   execution/regression harness and existing actual synthetic CLI workflow.
   Use an explicit unique private fixture directory, not store/environment
   discovery. Stop and report any failure with its original log.
5. Record actual commands, exits, counts, hashes and cleanup evidence. The full
   `gleam test` / root composition gate is parent-owned and is not authorized
   by this focused plan.

The old seven-offline/ten-execution/CLI passes and 15-input receipt in
`F04_RUNNER.md` remain historical and separate from these newly passed
eight-offline/twenty-execution/CLI results. The full root gate and all live/native
qualification remain unverified. Final handoff is quiescent, with no deferred
run and no additional validation permission inferred.
