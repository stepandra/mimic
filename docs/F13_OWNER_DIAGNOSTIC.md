# F13 single owner-death diagnostic receipt

**UNVALIDATED checkpoint: scoped build PASS, narrow owner-death test FAIL.**
Synchronization of this checkpoint is not feature admission. Root WS-lite
enablement remains off; `F13_ROOT.patch` is unapplied. No corrective socket
architecture, linger-policy change or broader error acceptance was implemented.

## Grant and execution

The parent lifted HOLD for one safe-instrument/build/owner-death-only sequence
under the shared exclusive lock, with a maximum 180-second workload. This was
the same outstanding grant, not an authorization for a second attempt.

- Isolated checkout:
  `/Users/jerryjohnson/dev/mimic/.delta/worktrees/5v6b0zndq97r/mimic`.
- Unique logs: `build/f13-owner-diagnostic-1790887117519563000`.
- Exact token:
  `f13-recovery-5v6b0zndq97r-79406-1790887117519191000`.
- Shared lock:
  `/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock`.
  Acquired atomically with exclusive file creation; removed in `finally` only
  after matching that token. The receipt records release.
- Total slot elapsed: **100.704 seconds**. No timeout/retry occurred.
- Build: `ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- gleam build`;
  exit 0, `Compiled in 11.57s`. It downloaded 18 dependencies, without importing
  preserved BEAM/root runtime or state.
- Test: one direct `erl -noshell` EUnit descriptor with freshly built application
  `ebin` paths, exit 1:

```erlang
eunit:test(
  {timeout, 15,
    fun codex_ws_lite_test:f13_actual_owner_death_stops_blocked_sender_and_success_leaves_no_helpers_test/0},
  [verbose])
```

The command halts 0 only for EUnit `ok`, otherwise 1. There was no `gleam test`,
formatter, other test, root workflow, browser, native/live, reference retrieval,
child agent, or second BEAM attempt in this slot. Existing dependency deprecations
and now-unused legacy private test externals were warnings, not build failures.

## Safe instrumentation only

The production FFI carries an opt-in process-dictionary diagnostic flag into its
short-lived guardian/sender. Without that test-set flag, trace output is disabled.
It logs fixed event/result categories and monotonic milliseconds only: no socket
terms, write arguments, credential values or raw diagnostic reasons. Connect,
socket options, send/close outcomes, deadlines, return/error decisions and the
existing ignored force-close result are unchanged.

Test-only probes validate live caller/helper processes, reciprocal loopback
client/peer ports, public raw-port owner, and the exact guardian/sender
monitor/link graph. They install all exact monitors before owner kill. Absent
object `noproc`/`nosock` cannot satisfy that prepared cleanup assertion. The TCP
fixture enables `show_econnreset` to distinguish reset from closed, and counts
raw drain bytes/reads/time. Strong peer EOF/reset and existing time ceilings
remain required. This diagnostic is port-backend-specific; it does not qualify
an alternative inet socket backend.

## Observed receipt

One EUnit test failed, zero passed tests. Failure:
`blocked-owner-TCP: synthetic peer termination: timeout`.
Successful-owner TCP ran earlier within the function. The owner-death TLS
branches were not reached and are not qualified by this receipt.

Recorded blocked TCP events:

```text
{prekill_identity,reciprocal,true,2}
owner_down
{preinstalled_down,port,killed}
abort_enter
{abortive_linger,ok}
{force_close_result,ok}
{raw_down,port,noproc}
{abort_result,ok}
{preinstalled_down,process,other}
{preinstalled_down,process,other}
{peer_timeout,1048,9000017,2180}
```

These are fixed categories from the log, not normalized successes.
Same-millisecond output from different processes does not establish a total
execution order. Within the guardian's own ordered abort path, its newly
installed socket monitor reports `noproc`; the public local handle already
does not exist when that monitor is installed. Despite this, the unchanged
abort predicate returns success.

The held peer then received **9,000,017 bytes in 2,180 reads**, and its raw
receive returned timeout after **1,048 ms**, not EOF/reset. The extra 17 bytes
are consistent with a masked Pong carrying the 11-byte `owner-death` payload.
Their time of submission was not recorded: do **not** claim they were written
after kill/helper DOWN, nor that prior queued bytes can be recalled.

Confirmed finding: local/helper DOWN plus `force_close=ok`/`abort_result=ok`
is not physical peer-termination evidence. The false-positive already-dead
monitor path is reproduced with reciprocal endpoints and prekill monitors,
not explained by a wrong fixture handle or arbitrary TLS alert.

The caller-owned automatic-close/queued-drain race remains the leading cause
to investigate. The exact driver/OS ordering and why an option/close call
reports `ok` while that monitor says `noproc` remain unresolved. Do not choose
stable independent socket custody or pre-write abortive-linger arming solely
from this receipt. Proposal/review is required before corrective architecture.

## Cleanup and remaining gates

Both owned build/test process groups were absent in the post-run `ps` check.
The shared lock was absent at that check. No task, retry or deferred validation
remains. Runtime HOLD resumes; this attempt is consumed.

The current probe source hashes are in
[F13_OWNER_DIAGNOSTIC_SHA256SUMS](F13_OWNER_DIAGNOSTIC_SHA256SUMS).
It includes the unchanged shared framing/read/HTTP-FFI and synthetic CA helpers,
build configuration/dependency lock, and unapplied root artifact. These are exact
critical input hashes, not a claim to hash every transitive installed binary.
Gleam1.18.1 and `ERL_FLAGS='+S 2:2 +A 2'` were used on the inspected local
OTP29.0.4/ssl11.7.4 toolchain; OTP28 was not run.
The recovery manifest remains historical. Source format, complete dedicated
suite, 176-selected strict/F11/F12/ws_transport/xAI regressions, alternative
backend/OTP28, parent source/shipment root WS/WSS and native/live qualification
are unverified for this checkpoint.

The source-only alternatives and separate public-proof hardening are described
in [F13_ABORT_PROPOSAL.md](F13_ABORT_PROPOSAL.md). The measured FFI remains intact
in this checkpoint; neither proposal nor a corrective proof predicate was
implemented after the run. New implementation/runtime scope is still required.

Log SHA-256:

```text
2faa1349ecba012bd5d7df429a6a4ba318a3847e3a53df7185be4695517f440a  build/f13-owner-diagnostic-1790887117519563000/build.log
14f57fcdc128e6e66f3cfdc99796420fb651a0e2cb84dcb2834f0982759f7434  build/f13-owner-diagnostic-1790887117519563000/owner-death.log
0c598afe1e58a48880c77d1377178a73ed31962c5730f2ae955ea5354e4e0b35  build/f13-owner-diagnostic-1790887117519563000/receipt.json
```
