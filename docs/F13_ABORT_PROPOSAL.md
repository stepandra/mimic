# F13 abort/lifetime proposal — source-only, not approved implementation

## Problem and measured boundary

The [single diagnostic receipt](F13_OWNER_DIAGNOSTIC.md) proves the raw socket is
the intended peer and is caller-owned before kill. Exact local/helper monitors
are installed before kill. The guardian's own later monitor reports `noproc`,
yet unchanged `abort/2` returns `ok`. The peer drains 9,000,017 bytes and times
out, not EOF/reset. This is measured owner-exit-before-abort evidence, **not**
qualified cleanup, driver-order proof or evidence of post-kill submission.

There are two decisions: remove the independently false local success predicate,
and choose how to keep an effective abort opportunity across vulnerable windows.
The measured source is unchanged while these decisions are reviewed.

## Separate required public-proof hardening

Proposed rule, independent of A/B:

- Do not ignore `force_close` failure.
- A newly installed `noproc`/`nosock` monitor proves absence of a public local
  handle, **not** that this call requested an effective abort or terminated the
  peer. Return explicit cleanup-unconfirmed failure unless independently retained
  evidence proves the same handle was already locally closed by a prior successful
  abort. Do not manufacture such evidence from the new absent-handle notification.
- Match the exact monitor, object and supported backend type. Reject missing
  evidence, unsupported backend and elapsed deadline; flush/cancel that exact
  monitor without extending the cleanup budget.
- Preserve the distinction between "requested abortive local close and observed
  matching local DOWN" and "peer actually observed EOF/reset." Public
  `inet:monitor`, `gen_tcp:close` and `port_close` can establish the former under
  their stated conditions, not remotely acknowledged termination or data delivery.
- A monitored live local handle plus successful abortive configuration/close and
  real local DOWN is stronger local evidence, but still requires the unchanged
  actual TCP/TLS peer gates before claiming bounded physical termination.

Existing String-boundary errors can represent unconfirmed cleanup. No new shared
wire type, `SessionAdapter`, root settings or public success guarantee is needed.
Idempotent cancellation may remain best-effort Nil at its compatibility boundary,
but that Nil must never be interpreted as qualified physical termination.

## A — Arm abortive linger before the vulnerable automatic-close window

Keep the logical socket owner and per-write short-lived guardian/sender. Configure
`{linger,{true,0}}` before a send can block or automatically close on timeout,
not afterward in the owner-DOWN branch.

- **TCP/TLS blocked sends:** Arming must complete on the correct still-live raw
  TCP handle before entering either `gen_tcp:send` or `ssl:send`. The same absolute
  guardian deadline must include configuration, send and any restoration. Merely
  shortening `send_timeout` or starting a timer is insufficient.
- **Successful sends:** Local `send=ok` means accepted by the stack, not delivered.
  Restore explicitly documented normal close policy only after successful send
  and under a bounded guardian-protected restoration. Never report success after
  failed/unconfirmed restoration or claim buffered bytes survived a reset.
- **Normal close:** A permanent abortive-linger default would change ordinary TCP
  FIN/TLS and WebSocket close behavior. It is not a harmless implementation detail.
  Preserve existing successful WS-close expectations and the compatibility close
  API's best-effort nature; do not silently replace it with a guaranteed reset.
  Existing raw `abort` is not graceful TLS close or acknowledged WS-close delivery.
- **Between writes/cancellation:** Restoring normal linger recreates an idle
  owner-exit window when accepted bytes remain queued, especially for TLS's user
  owner/connection processes. Explicit cancellation while a handle remains live
  can arm and abort, but caller death before that call cannot. A writes-only fix
  must not claim whole-connection lifetime coverage.
- **Connect/handshake failures:** Protection must be considered from initial raw
  TCP creation through public verified `ssl:connect` and HTTP upgrade. Caller death
  during handshake cannot rely on a guardian that has not yet been started.
  Failed setup never restores/reuses the socket; successful setup's policy must
  be explicit. CA/SNI/hostname/IP/ALPN verification cannot be weakened.

Advantages: no persistent helper or new domain owner, unchanged opaque
Connection/public seam, smallest potential change for the measured blocked-write
failure. Risks: option/control ordering, restoration, setup and idle/TLS ownership
windows remain real. Exact driver/OS ordering and peer proof are prerequisites.

## B — Independent surviving OS socket lifetime custody

Create/retain the socket under an OS-level lifetime owner that monitors the logical
caller but survives its exit long enough to arm abortive close on the still-live
handle. Keep all provider, authentication and continuation policy in Gleam.

- **TCP/TLS blocked sends:** Preserve one logical writer and exact short-lived
  sender/guardian cleanup. Use public TCP ownership and SSL user ownership APIs;
  raw ownership alone does not prevent SSL from closing when its user owner dies.
  Passive read/write behavior across the public controlling-owner boundary needs
  verification; do not inspect SSL's private tuple ABI.
- **Successful sends/normal close:** The custodian remains until explicit close.
  It must distinguish successful normal-close intent from cancellation/uncertain
  send; report no delivery guarantee beyond public APIs. It cannot be hidden as
  a write helper whose existence is omitted from cleanup assertions.
- **Between writes/cancellation:** A lifetime monitor can handle caller death
  outside sends and serialize terminal custody/abort, without reconnect, replay,
  rebind or account policy. All helpers must terminate after connection close.
- **Connect/handshake failures:** Custody must exist before creating/upgrading raw
  TCP, cover one absolute setup budget, close failed resources and itself exit.
  A transfer after successful handshake leaves the earlier vulnerable interval.

Advantages: coherent lifetime boundary across setup, blocked writes and idle
intervals, while leaving normal-close policy available. Costs: persistent process,
new custody/handshake/error states, SSL ownership verification and supervision.
It needs explicit architectural scope. If the no-helper contract means *zero*
persistent processes after a successful write, B is incompatible; do not exploit
the current monitor-only helper test to claim otherwise. If it means no orphaned
write helpers, explicitly identify the intentional connection custodian and prove
its eventual termination without relaxing guardian/sender cleanup.

## Recommendation and approval boundary

Approve the independent fail-closed proof hardening first. Then investigate A as
the smaller blocked-write correction, **only** with exact driver-order evidence,
bounded restoration and original TCP/TLS peer/no-helper/no-late-write gates.
Do not present A as covering idle/setup owner loss unless those windows are proven.
If whole-connection lifetime protection is required and A cannot provide it without
changing normal-close semantics, choose B only after approving its intentional
persistent custody boundary and accounting for SSL user ownership.

No alternative is implemented or admitted here. Do not widen any timeout, accept
arbitrary TLS alerts, waive peer EOF/reset, loosen helper cleanup, or claim the
diagnostic's extra 17 bytes were submitted after kill. The next implementation
scope and each new runtime gate require explicit parent approval.
