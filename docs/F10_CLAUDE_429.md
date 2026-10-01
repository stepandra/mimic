# F10 owner packet — bounded classification, parent root admission separate

Recovery: exact corrected
`074a8e620f8e6406ebe21fb97707eef218dde050`, read-only from the user-named old
worktree. This change is only F10. The egress deadline/raw-header/media diff
and rejection module match that packet byte-for-byte. Transport adds the
expressly requested `RequestLimited` refinement; shared contracts adds only
that Reason. Existing conservative `http` is unchanged.

No F08/F09, runtime/store, gateway/config/CLI, production FFI, TLS/origin, other
transport, dependency/vendor or sibling edit was made by this worker. Parent
and F44 edits are independently owned. No commits/refs/push/children, provider/
CPA execution, native/live qualification or real credentials were used.
All fixtures are synthetic; test state is private under `build/f10/state`.

See [the source contract](F10_CLAUDE_SOURCE.md#strict-mimic-admission) for scope/
precedence, source links, bounds and deliberate CPA differences. See
[historical failed attempts](F10_CLAUDE_HISTORY.md#original-f10-failures);
historical pass reports are not current-worktree qualification.

## Additive compiled contract

```gleam
claude_transport.http_classified(
  prepare: fn(contracts.Context, contracts.Request) ->
    Result(Capture, contracts.Failure),
  ca_file: Option(String),
) -> contracts.Adapter(claude_transport.Handle)
```

`Handle` is opaque: a real live egress stream or a closed rejection with no
socket/body/private headers. Successful statuses preserve the live lifecycle.

Inside `open`, before runtime Observe/retry:

| Outcome | Adapter result | Parent's classified downstream mapping |
| --- | --- | --- |
| Proven request/model/Fast-credit scope | `Error(Failure(RequestLimited, Rejected, None))` | Sanitized429, **no Retry-After**, no account penalty/replay |
| Proven shared/credential quota | Sanitized `Opened(429, ..., Closed)` | Existing bounded failover; exhausted quota429 with normalized hint |
| Unknown, malformed, ambiguous, compressed, truncated or budget-failed | Non-retryable Error before Observe | Conservative sanitized503, no hint |

The one 500ms absolute monotonic deadline is reused across all nested reads,
EOF, UTF-8 and strict bounded parsing, with a post-parse expiry check. ≤49,152
accepted body bytes, ≤65,536 payload bytes read, ≤32 pull events; strict whole
date/Retry-After validation is recovered unchanged. Raw HTTP values are
validated before normalization; only SP/HTAB OWS is trimmed. No reader closes:
the classified open closes exactly once, and Closed cancellation is a no-op.

The old conservative constructor intentionally still returns Unsupported for
all429 without reading the body. Runtime's retry allowlist is unchanged;
RequestLimited does not appear in it. The entire attached project compiled
with the new Reason; no additional exhaustive-match patch was required.

## Exact parent-owned root hook

No root hook was edited by this worker. Compose with the already-materialized
F09 `settings` argument and prepare closure, **not** hardcoded adapter.prepare.

1. Append `claude_quota_classification: Bool` to `gateway/config.Config`, decode
   with `ir.optional_bool(value, "claude_quota_classification", False) |> safe`,
   and pass it into the constructor. Parent-owned positional Config calls
   append False. It is operator config, never a client hint; omitted stays off.
2. Import `mimic/providers/claude/rejection as claude_rejection` in gateway.
3. In existing `serve_claude(incoming, settings, engine, req, streaming)`:

```gleam
let prepare = fn(context, request) {
  config.prepare_claude(settings, context, request)
}
let classified = settings.claude_quota_classification
let outcome = case classified {
  True ->
    runtime.open(engine, claude_transport.http_classified(prepare, None), req)
  False ->
    runtime.open(engine, claude_transport.http(prepare, None), req)
}
case outcome {
  Error(contracts.Failure(contracts.RequestLimited, contracts.Rejected, None))
    if classified
  -> reject(429, "provider request limited")
  Error(contracts.Failure(contracts.Quota, contracts.Rejected, Some(ms)))
    if classified && ms > 0 && ms <= claude_rejection.max_retry_ms
  ->
    reject(429, "provider quota exhausted")
    |> response.set_header("retry-after", int.to_string({ ms + 999 } / 1000))
  Error(_) -> reject(503, "provider unavailable")
  Ok(opened) -> // preserve the current F09 downstream handling unchanged
}
```

Branch around `runtime.open`, not around different Adapter handle types.
Runtime Response erases the handle type; **no root handle annotations need
changing**. One serve_claude path already covers Messages buffered/SSE and
count_tokens, so all routes get the same classification rule before output.
Do not broaden global error mappings or forward upstream rejection bytes.

4. Add the read-only library diagnostic, not an HTTP/CLI endpoint:

```gleam
pub fn active_leases(server: Server) -> Result(Int, String) {
  runtime.active_leases(server.services.engine) |> sanitized
}
```

The test requires the real function, never an always-zero callback. Error/
unavailable fails, not zero. No shared runtime edit is needed.

## Current executed evidence and retained failures

All BEAM commands use `ERL_FLAGS='+S 2:2 +A 2'` and
`mise exec gleam@1.18.1`. Complete argv/output/exits are retained under ignored
private `build/f10/`; logs are not trimmed. Per-command/process-group deadlines
are explicit in their log headers; no known failed attempt is counted passed.

| Current log | Result |
| --- | --- |
| `format-1.log`, `format-2.log` | Exit0, scoped Gleam format |
| `deadline-1.log` | Exit0; whole attached project compiled, six untraced deadline/raw-wire tests passed |
| `classifier-1.log` | Exit0;11 classifier/transport/runtime tests,28 actual two-account cases before adding explicit truncation |
| `os-harness-1.log` | Exit0;8 Python OS tests; actual45s expiry elapsed45.224s, graceful child0 but wrapper124, no group residue |
| `public-source-1.log` | Exit0;15 pinned public-source hashes match corrected packet |
| `legacy-1.log` | **Exit1**, unedited legacy immediate normal request failed `Persistence/Uncertain` at line245 |
| `legacy-trace-1.log` | Exit0; same30-case legacy under actual app startup and quota.save-return-only tracing; initial Persistence is not explained or waived |
| `classifier-2.log` | **Exit1**, existing <1300ms runtime-workflow assertion during an invalid-timing OAuth row; production500ms budget was not increased |
| `gateway-focused-baseline-1.log` | **Exit1**, first fresh-VM restoration expired10s (numeric -1), output only log-sink readiness; initial denial/immediate reuse had passed, matrix did not complete |

Initial public-source-cache inspection also failed before any network request
because a per-turn scratch directory had expired after an incoming message.
Recovery was then read directly with read-only `git show`; the successful
source-verification log above is separate. No source/test result depends on
the failed scratch read.

After these timed workflow failures the parent serialized a quiet validation
slot. Results of that one admitted sequence are recorded separately below.
No test timing assertion, production budget or root hook was removed to get
green.

### Single admitted quiet sequence

One outer 600s-bounded sequential invocation completed in 185.234s. The parent
and other owners held timed/BEAM/browser workflows. All numeric exits were0;
`quiet-results.json` records the exact elapsed times and log hashes.

| Log | Actual evidence | SHA-256 |
| --- | --- | --- |
| `quiet-format.log` | Scoped format exit0 | `de6add2dd8b0f24b10e8a8f99058b10a21a6d53e1b51abd3e2c0fa88365aa831` |
| `quiet-build.log` | Attached project compiled; no root hook removed | `479f232e8173fd02d6184144a3b401fafaa7f147d01c44b67d5ba61f6b1cfacd` |
| `quiet-f10.log` | Explicit 17 tests passed with 30s per-test bounds; includes 30 two-account runtime cases (18 scope/budget/truncation +12 invalid timing), unchanged production 500ms | `5e4807e786c28a3de3cf98ff8e74a9d8397d4628473a0c551be39592af39b9b4` |
| `quiet-existing-reader.log` | Ten unchanged egress/framing tests +five unchanged runtime lifecycle tests passed | `6c38f84fe8e02be0ad25fe657d177e2ca98db7707d0e06bc698273128bfc484d` |
| `quiet-legacy.log` | Unedited 30-case conservative control passed, untraced | `8d6cc5962b4fcf3892d8989a1c7367d7dd57c8c493112a986bc124f127dcf9fb` |
| `quiet-gateway-baseline.log` | Actual configured 30-case default-off matrix, both auth modes/all routes; 12 actual fresh VMs all exit 0 without reseeding | `32a0bb278094abbe85612ff90d5ea2237bd78944e347ed2e6a0f72b35a2c92d9` |
| `quiet-cli-baseline.log` | Actual registered source CLI 18 cases; 36 child starts/restarts all exit 0, no timeout waiver | `bdeaf7470367f017707aba0e8ea8b2f29d7ddbd4d4a7a9dcfb50f60efbd6a079` |

The CLI log retains **six crash reports and six supervisor reports** with
glisten `noproc` around controlled shutdown. Route/restart assertions and
numeric exits passed; clean-shutdown stability and the reports' cause are
not qualified. Earlier Persistence/elapsed/fresh-VM failures remain failures;
this quiet success does not prove their cause.

No actual root diagnostic callback was supplied in the default-off matrix.
Zero-runtime-leases proof comes from the direct runtime tests; **classified
root +actual gateway lease-query, full-suite and shipment remain parent gates**.
The quiet slot was explicitly released immediately after this sequence.

## Exact focused and root validation commands

Run sequentially under an admitted quiet slot; retain each full output and
numeric exit. Parent owns full/heavy/root/shipment integration.

```sh
export ERL_FLAGS='+S 2:2 +A 2'
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/egress.gleam src/mimic/providers/contracts.gleam \
  src/mimic/providers/claude/rejection.gleam \
  src/mimic/providers/claude/transport.gleam \
  test/claude_f10_test.gleam test/claude_f10_deadline_test.gleam \
  test/claude_f10_scenario.gleam
mise exec gleam@1.18.1 -- gleam run -m claude_f10_deadline_test
mise exec gleam@1.18.1 -- gleam run -m claude_f10_test
python3 test/fixtures/claude/f10/test_cli_process.py -v

# Conservative controls; fresh VMs restore identical persisted state.
mise exec gleam@1.18.1 -- gleam run -m claude_f10_scenario -- --focused-baseline
mise exec gleam@1.18.1 -- gleam run -m claude_f10_scenario \
  -- --cli-focused-baseline ./mimic

# After parent root wiring; bind the ACTUAL read-only lease query.
erl -noshell -pa build/dev/erlang/*/ebin \
  -eval '{ok,_}=application:ensure_all_started(mimic),claude_f10_scenario:focused_coordinator(fun mimic@gateway:active_leases/1),halt(0).'
mise exec gleam@1.18.1 -- gleam run -m claude_f10_scenario \
  -- --cli-focused-classified ./mimic

# Parent full configured gateway admission, actual lease query + fresh VMs.
erl -noshell -pa build/dev/erlang/*/ebin \
  -eval '{ok,_}=application:ensure_all_started(mimic),claude_f10_scenario:coordinator(fun mimic@gateway:active_leases/1),halt(0).'
mise exec gleam@1.18.1 -- gleam run -m claude_f10_scenario -- --cli-baseline ./mimic
mise exec gleam@1.18.1 -- gleam run -m claude_f10_scenario -- --cli-classified ./mimic

# Full suite belongs to parent; gleeunit's current main has no filter.
mise exec gleam@1.18.1 -- gleam test
```

Shipment repeats `--cli-baseline` and `--cli-classified` with the actual explicit
absolute shipment launcher path and reviewed prefix args in place of `./mimic`.
There is no shipment path fabricated by this worker.

- Full gateway:34 families ×2 auth ×3 routes +6 omitted controls =210 baseline;
  add30 exhausted quota rows =240 classified. Pure/time/header/parser failures,
  real half-close truncation, Fast/model/overage scope, healthy/malformed hints,
  aggregate/shared precedence, body boundary and bounded drip are included.
- Full CLI:36 baseline/42 classified cases, each immediate reuse and actual
  process restart; all three routes and both auth modes. Corrected helper
  preserves timeout cause (124), confirms process-group cleanup and never
  treats child0/143 after expiry as success.
- Focused gateway:30 baseline/36 classified rows,12/24 real fresh VMs.
  Focused CLI:18/24 cases with36/48 actual process invocations.
- Both classified paths must prove request429 without hint/account penalty/
  replay, unknown503, qualified failover200 and exhausted quota429 with hint.
  A later all-accounts-cooled request stays503 with zero extra sends.

## Outstanding admission boundaries

Configured-positive root/status/actual-lease-query, full suite, shipment,
native clients, CPA differential and live provider qualification are separate.
No current successful adapter test or historical baseline is a substitute.
The conservative constructor/default remains available and unmodified.

## Frozen recoverable input inventory

`docs/F10_SHA256SUMS` freezes current code/test/fixture bytes. The Python OS
fixtures are exact corrected-packet copies; their repository paths and original
hashes also appear in `test/fixtures/claude/f10/SHA256SUMS`. Test Gleam modules
retain corrected assertions while switching only to isolated FFI/private state,
the expressly granted RequestLimited/truncation regressions and focused
selectors/phase diagnostics. Existing shared429 fixture/test and runtime
source are byte-identical to attached base `dd15c610`.

Document self-hashes are supplied in the final owner message, not embedded
here. Ignored logs remain on this worktree; their hashes above are not evidence
that a downstream machine has copied or executed them.
