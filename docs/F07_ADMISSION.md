# F07 combined-root evidence

The parent applies typed xAI OAuth configuration, exact operation bindings,
model-qualified registration, the existing single refresh manager, private-file
administrative import and the configured native adapter.

The initial account selector now checks account-specific operation admission
before choosing its auth partition. Same-operation mixed-auth preference
remains configured order; no cross-auth fallback is implied.

## Passed in an exact combined snapshot

The worker copied actual parent source and overlaid only its owned F07 files,
recording/rechecking input hashes without root stubs. Snapshot 002 contains
1,084 inputs. The pre-validation manifest was `597292fa…`; two test-only
compile corrections were retained. The final actually validated-input receipt is:

```text
f44df99707d08e29f15365ad5ea49bf197c80560d4e28ed4dc0a04347e99180d
```

Build and 43 focused tests passed: 15 F07, five parent config/selection,
four coordinator, ten Codex and nine preserved F05 cases. This includes the
unchanged entered-poll cancellation/admin/store-failure regression.

The full actual root socket workflow passed device enrollment, S5 persistence,
rotation, configured proxy Responses/API Compact, durable unknown-refresh
fencing, cancellation/CAS/expiry, restart recovery and client/credential
revocation. The mixed-auth operation test passed both account orderings.
Observed synthetic counts: discovery 14, device 13, poll 20, verification 8,
exchange 8, refresh 4, proxy 6, API 3.

Worker receipt:

```text
build/account-ui-f07/logs/root-slot-001.log
SHA256 7a606fe1846238d10501a547349d3678f19c509200a3b289aad7857b2687a3db
```

## Browser gate: diagnosed fixture failure, corrected rerun passed

After an initial driver deep-socket-path setup failure, the short-directory
attempt reached logout and passed scripted UI/gateway/privacy/mobile checks,
with axe 29 passes, zero violations and zero incomplete checks. However,
the final fixture-error assertion failed. Its initial evidence recorded only
a generic GET/POST label.

```text
browser-slot-002.log
SHA256 bad0a4b7d77a872fa1d5534b978ecea6897fcb4be2b6473ddf2c4e210c40fbcd
```

A separate locked diagnostic retained every error and the original fatal
assertion. It identified the exact cause: unsolicited `GET /favicon.ico` on the
synthetic issuer, phase `authorize`, branch `get_route_parse`, `ValueError`.
Cancellation intent and confirmation were both false for that request; there
were no matched cancellation closes. Thus cancellation was not the observed
failure cause.

```text
browser-diagnostic-slot-003.log
SHA256 d34c02a40cd7565755dfec149b8819d9bb12ad8fffd65ff3b3efc570f9280ebb
Input manifest d1477a0422551d127cb766201ef03711a89ccbf7a40d57f870f3dd98e6bf8ab7
```

The fixture correction is exact no-query `GET /favicon.ico` → empty 204 before
OAuth parsing. Both narrow resource regressions then passed, including unchanged
S5 bytes/grant/auth/inference counters and fatal unknown/query/nonexact routes.
The unchanged full browser workflow also passed; every `f.errors` entry remained
fatal and no cancellation-close exemptions were added. Axe reported 29 passes,
zero violations and zero incomplete checks.

```text
favicon-regression-slot-004.log
SHA256 1ce0f39412f0aefc3a974dd001411065a843c1f8a2f7252dbf9af1b5c9bedef2
browser-slot-004.log
SHA256 bb6cf0b6d48deda187af706def6bcacfa3ec1a9e8f0111594a36e4608a6d6716
Input manifest 1d6fea5f6cc15fc7d1293ba32d8a7ffd5a378b9c57cc946ba83a4ec8e3889ecf
```

Workloads completed 112 seconds after the claim; final process audit/lock
release took 184 seconds, four beyond the granted 180-second slot. This overrun
is retained, not presented as compliance with that total slot limit. No workload
continued after cleanup. The earlier failed runs remain separate receipts.

## Shared HTTP dependency

The inherited UI reporter observed HTTP 200 for three duplicate Content-Type
forms. Its `desired: 400`/`strict_gate: false` output is retained, not a passing
ambiguity gate. The shared raw parser correction must prove zero handler
dispatch and peer closure, coherently with other malformed singletons.

Shipment, independently repeated parent workflows and full-suite gates remain
pending. No real-account OAuth, live Grok calls, native-client qualification or
CPA differential result follows from these synthetic results.

The 11 validated core/test files are imported. Corrected favicon scripts and the
new resource regression still require the worker's final synchronization;
the older imported diagnostic scripts are not silently treated as the exact
passing slot-004 bytes. The worker document records the separate script hashes.
