# Final parity umbrella 4: F14–F21

## Base and operating boundary

- Required public base: `ca86b531cea7e1a509ac8e6038604fe91819ac07`.
- Verified the attached worktree was clean but based on `c3ca7e80`; inspected
  JJ status and remotes, added `https://github.com/stepandra/mimic.git` as
  `origin`, fetched with JJ, and created a new local change on the required base.
- The base's documented 698 Gleam / 92 Python destination gate is historical
  evidence, not a rerun by this umbrella.
- At most one implementation child runs at once, with one slice per child.
  Provider children do not edit shared root gateway/config/CLI/build/vendor/CI.
  Shared changes need explicit named-owner agreement.
- No CPA restart/reconfiguration, credential-file inspection, live inference,
  public push, sibling checkout edits, or new umbrella creation is authorized
  by this work log.

## Slice ledger

| Slice | Scope | Current state / admission dependency |
| --- | --- | --- |
| F14 | Native Kimi Messages SSE | Library-ready: final format/build and 26 focused tests pass; exact final seam approved by Claude owner; root proposal targets admitted F15 revision, admission pending |
| F15 | Generic Kimi Chat SSE | Implementation admission DONE at coordinator `8fd0c6fc`; focused/source/shipment/full Gleam 711 pass and independent review approved; complete integration/CI/differential/live remain separate |
| F16 | Source-qualified native Kimi normalization | Awaiting F01 source freeze; compact remains explicitly denied under old pin |
| F17 | Grok HTTP continuation | Awaiting F01 qualification and F07 bindings; existing HTTP previous-ID denial remains |
| F18 | Actual Grok WS/WSS gateway | Provider transport exists; root selected-provider dispatch/default-off policy requires serialized coordinator lane |
| F19 | Grok tool contracts | Shared S6 raw validation precedes restoration; qualification required before extending approved tool kinds |
| F20 | Grok image operations | Requires qualified source contract and named typed-media/egress ownership agreement with F22 |
| F21 | Grok video jobs | Conditional on F01 capability evidence; no silent inventory removal or inferred support |

## Ownership grants issued

F15 child owns only:

- `src/mimic/providers/kimi_compat/**`
- `test/kimi_compat_test.gleam`
- new `test/kimi_compat_stream_test.gleam` and/or
  `test/kimi_compat_stream_loopback_test.gleam`
- new `scripts/smoke-kimi-compat-stream.py`
- `docs/kimi/F15*`, including an unapplied root integration patch

The umbrella parent owns this progress log. Later slice grants will identify
exact paths before each child starts.

## Evidence policy and completion

Each slice needs format/test results, focused real-loopback tests and actual
root CLI source/shipment admission before DONE. Library-ready or blocked is
not DONE. Record failed attempts as well as passing reruns. Source qualification,
synthetic mocks, executable CPA differential, native workflows, and live
provider validation remain distinct statuses.

Final handoff must freeze a local JJ revision/bookmark with exact owned-file
hashes. F15 library checkpoint is frozen at
`85f44ef07144a8a4433933b2f51f1972e4744039`, local bookmark
`umbrella4-f15-library-v1`, with `docs/kimi/F15_SHA256SUMS` verified 7/7.
This is not final gateway admission. Full heavy integration gates must
be coordinated rather than run concurrently by all umbrellas.

Coordinator admission protocol:

- `READY_FOR_ADMISSION(slice, JJ revision/bookmark + hashes, compiled API,
  minimal root patch/base/paths, focused results)` precedes root changes.
  Coordinator applies/reviews/tests and returns the accepted revision.
- `READY_FOR_GATE(slice, revision, command, timebound)` precedes any full
  Gleam or integration suite. Focused tests are allowed; no full gate is
  currently granted.

## F01 source relay, awaiting hash-bound source map

The coordinator relayed these findings from Foundation's audit of historical
CPA `acdace936fa7df2905500c7f5e0a97d683138dea`. These are source observations,
not runtime qualification or a replacement for the pending frozen source map:

- Kimi `kimi_executor.go:394–428` clones/rewrites model, stream, thinking,
  tools and temperature. Compact is denied at `395–396`; streaming compact is
  denied at `505–507`. Normalization is at `1163–1182`, tool handling at
  `1185+`, and domain handling at `helps/kimi_responses.go:11–51`.
  Opaque passthrough does not establish continuation or account isolation.
- xAI ordinary HTTP deletes `previous_response_id` at
  `xai_executor_request.go:83–91`. Compact separately restores it at
  `xai_executor_execute.go:144–173`, with a separate base and tools/stream
  stripped. F17 cannot enable ordinary HTTP continuation solely from the
  compact path.
- `server_routes.go:68–74` lists image generation/edit, video POST
  create/generation/edit/extensions, and GET `/videos/:request_id`.
  No cancel route was listed in this relay. F21 must not invent cancellation
  or infer methods from its slice title.

## F15 interrupted-run history

Before the coordinator's full-gate restriction reached the child, it ran:

```sh
git --no-optional-locks status --short --branch &&
git rev-parse HEAD &&
mise exec gleam@1.18.1 -- gleam format src/mimic/providers/kimi_compat test/kimi_compat_test.gleam &&
mise exec gleam@1.18.1 -- gleam test
```

The terminal invocation had a 120000 ms timeout. Library compilation succeeded,
but no suite summary was reached before closure; this is not a test pass.
The child did not redirect a disk log, so there is no log SHA-256 for this
attempt; evidence is the tool transcript only. Its subsequent read-only
`ps -eo pid,ppid,command | grep '[m]imic_test\|[b]eam.smp'` inspection returned
no matches, and no process kill was issued. Further verification is restricted
to focused tests until the coordinator grants a full gate.

## F15 destination admission update

Coordinator imported the exact frozen packet and verified all seven hashes.
Destination formatting, build and 22 focused tests passed. The first actual
source CLI smoke failed its malformed-stream closure assertion at script line
350. Coordinator subsequently reproduced that `HTTPResponse.readline` hides
`IncompleteRead` for an omitted terminal zero chunk and corrected the harness
to use `read(1)`, with clean/unclean/timeout controls. A second failed smoke
required distinguishing JSON-not-SSE 502 from egress-rejected invalid-header
503 and asserting one upstream send. Both failed runs remain retained.

After these harness-only corrections, coordinator reports actual source CLI
and shipment smokes passed (18 upstream requests each), with the provider
packet unchanged. Coordinator added regular integration steps and capability
documentation, recording results/hashes in its `docs/kimi/F15_ADMISSION.md`.
The coordinator then fixed a third harness issue identified in independent
review: source launch now honors `GLEAM` rather than requiring `mise`, with
launcher controls and rerun source/shipment checks. Independent review found
no remaining blocker. The full destination Gleam suite passed **711 tests,
zero failures**, in one 600-second-bounded run; log SHA-256:
`fe66a98d2defefea03e3c0a0b22804d95f05270b9fc75d33c3aa6fd26480259f`.

F15 implementation admission is **DONE locally** at coordinator revision
`8fd0c6fcff4f4e7a1a47de33e306e1c84d0ea936`, bookmark
`coordinator-f15-admitted`. The parent read the destination admission document
and verified that revision exists without editing the coordinator checkout.
It has not yet been imported here. The complete integration script, CI,
publication, CPA differential, native clients and live inference are separate
and unclaimed. The original provider packet remains unchanged.

## F14 named shared-seam grant

Claude umbrella 3 approved the narrower actual-code seam in
`src/mimic/providers/claude/stream.gleam` and `http.gleam`, not `adapter.gleam`.
The grant is additive model check/restoration at the existing parsed observer
boundary: preserve native `new`/`run` raw frames, lifecycle, usage, valid-prefix
errors, cleanup and bounds. Re-encode only `message_start` after checking its
protocol-owned model against the selected upstream model. No second parser,
recursive rewriting, or broad lifecycle changes. Exact signatures/hunks and
preservation/mismatch tests must be relayed to the Claude owner before freeze.
F09 will avoid these files.

The Claude owner inspected and approved the first exact patch/contract hashes,
with no blocking source issue. This is scoped source review, not runtime/test
qualification. Before freeze: refresh the patch to final formatted bytes,
remove stale draft status text, record preservation/mismatch/boundary outcomes,
and ensure trusted selection supplies nonempty validated model arguments.
