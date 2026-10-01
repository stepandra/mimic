# Shared Content-Type singleton correction (F07 reporter follow-up)

## Status

**All five focused raw Content-Type controls and all 19 unchanged F44 controls
pass** on the verified real dependency closure, with the cancellation lane also
passing all 18 cases across two explicitly granted runs. The duplicate controls
assert exact peer close/reset, zero response bytes and zero handler dispatch;
the single-Content-Type and repeated-Accept controls remain positive.

This is synthetic loopback dependency-closure evidence, not assembled actual-root
or shipment admission. The original F07 HTTP-200 failure below is preserved.
The parent owns the strict actual-root UI reporter rerun, full suite and shipment
gates. There is no pending/deferred workload here.

## Retained measured failure

The F07 actual root UI reporter measured HTTP 200 for all three duplicate
Content-Type cases. The original artifact remains unchanged:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/xeyaep9az5rw/mimic/build/account-ui-f07/logs/root-slot-001.log
SHA256 7a606fe1846238d10501a547349d3678f19c509200a3b289aad7857b2687a3db
```

That hash and the three rows were checked read-only during the validation hold.
Each original row says `actual_status: 200`, `desired_status: 400`,
`strict_gate: false`, `provider_sends_delta: 0`, `runtime_residue: false`, and
`before_handler_rejection: "not instrumented"`. Provider-counter/residue
assertions do not independently prove zero route dispatch. The 200 response
was measured, not inferred; the old report-only desired-400 discrepancy is not
a waiver or a successful rejection receipt.

The inherited `scripts/smoke-account-ui.py` reporter sent coalesced:

```text
POST /api/status HTTP/1.1
```

with body `{}`, Content-Length 2, Connection close, exact configured loopback
Host/Origin, and valid synthetic Cookie/CSRF plus `X-Mimic-UI: 1`. Duplicate
Content-Type fields led the frame before all remaining valid fields:

| Case | Leading raw fields | Old measured result |
| --- | --- | --- |
| equal | `Content-Type: application/json` twice | 200 |
| conflicting-invalid-first | `Content-Type: text/plain`, then `Content-Type: application/json` | 200 |
| mixed-case-invalid-first | `content-type: text/plain`, then `CONTENT-TYPE: application/json` | 200 |

## Coherent shared rule

Content-Type names one media type; it is not a repeatable list-valued field like
Accept or Connection. Add it to the existing raw singleton set in
`mist/internal/http.gleam` so duplicates are rejected **before** a header Dict
can discard an occurrence, independent of field case, value equality or order.
No UI-only canonicalized-header workaround is introduced.

The existing malformed-singleton policy closes/resets the connection without
an HTTP response, before route dispatch. The parent's approved regression
therefore requires **zero response bytes and zero dispatch**, not “any non-200”
and not a route-level 400. In the Python reporter, no HTTP status is represented
by `null`, not by an invented HTTP status 0.

The parent granted the narrow `raw_header_report` update: Content-Type cases
now have that same exact peer-closure expectation and a strict assertion for
zero response bytes. EOF and reset are recorded separately; timeout still fails.
The reporter's before-handler field remains honestly `"not instrumented"`.
The dedicated raw Gleam tests count handler entries directly.

`mist_content_type_boundary_test.gleam` defines five synthetic raw controls:
conflicting duplicates in both orders/case, equal duplicates, fragmented
duplicate, one mixed-case/OWS field accepted, and repeated Accept still accepted.
Servers bind loopback and tear down their own processes. No credential values
are retained by the raw test fixture.

## Retained earlier validation checkpoints

The stopped patch was recovered byte-for-byte into an isolated checkout; the
recovery paths/hashes and original setup failure are recorded in
`F12_CHUNK_CANCELLATION.md`. The exact focused recovery closure compiled and
scoped formatting passed. Its runner passed three cancellation cases, then
stopped before reset at a backpressure prerequisite failure.
**None of the five Content-Type cases or 19 F44 cases was reached.** Compilation
is not raw peer-closure/zero-dispatch evidence. A separately granted one-shot
run compiled the safe cancellation probe and executed only the failing
backpressure case. It observed an `Ok` send with queued driver bytes and failed
before reset/EOF/lease-zero gates. It did not execute any Content-Type/F44 case.

The parent subsequently approved a bounded cancellation-fixture correction for
source-only implementation. A later single-case slot passed its scoped
format/build checks, including the exact parent runtime source, then rejected
client `recbuf` readback 326,504 against the unchanged 65,536 limit. No pressure
write or reset/EOF gate ran. Production Mist and this Content-Type test remain
unchanged; no raw rejection/dispatch or runtime behavioral gate is admitted
from compilation.

The approved one-time post-prefix cancellation-fixture setup now exists in the
namespaced test-only FFI, but its next focused slot stopped at package-cache
inventory before formatting, compilation, BEAM or sockets. The two additional
metadata entries and unexecuted-input/cleanup receipts are retained in
`F12_CHUNK_CANCELLATION.md`. That setup-only attempt did not compile the new FFI.
A separately renewed exact-metadata slot passed scoped format/build, then only
ran the corrected cancellation case. It failed before reset at the shared
deadline, with final client `recbuf` 526,720 and the observed primitive
`prim_inet:send/4` not admitted by the existing send-path predicate. No semantic
correction or retry was made. None of these slots supplies Content-Type/F44,
root or shipment behavioral evidence.

This is an **UNVALIDATED synchronization checkpoint**, not admission. There is
no pending/deferred run; further validation requires a new explicit parent slot.
Run the five dedicated controls, existing F44 socket suite and the strict
actual-root UI reporter under the same atomic validation-lock protocol as the
F12 cancellation lane. The parent owns composed root/shipment admission.

This is synthetic loopback work, not live-provider, native-client, CPA
differential or real-account qualification.

## Passing raw boundary and preserved F44 evidence

The parent explicitly approved a test-only cancellation-fixture policy revision
and exact source-verified `prim_inet:send/4` support. A separately granted focused
backpressure case passed. All implementation bytes stayed unchanged for the
subsequent ordered 41-function sequence: 17 other cancellation cases, then the
five raw Content-Type cases, then 19 unchanged F44 cases. Every function passed
in a fresh bounded VM, with all original assertions and deadlines. No default
test discovery or root application was used.

The first new matrix setup attempted dependency metadata resolution and failed
its HTTP request before any testcase ran (`executed_cases = []`). That refusal
is preserved. The parent then authorized reuse of the exact already compiled
successful closure, without resolving, downloading or rebuilding. All 53 real
source/descriptors, full Mist and all 331 pinned package paths/hashes were
verified; all 163 compiled outputs were hashed before/after, and each runner
verified all 142 compiled module paths. No compiled/copied project or parent
runtime dependency is part of the owned synchronization packet.

The dedicated raw test source stayed unchanged, SHA256
`332824077614b7d77602852e26d173bc1e5d6365ad3a88b8d7ac484b6f0dbfb5`.
Shared production HTTP source stayed unchanged from recovery, SHA256
`f4bdbd1594f2a0f1b3c9707f345a095ee3acdb36ec2f7705394e6d0738ae7bce`.

All raw results are retained in
`build/closure/f12-matrix-reuse-45346-1790892563283714000-receipt/result-and-cleanup.json`,
21,668 bytes, SHA256
`0db3939058504ebe1074b864e42fa2e8287cb5602e5db58dbc994709b235aa17`.
The exact ordered-list receipt is SHA256
`b6809a482bd42eace33bcd8949d610b93148fa8cf63948ed933b4fe2fd4fe9eb`.
Per-case logs use prefix
`build/closure/f12-matrix-reuse-45346-1790892563283714000-case-`:

| Index | Raw control | Result | Log SHA256 |
| --- | --- | --- | --- |
| 18 | conflicting duplicates, both orders/case | pass | `98bec2131c49e1aae3d41c2bca2a1649a2fc3a6f7173182b7e0ac1f015109290` |
| 19 | identical duplicate rejected | pass | `22b23b4ece8f35fccdae34e2cbdf68f140162a4cfe9d1e241f762488882a84d9` |
| 20 | fragmented duplicate rejected | pass | `9c8141c502f532314145ac074e880b00c640b20ac8b67fb7f33e05fca2f897bd` |
| 21 | single mixed-case/OWS field accepted | pass | `ed8d299b785edaceee13ef251acd7ddc3f63babf77f634680ffc134534e89040` |
| 22 | repeated Accept accepted | pass | `1d911de3a3bc2f10463983dc2f3c973c32a1d08379c6aa2b9a20253c7c7da95c` |

The whole 41-case sequence, including cleanup/audit, took 52.388 seconds.
Owned descendant audits were empty, generated metadata and compiled-output
hashes stayed unchanged, and only the matched shared-lock token was released.
No source semantic correction or retry occurred during that sequence.

The narrow Python `raw_header_report` strict-close change and the original
actual-root 200 receipt remain intact. These raw fixture results do not pretend
to instrument route dispatch in the Python reporter or prove that the actual
root workflow has already passed. The parent will verify synchronized hashes/
conflict markers and run those assembled gates separately.
