# F18 xAI WS provider and root integration contract

**SCOPED-REVISION ADDITIONS UNVALIDATED / RUNTIME UNEXECUTED / ROOT BLOCKED. Default-off remains required.**
The parent approved the exclusive provider/helper/test/harness/doc scope, the
narrow F07 `operations` extension and the test-only compatibility correction.
No root, Codex, shared codec/transport, runtime/store/auth, vendor or build file
is changed by this packet. An earlier exact composed build passed, but subsequent
independent source review found authority/lifecycle gaps. The approved source
corrections received a later corrected-byte structural review, but no runtime
qualification. New scoped-revision additions and the P2 closure-oracle correction
are not formatted, compiled, tested or independently reviewed. The old build
receipt is historical, not qualification of these bytes. Root remains blocked.

## Public source facts, not runtime observations

F01 owns FINAL-v1 at CPA `acdace936fa7df2905500c7f5e0a97d683138dea`.
Its [operation inventory](../parity/final-v1/contract.json#L379) retains
`grok-ws-chain-source` and `paired-execution`; neither is closed here.
The [source map](../parity/final-v1/SOURCE_MAP.md#L128) and
[F17 decision](F17_SOURCE_DECISION.md#L30) delimit the source-backed surface:

| Source fact | Implementation boundary |
| --- | --- |
| `XAIAutoExecutor.ExecuteStream`, lines 1742–1752, chooses upstream WS only for downstream WS plus selected-auth enablement; required-WS cannot fall back to HTTP. | Explicit WS operation, no HTTP fallback, reconnect or replay. Nonstream HTTP is unchanged. |
| `xai_websockets_executor.go`, lines 1083–1091, separately restores the raw prior ID after ordinary preparation. Ordinary HTTP deletes it. | Same-physical-socket shared Session receipts only; no HTTP receipt reuse or implicit full-history repair. |
| F01 tool normalization collects declared refs before normalization. Broader form/model applicability remains unresolved. | Reuse existing function/namespace/`web_search` aliases; raw shared-codec validation precedes restoration. Custom/media forms are not invented by F18. |
| F01 does not prove the full configured xAI upgrade, close, credential and session chain. | Local protocol/fence tests cannot become source-chain, native, differential or live qualification. |

The historical `d6f307a72a395a137126016362297884e1061a8a` packet was read only.
Its unadmitted root patch, old test totals and absent-F07 design are not imported
or reused as current validation. No historical commands, reference service,
native client or real account was executed.

## Narrow F07 operation extension

[`operations.new`](../../src/mimic/providers/xai/operations.gleam#L30) now admits
`responses/websocket` only with a canonical explicitly configured HTTP(S)
`/v1` base and `using_api: true`. HTTP is numeric `127.0.0.1` only; HTTPS uses
verified TLS. WS/WSS are the physical transport, not configuration-origin
schemes. Proxy `using_api: false`, the official CLI proxy host, Build and
composer WS are rejected, not silently moved to `api.x.ai` or HTTP.

```json
{
  "protocol": "responses",
  "operation": "responses/websocket",
  "base": "https://api.x.ai/v1",
  "using_api": true
}
```

API-key and device-OAuth are separate explicit auth partitions. One OAuth grant
still uses F07's single credential worker across its explicitly configured
operations. A WS binding does not infer any HTTP or compact binding.
Registration aggregates **only the bound operation rows**:

| Explicit bindings | Capabilities |
| --- | --- |
| WS only | Stream, Tools, WebSocket, Continuation; no Buffer/HTTP/compact |
| Responses HTTP only | Existing Buffer, Stream, Tools; no WS |
| Compact only | Existing Buffer; no WS |
| Explicit HTTP and WS | Union of those rows, never inferred from a flag |
| Legacy API-key with no bindings | Existing HTTP registration; no WS |

Root account/model/operation admission must happen before credential acquisition
so unsupported proxy/Build/composer requests cannot trigger OAuth refresh.
Adapter binding selection repeats the exact selected Context check; an adapter
alone cannot establish a pre-acquisition guarantee.

[`select_configured`](../../src/mimic/providers/xai/operations.gleam#L272)
now accepts the aggregate of startup-validated account
bindings, partitions only by authoritative Context account/auth, and delegates
to unchanged per-account `select`. It does not drop duplicate or conflicting
bindings inside the selected partition. Protocol, operation, origin and pinned
account checks remain unchanged, as does F07 HTTP/per-account selection.

## Root-facing signatures — ABI unchanged, corrected source uncompiled

These signatures compiled in the original recorded snapshot. The corrected
implementation preserves the public signatures but has not been compiled:

```gleam
pub fn configured_adapter(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
) -> contracts.SessionAdapter(Handle)

pub fn configured_adapter_notifying(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: fn(Terminal) -> Nil,
) -> contracts.SessionAdapter(Handle)

pub fn terminal_action(
  terminal: Terminal,
) -> Result(TerminalAction, contracts.Failure)
// TerminalAction = Close(code: Int); currently 1008 or 1011, no raw body.
```

Additive source-only factories, not yet compiled:

```gleam
pub type ScopedOpen =
  fn(contracts.Context, runtime_store.Revision, contracts.Request) ->
    Result(contracts.Opened(Handle), contracts.Failure)

pub fn configured_scoped_open(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
) -> ScopedOpen

pub fn configured_scoped_open_notifying(
  tenant: String,
  bindings: List(operations.Binding),
  ca_file: Option(String),
  store: storage.Store,
  authorized: fn() -> Bool,
  notify: fn(Terminal) -> Nil,
) -> ScopedOpen
```

The source is
[`xai_websocket`](../../src/mimic/providers/xai_websocket.gleam#L104).
The parent keeps **one existing gateway actor and dispatcher**. A configured
model chooses a provider/auth/operation group, then the branch calls
the shared runtime with the appropriate Codex or xAI adapter. Its generic
`runtime.Session` erases differing handle types. No giant duplicate WS gateway,
heterogeneous adapter cast or changed shared `SessionAdapter` ABI is needed.
The parent's new `open_session_scoped` passes the acquired revision unchanged
to the additive provider callback. It is SOURCE-ONLY/uncompiled and the root
is still unwired/off. Existing `open_session` keeps its compatibility wrapper.

Root responsibilities:

1. Authenticate the actual GET request before upgrade and derive tenant from
   current server-owned client-key state, never from a frame/header hint.
2. Preserve exact path/no-query, Origin rejection, duplicate/singleton headers,
   no extensions/subprotocol/compression, body/framing limits and RFC6455 checks.
3. Maintain default-off xAI route admission separately from Codex enablement.
   Advertise only enabled configured WS models, not account entitlement.
4. Resolve the configured model route before acquisition. Reject unknown,
   unsupported or ambiguous routes without credential or upstream I/O.
5. xAI Request is Responses, `responses/websocket`, Streaming, `[WebSocket]`,
   server-owned session, and subsequently selected-account pinned. The first
   create pins provider, auth, model and operation until the socket closes.
   A reset does not clear that pin.
6. Supply all startup-validated configured bindings to the adapter.
   `operations.select_configured` chooses only the actual selected account/auth
   partition and delegates exact operation/origin checks to `select`; no request
   URL, account-origin fallback or private OAuth metadata creates destination
   authority. The adapter itself repeats model WS registration qualification,
   so composer/Build cannot bypass registration using nonempty history.
7. Use the current client authorization callback before first/new create, after
   acquisition, after blocking polls and immediately before publication.
8. Preserve the F17 pre-acquisition HTTP previous-ID guard and WS-transform
   boundary. Do not introduce an HTTP receipt lookup on the WS route.
9. Pair the existing configured SessionAdapter with its configured scoped-open
   callback in `runtime.open_session_scoped`. The adapter's old open callback is
   intentionally replaced; send/receive/cancel and generic Session are unchanged.
   Unscoped compatibility admission is not authoritative root acquisition.

## Acquired-revision/client fence — source implemented, qualification blocking

The xAI-specific [read-only fence](../../src/mimic/providers/xai_websocket/fence.gleam#L46)
now has `bind_acquired`, used by scoped-open factories. It requires the current
persisted revision to equal the supplied runtime-acquired revision, checks exact
material against Context, and retains that supplied revision rather than relabel
a newer read. It checks current client authorization,
exact revision, Ready status and OAuth expiry before and after each bounded
transport operation, including idle polls. Same-value replacement is rotation
for an already-open socket; deletion, expiry, refresh uncertainty and revoke
cannot transparently reauthenticate it. No Codex metadata or credential manager
is imported.

The older unscoped `bind` is **not proof of runtime-acquired revision**. A same-token
replacement between acquisition and `fence.bind` can preserve material equality
while changing revision. Root must use the new scoped callback plus parent
runtime API; the later send check does not make an earlier unscoped upgrade
authoritative. Root admission remains blocked on composition/qualification of
the source-only seam and exact race regressions.

The additive `bind_with_clock` is trusted test dependency injection only.
Configured legacy admission uses `bind`; scoped root admission uses
`bind_acquired`. Both always supply real OS time. There is no
request/configuration clock or expiry-bypass flag. The
dedicated expiry regression advances time on one unchanged persisted record
and verifies that its material and revision did not change.

The first message is validated before the upgrade but not sent by `open`.
`send` uses the shared transport idle fence and never retries. The shared
Responses Session alone pairs tool calls and grants a prior-ID receipt from
validated successful completion. A reset omits the prior ID; a fresh physical
generation has no receipt. Raw identity validation runs before restoring names,
so two namespaces with the same short name cannot hide a wire conflict.

## Typed close-only terminal seam — conservative local policy

**This error exposure policy is not CPA/source parity.** F01's xAI effective-chain
proof is incomplete; Codex's classifier is not xAI authority. The parent approved
close-only publication instead of forwarding arbitrary upstream error content or
a raw/generic diagnostic.

| Path | Public behavior / state |
| --- | --- |
| Successful validated completed response | Preserve event prefix, restored identity fields and usage; same-socket receipt may authorize the next create. |
| Error, failed, incomplete or cancelled terminal | Validate raw event through shared codec, request physical abort, notify close-only Terminal, then return sanitized `Failure(Cancelled, Started, None)`. No next handle/receipt or error body/usage is returned. |
| Malformed event, identity/model conflict or transport failure | Earlier validated prefix survives; no later malformed/error body is published; close-only terminal, no receipt/replay. |
| Current-client or provider-record fence failure | Abort attempt; terminal publication rechecks captured fence and is suppressed when stale. Never substitute a generic error response. |

Terminal is opaque and retains no raw text, token, URL, upstream diagnostics or
response document. The callback is nonblocking and has no acknowledgement wait.
Notifying receive termination now returns Error rather than `Ok(None, closed)`.
The existing runtime Error branch attempts cancellation and lease release
independently of callback arrival. Release follows cancellation returning:
F13 abort remains unqualified and can delay or fail cleanup.

Error cannot return an updated immutable Handle. Direct SessionAdapter callers
**must discard the old handle on every Error**; old retained copies are not
claimed globally one-shot. Runtime cleanup and callback count need actual
composed execution, separately from peer closure and abort return values.

The root actor can wrap `XaiTerminal(xai_websocket.Terminal)` beside its existing
Codex-specific terminal type. Check its priority mailbox before ordinary Tick
processing and again after **every** blocking runtime return. Callback and runtime
replies have different senders: do not assume mailbox arrival order. Consume at
most one fenced action, recheck current authorization immediately before writing
one close (1008 or 1011, empty reason), then stop/cancel. An absent/stale Terminal
on xAI terminal Failure means suppression and stop, never generic diagnostics,
raw events or an unfenced fallback. Root cancellation/publication and actual
lease release require composed proof, not callback invocation alone.

## Intentional compatibility tightening

- `selected_adapter` no longer invents or overwrites `websocket_base` from
  `Context.origin`, and now rejects None regardless of TLS policy. Configured
  production adapters require explicit bindings/bases. The legacy fixed-config
  `adapter` may retain the explicitly documented official endpoint default;
  it is not the selected/root factory or ambient origin authority.
- Any send Error is terminal, even when local validation prevents that new
  create from reaching upstream. A caller must discard the handle; rejection
  tests use separate sockets rather than continue a success case after Error.
- Success, incomplete, failed and cancelled are not interchangeable. F18 does
  not use failed/incomplete output as history or continuation authority.
- Normal successful completion still returns `Some(event)`; failure notification
  no longer idles with a lease until a later poll/root cancellation.

## Acquired-revision dependency provenance — parent source only

The parent implemented the minimal additive runtime API, analogous to HTTP
`open_scoped`, using existing `Driver.open(Context, Revision, Request)`:

```gleam
pub fn open_session_scoped(
  runtime: Runtime,
  adapter: contracts.SessionAdapter(h),
  open: fn(contracts.Context, runtime_store.Revision, contracts.Request) ->
    Result(contracts.Opened(h), contracts.Failure),
  request: contracts.Request,
) -> Result(Session, contracts.Failure)
```

Read-only exact dependency, not copied or included in this owned packet:

```text
/Users/jerryjohnson/dev/mimic/.delta/worktrees/rz87rbwdwjd8/mimic/src/mimic/providers/runtime.gleam
SHA256 90fd116141c7a47abdfa556a627cc0f66674b008e7e49ba0bd321b345e57fdb5
```

Its scoped callback is passed unchanged to Driver.open; existing `open_session`
delegates using its original adapter.open wrapper. This source is uncompiled,
not a runtime observation or approval. Existing SessionAdapter send/receive/
cancel and generic Session remain unchanged. No shared file was edited here.

The owned scoped factories now consume that authoritative revision and
`bind_acquired` requires revision AND exact material/Ready/expiry/client before
physical upgrade, retaining exactly the supplied revision. No token hash,
request field or newer equal-valued record substitutes for it.

Prepared actual-runtime race regressions synchronously replace the selected
record inside the acquired-open wrapper, before calling the real scoped
provider callback with R1. API-key/OAuth cover unchanged R1 success,
same-material R1->R2 and different-material denial. Requests pin
`Some("selected")` so ordinary account failover cannot hide denied opens.
A dedicated numeric-loopback TCP accept probe counts before closing unexpected
connections; expected zero accepts implies zero handshake/inference traffic.
Expected denial is CredentialUnavailable/NotSent with released lease. No
sleeps order the race. These tests and the closure assertions are UNEXECUTED.

## Shared F13 dependency and admission

F13 owner `b9101909e54c43c2` exclusively owns shared `ws_transport`,
`frames.quiescent` and WS-only OS primitives. Its old public open/send/poll/close
signatures remain intended unchanged. This packet requires its additive
`ensure_idle(Connection) -> Result(Connection, String)` and
`abort(Connection) -> Result(Nil, String)`; it does not duplicate them.

**The latest F13 transport is not imported or qualified here.** A diagnostic
confirmed that a new `noproc` monitor can falsely report abort success while the
peer times out. An `Ok` result is therefore not physical-close proof. Provider,
root and shipment gates require actual peer EOF/reset/close, and timeout is a
failure. No owner-death, WSS close or cleanup qualification follows here.

Parent-owned root edits, explicit dependency synchronization and serialized
validation are still required. The actual source/shipment harness is
[`smoke-xai-ws.py`](../../scripts/smoke-xai-ws.py#L1), synthetic localhost/TLS only,
with a process-local temporary CA and no host-trust modifications. Its prepared
scenarios are requirements, not observations; status is in
[F18_VALIDATION.md](F18_VALIDATION.md#L1).
