# F17 validation — compiled provider packet, root gates pending

**The final focused provider gate passed: 31 selected EUnit tests and seven pure
Python harness tests. Actual root source/shipment workflows have not run for this
packet.** No HTTP continuation was implemented or qualified.

Source recovery and initial edits respected the validation hold. Execution used
the parent's explicit bounded slots, Gleam 1.18.1, `ERL_FLAGS="+S 2:2 +A 2"` and
the shared lock at
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock`.
Each direct call acquired the lock with `mkdir`, retained unique no-clobber logs
and cleaned only its own owner record/lock in a shell exit trap. Workload processes
exited before explicit release; no deferred run remains.

## Actual executed gates

| Gate | Result |
| --- | --- |
| Initial scoped `gleam format --check` | Failed; retained in `gate-001/format.log`. Formatter stdout was inspected and the four owned formatting corrections used `apply_patch`. |
| Corrected scoped format/check | Passed in `gate-002` and final `gate-004`. No non-owned source was formatted. |
| Exact composed `gleam build` | Passed in `gate-002` and final `gate-004`; library and development tests compile, not full-suite execution. Existing dependency Header deprecation warnings were not suppressed. |
| Initial selected EUnit | 30 passed, one fixture assertion failed; stopped and reported before Python tests, with all processes/lock cleaned. |
| Final selected EUnit | **31 passed**: 10 new F17, six request, six bridge, seven endpoint and two argument-event tests. Existing bridge tests include synthetic loopback transport, not live account calls. |
| Pure Python harness assertions | **Seven passed**; no MIMIC/CPA/socket execution in this Python test stage. |
| Actual root source/shipment fixture | **Not run**. Root pre-runtime guard absent from this compiled snapshot by design; parent owns import, hook and workflow gates. |
| Full suite / heavy integration / differential / native / live / browser | Not granted and not run by this packet. |

The earlier failed/passing totals are not aggregated with the final totals.

## Delivered scope and pending actual-route evidence

- `test/xai_http_continuation_test.gleam`: top-level presence denial across API-key
  and OAuth, all HTTP adapter factories, explicit compact distinction, stateless
  paired-history and nested-data positives, malformed/escaped duplicate input,
  WS transform preservation and no implicit orphan-history replay.
- Narrow owner-approved update to `test/xai_request_test.gleam`: HTTP/compact
  controls are stateless; raw state remains the existing WS positive.
- `scripts/smoke-xai-http-continuation.py`: actual source and shipment root CLI
  fixture, numeric loopback only, private synthetic state, two client identities,
  legacy API-key/configured API-key/OAuth API/OAuth proxy operation bindings,
  ordinary buffered/SSE and buffered compact positives.
- Expired OAuth previous-ID denials are first, before any first turn, requiring
  zero OAuth/inference TCP accepts and HTTP requests. Stateless positives must
  then actually refresh; later denials and restart must not refresh again.
- Seven pure harness assertion tests distinguish denial from accepting fixtures,
  TCP-only activity, OAuth refresh, SSE errors, broken gateways and secret echo.
  They exercise no MIMIC code or socket and are not an actual-route gate.
- Parent-owned pre-runtime root hook is required before harness execution. The
  compiled API is `guard(body: String) -> Result(Nil, contracts.Failure)`; errors
  map to sanitized 422 before constructing/opening the xAI runtime adapter.

The **unexecuted actual-root fixture is designed to check** sanitized failures
and no credential echo, count TCP accepts as well as requests, and remove private
fixture state/processes on exit. Its loopback proxy role tests configured operation
selection, not official proxy headers, WSS, TLS fingerprints or real entitlement.
No expired-OAuth zero-refresh result or actual-route denial total is claimed yet.

## Exact source/dependency input and retained artifacts

The composed closure was materialized read-only from parent
`rz87rbwdwjd8/mimic` into this agent's ignored `build/f17/composed`. Before/after
copy checks matched all 1,092 parent source/dependency files. Exactly nine owned
files were overlaid; no root/provider stubs or non-owned source edits were made.
Later changes were the inspected owned formatting and one fixture-only assertion.
The initial parent aggregate digest is
`710229975875267d5dc95952139e3be4e5ce981219c7665c01bf2077ad86385f`.

| Retained artifact under `build/f17/` | SHA256 |
| --- | --- |
| `source-input-001.json` | `994b05809e2f7a09569b112597c155d8138b36f548913f6f05ba3cbeee60a8fd` |
| `source-input-002.json` | `a2ef8290e643154a2905df3e9cb3e10aba3968104f61f8731928f05617ee7492` |
| `source-input-003.json` — final tested input | `bea7ca5a06f37c6ed71caab3e127698b11743d800f80a8ae9cb2b1812c199d4c` |
| `gate-001/format.log` — failed | `16a39f711fec9f27515d26550c49403ddc315af3a2fb1b60d8fb15cc48a4463d` |
| `gate-002/build.log` | `4795556332b5ed0cc52083100426b9e33d99f96abd9b1bb0d9db5b2c18a86ded` |
| `gate-002/eunit.log` — failed fixture assertion | `94b77f104a0754c89fc675e5d2e13b640cc5e037bc53e6eb414a144d54248ffe` |
| `gate-004/format.log` — passed, empty output | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `gate-004/build.log` | `db33cbadd91eda9396ae14baa8396314ac1f2550ff49a17ec8fff5c8280a8adf` |
| `gate-004/eunit.log` — 31 passed | `98a5f910545898323cc474b49dddaeae6de7a4d79fd31884fc141f48d31e2619` |
| `gate-004/python.log` — seven passed | `c67ac7e21700aa1521accc24f142c723148baf853437e28814bd320dabdb790c` |

Final pre-build composed aggregate:
`56f86ac43d1d6e2a912b87f3d170ac6a5242d35b9e62d36ddbe4ece2bd0b75d9`.
These ignored artifacts remain local evidence, not a payload or upstream pass.

### Retained fixture and setup failures

1. The initial history assertion compared parsed wire `ir.Object` field lists
   against hand-ordered literal IR. [`ir.parse`](../../src/mimic/ir.gleam#L153)
   uses a dictionary for JSON objects, and
   [`responses.decode_request`](../../src/mimic/dialect/responses.gleam#L100)
   retains that parsed document unchanged. The parent-approved one-line
   correction compares to `decoded.document.input`, the actual submitted JSON
   structure. Passing equality still requires every key/value/type, input item,
   argument string and array order; no wire/golden/header normalization was added.
   No production change was needed.
2. `gate-003` refused setup before launching workloads because the preceding
   successful compiler rewrote generated `build/packages/packages.toml`.
   That refusal is retained in the tool transcript and its start record, not
   reported as an assertion failure. Read-only inspection showed an order-only
   rewrite of the same package/version map. The final input receipt records that
   generated-cache transition; dependency source files, canonical `manifest.toml`,
   root and vendor bytes remained unchanged.

## Reproduction and parent-owned next gate

The focused commands below ran in the exact composed closure under the shared
lock and explicit slot. Repeating them needs another authorized slot.

```sh
mise exec gleam@1.18.1 -- gleam format --check \
  src/mimic/providers/xai/http_continuation.gleam \
  src/mimic/providers/xai/request.gleam \
  src/mimic/providers/xai/bridge.gleam \
  test/xai_http_continuation_test.gleam test/xai_request_test.gleam
mise exec gleam@1.18.1 -- gleam build
erl -noshell -pa build/dev/erlang/*/ebin \
  -eval 'case eunit:test([xai_http_continuation_test,xai_request_test,xai_bridge_test,xai_endpoint_test,xai_argument_events_test],[verbose]) of ok -> halt(0); _ -> halt(1) end.'
python3 -B -m unittest discover -s scripts -p test_smoke_xai_http_continuation.py -v
```

Parent-only next gate, **not run here**, after actual root hook/import and exact
destination hash checks:

```sh
mise exec gleam@1.18.1 -- python3 -B scripts/smoke-xai-http-continuation.py
mise exec gleam@1.18.1 -- gleam export erlang-shipment
python3 -B scripts/smoke-xai-http-continuation.py --shipment build/erlang-shipment
```

Full `gleam test`, heavy integration, differential/reference, native clients,
browser, live provider and real WS receipt exchange are not part of this
focused packet. Historical d6f307 test totals are not imported as current evidence.
F01 source facts and the historical denominator are unchanged. The supported
deliverable is source/input enforcement, not positive HTTP continuation parity.
