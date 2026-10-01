# F13: native Codex WS-lite

**UNQUALIFIED pending owner-death diagnosis and complete composed gates. The
first revised candidate passed 176 focused tests. The later bounded-primitive
candidate compiled and passed 24 dedicated tests, including actual backpressured
TCP/TLS timing, then stopped at an owner-death peer-read failure. Sanitized
diagnostic source is ready but not rerun. Root admission remains off.**

Owned files: `providers/codex_websocket.gleam` and its `fence`/`errors` helpers, the additive
`providers/codex/request.prepare_websocket` seam, dedicated
`codex_ws_lite_{test,fixture}` tests/FFI, this document, root patch artifact and
`scripts/smoke-codex-ws-lite.py`. Root gateway/config/CLI, shared Responses,
credential runtime/store/auth, vendor, and F12 HTTP consumer are not edited.
Parent separately granted additive `ws_transport.ensure_idle`; the isolated
frames file synchronizes only the parent's exact pure `quiescent` addition.
The actual bounded-write/abort follow-up also has an explicit WS-only grant:
opaque physical TCP handle, public STARTTLS connect shim and
`mimic_ws_transport_ffi`; existing WS public APIs stay unchanged. No other shared
codec or HTTP egress FFI change is made.

`F13_ROOT.patch` is an **unapplied parent artifact**, in `apply_patch` format.
Apply/advertise it only after the provider/socket gates are qualified and its
actual authenticated source/shipment WS/WSS workflows pass in the composed root
lane. It is not evidence of root admission, compilation or a successful workflow.

## Pinned public source, not executor-to-gateway inference

Reference: `router-for-me/CLIProxyAPI`
`acdace936fa7df2905500c7f5e0a97d683138dea`. These public files were fetched
read-only in F13 and full-file SHA-256 was computed:

| File | SHA-256 |
| --- | --- |
| `internal/util/codex.go` | `9986e4b36056366ad7db83d5cc2f004c0d284b326b50dfd2e7b4b1b6d535cecc` |
| `internal/runtime/executor/codex_native_fidelity_test.go` | `5599b79aa51038c4b5f53054124510b9a31de9aedd01f144a9fcf5fe138288cc` |
| `sdk/api/handlers/openai/openai_responses_websocket.go` | `a48aec8c44dc88e83fad7a56408664f9bdb5a2fcab57421dec2658f4369efd0a` |
| `sdk/api/handlers/openai/openai_responses_websocket_forward.go` | `425dfed513699e2932eeec72423f5a807106489990ff9cdd700ac28cc1b8b2b1` |
| `sdk/api/handlers/openai/openai_responses_handlers.go` | `44425e6550b54e39a5305441be7037bd32d78126926b2a317bca6a9aca86144d` |
| `internal/clienterror/client_error.go` | `d3a91bd2b1e7e9f5d50cc06e3581cfaf72f0d1442aee8d53b34cc4c9550a7c88` |
| `sdk/api/handlers/openai/openai_responses_websocket_timeline.go` | `e607eaf6601258db66b6dc794e4587383bb1ad3f8165df0bbfe11cfdbec3a530` |
| `sdk/cliproxy/auth/errors.go` | `e8b821864289c66910c4d00d5f4bc744a40e742164df3ebb8819cc1469a543d5` |

- [Marker source](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/util/codex.go#L10-L16):
  trimmed, case-insensitive handshake header `true` OR the exact per-frame
  `client_metadata.ws_request_header_x_openai_internal_codex_responses_lite`
  boolean/string selector. A header true remains socket-wide intent; without it
  each frame supplies its own marker. No marker inheritance from prior frames.
- [Actual public WS classification](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket.go#L683-L722):
  computes nativeRequest from the **current payload and handshake headers**;
  preserves completion output only after selected-auth provider is Codex.
- [Actual public WS projection](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket_forward.go#L153-L190):
  skips completed-output repair when preserveCompletionOutput is true, then
  [writes the payload](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket_forward.go#L221-L229).
  **WS projection is Transparent; F12 public HTTP remains HydrateCompleted.**
- [Public HTTP framer](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L203-L211)
  has no native guard, and its
  [repair helper](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_handlers.go#L341-L379)
  fills absent/empty output from recorded item.done. This HTTP file was also
  fetched and hash-checked in F13 rather than inferred from executor behavior.
- [Native executor header distinction](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/runtime/executor/codex_native_fidelity_test.go#L104-L129):
  upstream Lite header is present for the handshake-header selector only,
  not the body metadata selector. Native path has no `session_id` alias and
  does not inject instructions. F13 follows that marker-layer distinction.
- [Credential-affinity source](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/api/handlers/openai/openai_responses_websocket.go#L739-L787):
  a connection-scoped continuation cannot rotate credentials in place.
  MIMIC closes, never rebinds/reconnects/replays the uncertain turn.

The three JSON event strings are the F11/F12 **synthetic source fixtures**,
not captured/native/live traffic. The root harness imports those exact strings
and independently verifies F11's event-data hashes on every invocation.
CPA executor's source matrix does not imply that MIMIC exercised that matrix.

Steering, append, accepted acknowledgements and generate=false prewarm are not
implemented or advertised. The pinned source does have separately configured
duplex/steering behavior; F13's one-active-response contract does not pretend
to implement it. Unsupported create controls/events fail explicitly and close.

## Consumer and request contract

All public provider signatures below compiled in the bounded-primitive candidate.
That is API evidence, not completed owner-death/root workflow qualification:

```gleam
// Existing compatibility/default-strict API is unchanged.
codex_websocket.adapter(tenant: String, catalog: models.Catalog,
  user_agent: String, ca_file: Option(String))
  -> contracts.SessionAdapter(codex_websocket.Handle)
codex_websocket.adapter_notifying(tenant: String, catalog: models.Catalog,
  user_agent: String, ca_file: Option(String),
  notify: fn(codex_websocket.Terminal) -> Nil)
  -> contracts.SessionAdapter(codex_websocket.Handle)

// Parent's explicit native root composition, after authenticated admission.
codex_websocket.native_adapter(tenant: String, catalog: models.Catalog,
  user_agent: String, ca_file: Option(String), header_lite: Bool,
  store: storage.Store, authorized: fn() -> Bool)
  -> contracts.SessionAdapter(codex_websocket.Handle)
codex_websocket.policy(request.ResponseMode) -> stream.Policy
codex_websocket.native_adapter_notifying(tenant: String, catalog: models.Catalog,
  user_agent: String, ca_file: Option(String), header_lite: Bool,
  store: storage.Store, authorized: fn() -> Bool,
  notify: fn(codex_websocket.Terminal) -> Nil)
  -> contracts.SessionAdapter(codex_websocket.Handle)
codex_websocket.terminal_action(codex_websocket.Terminal)
  -> Result(codex_websocket/errors.Action, contracts.Failure)

// Additive builder; old request.prepare and HTTP behavior remain strict.
request.prepare_websocket(ir.Value, request.Context,
  Option(session.Continuation), List(String), request.ResponseMode,
  header_lite: Bool) -> Result(request.Prepared, String)
```

The provider qualifies intent against the selected exact catalog entry before
connect; a caller marker cannot turn a `responses_lite:false` model sparse.
Catalog capability does not force an unmarked request into lite. One physical
socket freezes its strict/lite policy; a later mode switch fails closed, including
metadata omission without header=true. This is deliberately narrower than CPA
switching modes between turns and avoids implicit cross-policy receipt authority.
Existing compatibility adapter is still strict and rejects lite-only entries.

Header syntax/duplicates are validated by existing `codex/lite` in the new root
upgrade seam. Per-frame JSON uses the existing duplicate-key/size guard.
Request normalization retains previous_response_id only on the same physical
connection, forces parallel_tool_calls false for lite and does not inject native
instructions. Explicit image-generation/audio/file support is not invented.

F11 owns decoding, validated WireEvent data and sparse Report. F13 uses
`websocket.new_with_policy` and `receive_wire`, forwarding `wire_data` directly.
Sparse wire is **never** passed to strict `terminal_response`. Only Report's
`ContinuationEligible` enters `session.completed_ws`; `Reconstructed` alone,
MissingCreated, id-less/open items, unknown empty output/native types and
noncompleted outcomes clear both shared and provider receipts. Usage, reasoning
and tool data remain validated native data; no identifiers/history are invented.

Reset is a normal response.create without previous_response_id, not a fabricated
response.reset control. It starts a fresh turn on the same socket; no input replay
or HTTP receipt substitution occurs. The next cursor is scoped to this Handle's
fresh physical-open generation. Provider errors, cancellation, downstream
failure, malformed events, unexpected queued data and disconnect invalidate it.
The prior checkpoint wrongly treated poll None as clean and retained a reusable
Ready phase after raw error data. Both are reviewed authority/lifecycle defects.
The revised source uses `ensure_idle` for admission and permanently closes/cancels
protocol and transport before a typed terminal notification. The first revised
candidate passed 176 focused tests. The follow-up passed 24 dedicated tests
including decoded-key sanitization and actual backpressured TCP/TLS abort bounds,
then stopped at an owner-death peer-read failure. No complete qualification is
claimed; actual root workflow qualification remains parent-owned.

## Non-duplex error policy versus local sanitization

Verified public source, not executor transparency:

- `websocket_timeline.go:256-278` extracts positive top-level status, then
  status_code, then 500. Its payload wrapper implements StatusCode only.
- `websocket_forward.go:174-215,253-308` classifies every non-duplex error,
  suppresses or exposes it and closes in either case. Only separately configured
  duplex has recoverable error events; F13 does not advertise duplex.
- `client_error.go:79-127` gives 402/429 authoritative precedence, suppresses
  401 authentication and model-not-found bodies, then recognizes the exact
  request codes/types, stale nonpersisted-item text and 400/409/413/422.
- The source's terminal-auth exception is a **trusted Go error interface**,
  not JSON. Raw `terminal_auth`/similar body flags grant no exception here.
- Same-socket prior-id 401/429 uses the source's 1012 replay-required close,
  without performing any replay; exact 413/error.code message_too_big uses 1009
  with a bounded UTF-8 codepoint reason.

These source rules are separate from deliberate stricter local boundaries:
only canonical error objects with a nonempty message and optional string/null
type/code/param can be exposed; positive integer/string-integer status forms are
supported (no boolean/float truthiness); decoded access/refresh credential echoes
in both recursively nested keys and values (including escaped key spelling),
and credential-bearing fields suppress. No raw diagnostic logging is copied.
The intended wire preservation for allowed request faults changes no inner JSON
data. Unsupported shape/sensitive-value suppression is a fidelity difference,
not a measured CPA result.

`Terminal` is opaque and created only after codec validation, classification,
upstream close and the selected revision/client fence. Root receives a typed
NativeTerminal message; `terminal_action` repeats that same read-only fence
immediately before publication. Suppressed emits no generic fabricated error;
allowed fault/transport close publishes at most once and stops. Standard adapter
without a callback fails closed for suppression; a delivered request fault still
has a permanently closed Handle. No callback-less reusable idle state is allowed.
The root packet selects a dedicated root-owned Terminal Subject into its existing
actor, checks it with a zero-time priority receive before handling a queued Tick,
and checks it again after a blocking step failure before generic fail(). A
general-message callback alone would not preempt an older queued Tick.
Deterministic tests queue that Tick first, show the closed handle rejects reset,
then consume the pending dedicated notification without waiting/sleeping; provider
revision/client authorization is mutated before terminal publication.

This deliberate source-handler/safety correction also applies to Compatibility
strict sockets, with parent approval. Previously a strict `error` was forwarded
verbatim and left Ready(None), permitting a fresh reset on the same socket.
Now generic 503 diagnostics are suppressed and the socket closes; a canonical
allowed 400 request fault can be delivered once but also closes, denying reset.
The strict codec, marker opt-in, default adapter signature, S6 authorization and
F12 HTTP consumer/receipts are unchanged. Strict **error behavior** is tightened,
not claimed byte-compatible with the earlier unsafe adapter.

## Read-only lifetime fence

Runtime's existing send fence remains unchanged. Its poll path does not check
selected revisions, so F13 adds a provider-specific **read-only** lifetime fence
using `runtime_store.load_record`, `record_material`, `record_status`, `revision`.
There is no second credential owner, refresh/acquire callback or mutation.
No existing shared continuation storage-lifetime helper is present.

Before connecting, bind exact selected Context material to the server-owned
provider/auth/account key and immutable Revision. Load/mismatch/nonready/expiry
errors reject without inference I/O. Never rebind on a live socket. Same-token
replacement changes Revision, so token equality is not continuation authority.
Opaque record/raw material never enters errors, logs, responses or persisted
provider artifacts.

Every send/poll checks current client authorized() and current selected revision,
Ready status, unexpired OAuth; poll rechecks after the blocking socket operation.
Return/publication has one more fence after event validation. Error immediately
closes the physical socket; runtime cancellation also releases its lease.
The parent root hook rechecks client authorization before writing output.
Revocation during blocking poll must not deliver terminal data or mint authority.

Cost is explicit: each check rereads and decodes the selected bounded credential
record; an idle poll performs two checks, an event poll three, and sends include
pre/post transport checks. Current upstream poll duration is 20 ms; the gateway
also has a 10 ms client poll. Successful reads are not cached, so neither client
nor provider revocation waits for a next inference. This slice makes no throughput
measurement; a future poll/notification optimization must preserve these fences.

## Parent root packet and workflow gates

The artifact preserves `websocket.Settings` and the existing compatibility
upgrade API, adds `upgrade_native_authenticated(..., storage.Store)`, validates
the singleton marker, retains header intent in private State and constructs the
real `native_adapter_notifying`. Compatibility root upgrades intentionally use
the additive `adapter_notifying`; the plain low-level default adapter remains
strict/fail-closed but is not public gateway error projection authority.
This is not a wrapper substituting for a sparse consumer.

Only after qualification:

- Remove root registration's `!entry.responses_lite` WS exclusion under the
  existing default-off `codex_websocket` switch.
- Use existing `models.available(catalog, configured_ids, ws_enabled, True)` in
  native discovery. `models.available_http` and HTTP F12 qualification/cached
  receipt behavior stay unchanged; the root moves to the admitted WS binding.
- Keep tenant/client auth, raw handshake admission, selected runtime scopes,
  existing strict/S6 validation and HTTP receipt owner unchanged.

Parent runs the actual fresh-root-CLI harness in both modes:

```sh
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 scripts/smoke-codex-ws-lite.py
ERL_FLAGS='+S 2:2 +A 2' mise exec gleam@1.18.1 -- \
  python3 scripts/smoke-codex-ws-lite.py --shipment <export-directory>
```

Harness provides actual authenticated root sockets, selected account, coalesced
handshake/create, opt-in/native discovery, header/metadata projections, usage,
same-socket continuation/reset, gaps/noncompleted output, valid-prefix malformed
events, unsupported controls, fragmentation/ping, cancellation and active
client/provider deletion/rotation/same-token revision mutation through root CLI.
Each WS and WSS run has a fresh private synthetic state directory. WSS uses an
ephemeral CA via only child-VM `public_key.cacerts_path`; no host trust-store
change or verify-none/insecure setting. System/default TLS verification remains
the production rule. Focused provider WSS tests also use the explicit existing
CA seam and must test trust failure separately.

## Validation ledger

| Evidence | Current outcome |
| --- | --- |
| Pinned public source retrieval/full-file hashes | Verified read-only |
| Exact event-data source hashes | Existing F11/F12 source-derived values; harness recheck pending |
| Scoped Gleam format/check/build | Revised candidates passed with Gleam 1.18.1; `ERL_FLAGS='+S 2:2 +A 2'`; later sanitized diagnostic/style follow-up not rerun |
| Dedicated provider tests | 22 passed in first revised candidate: actual WS/WSS, selected lifetime fences, same-socket/reset, catalog/strict-mode fences, custom tool/reasoning, sparse gaps, malformed-prefix, queued data and unsupported controls, plus pure projection/classifier tests |
| WSS setup corrections | Existing new_ca_dir helper and exact OperatorHttps/LocalLoopback fleet contract used; no TLS/routing weakening |
| Gated active-revision, blocked-poll revision/client tests | Passed with owner-correct peer-created release Subjects |
| Partial/fragmented/large/flood pre-turn data and non-duplex error lifecycle | Passed including deterministic queued-tick/reset and publication fence |
| Selected provider/runtime and strict/F11/F12/ws_transport/xAI/frames regressions | 176 total focused exported tests passed; not a full composed gate |
| Follow-up decoded-key echoes and Compatibility strict error behavior | Passed actual key/escaped-key suppression and plain/notifying strict 503/fault one-shot/reset-denial tests |
| Follow-up physical TCP/TLS deadline primitive and backpressured Pong/abort | Passed gate-held output-backlog assertions, actual Pong/partial timing and peer EOF/reset |
| Owner death / successful-send helper cleanup | **Stopped:** positive raw socket/helper termination assertions passed before peer-read failure; sanitized branch/category diagnostic pending |
| Complete follow-up strict/F11/F12/ws_transport/xAI regression selection | Not reached after first owner-death test failure; previous 176-pass result is a different candidate |
| Actual root source/shipment WS/WSS workflow | **Not run: parent root gate** |
| Existing F11/F12/strict/S6 composed regression gates | **Not run here** |
| CPA differential, actual native Codex workflow, live provider | **Not performed; separate F31/F36/F40 gates** |

Validation was lock-protected and stopped at the first runtime failure. Logs:
`build/f13-validation.cdIcKx` (initial fixture Policy name correction),
`build/f13-validation.19XshN` (fixture transition return-type correction),
`build/f13-validation.oEWVQi` (successful compile/build and the two passing
actual WS tests, then CA setup failure), `build/f13-validation.uMWUOK` (fleet
setup contract), `build/f13-validation.iXyQco` (five passing tests then expected
JSON object representation correction), `build/f13-validation.7vSuWU` (ten
passing tests then fixture Subject ownership failure). No production semantics
were weakened to accommodate a fixture failure, and no deferred run is queued.
`build/f13-validation.vJMvVF` retains the compiler-only UTF8 codepoint pattern
correction; `build/f13-validation.tzbCfW` contains successful scoped compile/build,
harness AST and all 176 selected tests. The shared absolute validation lock was
released before the two follow-up review corrections; no later runtime run is
claimed by that log.
`build/f13-validation.CyZTER` retains a compile-only fixture Nil return correction.
`build/f13-validation.P9IyQd` contains successful follow-up compile/build/harness
AST and 24 dedicated passing tests, then the retained owner-death peer-read
failure. The shared validation lock was released on that first real failure.
Diagnostic error categories do not expose raw SSL reasons, peer payloads or
credentials and do not broaden arbitrary TLS alerts into closure proof.

### Additive shared transport and real socket deadline

Shared Responses frames remain parent-owned. Add a pure
`frames.quiescent(Decoder) -> Bool` checking live Header phase, zero pending
bytes and no fragmented message. `frames.finish` is not this predicate: clean
live state returns the EOF error "disconnected without close".

Under the precise parent grant, `ws_transport.ensure_idle(Connection) ->
Result(Connection, String)` consumes bounded legal ping/pong control data,
reject text/partial/fragmented data and require a real receive timeout before
returning. Merely seeing poll None, even with no retained transport pending,
does not prove idle: a partial message may be held by the decoder or more bytes
may remain in the kernel after the 8192-byte receive bound. Read/byte/time limits
fail closed: eight reads, 65536 bytes, 128 controls, one absolute deadline at most
250 ms covering reads/control writes, plus bounded failure cleanup (at most
100 ms). Provider send rechecks the selected revision afterward. Partial controls
also fail admission; active-turn poll behavior and all existing APIs are unchanged.

The first candidate copied a smaller timeout into Connection, but the inherited
`mimic_egress_ffi.write/3` ignores that parameter. Its configured five-second
socket send timeout did **not** enforce the advertised idle/cleanup deadline.
Passing fast loopback tests did not prove a bound under backpressure.

With the explicit parent grant, the WS-only `mimic_ws_transport_ffi` retains the
physical TCP handle by using public `ssl:connect(Tcp, Options, remaining)` after
TCP connect. One absolute connect budget covers both stages; peer verification,
CA selection, hostname/IP-SAN matcher, SNI and HTTP/1.1 ALPN mirror the original
verified TLS policy. Every failed setup closes the retained TCP handle. HTTP
egress FFI remains untouched. There is no private SSL tuple ABI.

All WS writes apply actual physical `send_timeout`/`send_timeout_close` per call.
A short-lived OS guardian independently monitors the executing caller and the
absolute deadline, with exactly one linked/monitored blocking sender. This keeps
a killed caller from orphaning an SSL send; no new root/runtime/domain actor is
created. Timeout or caller DOWN physically closes TCP first, then kills/drains
that exact sender monitor within a separate 100 ms cleanup budget. Only fixed
sanitized results are carried by DOWN; no payload/reason logging. There is no
unbounded socket-option restoration or `ssl:close`. Guardian/sender disappear
after the primitive, not a new persistent whole-connection lifetime owner.

`abort(Connection) -> Result(Nil, String)` uses abort-specific
`{linger, {true, 0}}` and requires the public `inet:monitor` DOWN as positive proof;
missing evidence is cleanup failure, not Nil success. Idle admission failures
and provider non-duplex terminal handling use abort, not a close-frame write.
Disabled linger is not a bound: verified OTP28/29 `prim_inet.close` may drain its
output queue for up to 180 seconds. If abortive setopts fails on an actual port
backend, public `erlang:port_close` bypasses that drain; unsupported/unconfirmed
cleanup is explicit failure. No private socket or SSL ABI is inspected.
The old Nil-returning compatibility `close` API remains best-effort and is not
treated as proof of successful physical cleanup.

The gate-held synthetic pressure test must establish at least 65536 pending
output bytes on a still-live socket before attempting Pong/partial admission,
then assert the elapsed bound and peer-observed EOF or reset after draining.
Abortive reset is not graceful TLS EOF and cannot promise pending-byte delivery
or recall bytes already handed to the socket; uncertain sends are never replayed.
The test never treats timeout/arbitrary TLS errors as peer termination. The 400 ms
Pong and 150 ms immediate-abort assertion ceilings include scheduler tolerance,
not measured performance results.

Public socket monitors exist since OTP24; only public TCP/SSL APIs are used.
The installed inspected source is OTP29.0.4 (`ssl`11.7.4), and shows that
`ssl:close(..., 0)` still enters a default-timeout gen_statem call, which is why it
is not the abort primitive. OTP28 and OTP29 compatibility require the focused
strict/TLS/socket suite on each toolchain; this slice does not claim a second
toolchain was executed.
