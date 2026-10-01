# F08 destination admission

The final destination now admits this bounded local workflow: **27 source CLI
and 27 shipment scenarios passed**, alongside the complete 801-test Gleam gate.
The later HTTP OWS correction, independent review and full evidence are recorded
in [the final-wave validation report](FINAL_WAVE_LANDING_VALIDATION.md).
Native/live/upstream-check qualification remains blocked.

The sections below preserve the earlier admission attempts and their original
pending status; they are historical evidence, not the latest admission verdict.

Only the nine F08-owned files from corrected snapshot
`c771d2365f0241e90f3b5faebfcbe98290a651be` were imported. Their destination
bytes match the source snapshot. The F11 protocol changes and proposal/status
documents were excluded; existing Responses files match coordinator
`428b7671452a4c637ca227411f02bc1760d66349`.

Root configuration now decodes explicit `oauth.companion` to
`ClaudeCompanionOAuth`. Missing approval, false/non-boolean approval, invalid
endpoints and use with other providers or API-key mode fail configuration.
Absence retains the old Claude path. The new CLI branch invokes the full
single-ticket enrollment wrapper; both variants use the same existing
refresher, without companion requests during refresh.

Format/build and 42 focused tests passed. The first coordinator invocation
omitted OTP application startup: 30 passed/12 failed, including explicit
`httpc_manager: noproc`. The same source passed after adding
`application:ensure_all_started(mimic)` as required by the owner command.
No source change was made to turn that failure into a pass.

Retained logs under `build/f08-admission/`:

```text
aa6ce6d29485b4ae8541b8690fa1af5ecebd432d46663f8c3cd3b59ab8cd5d3c  focused.log
e99944b708b3674d8b4c043df9cb557bb3cdfbfb61dc01212c80e817a7ccff93  focused-attempt2.log
```

Actual configured root CLI/source/shipment smoke is still pending.
The slice is NOT admitted yet. No real account, companion
endpoint, native client, CPA runtime or live provider was contacted.

## Actual-wire review correction

Independent root review traced Unicode whitespace normalization in
`replay.parse_response`. A new raw-loopback regression reproduced two failures:
VT and U+200E prefixes became valid JSON media. NBSP rejection and legal
SP/HTAB controls passed. The first test draft failed compilation before
execution; that separate log is not red behavioral evidence.

The coordinator changed the shared replay rule to reject illegal control
bytes and remove only leading HTTP OWS (SP/HTAB), preserving other bytes for
provider validation. No FFI or provider parser changed. The new wire tests,
existing replay tests and F08/config tests then passed: **78 tests**.
Targeted independent re-review confirmed the correction and found no remaining
blocker within its inspected scope. It did not rerun tests. Actual configured
CLI smoke remains pending.

```text
9ce73e96309b6fb1d790081897ad2ce18825bae97d6e00b3e9056148ec3e375b  media-wire-red.log (compile failure)
b0d236e06e41ef52f9d4834586ff4794f77df1283dc81ab8c74cf40eaef347f0  media-wire-red2.log (2 failed, 2 passed)
47d859571b481e540b56bdd842dc9fdb97d3b917ea2430a0ef5238f32bccad68  media-wire-green.log (78 passed)
db0a699a965214f9bab4ad3019da3a66e22e86249e8a3b1d1a89428a9665029e  src/mimic/replay.gleam
```

## First-callback response lifecycle

The actual CLI harness found that a first valid callback could receive EOF
even though login subsequently stored the grant. Three fresh controls
(HTTP client, one raw send and fragmented headers) produced the same result.
These are worker-executed synthetic observations, not live evidence.

The coordinator independently added a first-valid asynchronous callback test.
It failed against the existing auth listener: callback publication raced
listener shutdown before Mist wrote the 200 response. The test initially
stranded its parent after the HTTP library raised on EOF; a test-only
exception capture made the failure explicit instead of a timeout.

The auth listener now requests Connection: close and publishes the handler
PID with the validated callback. It waits for that handler's termination
within the original deadline before shutting down the listener. This gives
the response attempt a completion boundary without sleeps, callback retries,
a new process or another enrollment manager. It does not prove browser
delivery after a network failure.

The definitive regression failed once before the fix; 53 auth/F08/config/wire
tests then passed. Independent review and actual CLI/shipment reruns remain
pending. Earlier CLI failures are not relabelled successful.

```text
afe0e0c732c1a1e25574084a58d2882fb2bfbefdf582039953da16b3c0f28e66  callback-response-red3.log
3cb6ad3ccdfb9bcd35cc4cc3b2759e2f91eec768143fdce3b3bacaa14c8157c9  callback-response-green.log
f4c04c8956c8db91c2079c3eb45239a86a0056ff8f656e1661eb750e565f38f9  src/mimic/auth.gleam
```

The monitor wait is specifically an HTTP/1.x completion boundary. After
independent review identified Mist's different HTTP/2 stream-actor lifetime,
the direct callback handler explicitly rejects `Stream` bodies with 505,
before callback publication. The pinned internal `Initial`/`Stream` invariant
is documented beside the match; no vendor change was made.

A bounded loopback HTTP/2 probe returned 400 before that guard (not a
successful OAuth grant), then 505 afterward. A second test confirmed that the
same pending login still succeeds over HTTP/1.x following HTTP/2 rejection.
All 9 auth tests passed on this final version. This does not qualify HTTP/2
enrollment or guarantee browser delivery after network failure.

```text
d9382856f19ee6a59ab8754595ab2831b2da702f25638a9e98eeef4421840009  callback-h2-red.log
199998d6373364e1aca3d13a46e266ca98a36ce759f936f9239d4ed622374c01  callback-h2-green.log
4ca32d5c6c88e5bcc561de7f67d544d29a4717c14984664a6fbda6db681183fe  src/mimic/auth.gleam (final)
```
