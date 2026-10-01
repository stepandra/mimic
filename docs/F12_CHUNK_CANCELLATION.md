# F12 shared chunk cancellation: repro and decision record

## Status

**Focused dependency-closure evidence passes: 18 cancellation + 5 raw
Content-Type + 19 unchanged F44 cases.** The actual-send-backpressure case
passed once after the explicitly approved test-only option-B policy correction.
The other 41 distinct functions then passed in a separately granted serialized
run using the exact same verified implementation and compiled outputs. This is
not assembled application, actual-root, full-suite or shipment admission.

The actual root source workflow failed the unchanged five-second cancellation
assertion at `scripts/smoke-codex-http-lite.py:390`. The retained parent receipt
is `build/closure/f12-root-source-1790881487656107000.log`. It contains that
assertion failure, not process/socket instrumentation proving its exact cause.
That root workflow and the actual-root UI raw-header reporter were not rerun
by this worker; the parent owns those gates.

### Retained preceding checkpoints

**UNVALIDATED checkpoint, not admission.** The recovery dependency closure built,
and scoped formatting passed after a whitespace-only test correction. Three
cancellation cases passed, then the runner stopped at the first backpressure
prerequisite failure: queued driver bytes were observed, but the executor was
already dead before client reset. The remaining cancellation cases, all five
Content-Type cases and all 19 F44 cases were not reached.

A separate one-shot diagnostic compiled and ran only the instrumented failing
case. It rejected a completed `Ok` send with 16,115,079 queued driver bytes:
the executor was alive but not blocked in that send. Reset/EOF/lease-zero
assertions were not reached. This does not replace the earlier dead-executor
receipt or qualify cancellation under actual send backpressure. A bounded
fixture correction was subsequently approved for source-only implementation.
Its focused scoped format check and build now pass, but its single test failed
the socket-buffer prerequisite: client `recbuf` read back as 326,504, above the
unchanged 65,536 bound. Pressure authorization, pressure writes, send-path
admission and reset/EOF/lease-zero gates were not reached. No new pressure or
cancellation pass is claimed.

The one-time post-prefix client `recbuf` setup was then approved and implemented
in the test-only FFI. Its new focused slot stopped during cache inventory:
two additional cache metadata files were outside the preceding source receipt.
No formatter, compiler, BEAM or socket fixture started in that setup-only slot.
A separately renewed slot then passed scoped format/build and ran only the
corrected case. It failed admission at the unchanged deadline: final client
`recbuf` was 526,720, and the current send-path predicate rejected the observed
primitive `prim_inet:send/4`. No reset/EOF/lease-zero assertion was reached.
At that checkpoint the fixture was compiled, but cancellation remained
**unvalidated**. The later approved policy and passing focused receipts below
do not relabel any of these earlier failures.

The stopped setup failure remains retained history, not overwritten evidence.
Root/provider/runtime files and imported F44 corrections remain outside this
worker's edits. No full suite, root cancel workflow, shipment, browser or live
upstream qualification was run here. There is no pending/deferred validation
task; resumption requires a new explicit parent grant.

## Minimal deterministic feedback loop

Add a dedicated `mist_chunk_cancellation_test` lane using real Mist, the existing
shared provider runtime and HTTP egress, and a synthetic loopback TCP fixture:

1. Complete the downstream request body before handing off the connection.
2. Open one runtime stream. Adopt synchronously in the real Mist chunk `init`,
   before the request owner exits, just like the root sender.
3. The upstream emits one synthetic metadata SSE chunk and remains idle. It
   neither sends an HTTP terminal chunk nor closes on a fixture timeout.
4. Run the forwarding loop synchronously. Record only fixture-local milestones:
   callback PID, first chunk acknowledged, second pull entered, owner death,
   upstream peer EOF, and active lease count. Never record credential/header
   values.
5. The raw downstream client reads the exact first chunk, then closes. Assert
   actual upstream peer EOF and `runtime.active_leases == 0` promptly, before
   the existing five-second egress timeout can masquerade as cancellation.
6. Bound every fixture operation and tear down its own servers, sockets,
   monitors, and temporary synthetic credential store.

The real root source and fresh shipment must subsequently repeat the existing
F12 workflow through the parent. A focused primitive or Mist test cannot admit
that composed workflow.

### Ranked hypotheses and distinguishing signals

1. **Synchronous callback prevents lifecycle handling.** Prediction: the chunk
   actor is alive in the second pull after the client closes; killing that
   adopted owner yields upstream EOF and lease release before read timeout.
2. **No downstream-close observation is armed.** Prediction: even between
   callbacks, a close is not handled. The current actor selector contains only
   its application subject; selecting more messages alone would still not
   interrupt a blocking callback.
3. **Adoption/owner race or unauthorized cancellation.** Prediction: init and
   pull PIDs differ, adoption fails, or a cancel from a helper is rejected.
   The runtime requires pull/cancel caller PID to equal the adopted owner.
4. **Client-library close did not close the actual connection.** Prediction:
   raw socket close reproduces differently from the root HTTP client's close.
   The dedicated raw client removes that ambiguity.

## Approved ownership/API correction

The parent rejected the initial passive TCP-state polling proposal before any
production implementation. FIN/CLOSE_WAIT is a peer write-half-close, not proof
that it abandoned reading; OS-specific state queries also add portability and
polling costs. **No raw TCP-state primitive or other production FFI was added.**
Timeout-only cleanup and response heartbeats were rejected too.

`mist/internal/chunked.gleam` implements one shared lifecycle:

- The factory-supervised coordinator owns downstream socket receives and
  selects the transport's close/error messages.
- One linked persistent executor runs synchronous init/adopt, every callback,
  ordered data sends, and the final chunk. It retains callback state and its
  PID never changes between pulls. There are no per-pull tasks, speculative
  pulls, second credential manager or response buffers.
- Init completes synchronously before the old request owner may exit. The
  coordinator monitors that owner during handoff. Only after controlling-process
  transfer and private `Ready` does it arm `ActiveOnce` and dispatch callbacks.
- The coordinator sends one `Run` at a time and retains at most 32 pending
  application messages. Overflow explicitly aborts. The push-style Subject API
  is not a producer-side flow-control API; callers must not flood BEAM mailboxes.
- On transport termination, executor termination, tail/message overflow or
  startup failure, the pair closes/terminates. The coordinator never waits on
  upstream pulls or downstream writes, never sends a successful terminal chunk
  after abort, and never asks an unauthorized helper PID to cancel the runtime.
- Executor death invokes the existing runtime owner monitor, execution kill and
  coordinator lease release. A terminal coordinator unlinks then kills its
  executor, so its own normal cleanup cannot be interrupted by the linked kill.

### Intentional vendor contract tightening

The public function signatures, `ChunkNext` constructors and five-tuple
`Connection` ABI are retained. Broader upstream Mist behavioral compatibility
is **not** claimed:

1. Init's application Subject is now a **send-only capability owned by the
   coordinator**, not a subject locally receivable by the executor.
2. Read the request body before handoff. The original request owner's
   `http.request_body_completed` wrapper uses the existing non-consuming peek;
   it never drains input, consumes/reassigns a completion tail, or makes HTTP/2
   body streams supported. An unread-body handoff is rejected and closed.
3. A chunked response remains connection-terminal, as before: the HTTP handler
   returns stop for `Chunked` and does not dispatch its pipeline tail. It now
   explicitly emits `Connection: close`. Existing coalesced parser/completion
   tails remain with their original owner. Newly received post-request bytes
   are retained up to 64 KiB until closure, never dispatched or forwarded as
   response body; overflow explicitly aborts.
4. TCP write-half-close is **unsupported** for this streaming path. Under default
   active TCP behavior, a FIN/SHUT_WR can terminate the local transport and cause
   abort. Only actual `tcp_closed`/`tcp_error`/`ssl_closed`/`ssl_error` notifications
   drive disconnect abort; none is described as proof of peer read abandonment.
   The retained passive lifecycle fixture records the old half-close contrast.

### Caller audit (read-only)

All eight production call sites send to the init Subject; none receives from it:

- `mimic/gateway.gleam`: Claude, shared native encoder, strict Codex.
- `mimic/gateway/codex_http.gleam`: cached strict and sparse HTTP forwarding.
- `mimic/ingress.gleam`: next-chunk scheduling stores a send capability.
- Devin chat, messages and responses gateway senders.

Init/adopt and callback ownership therefore stay coherent for current callers.
Provider codecs, receipt budgets, provider error semantics, runtime authorization
and credential management were not edited. Root custom WS and the F44 normal
pipeline/framing/OWS/Connection-token/head-deadline rules remain untouched.

## Required regression matrix

- Idle upstream after first chunk, then downstream close: peer EOF and lease 0.
- Adopted owner death while a pull is blocked.
- Downstream write failure and peer close during write backpressure.
- Normal upstream EOF: ordered exact chunks and one complete final chunk.
- Upstream framing/error termination: retained valid prefix, no invented EOF.
- Repeated cancel: no double release, resurrection or surviving guard.
- No concurrent callbacks, reordered/dropped prefix, growing process count,
  credential leakage or consumed request/pipeline tail.
- Existing F44 socket tests and root custom-WS composition.
- Parent actual-root F12 source workflow and fresh-shipment workflow.

The dedicated lane currently defines 18 tests, including retained legacy idle
and half-close controls, TCP/TLS non-owner sends, actual blocked-send reset,
both process-death directions, overflow bounds and body/tail ownership.
`scripts/smoke-codex-http-cancel.py` reuses the original synthetic root upstream
and unchanged five-second peer-EOF assertion without running the rest of F12.
It reports that lease-zero is not exposed by that CLI lane rather than inventing
that measurement; the dedicated actual runtime tests assert it.

## Validation protocol

Only after explicit slot grant, acquire the shared lock with atomic `mkdir`:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/build/closure/validation.lock
```

Use unique retained logs, Gleam 1.18.1 through `mise exec gleam@1.18.1`, and
`ERL_FLAGS='+S 2:2 +A 2'`. Release only a lock this invocation acquired.
Run scoped formatting, Gleam build, the dedicated matrix and existing F44 socket
tests, then `gleam test` as scheduled by the parent. The saved legacy fixture is
the imported pre-F12 lifecycle, **not** the historical pre-F44 source tree. Its
controls can reproduce the synchronous/passive contrast but cannot be presented
as a historical red receipt. Parent owns actual-root source/shipment workflows,
assembled full-suite validation and admission updates.

Synthetic loopback evidence does not imply live-provider, CPA differential,
native-client or real-account qualification.

## Stopped-worker recovery receipt

Worker `feb6c4e096164a80` was recovered from the exact read-only checkout:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/zndtnmt5df3z/mimic
```

Only the 11 owned paths below were recovered via `apply_patch` into the isolated
`sq3wektw2543/mimic` checkout. Every path was byte-identical to the preserved
checkout at the recovery comparison. Subsequent changes were confined to the
two owned documents and two cancellation test files: formatting, private
fixture-directory setup and unrun metadata-only diagnosis. Production Mist, the
Content-Type tests, legacy fixture and smoke scripts still match the stopped
patch. Inherited parent/root/provider changes were not imported. No
source-checkout writes, ref mutations or child agents were used.

These are **recovery comparison hashes**, not test or admission receipts:

| Owned path | Recovered = preserved SHA256 |
| --- | --- |
| `vendor/mist/src/mist.gleam` | `6e6bc70c908397e1ee1427820fcac318a58904f262b81935b7fc33e767157ad3` |
| `vendor/mist/src/mist/internal/chunked.gleam` | `f0a2131f8c9d026cd01548b3ffafe884d816ce249c4c3ad1e0c3e64b4c1c0bd3` |
| `vendor/mist/src/mist/internal/http.gleam` | `f4bdbd1594f2a0f1b3c9707f345a095ee3acdb36ec2f7705394e6d0738ae7bce` |
| `test/mimic_mist_chunk_cancellation_test_ffi.erl` | `7d56f145dae75314a0208953c473bb4af1b45fc61592eac70030e81f28290e2a` |
| `test/mist_chunk_cancellation_test.gleam` | `c570d305a6dc527bea2a65fb7e865bb08d2511b2bf7c745f2d610d477add8772` |
| `test/mist_chunk_legacy_fixture.gleam` | `f0924a807ffdab2d2716d1a07fa5357034e2e8de52ca59b9bf6d3526b863f104` |
| `test/mist_content_type_boundary_test.gleam` | `332824077614b7d77602852e26d173bc1e5d6365ad3a88b8d7ac484b6f0dbfb5` |
| `scripts/smoke-codex-http-cancel.py` | `498aee69411286918aaa51b3a43a193fe8b65ce14876d3c318db9ad77a4f4255` |
| `scripts/smoke-account-ui.py` | `1bdaea88b02e3a60ad49e7922778bc98e1076f58b3f3890fc1e2770bc30c161e` |
| `docs/F12_CHUNK_CANCELLATION.md` | `97260fa923c102114506f4e01f99f1d5fd1915c5b432001c9c900fac34951bfd` |
| `docs/F12_CONTENT_TYPE_BOUNDARY.md` | `25d9e87d5d9444cd2035de98f9eb814a7aa8b0b2f551eebb53d9dac30f66053a` |

All 23 inspected unowned Mist/F44 files also remained byte-identical to the
inherited baseline and preserved checkout. In particular, production
`vendor/mist/src/mist_ffi.erl` remains unchanged at
`1a718152155ee767dcc72137b10153b092c3f6b90671a135ad0fdf1810163b50`.
The five-field `Connection` ABI and F44 framing/OWS/WS/head rules are retained.

The old setup receipt was read as data, not replayed:

```text
build/closure/f12-cancel-setup-1790884254624674000.log
bytes: 13381
SHA256: cf4a645b30ace53a9d2686271b0dd4f3749f3eac0e0dac4e059006e9c7461eed
```

The supplied persisted historical thread was unavailable through local thread
inspection. Recovery used the preserved source and setup log, without executing
historical transcript commands.

### Bounded focused validation plan, pending explicit slot

The parent authorized a dependency-closure project because the stopped root
imports prevent unrelated whole-project compilation. A read-only import walk
found 22 reachable local Gleam files: 18 actual production files and the four
dedicated cancellation/legacy/Content-Type/F44 modules, plus nine real
namespaced FFIs. The future snapshot must preserve their bytes, full patched
Mist, pinned dependency sources and byte/hash provenance. Only generated project
metadata is permitted; no root/provider stubs or semantic overlays.

After a fresh slot grant, use the shared atomic lock above and unique
no-clobber logs for:

1. Setup, scoped format check and dependency-closure build, bounded to 180 s.
2. The dedicated runner's 18 cancellation + 5 Content-Type + 19 unchanged F44
   cases, bounded to 180 s, only if compilation succeeds.

Retain setup/compile failures separately from assertion failures. On failure,
stop the workload and report before any further runtime retry. Release only this
invocation's lock after its descendants and fixtures have exited. Actual-root
F12 source/shipment, strict UI reporter, custom WS composition and assembled
full-suite validation remain parent-owned admission gates.

## Recovery validation checkpoint and backpressure diagnosis

The parent granted a 360 s total slot after F07 browser validation. Each direct
invocation acquired the shared lock atomically and released only its own lock
in `finally`, after its workload exited. The corrected run stopped at the first
assertion failure, at about 140 s total slot elapsed. No further runtime was
launched. A subsequent read-only process check found no matching recovery
BEAM/Gleam/mise/erl process and the shared lock was absent.

The snapshot contained exactly 22 real reachable Gleam modules (18 production
and four test/legacy modules), nine real namespaced FFIs, full patched Mist, and
332 byte-equal pinned dependency files copied from the read-only parent cache.
Root configuration/manifest metadata was copied exactly; no missing-F07 stub,
provider replacement, semantic overlay or generated source behavior was used.

### Retained receipts

All paths below are relative to this isolated checkout's `build/closure/`.

| Receipt | Path | SHA256 of retained file |
| --- | --- | --- |
| Initial format/build | `f12-recovery-sq3wektw2543-66236-1790886425082267000-setup.log` | `ee4e26eb146c8454a36b58644d425338a726365868724ab6fce1b4fe8d2fac3c` |
| First fixture failure | `f12-recovery-sq3wektw2543-66236-1790886425082267000-matrix-1790886501088290000.log` | `72d7fbf815e210665c9e2a037a07612df489ba98294ee66f3054aca20594b384` |
| Corrected fixture, first assertion failure | `f12-recovery-sq3wektw2543-66236-1790886425082267000-fixture-fixed-1790886564300489000.log` | `7224931d0ca87cc3cfeda92eba284ff3b59ed4ab68f777ca294a9806f4cd6d31` |
| Exact corrected source inputs | `f12-recovery-sq3wektw2543-66236-1790886425082267000/source-inputs-fixture-fixed-1790886564320910000.json` | `43df4e53de66955b322d57186f0afda2f991a216ec23bb5f3931755346c84b14` |
| Exact pinned dependency inputs | `f12-recovery-sq3wektw2543-66236-1790886425082267000/dependency-inputs.json` | `e958f3a68c3e7a8cd4d483e1843d1ed31f30e23bd869fb7bc1131153d76cfd75` |

The initial scoped format check failed only on the multiline typed `cancelled`
signature. It was corrected via `apply_patch`; the next check and build passed.
The first runner failed during setup because `storage.new` requires an existing
private 0700 state directory. The namespaced test FFI now creates/chmods that
fixture directory. The retry built and reached these cases:

| Case | Measured outcome |
| --- | --- |
| `active_tcp_half_close_aborts_without_hang_or_lease_leak_test` | Pass |
| `coalesced_chunked_body_tail_peek_preserves_owner_test` | Pass |
| `coordinator_death_kills_blocked_executor_test` | Pass |
| `downstream_reset_interrupts_actual_write_backpressure_test` | Fail before reset |

This is three case passes, not 18 cancellation passes. Idle client-close,
TCP/TLS send coverage, remaining cancellation controls, Content-Type and F44
are not qualified by this run.

### Exact pre-reset facts versus unknowns

The reported Gleam filename/line 633 was localized through the **retained
generated Erlang source**, not a new execution. Its `-file(..., 622)` directive
maps physical line 680 to reported line 633: that call asserts the result of
`erlang:is_process_alive(owner.executor)`. The preceding physical lines
677–678 perform `await_send_pending` and its assertion.

- **Started, not missing:** init/adoption published the executor PID, the
  downstream client parsed the first response chunk, and the test received the
  write notification. The executor was dead when the liveness gate sampled it.
- **Correct socket source:** the notification contains the same
  `connection.socket` passed to `mist.send_chunk`, a downstream server socket;
  it is not the upstream fixture socket or the downstream client's socket.
  The forwarding callback's TCP ownership check had run first.
- **Pending bytes observed:** `await_send_pending` returned true, which requires
  `inet:getstat(Socket, [send_pend])` to return a positive count at least once.
  Neither the exact count nor the counter category at the later liveness
  sample was retained.
- **Read category:** the fixture parsed the initial HTTP head and first chunk.
  It had not called `read_all`, reset or close explicitly at the failing gate.
- **No reset evidence:** reset, the `cancelled` helper, peer-EOF/lease-zero and
  both owner-death checks in this case were never reached. Cleanup afterward
  must not be relabeled as successful cancellation.

The original fixture's backpressure branch performs one bounded 16 MiB send,
discards its `Result`, then unconditionally calls `runtime.cancel` and returns
`ChunkAbort`. Pending driver bytes do **not** imply that the caller is blocked.
The retained log cannot distinguish these hypotheses:

1. Send returned `Ok` after buffering; the fixture cancelled/ended normally.
2. Send returned `Error`; the same unconditional fixture cleanup ended it.
3. Executor/coordinator terminated before the send could return.

Exact send return, exit reason, pending byte count, socket-open category and
pre-reset lease/request counters were not recorded. None is inferred as a
measurement. There is no justification to raise the root five-second gate,
increase timeouts, add OS TCP-state polling or alter production Mist.

### Probe prepared at the preceding synchronization checkpoint

The owned test now publishes `WriteStarted(socket, pid)` immediately before the
unchanged bounded send, after payload construction, and `WriteReturned(pid,
"ok" | "error")` afterward. Before reset it records only test-local PID/socket
identity, executor status/current-function/queue/reduction metadata, numeric
socket counters, client read category/buffer size, observed send return,
active-lease count (or -1 for unavailable) and upstream request count.

It does not receive socket data, inspect mailbox contents/stack arguments, log
payload/header/credential values, poll OS TCP_INFO, change production FFI or
widen a timeout. A completed send is now rejected as a blocked-send
prerequisite, rather than being admitted merely because `send_pend > 0`.
The metadata samples are not atomic with one another; an unobserved completion
alone is not proof of a blocked send.

At that checkpoint the probe and strengthened prerequisite were uncompiled and
unrun. The parent accepted the packet for **UNVALIDATED synchronization only**,
then separately granted the one-shot diagnostic below. Do not import the copied
root/dependency projects under `build/closure/`. The default multi-case `run/0`
entrypoint is not the single-case diagnostic lane.

## One-shot diagnostic receipt

The fresh grant allowed one 180 s slot including cleanup/audit. It was consumed
once, with an exclusive local receipt preventing duplicate execution. Scoped
format check and build passed, followed by direct EUnit execution of **only**
`downstream_reset_interrupts_actual_write_backpressure_test`. That case failed
its first result: `"ok"` did not equal `"unobserved"`. No retry or semantic
correction was made.

### Measured pre-reset state

| Probe field | Measured value |
| --- | --- |
| Send return observed | `ok` |
| Driver `send_pend` | 16,115,079 bytes |
| Server `send_cnt` / `send_oct` | 3 / 16,777,369 |
| Server `recv_cnt` / `recv_oct` | 1 / 95 |
| Writer / executor | Same PID `<0.151.0>` |
| Executor alive at gate | `true` |
| Sampled status / current function | `waiting` / `gleam_erlang_ffi:select/2` |
| Sampled executor message queue length | 0 |
| Coordinator / server socket owner | Same PID `<0.150.0>` |
| Downstream server / client socket | `#Port<0.10>` / `#Port<0.9>` |
| Client read category / buffered bytes | First chunk parsed / 0 |
| Active leases / upstream requests | 1 / 1 |

The 16 MiB `mist.send_chunk` returned `Ok` while the inet driver retained a
backlog. Neither pending bytes nor a live executor proved an actually blocked
send. The existing source proceeds from that return to `runtime.cancel`;
the sampled `select/2` frame is not evidence of a suspended `mist.send_chunk`.
These fields are sampled sequentially, not atomically.

Reset, real upstream peer-EOF, lease-zero and post-reset owner-death assertions
were **not reached**. Fixture cleanup is not a cancellation pass. The earlier
dead-executor/positive-backlog failure remains a separate timing receipt, not
rewritten using this later observation.

### Exact input and execution receipts

Paths are relative to `build/closure/` in the isolated checkout.

| Receipt | Path | File SHA256 |
| --- | --- | --- |
| One-shot diagnostic | `f12-diagnostic-88380-1790887824735032000.log` | `9fab109b8d9584fdc395eee2047fa6cc712f86d689c7ece03388123e5117c7cb` |
| Refreshed source inputs | `f12-diagnostic-88380-1790887824735032000-project/source-inputs.json` | `4fbb4ab6a25cd0ce05a444dd5b070beee227dfd655044b0ef39e9eecc70f2cd3` |
| Pinned dependency inputs | `f12-diagnostic-88380-1790887824735032000-project/dependency-inputs.json` | `7e553e20533eb3669f8dd9244d92c49706715e3ad1d84aedcf6c04f15f543f8e` |

The source receipt contains the same exact 22 real Gleam modules, nine real
namespaced FFIs, full patched Mist and root build metadata: 53 byte-equal file
rows. All 332 copied dependency files matched their previously recorded pinned
bytes. No missing-F07 stubs, root/provider overlays or replacement semantics
were used. The copied build project is ignored validation data, not owned
source for import.

Total invocation elapsed: 5.167 s. The retained cleanup audit reports
`OWN_DESCENDANTS_REMAINING=[]` before removal of this invocation's owner-token
lock. No CT, F44, root, shipment or live workload was launched.

### Inventory since the last finalized cancellation packet

Before this documentation update, a read-only SHA256 inventory confirmed all
11 owned paths still matched the last finalized packet. No production,
cancellation-test, test-FFI, legacy, Content-Type-test or smoke-script source
changed during the one-shot diagnostic. Its only new files were ignored
one-shot receipt/log and copied validation project data.

The initial source-only handoff updated only the two owned evidence documents.
The parent then approved the exact bounded fixture design below for source-only
implementation in `mist_chunk_cancellation_test.gleam` and its namespaced test
FFI. Those two test files and the evidence docs are now the only changes since
the prior finalized packet. Unowned source and copied build projects are
excluded.

## Approved bounded pressure fixture — source-only checkpoint

The following design was approved and implemented as source only. It is
now formatted and built in the exact refreshed focused closure; its only test
run failed the initial receive-buffer prerequisite, not a measured
pressure/cancellation pass. It changes only the existing cancellation test and
namespaced test FFI. It does not change production Mist, production FFI, socket
backend, stream ownership, timeouts or the five-field ABI.

### 1. Configure only this test's accepted downstream TCP socket

Use public `inet:setopts` on the accepted server socket:

```erlang
[{sndbuf, 4096}, {high_watermark, 4096}, {low_watermark, 1024}]
```

Retain the existing client's `{recbuf, 4096}` and passive mode. Read back server
`sndbuf`, `high_watermark`, `low_watermark` and client `recbuf`. Require both
kernel buffer values to be positive and no greater than 65,536 bytes; require
the driver watermarks to equal 4096/1024. Unsupported or out-of-policy readback
fails setup explicitly. Do not silently switch backends, enlarge pressure or
change `active`, `exit_on_close` or `send_timeout`.

The documented `inet` backend can return from an initial send after queuing
excess data. A busy driver socket then suspends later senders according to
high/low watermarks. References are public API documentation, not measured
qualification of this host:

- [gen_tcp backend buffering](https://www.erlang.org/doc/apps/kernel/gen_tcp.html)
- [inet public watermarks and buffer settings](https://www.erlang.org/doc/apps/kernel/inet.html#setopts/2)

### 2. Make the peer's non-reading phase explicit

After forwarding the ordinary first prefix, the same executor publishes
`PressureReady(socket, pid, begin_subject)` and waits on a private
executor-owned begin subject. This is not the public chunk init application
subject and does not alter its send-only contract.

The test finishes parsing the first prefix, seals its passive client's read
phase, and only then authorizes pressure. No `recv`, `read_all` or background
reader runs from that authorization through reset. Record read category and
buffer counts, not payload. Gate, pressure production and precondition observer
share **one absolute 1,000 ms deadline after prefix parsing**; do not add fresh
per-write deadlines or widen existing waits.

### 3. Use finitely capped sequential sends on the real executor

Reuse one 256 KiB synthetic UTF-8 payload. The adopted executor itself calls
the actual synchronous `mist.send_chunk`; no helper writer, task or replacement
callback process is introduced.

| Pressure limit | Exact cap |
| --- | --- |
| Payload per call | 262,144 bytes |
| Send calls | 8 |
| Total pressure body | 2,097,152 bytes (2 MiB) |
| Total framed pressure wire | 2,097,224 bytes: `8 * (262144 + 9)` |
| Combined gate/production/precondition time | 1,000 ms absolute |

Initial response head/prefix are the unchanged pre-pressure control, not hidden
additional pressure. Check write count, accumulated body/wire bytes and the
shared deadline before every call. Publish indexed `WriteStarted(index, socket,
pid)` immediately before each call and matching `WriteReturned(index, pid,
outcome)` afterward. Earlier successful returns are expected; the latest
outstanding sequence must be distinguished from them.

If all eight sends return, an error occurs, or the deadline expires without a
verified blocked send, fail the fixture prerequisite and clean up. Do not add
bytes, repeat indefinitely, reset prematurely or relabel cleanup as success.

### 4. Prove actual blocking before reset

Require all of the following together:

1. Writer is the exact live executor whose init adopted the real runtime stream.
2. The observed server socket is still owned by the coordinator.
3. The passive client remains in its sealed non-reading phase.
4. The latest indexed `WriteStarted` has no matching `WriteReturned`.
5. Executor status is waiting/suspended, and sanitized module/function/arity-only
   stack metadata includes the actual `mist:send_chunk/2` call with the
   underlying TCP send/driver path (`gen_tcp`, `prim_inet` or
   `erlang:port_command`). An unrelated `gleam` selector/runtime-cancel wait,
   running encoder or missing/unobservable send frame cannot pass.
6. Two samples 5 ms apart show the same unmatched sequence and send-path
   predicate within the single deadline. Drain/check completion events once
   more immediately before reset.

Only MFA metadata is retained; never log stack arguments, mailbox contents,
headers, credentials or body bytes. Pending driver bytes are supplemental,
never the sole admission rule. Missing evidence fails closed rather than
manufacturing a deterministic pass.

### 5. Preserve the cancellation outcome assertions

Only after the joint precondition passes may the existing reset occur. Retain
the existing real upstream peer-EOF, lease-zero, executor/coordinator-death,
single-upstream-request and no-fabricated-success assertions with their
unchanged 1,000 ms waits. Failed prerequisite runs cleanup only: no deliberate
reset before proof and no cancellation-under-backpressure pass.

### Implementation and explicit tail-call handling

The actual caller stays on the adopted executor. `pressure_send/4` emits its
indexed start immediately before `mist.send_chunk`, then emits a matching return
afterward; that post-call side effect prevents a tail call from removing the
fixture's exact send-site frame. The producer stops at eight writes, 2 MiB body,
2,097,224 pressure wire bytes or its shared deadline. All-returned/error/cap
results are failed prerequisites, not successful termination.

The namespaced test FFI stores explicit private per-client phase state after
prefix parsing. Its opaque client tuple gains a sixth internal phase field;
this is **not** the public five-field `Connection` ABI. `read_all`, the only
exported client socket-reading entry after initial parsing, rejects a sealed
phase. Other client helpers remain non-reading. The phase table is private to
the client/test owner and deleted in `with_client` cleanup. Buffer/watermark
configuration succeeds only while the prefix-derived deadline remains live,
logs requested/read-back numeric options and verifies unchanged
`active`/`exit_on_close`/`send_timeout`.

A source-only inspection of retained Gleam 1.18.1 generated Erlang established:

- `mist:send_chunk/2` invokes transport send, then replaces its error result,
  retaining that frame while the actual send is active.
- `glisten@transport:send/3` tail-calls `glisten_tcp_ffi:send/2` for TCP; requiring
  the transport wrapper frame would incorrectly reject a genuine blocked send.
- `glisten_tcp_ffi:send/2` calls `gen_tcp:send/2`, then converts `ok` to
  `{ok, nil}`, retaining the bridge frame. Lower TCP wrappers can tail-call.

The predicate therefore requires the non-tail `pressure_send/4` anchor, retained
`mist:send_chunk/2` and `glisten_tcp_ffi:send/2` frames, and a concrete underlying
send primitive: `erlang:port_command/2,3`, `prim_inet:send/2,3` or
`prim_inet:send_recv_reply/2,3`. It does **not** require optional tail-call wrapper
frames and never substitutes a generic waiting/select state for an unobservable
send path. All frame data is filtered to module/function/integer-arity only;
arguments and locations are never retained. If the pinned compiled shape or
primitive visibility differs at execution, the prerequisite fails closed and
needs review.

The observer consumes indexed events in producer order. Two successful samples
for the same unmatched write are separated by a full 5 ms; insufficient
remaining time fails rather than shortening that interval. A final joint
sample, zero-time completion recheck and deadline check precede the existing
reset. Logging and sampling cannot authorize a reset after the deadline.

Pre-reset lease queries are deliberately omitted from the new admission loop
and labeled `not_sampled_pre_reset`; a potentially blocking runtime query cannot
extend the 1,000 ms deadline. The existing post-reset real peer-EOF, lease-zero,
both process-death and request-count assertions and their deadlines are
unchanged.

At the preceding source-only checkpoint no formatter/compiler/test/lock command
had run for the correction. The later separately granted focused run is recorded
below. No pending/deferred workload survives its first-result stop. Another
single-case validation requires a new explicit slot; the earlier passes,
retained prerequisite failures and unqualified CT/F44/root/shipment gates remain
separate evidence.

## Corrected fixture validation — receive-buffer prerequisite failure

A fresh one-shot 180 s grant required the current parent dependencies plus only
the owned packet. The focused snapshot retained 22 real Gleam modules and nine
real namespaced FFIs, including the parent's exact `runtime.gleam`:

```text
90fd116141c7a47abdfa556a627cc0f66674b008e7e49ba0bd321b345e57fdb5
```

This additive `open_session_scoped` source compiled successfully. Compilation
does **not** qualify that runtime API's behavior, root workflows or shipment.
It was copied only into ignored validation data, not imported into owned source.

### Exact first result and stopping boundary

Scoped formatting was applied via a whitespace-only `apply_patch` to the owned
Gleam test. The next scoped format check and focused build passed. Direct EUnit
then invoked only `downstream_reset_interrupts_actual_write_backpressure_test`.
Its **first result was failure**, at `configure_pressure`:

| Setting | Requested | Measured readback |
| --- | --- | --- |
| Client `recbuf` at connect | 4096 | 326,504 at the post-prefix setup gate |
| Client active mode | `false` | `false` |
| Server `sndbuf` | 4096 | 4096 |
| Server high / low watermark | 4096 / 1024 | 4096 / 1024 |
| Server active / exit-on-close / send-timeout | Not changed | `once` / `true` / 30000, identical before and after |

The client readback exceeds the approved 65,536 bound, a sufficient reason to
reject setup. The bound was not raised. `PressureReady` preceded setup, but
`begin` was never authorized: no indexed pressure write, blocked-send sample,
reset, peer-EOF or lease-zero assertion ran. No retry or semantic correction
was made. Cleanup is not a cancellation proof.

The test command elapsed 0.619 s; the recorded setup-through-result slot elapsed
80.928 s, including tool gaps. The later retained audit found
`OWN_DESCENDANTS_REMAINING=[]` before matched owner-token lock removal.
The source code now tested is:

| Owned input | Exact tested SHA256 |
| --- | --- |
| `test/mist_chunk_cancellation_test.gleam` | `65a4f37d3b65e8db6943132b3def18303706434de321a390df5cf5601e48069e` |
| `test/mimic_mist_chunk_cancellation_test_ffi.erl` | `9ceae9cdddda7aafa836f0e4612ef32bd604b11e3d51c0f0004116feef4e917b` |

### Preserved source/package/cache receipts

Paths are relative to this isolated checkout's `build/closure/`.

| Receipt | Path | File SHA256 |
| --- | --- | --- |
| Setup and scoped formatting | `f12-pressure-corrected-22962-1790890357822215000-setup.log` | `1fdc8411e96f6ba7becc023cad90eff578754c7c004b74e4f6c46c0c345a3134` |
| Build and one-case failure | `f12-pressure-corrected-22962-1790890357822215000-build-case.log` | `83fd194dd7db63144c0637bdf963a17da49c4a18916b53f5293968bbf25474ef` |
| Tested source inputs | `f12-pressure-corrected-22962-1790890357822215000-project/tested-source-inputs.json` | `c5268eb1d96d627a256258b42852623b2e85be9c9ec70bb925ccd5d020c7a68e` |
| 331 exact package-source inputs | `f12-pressure-corrected-22962-1790890357822215000-project/package-source-inputs.json` | `0208daa833420a82b9e41d8155e943078c37efdaac705816fe4fbe4f35a270b2` |
| Parent cache-index receipt before build | `f12-pressure-corrected-22962-1790890357822215000-project/cache-index-before-build.json` | `a3f2b87c16c1fe35e1832c1c95d45ec0886007c2a292f778c3be8a6804d9e6ec` |
| Generated cache-index receipt after build | `f12-pressure-corrected-22962-1790890357822215000-project/generated-cache-index-after-build.json` | `95f927c9a0cc2adc310c2cd41cd90b5c525efc553f5272b133a3443465a1c04d` |

Package files matched their pinned source hashes before copying and after
building. Cache-index metadata is recorded separately: `packages.toml` remained
390 bytes but changed from hash `a7fdf7b4f629b4761ffe20cf704bc36990caf1d090f2a0d381ca348dcb162549`
to `205794987fea5845263d266374ccb397f9a0050c5484831559fdff4a6a819caf`.
That generated metadata change is not a package-version/source change or
semantic overlay. Copied runtime/build projects remain excluded from import.

## Source-only recbuf trace and proposed next setup

### Explicit writes and actual prefix-reader path

The fixture's only explicit **client recbuf write** is
`gen_tcp:connect(..., [{recbuf, 4096}, ...], 2000)`. The returned `Tcp` is bound
to `Socket`, passed unchanged through `read_head`, `read_chunk`, `line` and
`take`, then stored as the opaque client's second tuple field. Setup destructures
that same field as `ClientSocket` and calls `inet:getopts(ClientSocket, ...)`.
The callback runs in the connecting test process, with a private phase table;
the fixture does not transfer client ownership or spawn a client reader.

The other socket-option writes target different roles:

- Upstream fixture: listen options and `active, once` after its metadata send.
- Downstream server: setup writes only `sndbuf` and high/low watermarks,
  explicitly comparing other preserved options.
- Downstream client: reset sets `linger, {true, 0}`; reset was not reached.
- Standalone raw-header client: its separate connect path, not the pressure
  client's prefix reader.

The prefix reader's TCP `recv` wrapper calls `gen_tcp:recv` directly; it does not
call glisten receive helpers or set socket options. Read-only installed source
inspection followed this port-backend path:

```text
gen_tcp:recv -> inet_tcp:recv -> prim_inet:recv0
            -> async_recv -> TCP_REQ_RECV
```

No `SETOPTS` call appears in that Erlang receive path. Installed static source
references were `/opt/homebrew/Cellar/erlang/29.0.4/lib/erlang/lib/`:
`kernel-11.0.3/src/gen_tcp.erl:980`, `inet_tcp.erl:86`,
`erts-17.0.4/src/prim_inet.erl:808,820`. The launcher resolves to that installation;
this was source inspection, not an executed runtime-version probe. Native inet
C driver source was unavailable in the installed source directory.

The fresh failed setup log did **not** record client port/owner identity or
option values immediately after connect. Variable/tuple flow proves the intended
same-socket path, not an additional measured owner receipt. The observed 326,504
therefore does not by itself prove OS autotuning, normalization, an ignored
setting or the exact point at which the effective value differed. No explicit
fixture client rewrite after connect was found; the native/OS cause remains
unmeasured.

### Minimal proposal at the preceding source-only checkpoint

At the existing sealed post-prefix setup gate, under the same unchanged
prefix-derived 1,000 ms deadline:

1. Validate the exact client port and owner against the connecting test process,
   passive mode, parsed prefix, private phase owner and no post-prefix reads.
   Record port/owner identity and scalar option data, never payload.
2. Seal peer reads, then perform **one** public
   `inet:setopts(ClientSocket, [{recbuf, 4096}])` on that exact client.
3. Read back immediately from the same socket, retaining requested/before/
   setter-result/after metadata. Setter failure or effective value outside
   `0 < recbuf <= 65,536` is a failed prerequisite.
4. Never retry, repeatedly reclamp, switch backends, increase a bound, add
   pressure or reset before evidence. Keep all current producer caps and
   post-reset assertions.

This public setting is **not a promise that the effective buffer remains fixed**.
The existing `pressure_options_valid` readback must still pass initially, in both
blocked-send samples, and in the final admission sample. Later out-of-policy
readback fails admission; it is not corrected in the observer. These samples
check the bound at observed points, not an OS stability guarantee between them.

Only evidence docs were updated after the first-result stop; the tested fixture
code was not changed at that proposal checkpoint. The parent subsequently
approved this exact test-only setup and a new focused slot, as recorded below.

## Post-prefix setup implementation and cache-inventory stop

Only `test/mimic_mist_chunk_cancellation_test_ffi.erl` changed in the fixture
packet after the 326,504 prerequisite refusal. The opaque test client's private
phase now records its exact socket and whether the one-time setter was attempted.
Setup verifies that the same live TCP port is still owned by the current
connecting test process, with a private parsed-prefix phase, passive mode,
zero pending bytes and zero post-prefix reads. It then seals reads and consumes
the attempt **before** one public `recbuf = 4096` setter. Immediate readback is
from that same port; the receipt records requested/before/set/after scalar
options and port/owner identity only.

Setter failure, invalid immediate readback or deadline expiry refuses pressure.
The existing server-watermark checks and initial/per-sample/final buffer bounds
remain unchanged. Both blocked-send samples and the final completion recheck
also retain exact sealed-client identity. This is not a repeated clamp or an
effective-buffer stability promise. No producer cap, deadline, send-path MFA,
reset/EOF/lease assertion or production source was changed.

New test-only FFI SHA256:
`dad8c57088495a31706ba85327f2551b38f700f8c9eedcf962973ff108b122c6`.
The previously compiled Gleam test remains SHA256
`65a4f37d3b65e8db6943132b3def18303706434de321a390df5cf5601e48069e`.
**At this setup-only checkpoint, the new FFI hash had not been compiled or
executed.** The separately renewed slot below used this exact same hash.

The approved fresh one-shot slot acquired its atomic shared lock, copied the
real 22-module/9-FFI source closure with the exact parent runtime `90fd1161…`,
then refused the package-cache inventory. The current parent cache contained
two additional top-level entries absent from the preceding 331-file package
source receipt:

| Cache metadata candidate | Bytes | SHA256 |
| --- | ---: | --- |
| `gleam.lock` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `mist.config_fingerprint` | 19 | `02a7040c0e314cfc13235ffde566b389a3b802f2448c24cbb949f43f9b57acde` |

The copied source-input filename says `tested-source-inputs.json` because it
uses the established receipt schema; its contents were **not tested** in this
slot. No package build, formatter, compiler, BEAM, fixture socket or pressure
write ran. The first-result test boundary was never reached. The empty owned
descendant audit and token-matched lock release completed in 0.519 seconds.
The one-shot marker remains consumed; no implicit retry was scheduled.

Retained setup receipts under
`build/closure/f12-postprefix-recbuf-33832-1790891305727425000-project/`:

| Receipt | Bytes | SHA256 |
| --- | ---: | --- |
| `result-and-cleanup.json` | 577 | `c283380bdbda20bd11dd9732d6b4fd101b046d710f2094e61dd82c6d15cb4178` |
| `tested-source-inputs.json` (unexecuted inputs) | 15,944 | `27f0f5bf92fe453982ccc29d19c2a7e2e6e6ed49439097e7a4f44e820ef06637` |

A subsequent **read-only** comparison confirmed that all 331 recorded package
source files still match their prior bytes/hashes. It also recorded the empty
lock-file size and numeric fingerprint bytes without running the toolchain.
Any later setup must account for these metadata files separately, not discard
unexpected package source or change pinned versions. A new explicit slot is
required before another runtime operation; the parent granted that renewal
separately, as recorded below. The earlier 326,504 refusal and returned-16-MiB
send failure remain distinct retained evidence.

## Renewed exact-metadata slot — admission deadline failure

The parent classified **only** the two exact cache-root paths `gleam.lock` and
`mist.config_fingerprint` as generated metadata. The existing root-cache index
`packages.toml` was also recorded as metadata. No same-named nested file,
package source, Mist source/config or root manifest was excluded. The original
parent compiler lock was read-only: its empty contents did not grant concurrency
permission, and it was neither deleted nor modified.

The renewed slot refreshed the real 22-module/9-FFI closure and full patched
Mist from current parent inputs plus this owned packet. All 331 pinned package
source paths and hashes matched the preceding receipt; they were checked again
after build. There were no stubs, semantic overlays or root/provider imports
into this worker's source tree. The exact parent runtime input remained
`90fd116141c7a47abdfa556a627cc0f66674b008e7e49ba0bd321b345e57fdb5`;
none of the parent source inputs differed from the preceding focused build.

Using `/opt/homebrew/bin/mise exec gleam@1.18.1` and
`ERL_FLAGS='+S 2:2 +A 2'`, scoped `gleam format --check` and `gleam build` passed.
The runner booted library applications `crypto` and `mist` only, then directly
ran **one** EUnit function:
`downstream_reset_interrupts_actual_write_backpressure_test/0`. It did not run
the module's multi-case main, Content-Type tests, F44 tests or root application.

### First genuine result: prerequisite failure, no reset

The post-prefix setter succeeded once on client `#Port<0.9>`. Both owner
readbacks identified the same current connecting test PID `<0.112.0>`:

| Client setup fact | Measured value |
| --- | --- |
| Requested | `recbuf = 4096` |
| Before | `recbuf = 326504`, `active = false` |
| Setter result | `ok` |
| Immediate same-port after | `recbuf = 4096`, `active = false` |
| Reads sealed / post-prefix calls | `true` / `0` |

The unchanged server readback was `sndbuf = 4096`, `high_watermark = 4096`,
`low_watermark = 1024`. `active = once`, `exit_on_close = true` and
`send_timeout = 30000` remained equal to their pre-setup values.

The test failed in `await_blocked_write/5` with:
`no observable blocked send within shared pressure deadline`.
No `MIST_PRESSURE_SAMPLE` passing receipt was emitted. The final failed probe,
still **before client reset**, recorded:

| Failed admission fact | Measured value |
| --- | --- |
| Outstanding indexed write | `4` |
| Writer / exact live executor | `<0.143.0>` / `<0.143.0>`, alive |
| Coordinator / server port | `<0.142.0>` / `#Port<0.10>`, owner matches |
| Executor status / current MFA | `waiting` / `prim_inet:send/4` |
| Retained real send frames | `glisten_tcp_ffi:send/2`, `mist:send_chunk/2`, `mist_chunk_cancellation_test:pressure_send/4` |
| Existing send-path predicate | `false`; primitive send arity 4 is not in its admitted set |
| Client readback | `recbuf = 526720`, `active = false` |
| Buffer prerequisite | failed: `526720 > 65536` |
| Sealed reads / calls / pending client bytes | `true` / `0` / `0` |
| Executor message queue | `0` |
| Driver `send_pend` / `send_cnt` / `send_oct` | `520228` / `6` / `1048754` |
| Driver `recv_cnt` / `recv_oct` | `1` / `95` |
| Shared deadline remaining | `0` ms |
| Pre-reset active leases | intentionally not sampled |

These are two distinct failed prerequisites, not a cancellation pass. The
observed primitive arity is precise metadata from the real retained send stack;
it was not patched into the predicate or papered over by generic `waiting`.
The final client buffer differed from the successful immediate setup readback,
but the receipt does **not** measure the native/OS cause or the exact change
time. No inference of OS autotuning, repeated reclamping, backend switching,
extra pressure, increased bound or widened deadline is made.

The reset call and upstream EOF, lease-zero and process-death outcome
assertions were not reached. Fixture cleanup is not upstream cancellation
evidence. The runner stopped at the first genuine failure without correction
or retry. Total setup/result/cleanup time was **7.006 seconds**; owned descendant
audits before and after cleanup were empty. Parent metadata pre/post hashes
matched. The matched owner-token lock was removed only after those audits.

### Exact tested inputs and retained receipts

The tested cancellation FFI and Gleam test hashes are respectively
`dad8c57088495a31706ba85327f2551b38f700f8c9eedcf962973ff108b122c6` and
`65a4f37d3b65e8db6943132b3def18303706434de321a390df5cf5601e48069e`.
No fixture or production source changed after the first-result stop; only
evidence docs changed. Compilation of parent runtime/Content-Type/F44 sources
is not behavioral qualification.

Logs under `build/closure/f12-postprefix-metadata-35329-1790891468551503000-`:

| Log suffix | Bytes | SHA256 |
| --- | ---: | --- |
| `setup.log` | 392 | `bf4fe4965ce8d28c6572c9c76ec37bf81bc03476242b1cb19a8409f1638a0a59` |
| `format-check.log` | 530 | `86b1e0c534562915920ce5848f7dd68d8e196e60d4a0fbfd419e0f49eac34849` |
| `build.log` | 7,400 | `8d56581dd604a29a8acdcc63685764c43e99528c9c71c747fa894bd12a3dd80f` |
| `single-case.log` | 9,522 | `596a2fa3435e8ee1dbd8dd60f7985923592753db9bf041f3c5af6ac00b0fe13f` |

Receipts in the corresponding `…-project/`:

| Receipt | Bytes | SHA256 |
| --- | ---: | --- |
| `tested-source-inputs.json` | 15,944 | `27f0f5bf92fe453982ccc29d19c2a7e2e6e6ed49439097e7a4f44e820ef06637` |
| `package-source-inputs.json` | 97,559 | `e0550a8ecfc6120e855b8be30b237792724a797c4d7121ec0d933c4416704897` |
| `parent-cache-metadata-before.json` and `…-after.json` | 673 each | `b6e9bffa5f6763d13b6f9a5b201b5db721d9611fb2489fa1d6419c9446f890eb` |
| `closure-cache-metadata-before.json` | 544 | `9595206db9d658ffb579d48543b6fee810283fa3531d54dfa5141966e9470c14` |
| `closure-cache-metadata-after-build.json` and `…-final.json` | 697 each | `6b685142257dce3e5c6679ea29f3bb56a4bc230b2ab8b53a430d8b28d7196801` |
| `owned-packet-before-validation.json` | 1,781 | `9d7c7e4094d9d6ba898b97e2ae46f8d827b5657e3b2a8092b64a70debf36cfc5` |
| `result-and-cleanup.json` | 1,549 | `285b1d37b51e7c263ece673585dfa50d1de48245d9ad4516cd61b4d9913b8003` |

The isolated cache generated its own empty compiler lock and fingerprint. Its
generated cache index was 390 bytes, SHA256
`791eb62a25acb7a835373d1db7f6158bcf410f8afcce71a0a6f21aa48e42771d`;
parent metadata remained byte-identical. Those generated paths are separate
from all source receipts and are not part of the owned import packet.

The 0.519-second cache setup refusal, the 326,504 initial prerequisite failure,
the earlier returned-16-MiB-send diagnostic and the original three historical
cancellation passes remain separate receipts. This checkpoint is
**UNVALIDATED synchronization only**: no actual-backpressure cancellation,
Content-Type, F44, root, full-suite or shipment pass is admitted. There is no
pending/deferred workload; any further validation requires a fresh explicit
grant, and no copied project/dependency/runtime source may be imported.

## Source-only follow-up: exact OTP send path and fixture-policy choice

No runtime grant accompanies this follow-up. It reads installed source and
metadata only; no predicate, buffer guard, pressure code or production code is
changed.

### Installed OTP 29.0.4 source semantics

`/opt/homebrew/bin/erl` resolves to
`/opt/homebrew/Cellar/erlang/29.0.4/lib/erlang/bin/erl`, and the installed
`releases/29/OTP_VERSION` file reads `29.0.4`. This is an installed-source
identity check, not a new VM/version invocation. Retained read-only hashes:

| Installed file under `…/lib/erlang/` | SHA256 |
| --- | --- |
| `lib/erts-17.0.4/src/prim_inet.erl` | `a67a703b9fa63eae4797b2cbe95b62382cf8c50399b55e440e158e39c4927791` |
| `lib/kernel-11.0.3/src/gen_tcp.erl` | `ac46bcc600f7f50d2c79efb7b75276c8e719b0e47c664ac4ddd73941fb3640d2` |
| `lib/kernel-11.0.3/src/inet_tcp.erl` | `1cf026efca48b985690090a460aa6b8386513e56ea6c32488488eb8e7822255a` |

In this port backend, `gen_tcp:send/2` at lines 918–924 dispatches through
`inet_db:lookup_socket/1`; `inet_tcp:send/2` at line 81 tail-calls
`prim_inet:send/3` with `[]` options. `prim_inet:send/3` at lines 578–585
monitors the socket port, adds its driver reply reference, then tail-calls its
private **`send/4`** helper.

That helper at lines 587–629 calls `erlang:port_command/3`. It can be suspended
in that command, or after acceptance remain inside the synchronous send while
receiving the matching driver `inet_reply` or monitored port `DOWN`. It returns
the driver status, reports `closed` on `DOWN`, or maps a command error to
`einval`. The arity-2/3 wrappers can disappear through tail calls; the observed
arity-4 frame is the real send implementation, not a generic actor wait or a
helper writer. A `waiting` process in this function still needs the other
indexed/timing/identity checks: a normal transient reply wait alone is not
sustained backpressure, and return from a send is not proof of peer consumption.

### Exact predicate support proposed, not implemented

Add **only** `prim_inet:send/4` to the existing explicit primitive-send arity
allowlist in `send_path/1`; no module/function wildcard or generic `waiting`,
`select`, `receive` or `gen_tcp` frame would qualify. The proposed single arm is:

```erlang
({prim_inet, send, Arity}) ->
    Arity =:= 2 orelse Arity =:= 3 orelse Arity =:= 4;
```

Keep all three required retained call anchors:
`mist_chunk_cancellation_test:pressure_send/4`, `mist:send_chunk/2`, and
`glisten_tcp_ffi:send/2`. Keep the same exact live adopted executor/writer,
unmatched indexed `WriteStarted`, coordinator-owned server socket, same live
client/current owner, sealed reads, two bounded samples separated by the full
existing 5 ms, shared deadline, and final sample/completion-message recheck.
Only integer-arity MFA metadata is read; no process arguments, mailbox payloads
or credential-bearing values are inspected. Unobservable anchors or a returned
write still fail. This proposal does not retroactively admit the failed receipt.

### Is the ongoing client buffer bound part of the target?

The target behavior is cancelling a genuinely blocked synchronous Mist send
when the downstream resets, with real upstream EOF, lease release and executor/
coordinator death. A fixed ongoing client `recbuf <= 65,536` is **not** part of
that production contract. It is an attempted finite pressure-induction and
fixture-reproducibility guard. Direct observed send blocking can establish the
target prerequisite even when the effective receive buffer differs from its
initial requested/read-back value.

At this source-only checkpoint, two explicit choices were sent for approval
before any source correction:

| Choice | Definition and trade-off |
| --- | --- |
| A — preserve the ongoing bound | Keep every current client buffer admission check. Even with precise arity-4 support, this host's measured 526,720 readback remains an explicitly unsupported fixture prerequisite. Honest and unchanged, but it cannot supply the desired cancellation-under-pressure evidence here. Independent gates can still provide separately labelled partial evidence. |
| B — use sustained actual-send evidence | Keep the one-time `recbuf = 4096` setup and immediate positive `<= 65,536` check. Continue recording later `recbuf` readbacks, but remove **only the ongoing client-buffer bound** from send admission; exact sustained send-path evidence remains mandatory. This tests the behavior rather than a presumed stable buffer setting, without guaranteeing that this host will produce a qualifying blocked send. |

**Recommend B with explicit approval**, plus the exact arity-4 support above.
The minimal test-only change would separate initial socket-option validation
from in-flight admission. Initial validation retains both buffer bounds and all
requested/read-back watermarks. In-flight validation retains server `sndbuf`
bound, exact watermarks, successful option readback, passive client mode,
same-port/current-owner identity and sealed reads; the later client `recbuf`
value remains metadata, not an implicit clamp or a new higher bound.

Under either choice, retain one executor and no helper writer; at most eight
256-KiB synchronous writes, 2,097,152 body bytes and exactly 2,097,224 framed
pressure-byte cap; one shared 1,000-ms prefix-derived deadline; the two full
5-ms-separated sample checks and final completion recheck before reset; and all
unchanged reset/upstream-EOF/lease-zero/process-death/request-count assertions.
All writes returning, lost/unobservable send frames or an expired deadline are
failures, never successes. No backend change, OS polling, repeated reclamping,
pressure expansion, enlarged bound, deadline widening or production edit is
proposed. **Neither A-to-B nor the MFA correction was implemented at this
proposal checkpoint.** The parent later approved both narrowly, as recorded
below.

## Explicit independent partial-gate inventory — not run

These lists define later selectable **partial evidence**, not a skipped-to-green
full suite. There are 41 independent cases below; the eighteenth cancellation
case was explicitly failed at the inventory checkpoint:
`downstream_reset_interrupts_actual_write_backpressure_test`.
Its earlier failed diagnostics remain retained beside the later corrected
focused pass. No default multi-case main or root application is implied by
these lists. The later explicit 41-function sequence below supplied evidence
for every listed case without repeating the separately passed pressure case.

### Non-send-backpressure lifecycle — 17 explicit functions

Module `mist_chunk_cancellation_test`:

1. `idle_upstream_close_cancels_before_read_timeout_test`
2. `retained_legacy_idle_control_needs_owner_death_test`
3. `executor_owner_death_cancels_idle_upstream_test`
4. `coordinator_death_kills_blocked_executor_test`
5. `normal_eof_preserves_prefix_order_and_one_terminal_chunk_test`
6. `upstream_error_keeps_valid_prefix_without_invented_eof_test`
7. `repeated_owner_cancel_releases_once_and_aborts_test`
8. `downstream_send_failure_releases_stream_test`
9. `pending_application_message_limit_aborts_blocked_callback_test`
10. `retained_post_request_tail_is_not_dispatched_or_body_test`
11. `post_request_tail_limit_aborts_without_success_test`
12. `coalesced_chunked_body_tail_peek_preserves_owner_test`
13. `active_tcp_half_close_aborts_without_hang_or_lease_leak_test`
14. `retained_passive_half_close_control_can_finish_response_test`
15. `tls_nonowner_executor_send_and_normal_eof_test`
16. `tls_idle_close_interrupts_adopted_executor_test`
17. `unread_request_body_handoff_is_rejected_without_drain_test`

The blocked-callback/owner-death cases above block on the synthetic upstream
pull, not on the failed pressure fixture. TLS cases retain their actual local
certificate/SSL setup; compiling them is not evidence they ran.

### Raw Content-Type — all five functions

Module `mist_content_type_boundary_test`:

1. `conflicting_content_type_duplicates_both_orders_and_case_test`
2. `identical_content_type_duplicates_are_not_canonicalized_test`
3. `fragmented_content_type_duplicate_is_rejected_before_dispatch_test`
4. `single_mixed_case_content_type_remains_supported_test`
5. `repeatable_accept_fields_still_dispatch_once_test`

The first three require exact peer close/reset, zero response bytes and zero
handler dispatch. The last two are positive dispatch controls. The strict
actual-root reporter remains a separate parent-owned gate, not replaced by
these loopback tests.

### Existing F44 — all 19 functions

Module `f44_http_boundary_test`, exact current parent source SHA256
`ac112407c90dc94ab6b85dd1ae8545213262717e3dfdcdc69ec797a6b69022b6`:

1. `sequential_get_get_and_post_get_control_test`
2. `coalesced_get_get_and_fixed_post_get_test`
3. `every_fixed_request_pair_byte_split_test`
4. `multiple_coalesced_requests_and_streaming_fixed_body_test`
5. `chunked_body_trailers_tail_and_byte_splits_test`
6. `ambiguous_framing_rejected_without_any_dispatch_test`
7. `duplicate_ui_security_headers_rejected_without_any_dispatch_test`
8. `rejected_size_or_unread_body_closes_before_next_dispatch_test`
9. `chunked_size_guard_and_malformed_terminator_close_test`
10. `http10_single_body_and_request_close_controls_test`
11. `duplicate_connection_and_response_close_tokens_stop_pipeline_test`
12. `rejected_ows_websocket_upgrade_never_dispatches_http_tail_test`
13. `request_head_byte_and_raw_field_limits_are_per_request_test`
14. `request_line_and_header_progress_share_one_absolute_deadline_test`
15. `chunked_cumulative_size_and_metadata_bounds_test`
16. `chunked_progress_does_not_reset_socket_read_deadline_test`
17. `coalesced_http1_oauth_callback_preserves_initial_and_cleanup_test`
18. `websocket_upgrade_retains_coalesced_and_partial_frame_test`
19. `queued_on_init_selector_replacement_preserves_retained_frame_test`

No independent list was executed in this source-only follow-up. The tested
fixture hashes remain unchanged, all historical failure receipts are retained,
and there is no compiler/runtime/socket/lock operation or deferred workload.

## Approved option-B implementation and actual-backpressure focused pass

The parent explicitly approved option B as a **test-only pressure-induction
policy revision**, not a production buffer change or a waiver of cancellation
outcomes. Only the namespaced cancellation test FFI changed:

- `pressure_setup_options_valid` retains the immediate client receive-buffer
  bound plus the unchanged server-buffer/watermark/passive checks.
- `pressure_inflight_options_valid` retains server `sndbuf <= 65,536`, exact
  high/low watermarks and passive client mode. Later client receive-buffer
  sizes remain numeric diagnostics, not a supposed stable-buffer promise.
- The primitive-send allowlist adds only the source-verified
  `prim_inet:send/4`; all exact retained wrapper-frame requirements remain.

The one-time `recbuf = 4096` setter and immediate same-port bound check are
unchanged. Exact live executor/writer identity, coordinator-owned server socket,
same live client/current owner, sealed reads, unmatched indexed write, both
full-5-ms-separated samples and the final path/completion/deadline recheck
remain mandatory. Producer caps and the shared 1,000-ms deadline are unchanged.
So are all reset, real upstream EOF, lease-zero, process-death and request-count
assertions. A queued driver buffer or generic waiting state alone still cannot
qualify. No additional pressure, helper writer, backend change, OS polling,
repeated reclamping, timeout widening or production edit was made.

Current tested cancellation FFI SHA256:
`af90473906350eb27f6d955d711692ef0a5be069c920d1f17f09a132d5286583`.
The Gleam test stayed byte-identical:
`65a4f37d3b65e8db6943132b3def18303706434de321a390df5cf5601e48069e`.
All three recovered production Mist files stayed byte-identical to the stopped
worker throughout the fixture corrections.

The newly granted focused slot copied the exact real 22-module/9-FFI closure,
full patched Mist, all 331 pinned package source files and exact parent runtime
`90fd116141c7a47abdfa556a627cc0f66674b008e7e49ba0bd321b345e57fdb5`.
Scoped format/check and build passed under Gleam 1.18.1 with
`ERL_FLAGS='+S 2:2 +A 2'`. The runner directly called **only** the compiled public
backpressure test function, with all its existing assertions and cleanup.
This avoids EUnit's suppression of captured success output; it neither replaces
the test logic nor discovers other functions. It booted `crypto` and `mist`
library applications only, not the root application.

### Measured admission and asserted cancellation outcome

The single client setup read back 326,504 before, then **4,096 immediately
after** the one setter. Client `#Port<0.9>` stayed passive and owned by the same
connecting test PID `<0.10.0>`. Later readback was 526,720, recorded honestly as
a diagnostic with no native/OS cause inferred.

Both qualifying samples observed the same unmatched pressure write **index 2**,
same live writer/executor `<0.137.0>` and coordinator `<0.136.0>`. They retained
the exact `pressure_send/4`, `mist:send_chunk/2`, `glisten_tcp_ffi:send/2` and
`prim_inet:send/4` frames. Status was `waiting`, send-path observability and the
joint blocking predicate were true, reads were sealed with zero post-prefix
read calls/pending client bytes, and server socket `#Port<0.10>` remained owned
by the coordinator.

Shared deadline remaining was **990 ms**, then **984 ms**, spanning the full
required 5-ms separation. The final probe and final joint sample still admitted
the same unmatched index with 984 ms remaining; the zero-time completion
recheck found no returned write before reset. Driver counters were diagnostic:
`send_pend = 462866`, `send_cnt = 4`, `send_oct = 524448`,
`recv_cnt = 1`, `recv_oct = 95`.

Only after those checks did the test reset the client. The unchanged assertions
then passed: real upstream EOF within 1,000 ms, active leases reaching zero
within 1,000 ms, both exact executor/coordinator death observations within their
existing 1,000-ms limits, and exactly one upstream request. Those are assertion
budgets, not fabricated measured cancellation latencies. The direct runner
logged `FOCUSED_CASE_RESULT pass`.

The first genuine result was retained without retry. Total setup/result/cleanup
time was **6.597 seconds**; both owned descendant audits were empty, parent
cache metadata stayed unchanged, and only the matched owner-token lock was
removed. The old 16-MiB returned-send and both strict-buffer-policy failures
remain failures under their prior fixture designs.

### Focused-pass receipts

Logs under `build/closure/f12-option-b-send4-39582-1790891982626654000-`:

| Log suffix | Bytes | SHA256 |
| --- | ---: | --- |
| `setup.log` | 576 | `8b2ba49dbe30ebdd4f6afca771b1c2df6a75d68cf5f41116e4bca3561f9b233a` |
| `format-check.log` | 525 | `0d4d97add821ddfeffdfa41638bc036218be512a7ce1ab2a64083a98f53415bd` |
| `build.log` | 7,325 | `b76a18a6b480d92eb59d97ad3de3e590fdbac92d2339e83801ac88b17cddc3ea` |
| `single-case.log` | 14,921 | `a97d2f66500943a4eff1150b967ae95cb140ca6f50214d2e06985da51b755d9e` |

Receipts in its corresponding `…-project/`:

| Receipt | Bytes | SHA256 |
| --- | ---: | --- |
| `tested-source-inputs.json` | 15,944 | `57e2c5fcebafdb4f2d304fd3fb4f4711664b6a195f58eb3bbfcf3b51a62d9f0d` |
| `package-source-inputs.json` | 97,559 | `e0550a8ecfc6120e855b8be30b237792724a797c4d7121ec0d933c4416704897` |
| `owned-packet-before-validation.json` | 1,781 | `df9bc324a453027f701b267abd3841f746e88e97ab2ee77e2d8b9773f7489307` |
| `result-and-cleanup.json` | 1,776 | `834dd1227649ca49a9a82b86f25e74a18fd579bfb273ccee7814af07b9aef48a` |
| `closure-cache-metadata-after-build.json` and `…-final.json` | 697 each | `821cb89ddab20cbbea7eb8c7c03edc8db88722352ebbb437a512710060c1a041` |

Parent metadata pre/post remained identical to SHA256 `b6e9bffa…` above. The
isolated generated cache index was 390 bytes, SHA256
`c61623f5b56cbea0820c995a67c0ca3ee810aee83f27d2ef036690d493134f52`.
No generated/copied project or parent runtime file is an owned import input.

## Remaining-matrix setup refusal — no testcase ran

A separately granted matrix slot first logged the exact ordered 41-function
list and verified that all 53 source/config/manifest inputs and all 331 package
source files matched the focused pass. Its scoped format check passed, but a
fresh Gleam build tried dependency metadata resolution and failed an HTTP
request to `https://hex.pm/api/packages/gleam_stdlib/releases/1.0.5`.
No testcase was invoked: `executed_cases = []`. This is a **compile/setup
refusal**, not a failed lifecycle/Content-Type/F44 result or a replacement for
the separate focused pass.

The slot stopped without correction/retry, audited no owned descendants and
removed only its matched lock. Total setup/cleanup was **0.918 seconds**.
No package/source version changed; subsequent read-only checks confirmed the
53/331 hashes in both the refused project and successful focused project.
The reason a fresh resolution was requested was not measured, and no source
stub, semantic overlay or package substitution was introduced.

Retained logs under `build/closure/f12-remaining-matrix-41808-1790892240216241000-`:

| Log suffix | Bytes | SHA256 |
| --- | ---: | --- |
| `setup-and-order.log` | 7,327 | `bac257d481ccf47e784b1962433205c77ac592c30cbe415b76d103593e40d6ba` |
| `format-check.log` | 527 | `12c500c2a7b5c1c855c5503f7114005c013b7891f980bf79efb3dc3509635d90` |
| `build.log` | 458 | `ba3e2cc2440148648a11c6c2480772ca6b8e1e3cd79f515bbd8313429f1656c6` |

Its `…-project/result-and-cleanup.json` is 1,440 bytes, SHA256
`f95df83d79e31412d707ad4d1ddb2c330bdfe7bb17ba92f40b18e29c489f9b56`.
The explicit ordered-list receipt is 6,529 bytes, SHA256
`b6809a482bd42eace33bcd8949d610b93148fa8cf63948ed933b4fe2fd4fe9eb`.

## Verified compiled-closure reuse — remaining 41/41 pass

The parent then explicitly authorized setup-only reuse of the already compiled
successful focused closure, with **no rebuild, resolver call or package
download**. A fresh atomic-lock/deduplicated slot verified all 53 real
source/descriptors against both current parent/owned files and the successful
project; the full Mist source path set and all 331 pinned package paths/hashes
were also exact. The cancellation FFI `af904739…`, Gleam test `65a4f37d…` and
runtime `90fd1161…` bytes were unchanged.

Provenance used that unique successful project, its unchanged successful build
log and pass receipt, and compiled BEAM modification times within the recorded
successful build window. **All 163 actual compiled BEAM/ebin/app outputs**
were hashed with exact absolute paths, covering **142 BEAM modules** in 20
closure ebin directories. There were no mixed ebins, root beam files, source
stubs or rebuilt substitutions. Each fresh bounded VM checked `code:which`
against all 142 recorded module paths and logged its actual `code:get_path`.
Every compiled output hash was checked before every runner and again after the
sequence.

The ordered list above was recorded before execution and invoked directly,
one isolated VM per unchanged public function: **17 distinct remaining
cancellation functions, then all five Content-Type controls, then all 19
unchanged F44 functions. Every one passed.** The separately passed pressure
function was excluded, not invoked twice. No default/global discovery or root
application was run. All fixture assertions and deadlines remained unchanged,
including the actual local TLS controls and legacy half-close comparison.

| Evidence scope | Result |
| --- | --- |
| Separate same-source actual-backpressure case | 1/1 pass |
| Remaining cancellation/legacy/TLS/body-handoff controls | 17/17 pass |
| Duplicate Content-Type raw-close/zero-dispatch controls and valid positives | 5/5 pass |
| Existing F44 framing/OWS/WS/head/deadline/OAuth controls | 19/19 pass |

The 41-function sequence took **52.388 seconds including audit/cleanup**.
Per-runner and final owned descendant audits were empty. Parent and isolated
cache metadata pre/post were unchanged, all 163 compiled output hashes were
unchanged, and only the matched owner-token lock was removed after those checks.
All earlier policy/fixture/setup failures remain retained, not relabelled.

Receipts under
`build/closure/f12-matrix-reuse-45346-1790892563283714000-receipt/`:

| Receipt | Bytes | SHA256 |
| --- | ---: | --- |
| `result-and-cleanup.json` (all 41 results and individual log hashes) | 21,668 | `0db3939058504ebe1074b864e42fa2e8287cb5602e5db58dbc994709b235aa17` |
| `explicit-ordered-function-list.json` | 6,529 | `b6809a482bd42eace33bcd8949d610b93148fa8cf63948ed933b4fe2fd4fe9eb` |
| `verified-source-inputs.json` | 15,944 | `57e2c5fcebafdb4f2d304fd3fb4f4711664b6a195f58eb3bbfcf3b51a62d9f0d` |
| `verified-package-source-inputs.json` | 97,559 | `e0550a8ecfc6120e855b8be30b237792724a797c4d7121ec0d933c4416704897` |
| `compiled-provenance.json` | 729 | `b38e1c14a8686ba85d1a2694a03b4049b67d61c741ac8a0ba3ae77e82a162a91` |
| `exact-code-paths.json` | 3,691 | `eb900b953cce58cda1a1274d3a3517565743ce57dc4d2f7bf0f1b268cbac7287` |
| `all-compiled-beam-ebin-app-outputs-before.json` and `…-after.json` | 77,041 each | `463d5f37ca133e63ba2c83412801e599405501beab4a5da70d9d3b1596d8d73c` |
| `parent-cache-metadata-before.json` and `…-after.json` | 673 each | `b6e9bffa5f6763d13b6f9a5b201b5db721d9611fb2489fa1d6419c9446f890eb` |
| `closure-cache-metadata-before.json` and `…-after.json` | 715 each | `0c8529d650dde36c325b0312f1ecebe4b35237821fb8c93aaf16c22f64774db8` |

The setup/provenance/order log is 10,680 bytes, SHA256
`e597e81f315f8406a6886737b35b06c06bb328a85576cafea6be5103749943f3`.
Individual uniquely named logs are recorded in the result receipt, including
every exact public function and its runner argv, verified code paths and result.

This establishes **focused 18 + 5 + 19 dependency-closure evidence only**.
It is not assembled/root/full-suite/shipment admission and does not replace
the original failed actual-root cancellation or F07 HTTP-200 report receipts.
The parent owns actual-root cancellation, strict UI raw-header, full-suite and
shipment gates. Only the 11 owned source/script/doc paths may synchronize;
compiled/copied projects, package caches and runtime `90fd1161…` are excluded.
No production or fixture source changed after these tested hashes, only
finite evidence docs. The worker is quiescent with no pending/deferred workload.
