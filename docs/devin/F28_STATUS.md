# F28: authenticated local status/quota

## Admission state

Implementation is in the dedicated status modules, not the root gateway.
**Corrected scoped format/build and all 105 focused tests passed.**
The parent temporarily deferred its prepared exact root hook to keep its
checkpoint buildable, and will reapply it after auto-import. Actual composed
source/shipment CLI smoke remains for parent admission.
Nothing here establishes live Devin,
CPA differential, a native client, remote TLS/H2 compatibility or a dashboard.

Historical F28 files and their deadline-blocking review were read **only** from
`/Users/jerryjohnson/dev/mimic/.delta/worktrees/rn5e30kpycyq/mimic`.
Historical commands/test counts are data, not fresh execution receipts.
No sibling checkout, ref, commit, push or child agent was created.

## Operator workflow

```sh
# Supply the existing key locally through the environment, not argv.
mimic providers status <config.json> <account-id>
```

Root wiring (parent-owned): import `mimic/providers/devin/status_cli`, then
dispatch `["providers", "status", ..args] -> status_cli.cli(args)` **before**
the existing generic providers dispatch. Add the command to root help.
No new public registry row or HTTP route is required.

`status_cli.cli(args) -> Result(String, String)` takes exactly the config path
and configured account ID. The existing gateway decoder supplies the explicit
configuration. `keys.verify` authenticates `MIMIC_INGRESS_KEY` **before**
account selection, store creation, runtime or credential acquisition.
This is the ordinary ingress key plus local config/filesystem possession:
**not** a separate privileged management role.

Exactly one selected configured `devin/session_token/StaticSession` account
enters the private CLI runtime. The request is pinned to it. No URL/token
argument, discovery, alternate account attempt or origin override exists.
The allowed origin is canonical `http://127.0.0.1[:port]` with no userinfo,
path, query or fragment. DNS names, remote origins and live Devin are denied.

The runtime claims the **existing** store ownership guard. A running gateway
owning the store makes the command fail with the fixed “store busy or
unavailable; existing gateway is not stopped” diagnostic. The shared start
error cannot distinguish busy from every other initialization failure.
The command never bypasses ownership, stops that gateway, adopts its socket
or installs another credential manager. It is **not live dashboard support**.

## Private registry and ownership

The shared registry is model-indexed. F28 uses one already configured model ID
only as lease eligibility, admitting private `devin-status/status/Buffer`.
That ID is not serialized into the unary request, and the private registration
must never enter the public gateway registry or `/v1/models`.
The F27 catalog/model/client files remain untouched.

Serialization reuses the existing pure `status.request`; all network bytes use
`transport.binary_http`, shared egress framing and the existing runtime guard.
`open`, `finish`, `fetch`, `adopt`, and idempotent `cancel` return typed safe
status observations/errors. Completion requires complete HTTP framing, not just
a parseable prefix. The observation callback runs once after full success.

Permanent `SessionToken` material is used exactly as stored. Status does not
prefix, refresh, rotate, change metadata, persist enrichment or invent expiry.
Tests compare exact opaque records, including material, metadata, gate,
revision and raw bytes across success, failures, cancellation and expiry.

## Absolute deadline seam

The parent granted exclusive additive edits to `providers/runtime.gleam`.
`open_until(runtime, adapter, request, deadline_ms)` and
`next_until(stream, deadline_ms)` preserve existing `open/next` defaults.
`deadline_ms` is an **absolute monotonic** time: a negative BEAM origin is valid.
F28 creates one 30,000 ms deadline **before shared acquisition**.

The same existing execution guard interrupts acquisition/open, stalled reads
and idle ownership. It does not renew a budget for each chunk or spawn a
provider watchdog. The caller clamps its waits to the remaining budget and
rejects queued late results. Expiry before launch is `Cancelled/NotSent`;
after possible launch it is conservatively `Cancelled/Uncertain`, and after
headers it is `Cancelled/Started`. These cannot cause a transparent replay.
F28 classifies both successful and failed expired reads as `DeadlineExceeded`.

Only the request's execution/waiter dies. A shared credential refresh remains
owned by the existing credential worker, not by the cancelled request.
Expired pulls from a revoked/adopted old owner cannot kill the replacement
owner. A runtime release barrier targets only that execution; queued
acquisitions from dead executions cannot create late leases.

The shared cleanup allowance is **at most 1,000 ms after expiry** for execution
death and coordinator bookkeeping. A stalled coordinator may defer its lease
bookkeeping beyond that allowance; the execution/socket is already dead and
its monitor will release it when the coordinator resumes. The dedicated paused
private-actor regression passed in the corrected focused batch. The 30s request bound is not a
claim that config loading, runtime initialization/shutdown or arbitrary trusted
observer callbacks are included in that budget. Legacy initialization/shutdown
and cancellation bounds remain separate.

No transport/store/production FFI changes were made for the deadline seam.
Dedicated test-only FFI pauses a private runtime actor and inspects only
module/function atoms to prove an adopted owner is inside a pending read.

## Source semantics, bounds and safe output

Pinned source re-read (source evidence, not upstream measurement):
[CPA `user_status.go`](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/devin/user_status.go),
`FetchUserStatus`, `BuildGetUserStatusRequest`, `parsePlanStatus`,
`parseSecondsSubfield`.

- POST `/exa.seat_management_pb.SeatManagementService/GetUserStatus`.
  Literal `Basic <session-token>-<session-token>`, protocol version 1,
  `application/proto`, unframed protobuf, Accept `*/*`.
  No implicit compression, User-Agent, Sentry or chat Connect envelope.
- The **secret** token occurs in both the header and metadata f3. Never
  capture/log/stringify/persist this request plan. Fingerprint is random,
  not derived from the token; no native fingerprint measurement is claimed.
- Only HTTP **200** succeeds. Other transport-valid heads produce exact
  `HttpFailure(code)`, with fixed text `Devin status HTTP <code>`, never
  provider reason phrases, bodies or private headers. Invalid media/framing
  may fail in shared transport before a usable status response is available.
- At most **4 MiB**, declared length checked before pulling and cumulative
  bytes checked while reading. Missing/duplicate/wrong media, unsupported
  compression, malformed protobuf/UTF-8 and truncated HTTP framing fail closed.
  Redirects are never followed.
- Absent quota stays `None` / JSON `null`; present `0` stays exhausted `Some(0)`.
  Percentages must be integer **0..100**, rejected rather than clamped.
  This is documented stricter validation than CPA's permissive parser.
- Reset/plan values are exact positive signed-int64 **Unix seconds**.
  Source zero means unset. They are not inferred durations, milliseconds,
  grant expiry or cooldowns. Encoded negatives/overflow reject.
- Valid unknown fields of supported protobuf wire kinds are skipped;
  unsupported groups, duplicate/wrong-wire known fields reject. No partial
  decode manufactures success.
- Operator output/hook contains configured account ID, observation time,
  optional numeric quota/reset/plan fields and explicit non-enforcement and
  non-rotation labels. Upstream email, identity/org/plan strings and raw bytes
  are deliberately omitted so reflected secrets cannot escape.

Status protobuf provides **no token count**. A separate pure
`status_observation.estimated_tokens(payload)` reuses existing `tokens.estimate`
and labels `estimated_input_tokens`, `estimate=true`, `exact=false`,
`method=payload_utf8_bytes_div_4`. This is CPA's byte-length heuristic, not a
measured/native tokenizer. No token or model module was edited.

## Observation is not quota enforcement

Quota-body values are returned only to this operator call/callback. They are
not saved to the grant, management metadata or the shared quota ledger,
converted into cooldowns or interpreted as a refresh schedule.

**Existing shared runtime bookkeeping is intentionally retained:** every
accepted head runs `quota.observe` and saves the normal ledger, including
unknown-window/account timestamps on ordinary statuses. A real HTTP 429 or
529 uses the existing 60s fallback cooldown, preserving prior longer cooldowns.
F28 supplies only one canonical numeric Retry-After in 0..86400 seconds **on
429**; all other upstream-private headers are excluded. The existing shared
rule can make a later status acquisition fail pre-I/O with NoAccount.
This normal ledger effect is separate from immutable permanent grants and
from observed-body quotas. Status codes are never disguised to bypass it.

## Focused validation / parent admission

Executed dedicated tests:
`devin_f28_status_test`, `devin_f28_status_runtime_test`,
`provider_deadline_test`; unchanged `devin_status_test` stays in the focused
selection. Coverage includes wire/auth, exact reset/error semantics, body/media/
compression/framing/redirect bounds, real socket deadline/peer EOF, cancellation,
adopted owner death inside a blocked pull, grant equality, unauthorized/revoked/
busy/missing grant/account pre-I/O, paused acquisition, non-extension/revoked
owners and preservation of shared refresh ownership.

The corrected run used `mise exec gleam@1.18.1 --` with
`ERL_FLAGS='+S 2:2 +A 2'`, scoped `gleam format` and focused tests only.
No full heavy gate is authorized for this worker.

Corrected gate: **105 passed**: 32 new F28/deadline functions, 4 unchanged status
functions and 69 existing runtime/binding/Devin regressions. Compiler 0.36s.
Exact test selection (EUnit, the existing gleeunit `scale_timeouts=10` convention):

```text
devin_f28_status_test, devin_f28_status_runtime_test, provider_deadline_test,
devin_status_test, provider_runtime_test, provider_runtime_v3_test,
provider_runtime_v4_test, provider_binding_test, devin_runtime_test,
devin_stream_runtime_test
```

The actual source/shipment/root CLI, full `gleam test`, CPA differential,
native client and live/remote qualification were **not run by this worker**.

### Failure ledger and corrective diagnosis

- Initial scoped format/build passed (compiler 17.27s). The initial focused
  output reported **3 failed / 102 passed**, but its tool invocation had duplicate
  identical parallel entries targeting the same log. It is **unqualified timing
  evidence**, not a serialized gate or a passing receipt.
- Unique atomic-lock guarded diagnostic: build passed (compiler 0.45s), exactly
  the three failing functions ran with unchanged deadlines and assertions.
  The 200ms stalled-head/peer-EOF and 100ms idle tests passed. The initial two
  timing failures remain unexplained/unqualified, not “fixed by a rerun.”
- The adopted-owner test still failed. Its safe module/function-only probe
  demonstrated a real blocked selector, then `runtime.ask`, then the generated
  `-read_with_deadline/2-anonymous-1-` continuation. Gleam's `result.try` tail call
  removes the ordinary `read_with_deadline` frame; the test predicate was wrong.
  The predicate now requires the actual selector/ask frames and the exact known
  read-continuation prefix. It does not substitute a ready signal or match any
  anonymous function. All temporary DEBUG probes have been removed from source.
- Production deadline code/budgets, peer-EOF and lease assertions were **not**
  weakened or widened. The corrected atomic-lock guarded scoped format/build
  and all 105 focused functions then passed with the original 100/150/200/400ms
  test budgets. This qualifies the corrected batch, not the initial invocation.

Preserved local logs under ignored `build/f28`: `01_format.log`, `02_build.log`,
`03_focused.log` (initial unqualified duplicate invocation), `04_diag_format.log`,
`05_diag_build.log`, `06_three_diagnostic.log`. The first tool output is retained
as `out_6529851de34e`; it preserves the reported failures independently of the
shared log's overwrite risk. Subsequent runs use an atomic `.validation-running`
directory and no-clobber unique logs, refusing duplicate execution.
Corrected passing logs are `07_corrected_format.log`, `08_corrected_build.log`
and `09_corrected_focused.log`; the lock was released after the batch.

Parent-only actual root/shipment workflow:

```sh
ERL_FLAGS='+S 2:2 +A 2' python3 docs/devin/f28_local_cli.py
ERL_FLAGS='+S 2:2 +A 2' python3 docs/devin/f28_local_cli.py \
  --executable /explicit/path/to/actual/shipment/entrypoint
```

The smoke uses the real root CLI, synthetic private 0700 state/0600 inputs
inside `build/f28`, exact transient request inspection, two fresh VM restores,
explicit second-account selection, wire failures, key denials/revocation,
unchanged grant bytes, no fallback and a live **synthetic local** gateway
busy-store/public-model check. Its output is safe counters/booleans only.
It is supplied for admission, **not reported as executed here**.
