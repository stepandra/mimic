# F07 — configured Grok device enrollment through the shared account UI

**Current evidence: exact composed build, 43 focused tests, full actual root
socket workflow, two narrow resource regressions and corrected full browser
workflow passed.** The original browser failures remain retained receipts;
their measured favicon cause was fixed by an explicitly approved fixture
resource contract, not by dropping errors. Shipment and independent parent
integration gates remain unverified here. All executed I/O was synthetic
loopback after explicit exclusive-slot grants. The inherited duplicate
Content-Type dependency is not waived. This is not “done parity”, live-provider
approval, CPA differential success or measured upstream data.

## Same UI, same S5 store, one existing manager

The existing `accounts ui serve CONFIG [PRIVATE_DEVICE_IDENTITY] PORT` shell,
strict loopback Host/Origin/CSRF boundary, operator session, presentation
generation and coordinator are reused. The Kimi-only entrypoints and F06
`Transports(kimi,codex)` constructor remain supported. `WithXai` and `with_xai`
are additive synthetic injection seams, not browser inputs. Kimi alone still
requires its explicitly supplied private device identity.

`enrollment_xai.adapter` runs behind `Adapter(run)`, emits
`Some(DeviceCode(user_code,verification_uri))` while pending and `None` after
authorization. Private device codes remain worker memory. Discovery and start
cannot run until the coordinator reserves the exact S5 enrollment ticket.
Only the coordinator calls `commit_enrollment`; there is no unconditional
save fallback. Cancellation invalidates that exact generation before linked
network work is killed.

Scheduling and the provider deadline use monotonic milliseconds.
`oauth.poll_at` separates the monotonic poll clock from persisted credential
epoch expiry; legacy `oauth.poll` retains its existing semantics. A late start
or token response is rejected after the monotonic deadline, even if the
response is otherwise valid. No automatic token-exchange retry follows an
unknown outcome. Safe phase names replace provider error/body text.

`bridge.oauth_material` persists only access/refresh/expiry and the validated
discovered token endpoint, not unverified JWT identity or a new record per
origin. `bridge.oauth_policy(config,enrollment.send)` plugs into the **existing**
credential runtime worker. The existing refresh singleflight, exact-generation
rotation, durable unknown-outcome reauthorization fence, admin replacement and
deletion rules are not reimplemented or weakened.

UI cancellation/logout are not provider revocation. Same-token administrative
save, replacement or delete defeat older tickets. CAS uncertainty remains
`installation_unconfirmed`/`cancellation_unconfirmed`, not a claim of rollback.
Graceful restart cancels pending work and invalidates the operator session.
Whole-VM loss keeps the nonce-only pending marker; explicit administrative
deletion is required before a new first enrollment.

## Explicit configuration and exact compiled parent hooks

Parent-owned `gateway/config` must add:

- `OAuthConfig.XaiOAuth(xai/oauth.Config)`, decoded through
  `xai/enrollment.decode_config(raw)`.
- Optional `Account.xai_operations: List(xai/operations.Binding)`, absent `[]`
  preserving existing API-key configuration. Options on other providers fail.
  OAuth requires a nonempty explicit list. Decode with
  `operations.decode(account_id,auth_mode,raw)` and validate through
  `operations.validate_account(account_id,auth_mode,bindings)`.
- `runtime_accounts`: xAI OAuth uses
  `bridge.oauth_policy(settings,enrollment.send)`. No new manager.
- Derive bindings with `operations.runtime_bindings(bindings)` from validated
  account configuration and start **one** runtime via `start_with_bindings`.
  Do not duplicate mutable binding state in `Config`.
- Register each account/model through
  `operations.registration(account_id,auth_mode,bindings,model)`, then union
  per-account auth modes/operations/capabilities for a shared model in root.
  API-key `[]` preserves the existing native API-key registration. Explicit
  bindings advertise only exact model-qualified operations; a Build model with
  proxy Responses plus API Compact advertises Responses only. Compact-only
  normal models advertise Buffer, not Stream/Tools. A model with no qualifying
  configured operation fails. No generic OAuth default, unbound Compact, WS or
  Continuation is advertised.
- Serve HTTP with `adapter.configured_http(resolve,None)`, where `resolve`
  finds the actual selected configured account by Context
  account/provider/auth and calls `operations.select(bindings,context,request)`.
  Map denied selection to a safe `Failure(Unsupported,NotSent,None)`. Existing
  `http`/`selected_http` APIs remain unchanged for their existing callers;
  OAuth does not use their ambient-origin `/v1` factory.
- Before root selects the first account's auth mode, filter through
  `config.admits_operation(account,model,operation)`. An OAuth proxy-Responses-only
  row cannot select the auth partition for a legacy API-key Compact operation.
  Same-operation mixed-auth priority remains configured account order; no
  cross-auth automatic fallback is claimed.
- Existing root private-file administrative import may call
  `enrollment.import_material(settings,raw)` for xAI OAuth. Its exact keys are
  `access_token`, `refresh_token`, `expires_at_ms`, `token_endpoint`. No secret
  is accepted in argv.

No new root UI CLI command is necessary. The worker has not edited root
gateway/config/CLI, shared runtime/store/auth, build files or vendor code.

Source-qualified **illustrative configuration**, not permission for live I/O:

```json
{
  "provider": "xai",
  "auth_mode": "oauth",
  "id": "operator-selected-grok",
  "origin": "https://api.x.ai",
  "models": ["grok-4.7"],
  "oauth": {
    "discovery_url": "https://auth.x.ai/.well-known/openid-configuration"
  },
  "xai_operations": [
    {
      "protocol": "responses",
      "operation": "responses",
      "base": "https://cli-chat-proxy.grok.com/v1",
      "using_api": false
    },
    {
      "protocol": "responses",
      "operation": "responses/compact",
      "base": "https://api.x.ai/v1",
      "using_api": true
    }
  ]
}
```

Each binding is opaque, owned by that account/auth mode, and admits an exact
protocol/operation/origin. Its base must be full canonical `/v1`; never append
twice, fill missing bases, inherit `account.origin` or rewrite an implicit API
base into the proxy. Duplicate operations, extra/missing keys, non-boolean
`using_api`, plaintext non-numeric-loopback, proxy compact, WS/media operations
and unqualified protocol labels fail explicitly before provider I/O. No new
HTTP continuation/tool/media/WS capability is claimed by F07; their owners
must extend this explicit operation boundary with independently qualified
contracts rather than silently infer authority.

`enrollment.send` adapts OAuth Request/Response to existing `replay.send`:
GET discovery with no body, or form POST; explicit URL, only approved headers,
verified TLS or numeric loopback HTTP, bounded transport, no redirect follow,
no ambient proxy and no logging. A 64 KiB OAuth body cap applies after the
existing transport's bounded response allocation. IPv6 is explicitly
unsupported by this transport slice; it is not silently routed elsewhere.

## Source basis and limits

Pinned CPA revision `acdace936fa7df2905500c7f5e0a97d683138dea`, public read-only:

- `internal/auth/xai/xai.go`: OIDC discovery, `client_id` and `scope` device
  form, immediate poll, pending/slow-down, device grant and refresh form,
  validated x.ai TLS endpoints.
- `internal/runtime/executor/xai_executor_request.go`: OAuth `using_api=false`
  CLI proxy HTTP selection; compact independent of proxy; no proxy compact/WS.
- Existing snapshot `docs/xai-source-api-v2.json` records source hashes and
  the limits of the CPA-private OAuth/proxy contract.

The first two immutable source files were read for this slice. Existing
`oauth`/`bridge`/`endpoint` code is reused rather than copying CPA auth logic.
This is not official entitlement evidence or live authorization validation.
Tokens, private device code, verifier, client key and operator capabilities
must never enter browser HTML/status/storage/URL, stdout, logs or capture files.
Only transient operator user codes and configured verification URLs are shown.
Browser privacy assertions use a public synthetic prefix; actual provider/client
credential values are checked outside the browser and are never injected into
it, even for a negative privacy check.

## Bounded executable plan and observed evidence

Toolchain: `mise exec gleam@1.18.1`, `ERL_FLAGS='+S 2:2 +A 2'`.
No heavyweight full suite is requested.

1. After parent root hooks are present, format only F07-owned touched files,
   then one `gleam build` and `gleam run -m account_ui_xai_test`, externally
   capped at 120 seconds. Focused synthetic cases cover selection, persistence,
   rotation, unknown refresh fencing across restart, cancel during
   discovery/start/pending poll/authorized exchange, deadline/session expiry,
   same-token/replacement/delete CAS, session restart and account isolation.
2. `python3 scripts/smoke-account-ui-xai.py`, capped at 180 seconds, exercises
   actual root UI, actual GET/form sockets, configured API/proxy HTTP requests
   using one grant, persisted rotation/restart, unknown refresh outcome,
   cancellation/admin races, expiry, logout/session restart, whole-VM marker,
   provider deletion/client revocation, account isolation and strict inherited
   raw singleton boundaries. `--quick` retains the two-origin/rotation/restart
   core only and does **not** satisfy omitted race/revocation gates.
3. `python3 scripts/smoke-account-ui-xai-browser.py`, capped at 150 seconds,
   if the installed agent-browser/Chrome tools are available. The isolated
   browser clicks the actual served Grok button and verification link, returns
   to observe persisted installation, then requests both configured gateway
   operations. Includes cancel/logout, storage/DOM/token privacy, mobile
   overflow, screenshots, console/errors and axe.
4. Parent shipment smoke runs the same socket harness with
   `--root-command 'PATH_TO_EXPORTED_ERLANG_SHIPMENT_ENTRYPOINT'`. It does not
   replace the shipment with the feature module.
5. Parent independently runs composed F05/F06 regression and root/shipment
   workflow. F44 raw singleton/pipeline and any already-reported composed F05
   cancellation failure remain strict dependencies, not waived fixture passes.

Synthetic artifacts stay under `build/account-ui-f07`.
The fixtures initialize private state inside a per-run temporary directory,
use explicit 127.0.0.1 listeners and scrub outputs.

### Exact composed inputs

The worker's main tree was not given root stubs or locally rewritten parent
contracts. Validation used copied parent source, vendor and pinned dependency
source plus only the 14 F07-owned files, in ignored
`build/account-ui-f07/composed-source-002`. `composed-source-001` is an earlier
source-only receipt, intentionally superseded after root operation admission
was added.

`composed-source-002/composition-inputs.json` contains 1084 individual input
hashes and owner/source paths. Manifest SHA-256 after the trivial test-only
compile corrections:
`597292faf64cbf3884633106dcfbd069fe5d2f3dcc4d923eabb59b22dc0a46c0`.
The additive short browser socket-directory option changed only the browser
harness input; its second-run manifest SHA-256:
`f44df99707d08e29f15365ad5ea49bf197c80560d4e28ed4dc0a04347e99180d`.

Parent root inputs (never rewritten by this worker):

- `src/mimic/gateway.gleam`:
  `532d5b9a6e1d94faa1cdfb4fee6cdbb6adab039f914f5e4d4808268a7814c507`.
- `src/mimic/gateway/config.gleam`:
  `ce60884731a6e89a28d6a20d8e65ee019534b8f0fcbdcb6a064e78d1a9bd3924`.

### Executed commands and results

Commands below ran from that exact composed project, with the stated toolchain
and scheduler flags. Root and browser Python commands were wrapped with an
internal SIGALRM deadline to unwind `finally` cleanup, not left running after
the tool deadline.

| Command | Observed result |
| --- | --- |
| `gleam format` on F07-owned Gleam files | PASS; parent root files were not formatted/rewritten |
| `mise exec gleam@1.18.1 -- gleam build` | PASS after test-only type/branch-return corrections; initial compiler failure retained |
| `mise exec gleam@1.18.1 -- gleam run -m account_ui_xai_test` | 43 PASS: F07 15, parent xAI config/selection 5, coordinator 4, Codex 10, recovered F05 9 |
| `python3 scripts/smoke-account-ui-xai.py` (170-second internal budget) | Full source-root workflow PASS, not `--quick`; device UI/S5/one-manager/configured API+proxy/rotation/unknown refresh/races/restart/revocation/isolation |
| Same socket harness, mixed-auth order permutations | Actual Compact authenticated using legacy API key in both orders; OAuth proxy Responses additionally executed in OAuth-first order; no same-operation cross-auth fallback |
| `python3 scripts/smoke-account-ui-xai-browser.py` first attempt | FAIL before browser navigation; deep composed socket location produced driver open/close failure; original detail was withheld |
| Same browser harness with explicit short `--browser-socket-dir` | FAIL at final `assert not f.errors`, after stored/ended UI, verification, real configured gateway requests, privacy, mobile, console/error and axe assertions; peer failure is not yet classified |
| `python3 scripts/test_smoke_account_ui_xai.py` in corrected snapshot 004 | 2 PASS; exact favicon 204/empty/no credential or OAuth state effect, unknown/query/nonexact routes still fatal |
| Full unchanged browser workflow in corrected snapshot 004 | PASS after the approved exact favicon resource contract; no error/cancellation-close exemptions; all original assertions remain |
| Shipment / independent parent composed workflow / full suite | Not run here; parent-owned |

The source-root workflow observed discovery 14, device 13, poll 20, verification
8, exchange 8, refresh 4, proxy Responses 6 and API Compact 3. These are fixture
boundary counters, not measured upstream behavior or billing. Fresh gateway
reuse of persisted rotation and a durable unknown-refresh reauthorization fence
were tested. No duplicate per-origin grant record or manager was added.

The unchanged recovered F05 entered-poll cancel/admin/delete/store-failure test
passed in this focused run. That result does not waive the earlier parent
cancel-409 report or the separately diagnosed F12 idle downstream-close failure.

### Retained failures and next bounded gate

The inherited reporter `scripts/smoke-account-ui.py:353-406` still observed
duplicate Content-Type cases `equal`, `conflicting-invalid-first` and
`mixed-case-invalid-first` returning **200**, desired **400**, with
`strict_gate:false` unchanged. It sends coalesced `POST /api/status HTTP/1.1`,
body `{}`, `Content-Length: 2`, exact valid loopback Host/Origin and operator
Cookie/CSRF. Duplicate Content-Type fields precede the other valid headers.
Provider sends remained zero, runtime enrollment residue absent, peer EOF
observed. Handler dispatch was **not instrumented**. The parent/vendor owner
owns the coherent raw singleton fix; no UI-only workaround or new exemption
was made here. Strict Origin/CSRF/Cookie/CL/TE cases did close as expected, but
this is not a claim that all HTTP ambiguity gates passed.

The second browser run reached the final peer-error assertion after its other
checks. Retained `axe.json` reports 29 passes, 0 violations, 0 incomplete.
Stored/ended/mobile/waiting screenshots are artifacts, not a passing browser
gate. Its original catcher retained only a generic peer failure label.

A separately granted, one-shot diagnostic run then reproduced and classified
the fatal record: `GET`, fixed route enum `favicon`, role `issuer`, phase
`authorize`, attempt 2/account `none`, branch `get_route_parse`, exception
`ValueError`, classification `unsolicited_browser_route`. Neither cancellation
intent nor confirmation applied to that record. No cancellation closes were
observed; the first UI attempt's cancellation was actually confirmed. All
errors, including classified closes, remained fatal. No fix or waiver was made
during that diagnostic run.

The diagnostic used exact current parent source plus only the two diagnostic
scripts, in `composed-browser-diagnostic-003`, with 1089 individual input hashes.
Manifest SHA-256:
`d1477a0422551d127cb766201ef03711a89ccbf7a40d57f870f3dd98e6bf8ab7`.
Its failed receipt is retained, not overwritten by a later fixture correction.

After that measurement, the parent approved one explicit fixture resource:
issuer `GET /favicon.ico`, exact path with no query, returns **204 with an empty
body before OAuth route/code parsing**. A separate public-resource counter
changes; grants, authorization, refresh, inference and credential state do not.
Every other unknown GET remains fatal. There are no cancellation-close
exemptions. `scripts/test_smoke_account_ui_xai.py` adds a narrow real-loopback
fixture regression for favicon 204/no state change and unknown/query/nonexact
paths remaining fatal; it does not launch BEAM or contact providers.

The parent then granted the corrected validation slot. A fresh exact parent
snapshot plus only the three owned scripts, `composed-favicon-004`, contained
1097 individually hashed inputs. Both the source file set and every source byte
were checked for concurrent import changes before any workload; no retry was
needed. Input manifest SHA-256:
`1d6fea5f6cc15fc7d1293ba32d8a7ffd5a378b9c57cc946ba83a4ec8e3889ecf`.

The two narrow fixture tests passed in 2.070 seconds. One full unchanged browser
workflow then passed, with every `f.errors` entry fatal and no cancellation-close
exemption. The real isolated browser clicked Grok login/cancel/verification,
observed S5 installation, then used both actual configured gateway operations
with one refresh. DOM/storage/bootstrap/cookie privacy, mobile overflow,
console/errors and axe checks passed. Axe reported 29 passes, 0 violations and
0 incomplete checks. The full safe transcript and screenshots are retained in
that snapshot's `build/account-ui-f07/browser-proof`.

Workloads and their `finally` cleanup completed 112 seconds after lock claim.
The subsequent audit found no remaining owned BEAM/browser/driver processes;
lock release was recorded at 184 seconds, four seconds past the 180-second slot,
with no workload continued during that audit delay. This scheduling overrun is
recorded rather than presented as within-budget execution. No further tests
were started. Shipment and independent parent root/security/release admission
remain separate gates.

### Logs and cleanup

Logs under `build/account-ui-f07/logs`:

| Artifact | SHA-256 |
| --- | --- |
| `build-slot-002.log` | `b3164543ac7d5a1149832180c0ebbd881dd16fd3a0a805419efc4da3a192b347` |
| `focused-slot-001.log` | `694e9aed3d40e3de0fb991038ece78db74fa22b7bc329842cacbce7edab2b625` |
| `root-slot-001.log` | `7a606fe1846238d10501a547349d3678f19c509200a3b289aad7857b2687a3db` |
| `browser-slot-001.log` | `17de0e276ed91eafbabd80ff344276549c3d4bc92e8c42ef807dc23e7895cf88` |
| `browser-slot-002.log` | `bad0a4b7d77a872fa1d5534b978ecea6897fcb4be2b6473ddf2c4e210c40fbcd` |
| `browser-diagnostic-slot-003.log` | `d34c02a40cd7565755dfec149b8819d9bb12ad8fffd65ff3b3efc570f9280ebb` |
| `favicon-regression-slot-004.log` | `1ce0f39412f0aefc3a974dd001411065a843c1f8a2f7252dbf9af1b5c9bedef2` |
| `browser-slot-004.log` | `bb6cf0b6d48deda187af706def6bcacfa3ec1a9e8f0111594a36e4608a6d6716` |

The shared validation lock was released. Browser close and all fixture
UI/gateway shutdown `finally` blocks completed; the subsequent process audit
found no remaining composed BEAM pids. No validation or deferred workflow was
left running. Browser artifacts are under the composed project's
`build/account-ui-f07/browser-proof`, inside the attached worktree.
