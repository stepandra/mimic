# F13 STOPPED-worker recovery

**RECOVERED, DIAGNOSTIC-READY, UNQUALIFIED. Source-only hold remains in force.**
This is a recovery receipt, not a successful validation or root admission.
It supersedes the preserved document's "diagnostic pending/not rerun" ledger
only with the retained receipt described below.

The later explicitly granted single diagnostic attempt is recorded in
[F13_OWNER_DIAGNOSTIC.md](F13_OWNER_DIAGNOSTIC.md). Its scoped build passed and
owner-death test failed. The recovery manifest is the **historical pre-probe**
hash set; the current safe-instrumentation checkpoint has its own manifest.
No corrected close architecture or root admission has been applied.

## Recovery boundary

- Preserved checkout, read-only:
  `/Users/jerryjohnson/dev/mimic/.delta/worktrees/brtv35rqx2gj/mimic`.
- Isolated destination:
  `/Users/jerryjohnson/dev/mimic/.delta/worktrees/5v6b0zndq97r/mimic`.
- Recovered eight changed files and two missing files using `apply_patch` only.
  The 13 entries in [F13_RECOVERY_SHA256SUMS](F13_RECOVERY_SHA256SUMS) all match
  preserved bytes exactly. `codex/request.gleam`, `codex_websocket/fence.gleam`
  and shared `responses/frames.gleam` already matched; they were not edited.
- A before/after SHA-256 inventory of 779 existing durable project files found
  only the ten allowlisted recovery changes before these two new receipt files.
  Generated output, build directories and VCS metadata were excluded.
- No preserved root/old runtime, generated BEAM, state, credential data or build
  logs were imported. Gateway/config/CLI/runtime/auth/store/vendor, HTTP egress
  FFI, F12 HTTP and other shared codec files remain untouched.
- [F13_ROOT.patch](F13_ROOT.patch) is recovered but **unapplied**. Root WS-lite
  admission remains off. No synchronization/import is authorized by this receipt.
- No refs, child agents, live upstream/native workflows, compile, formatter,
  BEAM, socket, browser or test commands were run during recovery. No validation
  lock was acquired and no background/deferred task was started.

## Retained receipts, not reruns

All log paths below are relative to the read-only preserved checkout; the logs
remain there, not in this recovery's build directory.

| Log | Observed receipt |
| --- | --- |
| `build/f13-validation.P9IyQd/focused.log` | 24 dedicated tests passed, including real synthetic TCP/TLS pressure/Pong/abort, then owner-death failed at peer termination. |
| `build/f13-validation.CyZTER/check.log` | Intermediate fixture clause type error (`Nil` versus `Int`), not a passing gate. |
| `build/f13-diagnostic.Ck5Gyg/check.log` | Retained successful check, `Compiled in 0.29s`. |
| `build/f13-diagnostic.Ck5Gyg/build.log` | Retained successful build, `Compiled in 0.44s`. |
| `build/f13-diagnostic.Ck5Gyg/owner-death.log` | Narrow function failed: one failure, zero passed tests; `blocked-owner-TCP: synthetic peer termination: timeout`. |

The narrow function is
`f13_actual_owner_death_stops_blocked_sender_and_success_leaves_no_helpers_test`.
Its source order runs successful-owner TCP before blocked-owner TCP and TLS
afterward. The last receipt fails in the second TCP branch; it does **not**
qualify either owner-death TLS branch. The actual root source/shipment WS/WSS
workflow and complete follow-up 176-selected-test regression gate remain unrun.
An earlier candidate's 176-pass receipt is not this candidate's qualification.
OTP28 runtime remains unverified; the prior inspected local toolchain was
OTP29.0.4/ssl11.7.4, Gleam1.18.1, `ERL_FLAGS='+S 2:2 +A 2'`.

Retained log SHA-256:

```text
b719a6fb28c113204b3998b26b164c503dbd854664a99be4e7e02662b5db0ee9  build/f13-diagnostic.Ck5Gyg/owner-death.log
bec76de59424963211929be9eb5b11aa5c2feefc0a5c13b2bbb64d5a7ec1d8d9  build/f13-diagnostic.Ck5Gyg/check.log
b2c3ca094542d9fca62b4420b13a7143c993f880facf0b6d7ed1579725dd7cad  build/f13-diagnostic.Ck5Gyg/build.log
3b4c4ae98890ef0d2aa24ef4295292f7d789327d147f163ca7c11331b0de038e  build/f13-validation.P9IyQd/focused.log
164438ab550d5e4183e96e120be660c745977caca3d4f3e71bd4af53208017a1  build/f13-validation.CyZTER/check.log
```

## Static diagnostic findings

These findings do not establish the actual cause:

1. `ws_transport.Connection.physical` is the retained `gen_tcp` handle returned
   by `mimic_ws_transport_ffi.connect_with_ca`. In the TCP case its wrapped socket
   is that same handle. The pressure and cleanup FFI patterns both select the
   third tuple element of the same Connection, not the SSL tuple internals.
   The owner publishes this Connection directly to the test. No obvious
   alternate-handle assignment appears in that source path. The fixture checks
   only a live `inet:peername` result, not reciprocal client/peer endpoint identity.
2. The peer accepts one socket, upgrades it, emits pressure-ready/control data,
   and waits on its own release Subject before draining that same accepted socket.
   The timeout comes from its actual `gen_tcp:recv`, not Subject gate timeout,
   TLS alert, or generic downstream failure.
3. The guardian is monitored, **not linked to the caller**. It traps exits and
   links/monitors its sole sender. Caller DOWN selects `stop_sender`: abort first,
   then kill/drain that exact sender. A racing sender DOWN instead selects
   `cleanup_until`, which also attempts abort. Static control flow does not prove
   which branch ran or that physical closure succeeded before the sender exited.
4. `abort/2` discards `force_close`'s return and accepts an exact monitor/object
   DOWN with any reason. Fixture `await_down` also accepts any type/reason for
   the exact monitor/object. The references are matched, but an already-dead
   handle's `noproc` notification can satisfy these predicates. Monitors are
   installed after owner kill in the fixture. Local DOWN is not sufficient
   peer-side evidence, and force-close failure can be concealed.
5. Initial TCP options use disabled linger; only later explicit abort changes
   linger to `{true, 0}`. Raw TCP remains owned by the opening caller in the TCP
   branch. Owner death can race that option change/close. Whether the owner-exit
   close precedes guardian abort is unmeasured.
6. Pressure tries 9,000,000 synthetic bytes with a 4096-byte send buffer and
   asserts at least 65536 pending bytes while the peer is held. Drain uses raw
   length-zero receives under a single 1000 ms deadline, then the test allows
   1200 ms for its Subject result. Existing failure logs contain no pending value,
   byte/read totals, close-path result, DOWN category or per-branch timings.
   The code therefore cannot distinguish retained-fill drain from failed abort.
7. Production sender setopts enables `send_timeout_close=true` without arming
   abortive linger. Automatic timeout close is another possible pre-abort window,
   separate from owner death. Neither ordering has been observed in this receipt.

### Local OTP source cross-check (read-only, no runtime)

The installed sources under
`/opt/homebrew/Cellar/erlang/29.0.4/lib/erlang` were read without starting Erlang:

- `lib/erts-17.0.4/src/prim_inet.erl:175-215` takes `{true,0}` directly to
  `close_port`; the disabled/default linger branch can wait on pending output
  under a 180000 ms timer. This is the explicit Erlang close path, not proof of
  the driver's caller-exit or automatic timeout-close ordering.
- `lib/kernel-11.0.3/src/inet.erl:645-694` documents DOWN for a socket that did
  not exist when monitoring began (`nosock`); the port implementation delegates
  to `erlang:monitor(port, Socket)`. Existing-object validation must precede kill,
  and sanitized absent-object `nosock`/`noproc` must not become closure proof.
- `inet.erl:1435-1449` confirms automatic close on send timeout with
  `send_timeout_close=true`. `inet.erl:1451-1467` shows default
  `show_econnreset=false` maps RST to `closed`. The pressure listener does not
  enable that option, so its current `eof` label is closed-or-reset, not proof of
  graceful FIN. Use peer-side reset visibility in a granted diagnostic.
- `gen_tcp.erl:844-870` explicitly separates successful local close from
  acknowledged delivery. Do not report queued writes as delivered.
- The installed tree contains no `inet_drv.c`; exact driver/OS ordering remains
  unverified. No external reference retrieval was performed.

SHA-256 of those installed files:

```text
a67a703b9fa63eae4797b2cbe95b62382cf8c50399b55e440e158e39c4927791  lib/erts-17.0.4/src/prim_inet.erl
a8b5c3ab91129e8dbb17fea669beae90a518c574a4f3aed19f7f53c0396c0bdd  lib/kernel-11.0.3/src/inet.erl
ac46bcc600f7f50d2c79efb7b75276c8e719b0e47c664ac4ddd73941fb3640d2  lib/kernel-11.0.3/src/gen_tcp.erl
```

## Ranked falsifiable next probes (not installed or run)

1. **Caller-owned TCP auto-close wins the abort race.** Record safe relative
   timing and fixed result categories for owner DOWN, sender DOWN, abort entry,
   abortive setopts, close/fallback and inet DOWN on a previously validated live
   handle. Prediction: blocked TCP loses abortive setopts to owner-exit closure,
   while direct pressure/abort with a surviving owner does not. Do not change
   initial linger/ownership speculatively or add a persistent connection owner.
2. **The apparent helper/raw DOWN is not the intended completed abort.** Validate
   reciprocal endpoints before pressure, exact physical-handle equality, the
   guardian's owner monitor and sender link/monitor, then retain sanitized branch,
   force-close result and DOWN type/reason categories. Prediction: the receipt
   exposes wrong association, pre-existing DOWN or an unobserved cleanup failure
   instead of successful physical abort. Never log socket internals or arguments.
3. **Peer drain sees buffered fill rather than termination within its bound.**
   Add only byte/read/elapsed counters and fixed closed/reset/timeout/TLS
   categories to the same held peer. Prediction: timeout follows a quantifiable
   prefix/backlog without close/reset despite local DOWN, or reveals a fixture
   association/state defect. Do not widen deadlines or normalize timeout/alerts.

Install all exact socket/helper monitors **before** kill, prove reciprocal
client/peer endpoints and the public socket owner, and record monotonic
byte/read/pending/ordering counters with fixed result categories only. Do not
print write arguments, secret values, complete socket info or opaque SSL terms.

If automatic close is confirmed, compare proposals before editing architecture:
arm `{linger,{true,0}}` before the blocked-write/automatic-close window with
bounded normal-policy restoration only after proved successful send, versus
independent stable OS socket custody (including SSL's user controlling owner).
Neither is approved here. The smaller arming proposal must demonstrate exact
driver ordering and retain graceful successful WebSocket-close behavior; the
custody proposal must justify its new lifetime boundary. Neither may claim
discarded queued bytes were delivered or introduce unbounded restoration.

All proposals require explicit grant. Keep positive peer EOF/reset, proven output
backlog, elapsed limits, exact-helper termination and no-late-write checks.
After grant, use only the direct narrow function in unique logs and atomically
acquire `/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock`;
remove only this worker's lock. Further regressions and parent root composition
need their own authorized gates. There is no queued retry and no automatic import.
