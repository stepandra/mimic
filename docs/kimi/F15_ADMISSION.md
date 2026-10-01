# F15 destination admission

Status: admitted locally. Root wiring, focused synthetic source/shipment
gates and the full 711-test Gleam suite passed. Independent focused source
review found no remaining blocker after the launcher portability correction.
The complete integration script and publication remain pending.
This is not CPA differential, native-client or live-provider qualification.

## Input and destination changes

Imported local JJ revision `85f44ef07144a8a4433933b2f51f1972e4744039`
(`umbrella4-f15-library-v1`), based on
`ca86b531cea7e1a509ac8e6038604fe91819ac07`.
All seven entries in `F15_SHA256SUMS` matched the frozen Git objects before
import. The provider source and tests remain unchanged from that packet.
`F15_HANDOFF.md` records the owner's earlier results and failures.

The coordinator applied `F15_GATEWAY.patch` through `apply_patch`.
Generic `openai-compatible-kimi` Chat now accepts streaming requests through
the shared Chat codec and existing synchronous runtime ownership transfer.
The buffered handler is preserved as a separate helper. No native Kimi
transformation, OAuth identity, alternate parser or retry path was added.

Three destination smoke corrections are explicit integration deltas, not silent
edits to the frozen packet:

1. Python `HTTPResponse.readline()` can hide a missing terminal HTTP chunk:
   an in-memory chunked-response control returned ordinary EOF both with and
   without a zero chunk. `read(1)` instead raises `IncompleteRead` for the
   missing terminator. The smoke reader now uses bounded incremental reads;
   controls require clean completion, interrupted completion and timeout to
   remain distinct. No gateway change was needed for this failure.
2. Egress rejects invalid charset/media/duplicate encoding before returning
   `Opened`, as `Unavailable/Uncertain`; the existing gateway returns 503.
   JSON media admitted by egress but rejected as non-SSE returns 502. The
   smoke now requires the exact status per boundary, not an arbitrary 5xx,
   and checks one upstream request with no retry.
3. Independent review found a CI portability defect: the source launcher
   required `mise` instead of honoring the root gate's `GLEAM` executable.
   It now uses `GLEAM` with a `gleam` default, matching existing smokes.
   Pure controls cover executable paths with spaces and unchanged shipment
   arguments. Source smoke was rerun with `GLEAM=$PWD/.tools/gleam`; the
   harness self-test and shipment smoke were also rerun successfully.

The root integration script now runs the harness self-test and both source
and shipment workflows. The exposed capability matrix includes generic Chat
SSE. Historical handoff manifests still describe the original input bytes.

## Executed destination gates

Commands used Gleam 1.18.1 and local synthetic credentials/upstreams only.

| Gate | Outcome |
| --- | --- |
| `gleam format --check src test` and `gleam build` | Passed |
| Named EUnit `kimi_compat_test`, `kimi_compat_stream_test`, timeout scale 10 | 22 passed |
| Initial source smoke | Failed: malformed stream appeared clean to the test reader |
| Source smoke attempt 2 | Failed: bad-charset expected 502, actual 503 |
| Harness `--self-test` including reader controls | Passed; not MIMIC execution evidence |
| Source smoke attempt 3 | Passed; 18 upstream requests |
| `gleam export erlang-shipment` | Passed; dependency deprecation warnings |
| Shipment smoke from a different working directory | Passed; 18 upstream requests |
| Final self-test, explicit-GLEAM source and shipment smoke after review fix | All passed; 18 upstream requests per actual workflow |
| `mise exec gleam@1.18.1 -- gleam test`, one 600-second-bounded invocation | 711 passed, no failures, exit 0 |
| `git diff --check`, shell syntax check | Passed |

Both actual CLI workflows check incremental UTF-8/SSE delivery, preserved
native documents, overlapping client/account scopes, valid prefix before
corruption, named remote errors, downstream cancellation, media denial before
I/O and unchanged buffered responses.

The complete integration script was not executed for this destination
checkpoint. The historical 698-test baseline is not a new result; the new
711-test result is the coordinator's destination run, not the reviewer's run.
The reviewer performed source/diff/hash inspection only, including the final
`GLEAM` launcher correction.

## Evidence hashes

Logs are retained under ignored `build/f15-admission/`:

```text
9e25c833cf2552c48be6be7899f9eacb363bd622ae9b20cddfe5e41d2e910a61  focused.log
3d318f9ac8cf70a2d76003ceaee88db192784ffe121d3c130dba39b9497f1b8e  source-smoke.log
ce3cf28230629807f667aa0e558966e24ac2e118f57563ec61f4c897f7310619  source-smoke-attempt2.log
22bc632816c2f5cc584f1722c986b2aac5c147b7781bd110a579c76b76dad027  source-smoke-attempt3.log
4136334d7a312fadd400a2416e96f864fb95012839baf46d310faef045e9d8c3  reader-self-test.log
ed65006d9478c35bfbf35d81b022989bc67ef23cd8789e3c8e0d30b86c3337bb  export.log
ad8cdf1a647ebb692786566575958fc170cb100f325c7160c05c6a18bd8025dc  shipment-smoke.log
4136334d7a312fadd400a2416e96f864fb95012839baf46d310faef045e9d8c3  reader-self-test-final.log
22bc632816c2f5cc584f1722c986b2aac5c147b7781bd110a579c76b76dad027  source-smoke-final.log
ad8cdf1a647ebb692786566575958fc170cb100f325c7160c05c6a18bd8025dc  shipment-smoke-final.log
fe66a98d2defefea03e3c0a0b22804d95f05270b9fc75d33c3aa6fd26480259f  full-gleam.log
```

Reviewed destination source:

```text
e449770f6865d16239db69a4ac922157c9c2fa8fc6cd6a5c9d35b82fefb60454  src/mimic/gateway.gleam
ee2aaccf2d5640fa731544d54533337ec273c18204abe2199a393f195e25434e  scripts/smoke-kimi-compat-stream.py
e3c15f377bb85dc8e173cb2b232c3c145ea71a839b59b9ef2fe25177752ce243  scripts/verify-integration.sh
```
